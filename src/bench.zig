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
    speech_in_db: f32,
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

var model_buf: [128]u8 = undefined;

fn cpuModel() []const u8 {
    const text = std.fs.cwd().readFileAlloc(std.heap.page_allocator, "/proc/cpuinfo", 1 << 16) catch return "unknown";
    defer std.heap.page_allocator.free(text);
    const key = "model name";
    const at = std.mem.indexOf(u8, text, key) orelse return "unknown";
    const rest = text[at + key.len ..];
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return "unknown";
    const line = rest[colon + 1 ..];
    const end = std.mem.indexOfScalar(u8, line, '\n') orelse line.len;
    const name = std.mem.trim(u8, line[0..end], " \t");
    if (name.len == 0) return "unknown";
    const n = @min(name.len, model_buf.len);
    @memcpy(model_buf[0..n], name[0..n]);
    return model_buf[0..n];
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

fn maskedRms(samples: []const f32, mask: []const u8, want: u8, skip: usize, delay: usize) f32 {
    var acc: f32 = 0;
    var n: usize = 0;
    for (samples, 0..) |s, i| {
        if (i < skip + delay or i < delay) continue;
        const src = i - delay;
        if (src >= mask.len or mask[src] != want) continue;
        acc += s * s;
        n += 1;
    }
    if (n == 0) return 0;
    return @sqrt(acc / @as(f32, @floatFromInt(n)));
}

fn dbOf(lin: f32) f32 {
    if (lin < 1e-10) return -120;
    return 20 * std.math.log10(lin);
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

    const skip: usize = 48000 / 2;
    const speech = maskedRms(output, far.speech, 1, skip, engine.delay);
    const pause = maskedRms(output, far.speech, 0, skip, engine.delay);
    const speech_in = maskedRms(far.samples, far.speech, 1, skip, 0);
    const pause_in = maskedRms(far.samples, far.speech, 0, skip, 0);
    const speech_db = dbOf(speech);
    const speech_in_db = dbOf(speech_in);
    const pause_out_db = dbOf(pause);
    const pause_in_db = dbOf(pause_in);

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
        .speech_in_db = speech_in_db,
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

    var passers: usize = 0;
    var best_tail: f32 = 10;
    var best_pause_drop: f32 = -100;
    for (rows.items) |row| {
        if (!row.pass) continue;
        passers += 1;
        if (row.tail_ratio < best_tail) best_tail = row.tail_ratio;
        const drop = row.pause_in_db - row.pause_out_db;
        if (drop > best_pause_drop) best_pause_drop = drop;
    }
    const room_matters = passers > 0 and best_tail < raw_tail * 0.90;
    var winner: []const u8 = "";
    var winner_cpu: f64 = 10;
    var winner_tail: f32 = 10;
    var winner_loud: f32 = 100;
    for (rows.items) |row| {
        if (!row.pass) continue;
        const room_close = !room_matters or row.tail_ratio <= best_tail * 1.15;
        const noise_close = row.pause_in_db - row.pause_out_db >= best_pause_drop - 3;
        if (!room_close or !noise_close) continue;
        const cpu_tie = winner.len != 0 and @abs(row.cpu - winner_cpu) <= @max(winner_cpu * 0.10, 0.0002);
        const better = winner.len == 0 or (!cpu_tie and row.cpu < winner_cpu) or (cpu_tie and row.tail_ratio < winner_tail - 0.005) or (cpu_tie and @abs(row.tail_ratio - winner_tail) <= 0.005 and row.loud_err < winner_loud);
        if (better) {
            winner = row.name;
            winner_cpu = row.cpu;
            winner_tail = row.tail_ratio;
            winner_loud = row.loud_err;
        }
    }

    const model = cpuModel();
    const cores = try std.Thread.getCpuCount();
    try writer.print("# Bake-off\n\n", .{});
    try writer.print("Machine: {s}, {d} cores. CPU is process time divided by audio duration divided by core count, so 0.05 is 5% of the whole machine while keeping up with 48 kHz.\n\n", .{ model, cores });
    try writer.print("Fixture: 4.0 seconds at 48 kHz. Stationary noise at amplitude 0.004, five harmonics in 170 ms bursts, then three echoes at 25 ms, 54 ms, and 100 ms. This is synthetic. It is not a recording of a Comica VM40.\n\n", .{});
    try writer.print("A row passes only when every gate holds: p99 block time is under the block duration, CPU is at or under 0.05, speech RMS is above -36 dBFS, speech RMS is within 8 dB of -18 dBFS, and pause RMS does not rise more than 6 dB.\n\n", .{});
    try writer.print("Raw impulse tail ratio: {d:.3}\n\n", .{raw_tail});
    try writer.print("| engine | pass | cpu | x realtime | p99 ms | block ms | delay ms | speech in | speech out | loudness error | pause in | pause out | tail ratio |\n", .{});
    try writer.print("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n", .{});
    for (rows.items) |row| {
        const times = if (row.p99_ms > 0) row.block_ms / row.p99_ms else 0;
        try writer.print("| {s} | {s} | {d:.4} | {d:.0} | {d:.3} | {d:.3} | {d:.2} | {d:.1} | {d:.1} | {d:.1} | {d:.1} | {d:.1} | {d:.3} |\n", .{
            row.name,
            if (row.pass) "yes" else "no",
            row.cpu,
            times,
            row.p99_ms,
            row.block_ms,
            row.delay_ms,
            row.speech_in_db,
            row.speech_db,
            row.loud_err,
            row.pause_in_db,
            row.pause_out_db,
            row.tail_ratio,
        });
    }
    if (winner.len == 0) {
        try writer.print("\nWinner: **none**. No row passed every gate.\n\n", .{});
    } else {
        try writer.print("\nWinner: **{s}**\n\n", .{winner});
    }
    if (passers == 0) {
        try writer.print("No passing tail was measured, so the room score did not pick an engine.\n", .{});
    } else {
        try writer.print("Best passing tail ratio {d:.3} against raw {d:.3}. The room score {s}, because that tail {s} under 90% of raw. Among passers that stay within 15% of that tail and within 3 dB of the best pause drop, the lowest CPU wins. A CPU gap under 10% (or 0.0002) is a tie, broken by the lower tail ratio and then the smaller loudness error.\n", .{
            best_tail,
            raw_tail,
            if (room_matters) "counts" else "does not decide the pick",
            if (room_matters) "is" else "is not",
        });
    }
    try writer.print("\n## Not in this binary\n\n", .{});
    try writer.print("- RNNoise, LocalVQE, and DPDFNet were run on this same fixture. The rows, including DPDFNet's measured realtime factor, are in bench/AI.md. None of those models pass the gates at their native level. A fixed makeup gain makes DPDFNet pass on this clip; that gain is not what the binary ships.\n", .{});
    try writer.print("- ClearerVoice-Studio was run on CPU PyTorch. FRCRN and MossFormerGAN were slower than the audio. The rows are in bench/AI.md. It is not linked here.\n", .{});
    return winner;
}

fn writeF32(path: []const u8, samples: []const f32) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var bytes = std.ArrayList(u8).init(std.heap.page_allocator);
    defer bytes.deinit();
    try bytes.resize(samples.len * 4);
    for (samples, 0..) |s, i| {
        std.mem.writeInt(u32, bytes.items[i * 4 ..][0..4], @bitCast(s), .little);
    }
    try file.writeAll(bytes.items);
}

