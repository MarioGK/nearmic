const std = @import("std");
const dsp = @import("dsp.zig");
const options = @import("build_options");

extern "c" fn sysconf(name: c_int) c_long;
const sc_clk_tck: c_int = 2;

const Engine = struct {
    name: []const u8,
    block: usize,
    delay: usize,
    ctx: *anyopaque,
    deinit: *const fn (*anyopaque) void,
    process: *const fn (*anyopaque, []const f32, []f32) void,
    linear: *const fn (*anyopaque, []const f32, []f32) void,
    passes_cpu: bool = false,
};

const Row = struct {
    name: []const u8,
    cpu: f64,
    p99_ms: f64,
    block_ms: f64,
    delay_ms: f64,
    speech_db: f32,
    loud_err: f32,
    pause_in_db: f32,
    pause_out_db: f32,
    tail_ratio: f32,
    tail_raw: f32,
    pass: bool,
};

pub const Fixture = struct {
    samples: []f32,
    speech: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Fixture) void {
        self.allocator.free(self.samples);
        self.allocator.free(self.speech);
    }
};

pub fn makeFarMic(allocator: std.mem.Allocator) !Fixture {
    const n: usize = 48000 * 4;
    const samples = try allocator.alloc(f32, n);
    const speech = try allocator.alloc(u8, n);
    @memset(samples, 0);
    @memset(speech, 0);
    var rng = std.Random.DefaultPrng.init(42);
    const rand = rng.random();
    var t: usize = 0;
    while (t < n) : (t += 1) {
        const noise: f32 = (rand.float(f32) * 2 - 1) * 0.004;
        samples[t] = noise;
        const sec = @as(f32, @floatFromInt(t)) / 48000;
        if (sec < 0.35 or sec > 3.6) continue;
        const cycle = (sec - 0.35) / 0.32;
        const frac = cycle - @floor(cycle);
        if (frac < 0.62) {
            const env = @sin(std.math.pi * frac / 0.62);
            var tone: f32 = 0;
            const harmonics = [_]f32{ 170, 340, 510, 760, 1200 };
            for (harmonics, 0..) |f, i| {
                const amp: f32 = 0.045 / @as(f32, @floatFromInt(i + 1));
                tone += amp * @sin(2 * std.math.pi * f * @as(f32, @floatFromInt(t)) / 48000);
            }
            samples[t] += tone * env;
            speech[t] = 1;
        }
    }
    const dry = try allocator.dupe(f32, samples);
    defer allocator.free(dry);
    const echoes = [_]struct { delay: usize, gain: f32 }{
        .{ .delay = 1200, .gain = 0.55 },
        .{ .delay = 2600, .gain = 0.35 },
        .{ .delay = 4800, .gain = 0.22 },
    };
    for (echoes) |echo| {
        var i = echo.delay;
        while (i < n) : (i += 1) samples[i] += echo.gain * dry[i - echo.delay];
    }
    return .{ .samples = samples, .speech = speech, .allocator = allocator };
}

