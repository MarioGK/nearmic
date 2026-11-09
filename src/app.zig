const std = @import("std");
const accel = @import("accel.zig");
const dsp = @import("dsp.zig");
const wav = @import("wav.zig");
const config = @import("config.zig");
const engines = @import("engines.zig");
const options = @import("build_options");

pub const version = "0.2.0";
pub const Mode = config.Mode;

extern fn nm_pw_open(target: [*:0]const u8) c_int;
extern fn nm_pw_close() void;
extern fn nm_pw_last_error() [*:0]const u8;
extern fn nm_pw_node_id() u32;
extern fn nm_in_read(dst: [*]f32, n: u32) u32;
extern fn nm_out_write(src: [*]const f32, n: u32) u32;
extern fn nm_listen_write(src: [*]const f32, n: u32) u32;
extern fn nm_source_streaming() c_int;
extern fn nm_set_listen(enabled: c_int) void;
extern fn nm_underruns() u64;

extern "c" fn dlopen(path: [*:0]const u8, flags: c_int) ?*anyopaque;
extern "c" fn dlclose(handle: *anyopaque) c_int;

pub fn shippedChain() dsp.Chain {
    if (std.mem.eql(u8, options.shipped, "dsp-dereverb")) return dsp.Chain.init(true, true);
    if (std.mem.eql(u8, options.shipped, "leveler")) return dsp.Chain.init(false, false);
    return dsp.Chain.init(true, false);
}

pub fn engineName() []const u8 {
    return options.shipped;
}

const App = struct {
    allocator: std.mem.Allocator,
    alive: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    mode: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(Mode.suppress)),
    listen: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mu: std.Thread.Mutex = .{},
    slot: engines.Slot,
    gain_db: f32 = 0,
    delay_buf: [16384]f32 = .{0} ** 16384,
    delay_pos: usize = 0,
    source_name: [128]u8 = .{0} ** 128,
    source_len: usize = 0,
    config_path: []u8,
    config_mtime: i128 = 0,
    noted_source: [128]u8 = .{0} ** 128,
    noted_len: usize = 0,
    failed_engine: [64]u8 = .{0} ** 64,
    failed_len: usize = 0,
    profile: config.Profile = .desktop,
    thread_request: u32 = 1,
    cpu_budget: f32 = 0.05,
    threads_explicit: bool = false,
    budget_explicit: bool = false,
};

var global_app: ?*App = null;

fn onSignal(_: c_int) callconv(.C) void {
    if (global_app) |app| app.alive.store(false, .release);
}

pub fn socketPath(buf: []u8) ![]const u8 {
    const uid = std.os.linux.getuid();
    return std.fmt.bufPrintZ(buf, "/tmp/nearmic-{d}.sock", .{uid});
}