fn readF32(allocator: std.mem.Allocator, path: []const u8) ![]f32 {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(data);
    if (data.len % 4 != 0) return error.BadPcm;
    const out = try allocator.alloc(f32, data.len / 4);
    for (out, 0..) |*s, i| s.* = @bitCast(std.mem.readInt(u32, data[i * 4 ..][0..4], .little));
    return out;
}

pub fn writeFixture(allocator: std.mem.Allocator, dir: []const u8) !void {
    try std.fs.cwd().makePath(dir);
    var far = try makeFarMic(allocator);
    defer far.deinit();
    const impulse = try makeImpulse(allocator);
    defer allocator.free(impulse);
    var path_buf: [512]u8 = undefined;
    try writeF32(try std.fmt.bufPrint(&path_buf, "{s}/far48.f32", .{dir}), far.samples);
    try writeF32(try std.fmt.bufPrint(&path_buf, "{s}/impulse48.f32", .{dir}), impulse);

    var rs = dsp.Resampler3.init();
    const far16 = try allocator.alloc(f32, far.samples.len / 3 + 8);
    defer allocator.free(far16);
    const nfar = rs.decimate(far.samples, far16);
    try writeF32(try std.fmt.bufPrint(&path_buf, "{s}/far16.f32", .{dir}), far16[0..nfar]);
    rs = dsp.Resampler3.init();
    const imp16 = try allocator.alloc(f32, impulse.len / 3 + 8);
    defer allocator.free(imp16);
    const nimp = rs.decimate(impulse, imp16);
    try writeF32(try std.fmt.bufPrint(&path_buf, "{s}/impulse16.f32", .{dir}), imp16[0..nimp]);
}

