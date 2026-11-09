const std = @import("std");
const dsp = @import("dsp.zig");
const wav = @import("wav.zig");
const options = @import("build_options");

pub const version = "0.1.0";

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

pub const Mode = enum(u8) { suppress, bypass, mute };

pub fn shippedChain() dsp.Chain {
    if (std.mem.eql(u8, options.shipped, "dsp-dereverb")) return dsp.Chain.init(true, true);
    if (std.mem.eql(u8, options.shipped, "leveler")) return dsp.Chain.init(false, false);
    return dsp.Chain.init(true, false);
}

pub fn engineName() []const u8 {
    return options.shipped;
}

const App = struct {
    alive: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    mode: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(Mode.suppress)),
    listen: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    chain: dsp.Chain,
    delay_buf: [8192]f32 = .{0} ** 8192,
    delay_pos: usize = 0,
    source_name: [128]u8 = .{0} ** 128,
    source_len: usize = 0,
};

var global_app: ?*App = null;

fn onSignal(_: c_int) callconv(.C) void {
    if (global_app) |app| app.alive.store(false, .release);
}

pub fn socketPath(buf: []u8) ![]const u8 {
    const uid = std.os.linux.getuid();
    return std.fmt.bufPrintZ(buf, "/tmp/nearmic-{d}.sock", .{uid});
}

fn configDir(allocator: std.mem.Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    return std.fmt.allocPrint(allocator, "{s}/.config/nearmic", .{home});
}

fn loadConfig(allocator: std.mem.Allocator, app: *App) !void {
    const dir = try configDir(allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/config", .{dir});
    defer allocator.free(path);
    const text = std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024) catch return;
    defer allocator.free(text);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "source")) {
            const n = @min(value.len, app.source_name.len - 1);
            @memcpy(app.source_name[0..n], value[0..n]);
            app.source_len = n;
            app.source_name[n] = 0;
        } else if (std.mem.eql(u8, key, "mode")) {
            if (std.meta.stringToEnum(Mode, value)) |m| app.mode.store(@intFromEnum(m), .release);
        } else if (std.mem.eql(u8, key, "listen")) {
            app.listen.store(std.mem.eql(u8, value, "on"), .release);
        }
    }
}

fn saveMode(allocator: std.mem.Allocator, app: *App) void {
    const dir = configDir(allocator) catch return;
    defer allocator.free(dir);
    std.fs.cwd().makePath(dir) catch return;
    const path = std.fmt.allocPrint(allocator, "{s}/config", .{dir}) catch return;
    defer allocator.free(path);
    const mode = @as(Mode, @enumFromInt(app.mode.load(.acquire)));
    const listen: []const u8 = if (app.listen.load(.acquire)) "on" else "off";
    const source = app.source_name[0..app.source_len];
    const body = std.fmt.allocPrint(allocator, "source={s}\nmode={s}\nlisten={s}\n", .{ source, @tagName(mode), listen }) catch return;
    defer allocator.free(body);
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = body }) catch return;
}

fn applyBypass(app: *App, input: []const f32, output: []f32) void {
    const d = app.chain.delaySamples();
    for (input, 0..) |x, i| {
        const at = (app.delay_pos + i) % app.delay_buf.len;
        const from = (at + app.delay_buf.len - d) % app.delay_buf.len;
        output[i] = if (d == 0) x else app.delay_buf[from];
        app.delay_buf[at] = x;
    }
    app.delay_pos = (app.delay_pos + input.len) % app.delay_buf.len;
}

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
        switch (mode) {
            .mute => @memset(&output, 0),
            .bypass => applyBypass(app, &input, &output),
            .suppress => app.chain.process(&input, &output),
        }
        _ = nm_out_write(&output, block);
        if (app.listen.load(.acquire)) _ = nm_listen_write(&output, block);
        filled = 0;
    }
}

fn statusText(allocator: std.mem.Allocator, app: *App) ![]u8 {
    const mode: Mode = @enumFromInt(app.mode.load(.acquire));
    return std.fmt.allocPrint(allocator, "engine={s}\nmode={s}\nlisten={s}\nstreaming={d}\ndelay_samples={d}\nunderruns={d}\nsource={s}\n", .{
        engineName(),
        @tagName(mode),
        if (app.listen.load(.acquire)) "on" else "off",
        nm_source_streaming(),
        app.chain.delaySamples(),
        nm_underruns(),
        app.source_name[0..app.source_len],
    });
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
        saveMode(allocator, app);
        return std.fmt.allocPrint(allocator, "mode={s}\n", .{name});
    }
    if (std.mem.startsWith(u8, trimmed, "listen ")) {
        const name = trimmed["listen ".len..];
        const on = std.mem.eql(u8, name, "on");
        if (!on and !std.mem.eql(u8, name, "off")) return allocator.dupe(u8, "use listen on or listen off\n");
        app.listen.store(on, .release);
        nm_set_listen(if (on) 1 else 0);
        saveMode(allocator, app);
        if (on) return allocator.dupe(u8, "listen=on\nHeadphones only. Speakers will feed the microphone.\n");
        return allocator.dupe(u8, "listen=off\n");
    }
    return allocator.dupe(u8, "commands: status, mode suppress|bypass|mute, listen on|off, quit\n");
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
    var app = App{ .chain = shippedChain() };
    try loadConfig(allocator, &app);
    chooseCaptureTarget(allocator, &app);
    global_app = &app;
    var act = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);

    var path_buf: [128]u8 = undefined;
    const path = try socketPath(&path_buf);
    std.posix.unlink(path) catch {};
    const server = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(server);
    var addr = std.mem.zeroes(std.posix.sockaddr.un);
    addr.family = std.posix.AF.UNIX;
    @memcpy(addr.path[0..path.len], path);
    try std.posix.bind(server, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));
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
    defer if (restore) |id| {
        allocator.free(id);
    };
    if (node != 0 and std.posix.getenv("NEARMIC_NO_DEFAULT") == null) setDefault(allocator, node_text);

    std.debug.print("NearMic {s} is running ({s}, {d} sample delay). Pick NearMic as the microphone.\n", .{
        version,
        engineName(),
        app.chain.delaySamples(),
    });
    if (restore) |id| {
        defer setDefault(allocator, id);
        serve(&app, server);
    } else {
        serve(&app, server);
    }
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
    var pcm = try wav.readWav(allocator, in_path);
    defer pcm.deinit();
    const n = pcm.samples.len - (pcm.samples.len % dsp.hop);
    if (n == 0) return error.TooShort;
    const output = try allocator.alloc(f32, n);
    defer allocator.free(output);
    var chain = shippedChain();
    chain.process(pcm.samples[0..n], output);
    try wav.writeWav(out_path, output);
    std.debug.print("wrote {s} ({d} samples, engine {s})\n", .{ out_path, n, engineName() });
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