fn copyName(dst: []u8, src: []const u8) usize {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

fn applyBypass(app: *App, input: []const f32, output: []f32) void {
    const d = app.slot.delaySamples();
    if (d == 0) {
        @memcpy(output, input);
        return;
    }
    for (input, 0..) |x, i| {
        const at = (app.delay_pos + i) % app.delay_buf.len;
        const from = (at + app.delay_buf.len - d) % app.delay_buf.len;
        output[i] = app.delay_buf[from];
        app.delay_buf[at] = x;
    }
    app.delay_pos = (app.delay_pos + input.len) % app.delay_buf.len;
}

fn openOpts(app: *const App) engines.OpenOptions {
    return .{
        .profile = app.profile,
        .threads = app.thread_request,
        .cpu_budget = app.cpu_budget,
    };
}

fn rememberRuntime(app: *App, cfg: config.Config) void {
    app.profile = cfg.profile;
    app.thread_request = cfg.effectiveThreads();
    app.cpu_budget = cfg.effectiveBudget();
    app.threads_explicit = cfg.threads_explicit;
    app.budget_explicit = cfg.budget_explicit;
}

fn runtimeChanged(app: *const App, cfg: config.Config) bool {
    if (app.profile != cfg.profile) return true;
    if (app.thread_request != cfg.effectiveThreads()) return true;
    if (app.threads_explicit != cfg.threads_explicit) return true;
    if (app.budget_explicit != cfg.budget_explicit) return true;
    if (@abs(app.cpu_budget - cfg.effectiveBudget()) > 0.0001) return true;
    return false;
}

/// DSP runs here, on this worker and on the rock profile's pool. The PipeWire
/// callback only copies samples into the ring.
fn worker(app: *App) void {
    const block = dsp.hop;
    var input: [dsp.hop]f32 = undefined;
    var output: [dsp.hop]f32 = undefined;
    var filled: usize = 0;
    while (app.alive.load(.acquire)) {
        if (nm_source_streaming() == 0) {
            std.time.sleep(4 * std.time.ns_per_ms);
            continue;
        }
        const got = nm_in_read(input[filled..].ptr, @intCast(block - filled));
        filled += got;
        if (filled < block) {
            std.time.sleep(std.time.ns_per_ms);
            continue;
        }
        const mode: Mode = @enumFromInt(app.mode.load(.acquire));
        app.mu.lock();
        switch (mode) {
            .mute => {
                applyBypass(app, &input, &output);
                @memset(&output, 0);
            },
            .bypass => applyBypass(app, &input, &output),
            .suppress => app.slot.process(&input, &output),
        }
        const listen = app.listen.load(.acquire);
        app.mu.unlock();
        _ = nm_out_write(&output, block);
        if (listen) _ = nm_listen_write(&output, block);
        filled = 0;
    }
}

fn statusText(allocator: std.mem.Allocator, app: *App) ![]u8 {
    const mode: Mode = @enumFromInt(app.mode.load(.acquire));
    return std.fmt.allocPrint(allocator, "engine={s}\ngain_db={d}\nmode={s}\nlisten={s}\nstreaming={d}\ndelay_samples={d}\nunderruns={d}\nsource={s}\nshipped={s}\nprofile={s}\nthreads={d}\ncpu_budget={d:.2}\nsimd={s}\nnpu_invoked=no\n", .{
        app.slot.name,
        app.gain_db,
        @tagName(mode),
        if (app.listen.load(.acquire)) "on" else "off",
        nm_source_streaming(),
        app.slot.delaySamples(),
        nm_underruns(),
        app.source_name[0..app.source_len],
        engineName(),
        config.profileName(app.profile),
        app.slot.threadsUsed(),
        app.cpu_budget,
        dsp.compiledSimd(),
    });
}

fn persist(app: *App, key: []const u8, rendered: []const u8) void {
    config.patchFile(app.allocator, app.config_path, key, rendered) catch |err| {
        std.debug.print("config write failed: {s}\n", .{@errorName(err)});
        return;
    };
    if (std.fs.cwd().statFile(app.config_path)) |st| app.config_mtime = st.mtime else |_| {}
}

fn swapEngine(app: *App, name: []const u8) bool {
    const avail = engines.availability(name);
    if (!avail.ok) {
        std.debug.print("engine {s}: {s}\n", .{ name, avail.reason });
        return false;
    }
    const opened = engines.open(app.allocator, name, openOpts(app)) catch |err| {
        std.debug.print("engine {s}: {s}\n", .{ name, @errorName(err) });
        return false;
    };
    var fresh = opened;
    fresh.setGainDb(app.gain_db);
    app.mu.lock();
    app.slot.deinit();
    app.slot = fresh;
    app.delay_pos = 0;
    @memset(&app.delay_buf, 0);
    app.mu.unlock();
    app.failed_len = 0;
    return true;
}

fn handleCommand(allocator: std.mem.Allocator, app: *App, line: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, line, " \r\n\t");
    if (std.mem.eql(u8, trimmed, "status") or std.mem.eql(u8, trimmed, "doctor")) {
        return statusText(allocator, app);
    }
    if (std.mem.eql(u8, trimmed, "quit")) {
        app.alive.store(false, .release);
        return allocator.dupe(u8, "stopping\n");
    }
    if (std.mem.startsWith(u8, trimmed, "mode ")) {
        const name = trimmed["mode ".len..];
        const mode = std.meta.stringToEnum(Mode, name) orelse return allocator.dupe(u8, "unknown mode\n");
        app.mode.store(@intFromEnum(mode), .release);
        const rendered = try config.quote(allocator, name);
        defer allocator.free(rendered);
        persist(app, "mode", rendered);
        return std.fmt.allocPrint(allocator, "mode={s}\n", .{name});
    }
    if (std.mem.startsWith(u8, trimmed, "listen ")) {
        const name = trimmed["listen ".len..];
        const on = std.mem.eql(u8, name, "on");
        if (!on and !std.mem.eql(u8, name, "off")) return allocator.dupe(u8, "use listen on or listen off\n");
        app.listen.store(on, .release);
        nm_set_listen(if (on) 1 else 0);
        persist(app, "listen", if (on) "true" else "false");
        if (on) return allocator.dupe(u8, "listen=on\nHeadphones only. Speakers will feed the microphone.\n");
        return allocator.dupe(u8, "listen=off\n");
    }
    if (std.mem.startsWith(u8, trimmed, "engine ")) {
        const name = std.mem.trim(u8, trimmed["engine ".len..], " ");
        if (!swapEngine(app, name)) return allocator.dupe(u8, "engine unchanged\n");
        const rendered = try config.quote(allocator, app.slot.name);
        defer allocator.free(rendered);
        persist(app, "engine", rendered);
        return std.fmt.allocPrint(allocator, "engine={s}\ndelay_samples={d}\n", .{ app.slot.name, app.slot.delaySamples() });
    }
    if (std.mem.startsWith(u8, trimmed, "gain ")) {
        const text = std.mem.trim(u8, trimmed["gain ".len..], " ");
        const value = std.fmt.parseFloat(f32, text) catch return allocator.dupe(u8, "gain must be a number of dB\n");
        if (!std.math.isFinite(value)) return allocator.dupe(u8, "gain must be finite\n");
        app.mu.lock();
        app.gain_db = value;
        app.slot.setGainDb(value);
        app.mu.unlock();
        var buf: [64]u8 = undefined;
        const rendered = std.fmt.bufPrint(&buf, "{d}", .{value}) catch "0";
        persist(app, "gain_db", rendered);
        return std.fmt.allocPrint(allocator, "gain_db={d}\n", .{value});
    }
    return allocator.dupe(u8, "commands: status, mode suppress|bypass|mute, listen on|off, engine NAME, gain DB, quit\n");
}

