const std = @import("std");
const dsp = @import("dsp.zig");
const rt = @import("rt.zig");

/// Parallel speech path for the Radxa ROCK 4 Plus V1.73 profile.
///
/// The audio thread (or the offline caller) only hands a hop in. Extra
/// threads, capped at nproc and at `threads`, run the other STFT jobs.
/// PipeWire's callback never enters this file.
///
/// Jobs are real DSP, not a spin:
/// - up to three 512-point denoise/dereverb hypotheses (the COLA hop the
///   desktop chain already uses), averaged so musical noise drops
/// - 1024- and 2048-point noise trackers whose floors protect harmonics
///   and push stationary bins down
///
/// RKNN is not called. `accel.selectNpu` is the hook, and it stays false
/// without a converted enhancer.rknn and without an NPU on the RK3399.
const accel = @import("accel.zig");

pub const max_jobs: usize = 6;

pub fn resolveThreads(requested: u32) usize {
    const nproc = std.Thread.getCpuCount() catch 1;
    const cap = @max(nproc, 1);
    if (requested == 0) return cap;
    return @max(@min(@as(usize, requested), cap), 1);
}

pub fn jobCount(threads: usize, budget: f32) usize {
    const allowed: usize = if (budget >= 0.89) max_jobs else if (budget >= 0.50) 3 else 1;
    const n = @max(threads, 1);
    return @max(@min(n, allowed), 1);
}