fn upsample3(allocator: std.mem.Allocator, input: []const f32) ![]f32 {
    var rs = dsp.Resampler3.init();
    const out = try allocator.alloc(f32, input.len * 3 + 16);
    const n = rs.interpolate(input, out);
    return allocator.realloc(out, n);
}

fn peakDelay(samples: []const f32) usize {
    var best: usize = 0;
    var mag: f32 = 0;
    for (samples, 0..) |s, i| {
        const a = @abs(s);
        if (a > mag) {
            mag = a;
            best = i;
        }
    }
    return best;
}

pub fn scoreExternal(
    allocator: std.mem.Allocator,
    writer: anytype,
    name: []const u8,
    cpu_seconds: f64,
    p99_ns: u64,
    block: usize,
    rate: f64,
    audio_samples: usize,
    level: bool,
    far_path: []const u8,
    impulse_path: []const u8,
) !void {
    var far = try makeFarMic(allocator);
    defer far.deinit();
    const raw_impulse = try makeImpulse(allocator);
    defer allocator.free(raw_impulse);
    const raw_tail = tailRatio(raw_impulse, 0);

    var far_out = try readF32(allocator, far_path);
    defer allocator.free(far_out);
    var impulse_out = try readF32(allocator, impulse_path);
    defer allocator.free(impulse_out);
    if (rate < 20000) {
        const up_far = try upsample3(allocator, far_out);
        allocator.free(far_out);
        far_out = up_far;
        const up_imp = try upsample3(allocator, impulse_out);
        allocator.free(impulse_out);
        impulse_out = up_imp;
    }
    const delay = peakDelay(impulse_out);
    const tail = tailRatio(impulse_out, delay);

    var leveled: []f32 = far_out;
    var owned_level = false;
    if (level) {
        const n = far_out.len - (far_out.len % dsp.hop);
        leveled = try allocator.alloc(f32, n);
        owned_level = true;
        var chain = dsp.Chain.init(false, false);
        chain.process(far_out[0..n], leveled);
    }
    defer if (owned_level) allocator.free(leveled);

    const skip: usize = 48000 / 2;
    const speech_db = dbOf(maskedRms(leveled, far.speech, 1, skip, delay));
    const pause_out_db = dbOf(maskedRms(leveled, far.speech, 0, skip, delay));
    const speech_in_db = dbOf(maskedRms(far.samples, far.speech, 1, skip, 0));
    const pause_in_db = dbOf(maskedRms(far.samples, far.speech, 0, skip, 0));
    const audio_seconds = @as(f64, @floatFromInt(audio_samples)) / rate;
    const cores: f64 = @floatFromInt(try std.Thread.getCpuCount());
    const cpu = cpu_seconds / audio_seconds / cores;
    const p99_ms = @as(f64, @floatFromInt(p99_ns)) / 1e6;
    const block_ms = @as(f64, @floatFromInt(block)) / rate * 1000.0;
    const loud_err = @abs(speech_db - dsp.target_db);
    const pass = p99_ms < block_ms and cpu <= 0.05 and speech_db > -36 and loud_err <= 8 and (pause_out_db < -42 or pause_out_db <= pause_in_db + 6);
    const times = if (p99_ms > 0) block_ms / p99_ms else 0;
    try writer.print("| {s} | {s} | {d:.4} | {d:.0} | {d:.3} | {d:.3} | {d:.2} | {d:.1} | {d:.1} | {d:.1} | {d:.1} | {d:.1} | {d:.3} |\n", .{
        name,
        if (pass) "yes" else "no",
        cpu,
        times,
        p99_ms,
        block_ms,
        @as(f64, @floatFromInt(delay)) / 48.0,
        speech_in_db,
        speech_db,
        loud_err,
        pause_in_db,
        pause_out_db,
        tail,
    });
    try writer.print("raw_tail={d:.3} measured_delay_samples={d}\n", .{ raw_tail, delay });
}