pub fn makeImpulse(allocator: std.mem.Allocator) ![]f32 {
    const n: usize = dsp.hop * 48;
    const samples = try allocator.alloc(f32, n);
    @memset(samples, 0);
    samples[0] = 1;
    samples[2400] = 0.7;
    samples[4800] = 0.45;
    return samples;
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

fn percentile(times: []u64, p: f64) u64 {
    if (times.len == 0) return 0;
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    var idx: usize = @intFromFloat(@floor(p * @as(f64, @floatFromInt(times.len - 1))));
    if (idx >= times.len) idx = times.len - 1;
    return times[idx];
}

fn maskedRms(samples: []const f32, mask: []const u8, want: u8, skip: usize) f32 {
    var acc: f32 = 0;
    var n: usize = 0;
    for (samples, mask, 0..) |s, m, i| {
        if (i < skip or m != want) continue;
        acc += s * s;
        n += 1;
    }
    if (n == 0) return 0;
    return @sqrt(acc / @as(f32, @floatFromInt(n)));
}

fn tailRatio(samples: []const f32, delay: usize) f32 {
    if (delay >= samples.len) return 1;
    const peak_at = delay;
    const early_end = @min(samples.len, peak_at + 800);
    const late_start = peak_at + 2000;
    const late_end = @min(samples.len, peak_at + 7000);
    if (late_end <= late_start or early_end <= peak_at) return 1;
    const early = dsp.rms(samples[peak_at..early_end]);
    const late = dsp.rms(samples[late_start..late_end]);
    if (early < 1e-8) return 1;
    return late / early;
}

const ZigCtx = struct { chain: dsp.Chain };

fn zigDeinit(ptr: *anyopaque) void {
    _ = ptr;
}

fn zigProcess(ptr: *anyopaque, in: []const f32, out: []f32) void {
    const ctx: *ZigCtx = @ptrCast(@alignCast(ptr));
    ctx.chain.process(in, out);
}

fn zigLinear(ptr: *anyopaque, in: []const f32, out: []f32) void {
    const ctx: *ZigCtx = @ptrCast(@alignCast(ptr));
    ctx.chain.processLinear(in, out);
}

const SpeexCtx = struct {
    eng: *SpeexEng,
    leveler: dsp.Chain,
    pending_in: [3840]f32 = undefined,
    pending_n: usize = 0,
};

const SpeexEng = opaque {};
extern fn speex_eng_new(dereverb: c_int) ?*SpeexEng;
extern fn speex_eng_free(eng: ?*SpeexEng) void;
extern fn speex_eng_frame() c_int;
extern fn speex_eng_process(eng: *SpeexEng, in: [*]const f32, out: [*]f32) void;

fn speexDeinit(ptr: *anyopaque) void {
    const ctx: *SpeexCtx = @ptrCast(@alignCast(ptr));
    speex_eng_free(ctx.eng);
}

fn speexCore(ctx: *SpeexCtx, in: []const f32, mid: []f32) void {
    var f: usize = 0;
    while (f + 480 <= in.len) : (f += 480) {
        speex_eng_process(ctx.eng, in[f..][0..480].ptr, mid[f..][0..480].ptr);
    }
}

fn speexProcess(ptr: *anyopaque, in: []const f32, out: []f32) void {
    const ctx: *SpeexCtx = @ptrCast(@alignCast(ptr));
    var mid: [3840]f32 = undefined;
    speexCore(ctx, in, &mid);
    const n = in.len - (in.len % dsp.hop);
    ctx.leveler.process(mid[0..n], out[0..n]);
}

fn speexLinear(ptr: *anyopaque, in: []const f32, out: []f32) void {
    const ctx: *SpeexCtx = @ptrCast(@alignCast(ptr));
    speexCore(ctx, in, out);
}

fn measure(allocator: std.mem.Allocator, engine: *Engine, far: Fixture, impulse: []const f32, raw_tail: f32) !Row {
    const n = far.samples.len - (far.samples.len % engine.block);
    const output = try allocator.alloc(f32, n);
    defer allocator.free(output);
    var times = std.ArrayList(u64).init(allocator);
    defer times.deinit();

    const imp_len = impulse.len - (impulse.len % engine.block);
    const imp_out = try allocator.alloc(f32, imp_len);
    defer allocator.free(imp_out);
    var offset: usize = 0;
    while (offset < imp_len) : (offset += engine.block) {
        engine.linear(engine.ctx, impulse[offset .. offset + engine.block], imp_out[offset .. offset + engine.block]);
    }
    const tail = tailRatio(imp_out, engine.delay);

    var timer = try std.time.Timer.start();
    offset = 0;
    while (offset < n) : (offset += engine.block) {
        timer.reset();
        engine.process(engine.ctx, far.samples[offset .. offset + engine.block], output[offset .. offset + engine.block]);
        try times.append(timer.read());
    }

    const cpu0 = try procCpuSeconds();
    var audio_samples: usize = 0;
    const wall0 = std.time.nanoTimestamp();
    while (std.time.nanoTimestamp() - wall0 < 1_200_000_000) {
        offset = 0;
        while (offset < n) : (offset += engine.block) {
            engine.process(engine.ctx, far.samples[offset .. offset + engine.block], output[offset .. offset + engine.block]);
        }
        audio_samples += n;
    }
    const cpu1 = try procCpuSeconds();
    const audio_seconds = @as(f64, @floatFromInt(audio_samples)) / 48000.0;
    const cores: f64 = @floatFromInt(try std.Thread.getCpuCount());
    const cpu = (cpu1 - cpu0) / audio_seconds / cores;

    const speech = maskedRms(output, far.speech, 1, 48000 / 2);
    const pause = maskedRms(output, far.speech, 0, 48000 / 2);
    const pause_in = maskedRms(far.samples, far.speech, 0, 48000 / 2);
    const speech_db: f32 = if (speech < 1e-10) -120 else 20 * std.math.log10(speech);
    const pause_out_db: f32 = if (pause < 1e-10) -120 else 20 * std.math.log10(pause);
    const pause_in_db: f32 = if (pause_in < 1e-10) -120 else 20 * std.math.log10(pause_in);

    const p99 = percentile(times.items, 0.99);
    const p99_ms = @as(f64, @floatFromInt(p99)) / 1e6;
    const block_ms = @as(f64, @floatFromInt(engine.block)) / 48.0;
    const delay_ms = @as(f64, @floatFromInt(engine.delay)) / 48.0;
    const loud_err = @abs(speech_db - dsp.target_db);
    const realtime = p99_ms < block_ms;
    const cpu_ok = cpu <= 0.05;
    const not_chopped = speech_db > -36;
    const loud_enough = loud_err <= 8;
    const pauses_ok = pause_out_db < -42 or pause_out_db <= pause_in_db + 6;
    return .{
        .name = engine.name,
        .cpu = cpu,
        .p99_ms = p99_ms,
        .block_ms = block_ms,
        .delay_ms = delay_ms,
        .speech_db = speech_db,
        .loud_err = loud_err,
        .pause_in_db = pause_in_db,
        .pause_out_db = pause_out_db,
        .tail_ratio = tail,
        .tail_raw = raw_tail,
        .pass = realtime and cpu_ok and not_chopped and pauses_ok and loud_enough,
    };
}

pub fn run(allocator: std.mem.Allocator, writer: anytype) ![]const u8 {
    var far = try makeFarMic(allocator);
    defer far.deinit();
    const impulse = try makeImpulse(allocator);
    defer allocator.free(impulse);
    const raw_tail = tailRatio(impulse, 0);

    var zig_plain = ZigCtx{ .chain = dsp.Chain.init(true, false) };
    var zig_room = ZigCtx{ .chain = dsp.Chain.init(true, true) };
    var leveler = ZigCtx{ .chain = dsp.Chain.init(false, false) };

    var engines = std.ArrayList(Engine).init(allocator);
    defer engines.deinit();
    try engines.append(.{
        .name = "leveler",
        .block = dsp.hop,
        .delay = 0,
        .ctx = &leveler,
        .deinit = zigDeinit,
        .process = zigProcess,
        .linear = zigLinear,
    });
    try engines.append(.{
        .name = "dsp",
        .block = dsp.hop,
        .delay = dsp.hop,
        .ctx = &zig_plain,
        .deinit = zigDeinit,
        .process = zigProcess,
        .linear = zigLinear,
    });
    try engines.append(.{
        .name = "dsp-dereverb",
        .block = dsp.hop,
        .delay = dsp.hop,
        .ctx = &zig_room,
        .deinit = zigDeinit,
        .process = zigProcess,
        .linear = zigLinear,
    });

    var speex_ctx: SpeexCtx = undefined;
    if (options.with_speex) {
        const eng = speex_eng_new(1) orelse return error.SpeexInit;
        speex_ctx = .{ .eng = eng, .leveler = dsp.Chain.init(false, false) };
        try engines.append(.{
            .name = "speex-dereverb",
            .block = 3840,
            .delay = 480,
            .ctx = &speex_ctx,
            .deinit = speexDeinit,
            .process = speexProcess,
            .linear = speexLinear,
        });
    }
    defer if (options.with_speex) speex_eng_free(speex_ctx.eng);

    var rows = std.ArrayList(Row).init(allocator);
    defer rows.deinit();
    for (engines.items) |*engine| {
        try rows.append(try measure(allocator, engine, far, impulse, raw_tail));
    }

    var best_tail: f32 = 10;
    var best_pause_drop: f32 = -100;
    for (rows.items) |row| {
        if (!row.pass) continue;
        if (row.tail_ratio < best_tail) best_tail = row.tail_ratio;
        const drop = row.pause_in_db - row.pause_out_db;
        if (drop > best_pause_drop) best_pause_drop = drop;
    }
    const room_matters = best_tail < raw_tail * 0.90;
    var winner: []const u8 = "dsp";
    var winner_cpu: f64 = 10;
    for (rows.items) |row| {
        if (!row.pass) continue;
        const room_close = !room_matters or row.tail_ratio <= best_tail * 1.15;
        const noise_close = row.pause_in_db - row.pause_out_db >= best_pause_drop - 3;
        if (room_close and noise_close and row.cpu < winner_cpu) {
            winner = row.name;
            winner_cpu = row.cpu;
        }
    }

    try writer.print("# Bake-off\n\n", .{});
    try writer.print("Same 4 second far-mic fixture on this machine. CPU is the share of the whole machine needed to keep up with 48 kHz audio. A row passes when the 99th percentile block is faster than realtime, that share stays at or under 5%, speech lands within 8 dB of -18 dBFS, and pauses do not rise more than 6 dB.\n\n", .{});
    try writer.print("Raw impulse tail ratio: {d:.3}\n\n", .{raw_tail});
    try writer.print("| engine | pass | cpu | p99 ms | block ms | delay ms | speech dBFS | loudness error | pause in | pause out | tail ratio |\n", .{});
    try writer.print("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n", .{});
    for (rows.items) |row| {
        try writer.print("| {s} | {s} | {d:.4} | {d:.3} | {d:.3} | {d:.2} | {d:.1} | {d:.1} | {d:.1} | {d:.1} | {d:.3} |\n", .{
            row.name,
            if (row.pass) "yes" else "no",
            row.cpu,
            row.p99_ms,
            row.block_ms,
            row.delay_ms,
            row.speech_db,
            row.loud_err,
            row.pause_in_db,
            row.pause_out_db,
            row.tail_ratio,
        });
    }
    try writer.print("\nWinner: **{s}**\n\n", .{winner});
    try writer.print("The best passing tail ratio is {s} 90 percent of the raw impulse, so the room score {s}. The winner is the lightest passer near the best tail and the best pause drop.\n", .{
        if (room_matters) "under" else "not under",
        if (room_matters) "counts" else "does not decide the pick",
    });
    try writer.print("\n## Not in this binary\n\n", .{});
    try writer.print("- RNNoise current weights are a generated 78 MB C file downloaded at build time. It was left out of the single binary so the release stays one small file. The classical denoise above is the lightweight stand-in.\n", .{});
    try writer.print("- LocalVQE, DPDFNet, and ClearerVoice are reference designs. ClearerVoice's published models decode in 1 to 10 second windows and want CUDA, so they miss the live gates without a separate measurement. LocalVQE and DPDFNet are not linked here; see bench/EXTERNAL.md for the build attempt.\n", .{});
    return winner;
}