fn rememberFailure(app: *App, name: []const u8) bool {
    if (std.mem.eql(u8, name, app.failed_engine[0..app.failed_len])) return false;
    app.failed_len = copyName(&app.failed_engine, name);
    return true;
}

fn applyHot(app: *App, cfg: config.Config) void {
    app.mode.store(@intFromEnum(cfg.mode), .release);
    const listen = cfg.listen;
    if (app.listen.load(.acquire) != listen) {
        app.listen.store(listen, .release);
        nm_set_listen(if (listen) 1 else 0);
    }
    if (cfg.gain_db != app.gain_db) {
        app.mu.lock();
        app.gain_db = cfg.gain_db;
        app.slot.setGainDb(cfg.gain_db);
        app.mu.unlock();
    }
    const runtime = runtimeChanged(app, cfg);
    const engine_changed = !std.mem.eql(u8, cfg.engine, app.slot.name);
    const saved_profile = app.profile;
    const saved_threads = app.thread_request;
    const saved_budget = app.cpu_budget;
    const saved_threads_explicit = app.threads_explicit;
    const saved_budget_explicit = app.budget_explicit;
    if (runtime) rememberRuntime(app, cfg);
    if (engine_changed or runtime) {
        const avail = engines.availability(cfg.engine);
        const started = avail.ok and swapEngine(app, cfg.engine);
        if (!started) {
            app.profile = saved_profile;
            app.thread_request = saved_threads;
            app.cpu_budget = saved_budget;
            app.threads_explicit = saved_threads_explicit;
            app.budget_explicit = saved_budget_explicit;
            if (rememberFailure(app, cfg.engine)) {
                if (!avail.ok) {
                    std.debug.print("engine {s}: {s}\n", .{ cfg.engine, avail.reason });
                } else {
                    std.debug.print("engine {s} failed to start\n", .{cfg.engine});
                }
            }
        } else {
            std.debug.print("engine={s} profile={s} threads={d} cpu_budget={d:.2} delay_samples={d}\n", .{
                app.slot.name,
                config.profileName(app.profile),
                app.slot.threadsUsed(),
                app.cpu_budget,
                app.slot.delaySamples(),
            });
        }
    }
    const running = app.source_name[0..app.source_len];
    if (!std.mem.eql(u8, cfg.source, running) and !std.mem.eql(u8, cfg.source, app.noted_source[0..app.noted_len])) {
        std.debug.print("source change applies on restart\n", .{});
        app.noted_len = copyName(&app.noted_source, cfg.source);
    }
}

