const std = @import("std");
const accel = @import("accel.zig");
const bench = @import("bench.zig");
const config = @import("config.zig");
const dsp = @import("dsp.zig");
const engines = @import("engines.zig");
const rock = @import("rock.zig");

extern "c" fn sysconf(name: c_int) c_long;
const sc_clk_tck: c_int = 2;

fn isCore(name: []const u8) bool {
    return std.mem.eql(u8, name, "leveler") or
        std.mem.eql(u8, name, "dsp") or
        std.mem.eql(u8, name, "dsp-dereverb") or
        std.mem.eql(u8, name, "speex-dereverb");
}

fn allFinite(samples: []const f32) bool {
    for (samples) |sample| if (!std.math.isFinite(sample)) return false;
    return true;
}

pub fn run(allocator: std.mem.Allocator) !u8 {
    const stdout = std.io.getStdOut().writer();
    var far = try bench.makeFarMic(allocator);
    defer far.deinit();
    const n = far.samples.len - (far.samples.len % dsp.hop);
    var failures: usize = 0;
    for (engines.catalog) |spec| {
        const avail = engines.availability(spec.name);
        if (!avail.ok) {
            try stdout.print("{s:<22} SKIP  {s}\n", .{ spec.name, avail.reason });
            continue;
        }
        var slot = engines.open(allocator, spec.name, .{}) catch |err| {
            try stdout.print("{s:<22} {s}  {s}\n", .{ spec.name, if (isCore(spec.name)) "FAIL" else "SKIP", @errorName(err) });
            if (isCore(spec.name)) failures += 1;
            continue;
        };
        defer slot.deinit();
        slot.setGainDb(0);
        const output = try allocator.alloc(f32, n);
        defer allocator.free(output);
        var offset: usize = 0;
        while (offset < n) : (offset += dsp.hop) {
            slot.process(far.samples[offset..][0..dsp.hop], output[offset..][0..dsp.hop]);
        }
        const finite = allFinite(output);
        if (std.mem.eql(u8, spec.name, "dsp-dereverb")) {
            const gate = bench.loudnessGate(far, output, slot.delaySamples());
            if (!finite or !gate.ok) {
                failures += 1;
                try stdout.print("{s:<22} FAIL  speech {d:.1} dBFS pause {d:.1} dBFS (pause in {d:.1})\n", .{
                    spec.name, gate.speech_db, gate.pause_out_db, gate.pause_in_db,
                });
            } else {
                try stdout.print("{s:<22} pass  speech {d:.1} dBFS pause {d:.1} dBFS\n", .{
                    spec.name, gate.speech_db, gate.pause_out_db,
                });
            }
            continue;
        }
        if (isCore(spec.name) and !finite) {
            failures += 1;
            try stdout.print("{s:<22} FAIL  non-finite audio\n", .{spec.name});
            continue;
        }
        if (!finite) {
            try stdout.print("{s:<22} pass  non-finite samples are not a gate for this engine\n", .{spec.name});
        } else {
            try stdout.print("{s:<22} pass  finite\n", .{spec.name});
        }
    }
    failures += try rockProfile(allocator, stdout);
    if (failures != 0) {
        try stdout.print("{d} failure(s)\n", .{failures});
        return 1;
    }
    try stdout.print("qa passed\n", .{});
    return 0;
}

fn procCpuSeconds() !f64 {
    const text = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, "/proc/self/stat", 1 << 16);
    defer std.heap.page_allocator.free(text);
    const paren = std.mem.lastIndexOfScalar(u8, text, ')') orelse return error.BadStat;
    var it = std.mem.tokenizeScalar(u8, text[paren + 1 ..], ' ');
    var field: usize = 0;
    var utime: u64 = 0;
    var stime: u64 = 0;
    while (it.next()) |tok| {
        field += 1;
        if (field == 12) utime = try std.fmt.parseInt(u64, tok, 10);
        if (field == 13) {
            stime = try std.fmt.parseInt(u64, tok, 10);
            break;
        }
    }
    const ticks = sysconf(sc_clk_tck);
    return @as(f64, @floatFromInt(utime + stime)) / @as(f64, @floatFromInt(ticks));
}