const Pool = struct {
    mu: std.Thread.Mutex = .{},
    wake: std.Thread.Condition = .{},
    done: std.Thread.Condition = .{},
    epoch: usize = 0,
    pending: usize = 0,
    stop: bool = false,
    threads: []std.Thread = &.{},
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    denoise: bool,
    dereverb: bool,
    used: usize,
    resolved: usize,
    budget: f32,
    phase: u8 = 1,
    have_floor: bool = false,
    highpass: dsp.Biquad,
    shelf: dsp.Biquad,
    agc: dsp.Agc,
    limiter: dsp.Limiter,
    frame: [dsp.hop]f32 = undefined,
    floor: [dsp.bins]f32 = .{0} ** dsp.bins,
    hyp: [3]dsp.Spectral = undefined,
    est1024: NoiseEst(1024) = undefined,
    est2048: NoiseEst(2048) = undefined,
    est_fast: NoiseEst(2048) = undefined,
    outs: [3][dsp.hop]f32 = undefined,
    pool: Pool = .{},

    pub fn open(allocator: std.mem.Allocator, denoise: bool, dereverb: bool, threads: u32, budget: f32) !*Engine {
        const e = try allocator.create(Engine);
        errdefer allocator.destroy(e);
        e.allocator = allocator;
        e.denoise = denoise;
        e.dereverb = dereverb;
        e.resolved = resolveThreads(threads);
        e.used = jobCount(e.resolved, budget);
        e.budget = budget;
        e.phase = 1;
        e.have_floor = false;
        e.highpass = dsp.Biquad.highpass(dsp.sample_rate, 80, 0.707);
        e.shelf = dsp.Biquad.highShelf(dsp.sample_rate, 3500, 4);
        e.agc = dsp.Agc.init();
        e.limiter = .{};
        @memset(&e.frame, 0);
        @memset(&e.floor, 0);
        for (&e.outs) |*row| @memset(row, 0);
        e.hyp[0] = dsp.Spectral.initTune(denoise, dereverb, .{});
        e.hyp[1] = dsp.Spectral.initTune(denoise, dereverb, .{ .oversub = 1.40, .late_mix = 0.80 });
        e.hyp[2] = dsp.Spectral.initTune(denoise, dereverb, .{ .oversub = 1.05, .late_mix = 0.70 });
        e.est1024 = NoiseEst(1024).init(0.85, 0.15, 0.995, 0.005);
        e.est2048 = NoiseEst(2048).init(0.85, 0.15, 0.995, 0.005);
        e.est_fast = NoiseEst(2048).init(0.70, 0.30, 0.98, 0.02);
        e.pool = .{};
        // Checked once at start. RK3399 has no NPU and no converted model,
        // so this stays false and the ensemble below is the path that runs.
        std.debug.assert(!accel.selectNpu());
        e.spawn() catch |err| {
            e.joinThreads();
            return err;
        };
        return e;
    }

    pub fn threadsUsed(self: *const Engine) usize {
        return self.used;
    }

    pub fn delaySamples(_: *const Engine) usize {
        return dsp.hop;
    }

    pub fn deinit(self: *Engine) void {
        self.joinThreads();
    }

    fn spawn(self: *Engine) !void {
        const extra = if (self.used > 1) self.used - 1 else 0;
        if (extra == 0) return;
        const mem = try self.allocator.alloc(std.Thread, extra);
        self.pool.threads = mem;
        var started: usize = 0;
        errdefer {
            self.pool.mu.lock();
            self.pool.stop = true;
            self.pool.wake.broadcast();
            self.pool.mu.unlock();
            for (self.pool.threads[0..started]) |thread| thread.join();
            self.allocator.free(self.pool.threads);
            self.pool.threads = &.{};
        }
        while (started < extra) : (started += 1) {
            self.pool.threads[started] = try std.Thread.spawn(.{}, threadMain, .{ self, started + 1 });
        }
    }

    fn joinThreads(self: *Engine) void {
        if (self.pool.threads.len == 0) return;
        self.pool.mu.lock();
        self.pool.stop = true;
        self.pool.wake.broadcast();
        self.pool.mu.unlock();
        for (self.pool.threads) |thread| thread.join();
        self.allocator.free(self.pool.threads);
        self.pool.threads = &.{};
    }

    pub fn process(self: *Engine, input: []const f32, output: []f32) void {
        std.debug.assert(input.len == dsp.hop and output.len == dsp.hop);
        var presence_sq: f32 = 0;
        for (input, 0..) |x, i| {
            self.frame[i] = self.highpass.process(x);
            presence_sq += self.frame[i] * self.frame[i];
        }
        const presence_rms = @sqrt(presence_sq / @as(f32, dsp.hop));
        self.have_floor = false;
        self.phase = 1;
        self.runJobs();
        self.mixFloor();
        self.phase = 2;
        self.runJobs();
        self.average(output);
        for (output) |*s| s.* = self.shelf.process(s.*);
        var level_sq: f32 = 0;
        for (output) |s| level_sq += s * s;
        const level_rms = @sqrt(level_sq / @as(f32, dsp.hop));
        self.agc.process(presence_rms, level_rms, output);
        for (output) |*s| s.* = self.limiter.process(s.*);
    }

    fn mixFloor(self: *Engine) void {
        var mixed: [dsp.bins]f32 = .{0} ** dsp.bins;
        var any = false;
        if (self.used > 2) {
            mixed = self.est1024.coarse;
            any = true;
        }
        if (self.used > 3) minInto(&mixed, &self.est2048.coarse);
        if (self.used > 5) minInto(&mixed, &self.est_fast.coarse);
        if (any) {
            self.floor = mixed;
            self.have_floor = true;
        }
    }

    fn average(self: *Engine, output: []f32) void {
        var acc: [dsp.hop]f32 = .{0} ** dsp.hop;
        var n: usize = 0;
        // Stronger hypotheses get more of the mix so pauses stay down.
        // The gentler one only tops up harmonics when a sixth core is in use.
        if (self.used > 4) {
            addWeighted(&acc, &self.outs[0], 0.25);
            addWeighted(&acc, &self.outs[1], 0.60);
            addWeighted(&acc, &self.outs[2], 0.15);
            n = 1;
        } else if (self.used > 1) {
            addWeighted(&acc, &self.outs[0], 0.35);
            addWeighted(&acc, &self.outs[1], 0.65);
            n = 1;
        } else if (self.used > 0) {
            addHop(&acc, &self.outs[0]);
            n = 1;
        }
        const inv = 1 / @as(f32, @floatFromInt(@max(n, 1)));
        for (output, acc) |*sample, sum| sample.* = sum * inv;
    }

    fn runJobs(self: *Engine) void {
        if (self.used <= 1) {
            self.dispatch(0);
            return;
        }
        self.pool.mu.lock();
        self.pool.pending = self.used - 1;
        self.pool.epoch += 1;
        self.pool.wake.broadcast();
        self.pool.mu.unlock();
        self.dispatch(0);
        self.pool.mu.lock();
        while (self.pool.pending != 0) self.pool.done.wait(&self.pool.mu);
        self.pool.mu.unlock();
    }

    fn dispatch(self: *Engine, index: usize) void {
        if (index >= self.used) return;
        const input = self.frame[0..dsp.hop];
        if (self.phase == 1) {
            switch (index) {
                0 => self.hyp[0].analyze(input),
                1 => self.hyp[1].analyze(input),
                2 => self.est1024.analyze(input),
                3 => self.est2048.analyze(input),
                4 => self.hyp[2].analyze(input),
                5 => self.est_fast.analyze(input),
                else => {},
            }
            return;
        }
        const ext: ?[]const f32 = if (self.have_floor) &self.floor else null;
        switch (index) {
            0 => self.hyp[0].synthesize(self.outs[0][0..dsp.hop], ext),
            1 => self.hyp[1].synthesize(self.outs[1][0..dsp.hop], ext),
            4 => self.hyp[2].synthesize(self.outs[2][0..dsp.hop], ext),
            else => {},
        }
    }
};