fn maybeReload(app: *App) void {
    const st = std.fs.cwd().statFile(app.config_path) catch return;
    if (st.mtime == app.config_mtime) return;
    app.config_mtime = st.mtime;
    const text = std.fs.cwd().readFileAlloc(app.allocator, app.config_path, 64 * 1024) catch |err| {
        std.debug.print("config.toml: {s}\n", .{@errorName(err)});
        return;
    };
    defer app.allocator.free(text);
    const source_copy = app.allocator.dupe(u8, app.source_name[0..app.source_len]) catch return;
    const engine_copy = app.allocator.dupe(u8, app.slot.name) catch {
        app.allocator.free(source_copy);
        return;
    };
    var prev = config.Config{
        .source = source_copy,
        .mode = @enumFromInt(app.mode.load(.acquire)),
        .listen = app.listen.load(.acquire),
        .engine = engine_copy,
        .gain_db = app.gain_db,
        .profile = app.profile,
        .threads = app.thread_request,
        .cpu_budget = app.cpu_budget,
        .threads_explicit = app.threads_explicit,
        .budget_explicit = app.budget_explicit,
        .allocator = app.allocator,
    };
    const loaded = config.loadKeeping(app.allocator, &prev, text) catch |err| {
        prev.deinit();
        std.debug.print("config.toml: {s}\nkeeping the previous config\n", .{@errorName(err)});
        return;
    };
    switch (loaded) {
        .err => |msg| {
            prev.deinit();
            std.debug.print("{s}\nkeeping the previous config\n", .{msg});
            app.allocator.free(msg);
        },
        .ok => |cfg| {
            var live = cfg;
            defer live.deinit();
            applyHot(app, live);
        },
    }
}

fn serve(app: *App, server: std.posix.socket_t) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    while (app.alive.load(.acquire)) {
        var fds = [_]std.posix.pollfd{.{
            .fd = server,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const n = std.posix.poll(&fds, 200) catch continue;
        maybeReload(app);
        if (n == 0) continue;
        const client = std.posix.accept(server, null, null, 0) catch continue;
        defer std.posix.close(client);
        var buf: [256]u8 = undefined;
        const got = std.posix.read(client, &buf) catch continue;
        _ = arena.reset(.retain_capacity);
        const reply = handleCommand(arena.allocator(), app, buf[0..got]) catch continue;
        _ = std.posix.write(client, reply) catch {};
    }
}

fn runWpctl(allocator: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    const res = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    }) catch return null;
    allocator.free(res.stderr);
    switch (res.term) {
        .Exited => |code| if (code != 0) {
            allocator.free(res.stdout);
            return null;
        },
        else => {
            allocator.free(res.stdout);
            return null;
        },
    }
    return res.stdout;
}

fn nodeName(allocator: std.mem.Allocator, id: []const u8) ?[]u8 {
    const text = runWpctl(allocator, &.{ "wpctl", "inspect", id }) orelse return null;
    defer allocator.free(text);
    const key = "node.name = \"";
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    if (end == 0) return null;
    return allocator.dupe(u8, rest[0..end]) catch null;
}

const SourcePick = struct { id: []const u8, starred: bool };

fn sourcePicks(text: []const u8, out: []SourcePick) usize {
    var in_sources = false;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "Sources:")) |_| {
            in_sources = true;
            continue;
        }
        if (!in_sources) continue;
        if (std.mem.indexOf(u8, line, "Source endpoints:") != null or std.mem.indexOf(u8, line, "Streams:") != null) break;
        var i: usize = 0;
        while (i < line.len and !std.ascii.isDigit(line[i])) : (i += 1) {}
        if (i == line.len) continue;
        const start = i;
        while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
        if (i == line.len or line[i] != '.') continue;
        if (n < out.len) {
            out[n] = .{ .id = line[start..i], .starred = std.mem.indexOfScalar(u8, line, '*') != null };
            n += 1;
        }
    }
    return n;
}

fn rememberSource(app: *App, name: []const u8) void {
    if (name.len == 0 or std.mem.eql(u8, name, "nearmic")) return;
    const n = @min(name.len, app.source_name.len - 1);
    @memcpy(app.source_name[0..n], name[0..n]);
    app.source_len = n;
    app.source_name[n] = 0;
}