fn percentile(times: []u64) u64 {
    if (times.len == 0) return 0;
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    var idx: usize = @intFromFloat(@floor(0.99 * @as(f64, @floatFromInt(times.len - 1))));
    if (idx >= times.len) idx = times.len - 1;
    return times[idx];
}

fn rockProfile(allocator: std.mem.Allocator, stdout: anytype) !usize {
    const loaded = try config.load(allocator, "profile = \"rock-pi-plus\"\n");
    const cfg = switch (loaded) {
        .err => |msg| {
            defer allocator.free(msg);
            try stdout.print("rock-pi-plus          FAIL  {s}\n", .{msg});
            return 1;
        },
        .ok => |item| item,
    };
    defer {
        var live = cfg;
        live.deinit();
    }
    const threads = rock.resolveThreads(cfg.effectiveThreads());
    const budget = cfg.effectiveBudget();
    const budget_ok = @abs(budget - 0.90) < 0.001;
    if (!(threads > 1 and budget_ok and cfg.profile == .rock_pi_plus)) {
        try stdout.print("rock-pi-plus          FAIL  threads={d} budget={d:.2}\n", .{ threads, budget });
        return 1;
    }
    var slot = engines.open(allocator, "dsp-dereverb", .{
        .profile = cfg.profile,
        .threads = cfg.effectiveThreads(),
        .cpu_budget = budget,
    }) catch |err| {
        try stdout.print("rock-pi-plus          FAIL  {s}\n", .{@errorName(err)});
        return 1;
    };
    defer slot.deinit();
    if (slot.threadsUsed() <= 1) {
        try stdout.print("rock-pi-plus          FAIL  engine threads={d}\n", .{slot.threadsUsed()});
        return 1;
    }
    var far = try bench.makeFarMic(allocator);
    defer far.deinit();
    const n = far.samples.len - (far.samples.len % dsp.hop);
    const output = try allocator.alloc(f32, n);
    defer allocator.free(output);
    var times = std.ArrayList(u64).init(allocator);
    defer times.deinit();
    var warmup: usize = 0;
    while (warmup < 8) : (warmup += 1) {
        slot.process(far.samples[0..dsp.hop], output[0..dsp.hop]);
    }
    var timer = try std.time.Timer.start();
    var offset: usize = 0;
    while (offset < n) : (offset += dsp.hop) {
        timer.reset();
        slot.process(far.samples[offset..][0..dsp.hop], output[offset..][0..dsp.hop]);
        try times.append(timer.read());
    }
    const finite = allFinite(output);
    const gate = bench.loudnessGate(far, output, slot.delaySamples());
    const cpu0 = try procCpuSeconds();
    var audio_samples: usize = 0;
    const wall0 = std.time.nanoTimestamp();
    while (std.time.nanoTimestamp() - wall0 < 800_000_000) {
        offset = 0;
        while (offset < n) : (offset += dsp.hop) {
            slot.process(far.samples[offset..][0..dsp.hop], output[offset..][0..dsp.hop]);
        }
        audio_samples += n;
    }
    const cpu1 = try procCpuSeconds();
    const audio_seconds = @as(f64, @floatFromInt(audio_samples)) / 48000.0;
    const cores: f64 = @floatFromInt(try std.Thread.getCpuCount());
    const cpu = (cpu1 - cpu0) / audio_seconds / cores;
    const p99_ms = @as(f64, @floatFromInt(percentile(times.items))) / 1e6;
    const block_ms = @as(f64, @floatFromInt(dsp.hop)) / 48.0;
    const realtime = p99_ms < block_ms;
    const within_budget = cpu <= 0.90;
    const hw = accel.probe();
    const ok = finite and gate.ok and realtime and within_budget and !hw.npu_invoked;
    try stdout.print("rock-pi-plus          {s}  threads={d} budget={d:.2} cpu={d:.4} p99={d:.3} ms block={d:.3} ms speech={d:.1} dBFS pause={d:.1} dBFS\n", .{
        if (ok) "pass" else "FAIL",
        slot.threadsUsed(),
        budget,
        cpu,
        p99_ms,
        block_ms,
        gate.speech_db,
        gate.pause_out_db,
    });
    try stdout.writeAll("accel                 ");
    try accel.write(stdout, hw);
    if (!ok) return 1;
    return 0;
}