fn threadMain(self: *Engine, index: usize) void {
    _ = rt.promote(rt.pool_priority);
    self.pool.mu.lock();
    var seen: usize = 0;
    while (true) {
        while (self.pool.epoch == seen and !self.pool.stop) self.pool.wake.wait(&self.pool.mu);
        if (self.pool.stop) {
            self.pool.mu.unlock();
            return;
        }
        const epoch = self.pool.epoch;
        self.pool.mu.unlock();
        self.dispatch(index);
        self.pool.mu.lock();
        seen = epoch;
        self.pool.pending -= 1;
        if (self.pool.pending == 0) self.pool.done.signal();
    }
}

fn addHop(acc: *[dsp.hop]f32, src: *const [dsp.hop]f32) void {
    addWeighted(acc, src, 1);
}

fn addWeighted(acc: *[dsp.hop]f32, src: *const [dsp.hop]f32, weight: f32) void {
    for (acc, src) |*a, s| a.* += s * weight;
}

fn minInto(dst: *[dsp.bins]f32, src: *const [dsp.bins]f32) void {
    for (dst, src) |*d, s| d.* = @min(d.*, s);
}

fn NoiseEst(comptime n: usize) type {
    const nb = n / 2 + 1;
    const hist_n = n - dsp.hop;
    return struct {
        down: f32,
        down_new: f32,
        up: f32,
        up_new: f32,
        primed: bool,
        window: [n]f32,
        hist: [hist_n]f32,
        noise: [nb]f32,
        coarse: [dsp.bins]f32,
        plan: dsp.FftPlan(n),

        const Self = @This();

        pub fn init(down: f32, down_new: f32, up: f32, up_new: f32) Self {
            var s: Self = undefined;
            s.down = down;
            s.down_new = down_new;
            s.up = up;
            s.up_new = up_new;
            s.primed = false;
            dsp.fillHann(n, &s.window);
            @memset(&s.hist, 0);
            @memset(&s.noise, 0);
            @memset(&s.coarse, 0);
            s.plan = dsp.FftPlan(n).init();
            return s;
        }

        pub fn analyze(self: *Self, input: []const f32) void {
            var real: [n]f32 = undefined;
            var imag: [n]f32 = .{0} ** n;
            @memcpy(real[0..hist_n], &self.hist);
            @memcpy(real[hist_n..], input);
            if (hist_n == dsp.hop) {
                @memcpy(self.hist[0..], input);
            } else {
                std.mem.copyForwards(f32, self.hist[0 .. hist_n - dsp.hop], self.hist[dsp.hop..]);
                @memcpy(self.hist[hist_n - dsp.hop ..], input);
            }
            dsp.applyWindow(real[0..n], self.window[0..n]);
            self.plan.run(real[0..n], imag[0..n], false);
            for (0..nb) |k| {
                const mag = @sqrt(real[k] * real[k] + imag[k] * imag[k]) + 1e-12;
                if (!self.primed) {
                    self.noise[k] = mag;
                } else if (mag < self.noise[k]) {
                    self.noise[k] = self.down * self.noise[k] + self.down_new * mag;
                } else {
                    self.noise[k] = self.up * self.noise[k] + self.up_new * mag;
                }
            }
            self.primed = true;
            self.publish();
        }

        fn publish(self: *Self) void {
            const ratio = (n / 2) / 256;
            for (0..256) |k| {
                var m = self.noise[k * ratio];
                var i: usize = 1;
                while (i < ratio) : (i += 1) m = @min(m, self.noise[k * ratio + i]);
                self.coarse[k] = m;
            }
            self.coarse[256] = self.noise[n / 2];
        }
    };
}

test "thread cap follows nproc and the rock budget" {
    const cores = resolveThreads(0);
    try std.testing.expect(cores > 1);
    try std.testing.expectEqual(cores, resolveThreads(10_000));
    try std.testing.expectEqual(@as(usize, 1), jobCount(cores, 0.05));
    try std.testing.expect(jobCount(cores, 0.90) > 1);
    try std.testing.expect(jobCount(cores, 0.90) <= max_jobs);
    try std.testing.expect(jobCount(cores, 0.90) <= cores);
}

test "rock ensemble stays finite on more than one thread" {
    const engine = try Engine.open(std.testing.allocator, true, true, 0, 0.90);
    defer {
        engine.deinit();
        std.testing.allocator.destroy(engine);
    }
    try std.testing.expect(engine.threadsUsed() > 1);
    try std.testing.expect(engine.threadsUsed() <= resolveThreads(0));
    var input: [dsp.hop]f32 = .{0} ** dsp.hop;
    var output: [dsp.hop]f32 = .{0} ** dsp.hop;
    var n: usize = 0;
    while (n < 48) : (n += 1) {
        for (&input, 0..) |*s, i| {
            const t = @as(f32, @floatFromInt(n * dsp.hop + i));
            s.* = 0.004 * @sin(t * 0.17) + 0.03 * @sin(t * 0.023);
        }
        engine.process(&input, &output);
        for (output) |s| try std.testing.expect(std.math.isFinite(s));
    }
}