fn chooseCaptureTarget(allocator: std.mem.Allocator, app: *App) void {
    if (app.source_len != 0) return;
    const status = runWpctl(allocator, &.{ "wpctl", "status" }) orelse return;
    defer allocator.free(status);
    var picks: [16]SourcePick = undefined;
    const n = sourcePicks(status, &picks);
    var fallback: ?[]u8 = null;
    defer if (fallback) |name| allocator.free(name);
    for (picks[0..n]) |pick| {
        const name = nodeName(allocator, pick.id) orelse continue;
        if (std.mem.eql(u8, name, "nearmic")) {
            allocator.free(name);
            continue;
        }
        if (pick.starred) {
            rememberSource(app, name);
            allocator.free(name);
            return;
        }
        if (fallback == null) fallback = name else allocator.free(name);
    }
    if (fallback) |name| rememberSource(app, name);
}

fn previousDefault(allocator: std.mem.Allocator) ?[]u8 {
    const res = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "wpctl", "status" },
    }) catch return null;
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    var in_sources = false;
    var it = std.mem.splitScalar(u8, res.stdout, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "Sources:")) |_| {
            in_sources = true;
            continue;
        }
        if (!in_sources) continue;
        if (std.mem.indexOf(u8, line, "Sinks:") != null or std.mem.indexOf(u8, line, "Filters:") != null) break;
        if (std.mem.indexOfScalar(u8, line, '*')) |_| {
            var tok = std.mem.tokenizeAny(u8, line, " \t.*");
            if (tok.next()) |id| return allocator.dupe(u8, id) catch null;
        }
    }
    return null;
}

fn setDefault(allocator: std.mem.Allocator, id: []const u8) void {
    const res = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "wpctl", "set-default", id },
    }) catch return;
    allocator.free(res.stdout);
    allocator.free(res.stderr);
}

pub fn runDaemon(allocator: std.mem.Allocator) !void {
    var cfg = try config.loadUser(allocator);
    defer cfg.deinit();
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const config_path = try config.configPath(allocator, home);
    var app = App{
        .allocator = allocator,
        .slot = undefined,
        .gain_db = cfg.gain_db,
        .config_path = config_path,
    };
    rememberRuntime(&app, cfg);
    var slot = engines.open(allocator, cfg.engine, openOpts(&app)) catch blk: {
        const avail = engines.availability(cfg.engine);
        std.debug.print("engine {s}: {s}\nfalling back to dsp-dereverb\n", .{ cfg.engine, avail.reason });
        break :blk try engines.open(allocator, "dsp-dereverb", openOpts(&app));
    };
    slot.setGainDb(cfg.gain_db);
    app.slot = slot;
    app.mode.store(@intFromEnum(cfg.mode), .release);
    app.listen.store(cfg.listen, .release);
    if (cfg.source.len != 0) rememberSource(&app, cfg.source);
    if (std.fs.cwd().statFile(config_path)) |st| app.config_mtime = st.mtime else |_| {}
    defer {
        app.slot.deinit();
        allocator.free(app.config_path);
    }

    chooseCaptureTarget(allocator, &app);
    global_app = &app;
    defer global_app = null;
    var act = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);

    var path_buf: [128]u8 = undefined;
    const path = try socketPath(&path_buf);
    if (daemonListening(path)) {
        std.debug.print("NearMic is already running\n", .{});
        return;
    }
    std.posix.unlink(path) catch {};
    const server = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(server);
    var addr = std.mem.zeroes(std.posix.sockaddr.un);
    addr.family = std.posix.AF.UNIX;
    @memcpy(addr.path[0..path.len], path);
    std.posix.bind(server, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch |err| {
        if (err == error.AddressInUse) {
            std.debug.print("NearMic is already running\n", .{});
            return;
        }
        return err;
    };
    try std.posix.listen(server, 4);
    defer std.posix.unlink(path) catch {};

    var target_buf: [128:0]u8 = .{0} ** 128;
    @memcpy(target_buf[0..app.source_len], app.source_name[0..app.source_len]);
    if (nm_pw_open(&target_buf) != 0) {
        std.debug.print("{s}\n", .{std.mem.span(nm_pw_last_error())});
        return error.PipeWire;
    }
    defer nm_pw_close();
    if (app.listen.load(.acquire)) nm_set_listen(1);

    const thread = try std.Thread.spawn(.{}, worker, .{&app});
    defer {
        app.alive.store(false, .release);
        thread.join();
    }

    var id_buf: [16]u8 = undefined;
    var waited: usize = 0;
    while (waited < 50 and nm_pw_node_id() == 0) : (waited += 1) std.time.sleep(20 * std.time.ns_per_ms);
    const node = nm_pw_node_id();
    const node_text = std.fmt.bufPrint(&id_buf, "{d}", .{node}) catch "";
    const restore = if (std.posix.getenv("NEARMIC_NO_DEFAULT") == null) previousDefault(allocator) else null;
    defer if (restore) |id| allocator.free(id);
    if (node != 0 and std.posix.getenv("NEARMIC_NO_DEFAULT") == null) setDefault(allocator, node_text);

    const hw = accel.probe();
    std.debug.print("NearMic {s} is running ({s}, {d} sample delay, profile {s}, {d} dsp threads, cpu budget {d:.2}, simd {s}). Pick NearMic as the microphone.\n", .{
        version,
        app.slot.name,
        app.slot.delaySamples(),
        config.profileName(app.profile),
        app.slot.threadsUsed(),
        app.cpu_budget,
        hw.simd,
    });
    if (app.profile == .rock_pi_plus) {
        std.debug.print("ROCK 4 Plus path: multithreaded CPU/{s}. NPU invoked: no. OpenCL detected: {s}.\n", .{
            hw.simd,
            if (hw.opencl) "yes" else "no",
        });
    }
    if (restore) |id| {
        defer setDefault(allocator, id);
        serve(&app, server);
    } else serve(&app, server);
}

fn daemonListening(path: []const u8) bool {
    const sock = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch return false;
    defer std.posix.close(sock);
    var addr = std.mem.zeroes(std.posix.sockaddr.un);
    addr.family = std.posix.AF.UNIX;
    @memcpy(addr.path[0..path.len], path);
    std.posix.connect(sock, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch return false;
    return true;
}

pub fn sendCommand(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    var path_buf: [128]u8 = undefined;
    const path = try socketPath(&path_buf);
    const sock = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);
    var addr = std.mem.zeroes(std.posix.sockaddr.un);
    addr.family = std.posix.AF.UNIX;
    @memcpy(addr.path[0..path.len], path);
    std.posix.connect(sock, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch {
        return error.NotRunning;
    };
    _ = try std.posix.write(sock, line);
    _ = try std.posix.write(sock, "\n");
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();
    var buf: [512]u8 = undefined;
    while (list.items.len < 4096) {
        const n = std.posix.read(sock, &buf) catch return error.NotRunning;
        if (n == 0) break;
        try list.appendSlice(buf[0..n]);
    }
    return list.toOwnedSlice();
}

pub fn enhance(allocator: std.mem.Allocator, in_path: []const u8, out_path: []const u8) !void {
    var cfg = try config.loadUser(allocator);
    defer cfg.deinit();
    var pcm = try wav.readWav(allocator, in_path);
    defer pcm.deinit();
    const n = pcm.samples.len - (pcm.samples.len % dsp.hop);
    if (n == 0) return error.TooShort;
    var slot = engines.open(allocator, cfg.engine, .{
        .profile = cfg.profile,
        .threads = cfg.effectiveThreads(),
        .cpu_budget = cfg.effectiveBudget(),
    }) catch {
        const avail = engines.availability(cfg.engine);
        std.debug.print("engine {s}: {s}\n", .{ cfg.engine, avail.reason });
        return error.Unavailable;
    };
    defer slot.deinit();
    slot.setGainDb(cfg.gain_db);
    const output = try allocator.alloc(f32, n);
    defer allocator.free(output);
    var offset: usize = 0;
    while (offset < n) : (offset += dsp.hop) {
        slot.process(pcm.samples[offset..][0..dsp.hop], output[offset..][0..dsp.hop]);
    }
    try wav.writeWav(out_path, output);
    std.debug.print("wrote {s} ({d} samples, engine {s})\n", .{ out_path, n, slot.name });
}

pub fn pipewireLibraryPresent() bool {
    const names = [_][:0]const u8{ "libpipewire-0.3.so.0", "libpipewire-0.3.so.2", "libpipewire-0.3.so" };
    for (names) |name| {
        const handle = dlopen(name, 2) orelse continue;
        _ = dlclose(handle);
        return true;
    }
    return false;
}
