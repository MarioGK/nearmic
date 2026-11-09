const std = @import("std");
const builtin = @import("builtin");

/// Four-wide f32. On aarch64 this lowers to NEON. On x86-64 it lowers to SSE.
/// ROCK 4 Plus V1.73 is big.LITTLE (Cortex-A72 + Cortex-A53). Both cores are
/// ARMv8-A with NEON, so the cross build pins -mcpu=cortex-a53 and this vector
/// width is legal on either cluster.
const Vec = @Vector(4, f32);

pub fn compiledSimd() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "neon",
        .x86_64, .x86 => "sse",
        else => "scalar",
    };
}

pub fn cpuModelName() []const u8 {
    return builtin.cpu.model.name;
}

fn load4(src: []const f32, i: usize) Vec {
    return .{ src[i], src[i + 1], src[i + 2], src[i + 3] };
}

fn store4(dst: []f32, i: usize, v: Vec) void {
    dst[i] = v[0];
    dst[i + 1] = v[1];
    dst[i + 2] = v[2];
    dst[i + 3] = v[3];
}

pub fn applyWindow(real: []f32, window: []const f32) void {
    var i: usize = 0;
    while (i + 4 <= real.len) : (i += 4) {
        store4(real, i, load4(real, i) * load4(window, i));
    }
    while (i < real.len) : (i += 1) real[i] *= window[i];
}

pub const sample_rate: f32 = 48000;
pub const hop: usize = 256;
pub const fft_size: usize = 512;
pub const bins: usize = fft_size / 2 + 1;

pub const target_db: f32 = -18;
pub const max_gain_db: f32 = 30;
pub const speech_db: f32 = -42;

pub fn dbToLin(db: f32) f32 {
    return std.math.pow(f32, 10, db / 20);
}

pub const Biquad = struct {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    z1: f32 = 0,
    z2: f32 = 0,

    pub fn process(self: *Biquad, x: f32) f32 {
        const y = self.b0 * x + self.z1;
        self.z1 = self.b1 * x - self.a1 * y + self.z2;
        self.z2 = self.b2 * x - self.a2 * y;
        return y;
    }

    pub fn highpass(fs: f32, freq: f32, q: f32) Biquad {
        const w0 = 2 * std.math.pi * freq / fs;
        const cosw = @cos(w0);
        const sinw = @sin(w0);
        const alpha = sinw / (2 * q);
        const b0 = (1 + cosw) / 2;
        const b1 = -(1 + cosw);
        const b2 = (1 + cosw) / 2;
        const a0 = 1 + alpha;
        const a1 = -2 * cosw;
        const a2 = 1 - alpha;
        return .{
            .b0 = b0 / a0,
            .b1 = b1 / a0,
            .b2 = b2 / a0,
            .a1 = a1 / a0,
            .a2 = a2 / a0,
        };
    }

    pub fn highShelf(fs: f32, freq: f32, gain_db: f32) Biquad {
        const a = std.math.pow(f32, 10, gain_db / 40);
        const w0 = 2 * std.math.pi * freq / fs;
        const cosw = @cos(w0);
        const sinw = @sin(w0);
        const alpha = sinw / 2 * @sqrt((a + 1 / a) * (1 / 1 - 1) + 2);
        const two_sqrt_a_alpha = 2 * @sqrt(a) * alpha;
        const b0 = a * ((a + 1) + (a - 1) * cosw + two_sqrt_a_alpha);
        const b1 = -2 * a * ((a - 1) + (a + 1) * cosw);
        const b2 = a * ((a + 1) + (a - 1) * cosw - two_sqrt_a_alpha);
        const a0 = (a + 1) - (a - 1) * cosw + two_sqrt_a_alpha;
        const a1 = 2 * ((a - 1) - (a + 1) * cosw);
        const a2 = (a + 1) - (a - 1) * cosw - two_sqrt_a_alpha;
        return .{
            .b0 = b0 / a0,
            .b1 = b1 / a0,
            .b2 = b2 / a0,
            .a1 = a1 / a0,
            .a2 = a2 / a0,
        };
    }

    pub fn lowShelf(fs: f32, freq: f32, gain_db: f32) Biquad {
        const a = std.math.pow(f32, 10, gain_db / 40);
        const w0 = 2 * std.math.pi * freq / fs;
        const cosw = @cos(w0);
        const sinw = @sin(w0);
        const alpha = sinw / 2 * @sqrt(@as(f32, 2));
        const two_sqrt_a_alpha = 2 * @sqrt(a) * alpha;
        const b0 = a * ((a + 1) - (a - 1) * cosw + two_sqrt_a_alpha);
        const b1 = 2 * a * ((a - 1) - (a + 1) * cosw);
        const b2 = a * ((a + 1) - (a - 1) * cosw - two_sqrt_a_alpha);
        const a0 = (a + 1) + (a - 1) * cosw + two_sqrt_a_alpha;
        const a1 = -2 * ((a - 1) + (a + 1) * cosw);
        const a2 = (a + 1) + (a - 1) * cosw - two_sqrt_a_alpha;
        return .{
            .b0 = b0 / a0,
            .b1 = b1 / a0,
            .b2 = b2 / a0,
            .a1 = a1 / a0,
            .a2 = a2 / a0,
        };
    }
};

pub const Limiter = struct {
    ceiling: f32 = dbToLin(-1),

    pub fn process(self: Limiter, x: f32) f32 {
        const ax = @abs(x);
        if (ax <= self.ceiling) return x;
        const over = ax - self.ceiling;
        var y = self.ceiling + over / (1 + over / 0.15);
        if (y > 0.98) y = 0.98;
        return std.math.copysign(y, x);
    }
};

pub const Agc = struct {
    makeup: f32 = 1,
    duck: f32 = 1,
    target: f32 = dbToLin(target_db),
    max_gain: f32 = dbToLin(max_gain_db),
    speech_rms: f32 = dbToLin(speech_db),
    attack: f32,
    release: f32,
    duck_open: f32,
    duck_close: f32,

    pub fn init() Agc {
        return .{
            .attack = coeff(0.012),
            .release = coeff(0.300),
            .duck_open = coeff(0.008),
            .duck_close = coeff(0.070),
        };
    }

    fn coeff(seconds: f32) f32 {
        return 1 - @exp(-(@as(f32, hop) / sample_rate) / seconds);
    }

    pub fn process(self: *Agc, presence_rms: f32, level_rms: f32, samples: []f32) void {
        const speech = presence_rms >= self.speech_rms;
        if (speech) {
            var desired = if (level_rms > 1e-8) self.target / level_rms else self.max_gain;
            if (desired > self.max_gain) desired = self.max_gain;
            if (desired < 0.25) desired = 0.25;
            const c = if (desired < self.makeup) self.attack else self.release;
            self.makeup += c * (desired - self.makeup);
            self.duck += self.duck_open * (1 - self.duck);
        } else {
            self.duck += self.duck_close * (0.02 - self.duck);
        }
        const g = self.makeup * self.duck;
        for (samples) |*s| s.* *= g;
    }
};

pub fn FftPlan(comptime n: usize) type {
    if (n < 8 or (n & (n - 1)) != 0) @compileError("FftPlan size must be a power of two and at least 8");
    return struct {
        rev: [n]u16,
        wr: [n / 2]f32,
        wi: [n / 2]f32,

        const Self = @This();

        pub fn init() Self {
            var plan: Self = undefined;
            const bits = std.math.log2_int(usize, n);
            for (0..n) |i| {
                var x = i;
                var r: usize = 0;
                var bit: usize = 0;
                while (bit < bits) : (bit += 1) {
                    r = (r << 1) | (x & 1);
                    x >>= 1;
                }
                plan.rev[i] = @intCast(r);
            }
            for (0..n / 2) |k| {
                const ang = -2 * std.math.pi * @as(f32, @floatFromInt(k)) / @as(f32, n);
                plan.wr[k] = @cos(ang);
                plan.wi[k] = @sin(ang);
            }
            return plan;
        }

        pub fn run(self: *const Self, real: []f32, imag: []f32, inverse: bool) void {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const j: usize = self.rev[i];
                if (i < j) {
                    std.mem.swap(f32, &real[i], &real[j]);
                    std.mem.swap(f32, &imag[i], &imag[j]);
                }
            }
            var len: usize = 2;
            while (len <= n) : (len <<= 1) {
                const half = len / 2;
                const step = n / len;
                var start: usize = 0;
                while (start < n) : (start += len) {
                    if (half < 4) {
                        var k: usize = 0;
                        while (k < half) : (k += 1) {
                            const tw = k * step;
                            const wr = self.wr[tw];
                            const wi = if (inverse) -self.wi[tw] else self.wi[tw];
                            const a = start + k;
                            const b = a + half;
                            const tr = wr * real[b] - wi * imag[b];
                            const ti = wr * imag[b] + wi * real[b];
                            real[b] = real[a] - tr;
                            imag[b] = imag[a] - ti;
                            real[a] += tr;
                            imag[a] += ti;
                        }
                    } else {
                        var k: usize = 0;
                        while (k < half) : (k += 4) {
                            const tw = k * step;
                            const wrv = Vec{
                                self.wr[tw],
                                self.wr[tw + step],
                                self.wr[tw + 2 * step],
                                self.wr[tw + 3 * step],
                            };
                            var wiv = Vec{
                                self.wi[tw],
                                self.wi[tw + step],
                                self.wi[tw + 2 * step],
                                self.wi[tw + 3 * step],
                            };
                            if (inverse) wiv = -wiv;
                            const a = start + k;
                            const b = a + half;
                            const rb = load4(real, b);
                            const ib = load4(imag, b);
                            const ra = load4(real, a);
                            const ia = load4(imag, a);
                            const tr = wrv * rb - wiv * ib;
                            const ti = wrv * ib + wiv * rb;
                            store4(real, b, ra - tr);
                            store4(imag, b, ia - ti);
                            store4(real, a, ra + tr);
                            store4(imag, a, ia + ti);
                        }
                    }
                }
            }
            if (inverse) {
                const inv = 1 / @as(f32, @floatFromInt(n));
                const scale: Vec = @splat(inv);
                var j: usize = 0;
                while (j + 4 <= n) : (j += 4) {
                    store4(real, j, load4(real, j) * scale);
                    store4(imag, j, load4(imag, j) * scale);
                }
                while (j < n) : (j += 1) {
                    real[j] *= inv;
                    imag[j] *= inv;
                }
            }
        }
    };
}

pub fn fillHann(comptime n: usize, window: *[n]f32) void {
    for (window, 0..) |*w, i| {
        w.* = 0.5 - 0.5 * @cos(2 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, n));
    }
}

fn fftRadix2(real: []f32, imag: []f32, inverse: bool) void {
    const n = real.len;
    var i: usize = 1;
    var j: usize = 0;
    while (i < n) : (i += 1) {
        var bit: usize = n >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            std.mem.swap(f32, &real[i], &real[j]);
            std.mem.swap(f32, &imag[i], &imag[j]);
        }
    }
    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const ang = (if (inverse) @as(f32, 2) else @as(f32, -2)) * std.math.pi / @as(f32, @floatFromInt(len));
        const wlen_r = @cos(ang);
        const wlen_i = @sin(ang);
        var start: usize = 0;
        while (start < n) : (start += len) {
            var wr: f32 = 1;
            var wi: f32 = 0;
            var k: usize = 0;
            while (k < len / 2) : (k += 1) {
                const a = start + k;
                const b = a + len / 2;
                const tr = wr * real[b] - wi * imag[b];
                const ti = wr * imag[b] + wi * real[b];
                real[b] = real[a] - tr;
                imag[b] = imag[a] - ti;
                real[a] += tr;
                imag[a] += ti;
                const nwr = wr * wlen_r - wi * wlen_i;
                wi = wr * wlen_i + wi * wlen_r;
                wr = nwr;
            }
        }
    }
    if (inverse) {
        const inv = 1 / @as(f32, @floatFromInt(n));
        for (real, imag) |*r, *im| {
            r.* *= inv;
            im.* *= inv;
        }
    }
}

pub const Tune = struct {
    oversub: f32 = 1.15,
    late_mix: f32 = 0.85,
    noise_down: f32 = 0.85,
    noise_down_new: f32 = 0.15,
    noise_up: f32 = 0.995,
    noise_up_new: f32 = 0.005,
};

pub const Spectral = struct {
    denoise: bool,
    dereverb: bool,
    oversub: f32,
    late_mix: f32,
    noise_down: f32,
    noise_down_new: f32,
    noise_up: f32,
    noise_up_new: f32,
    window: [fft_size]f32,
    hist: [hop]f32,
    ola: [fft_size]f32,
    noise: [bins]f32,
    late: [bins]f32,
    late_hist: [8][bins]f32,
    late_pos: usize,
    prev_gain: [bins]f32,
    primed: bool,
    plan: FftPlan(fft_size),
    real_buf: [fft_size]f32,
    imag_buf: [fft_size]f32,
    mag_buf: [bins]f32,

    pub fn init(denoise: bool, dereverb: bool) Spectral {
        return initTune(denoise, dereverb, .{});
    }

    pub fn initTune(denoise: bool, dereverb: bool, tune: Tune) Spectral {
        var s: Spectral = undefined;
        s.denoise = denoise;
        s.dereverb = dereverb;
        s.oversub = tune.oversub;
        s.late_mix = tune.late_mix;
        s.noise_down = tune.noise_down;
        s.noise_down_new = tune.noise_down_new;
        s.noise_up = tune.noise_up;
        s.noise_up_new = tune.noise_up_new;
        s.late_pos = 0;
        s.primed = false;
        fillHann(fft_size, &s.window);
        @memset(&s.hist, 0);
        @memset(&s.ola, 0);
        @memset(&s.noise, 0);
        @memset(&s.late, 0);
        for (&s.late_hist) |*row| @memset(row, 0);
        @memset(&s.prev_gain, 1);
        @memset(&s.real_buf, 0);
        @memset(&s.imag_buf, 0);
        @memset(&s.mag_buf, 0);
        s.plan = FftPlan(fft_size).init();
        return s;
    }

    pub fn processHop(self: *Spectral, input: []const f32, output: []f32) void {
        self.analyze(input);
        self.synthesize(output, null);
    }

    pub fn analyze(self: *Spectral, input: []const f32) void {
        std.debug.assert(input.len == hop);
        @memcpy(self.real_buf[0..hop], &self.hist);
        @memcpy(self.real_buf[hop..], input);
        @memcpy(&self.hist, input);
        @memset(&self.imag_buf, 0);
        applyWindow(&self.real_buf, &self.window);
        self.plan.run(&self.real_buf, &self.imag_buf, false);
        for (0..bins) |k| {
            self.mag_buf[k] = @sqrt(self.real_buf[k] * self.real_buf[k] + self.imag_buf[k] * self.imag_buf[k]) + 1e-12;
        }
    }

    pub fn synthesize(self: *Spectral, output: []f32, external: ?[]const f32) void {
        std.debug.assert(output.len == hop);
        const real = &self.real_buf;
        const imag = &self.imag_buf;
        const mag = &self.mag_buf;

        if (self.dereverb) {
            const old = self.late_pos;
            for (0..bins) |k| {
                const before = mag[k];
                const delayed = self.late_hist[old][k];
                self.late[k] = 0.65 * self.late[k] + 0.35 * delayed;
                var cleaned = before - self.late_mix * self.late[k];
                if (cleaned < 0.2 * before) cleaned = 0.2 * before;
                mag[k] = cleaned;
                self.late_hist[old][k] = before;
            }
            self.late_pos = (old + 1) % self.late_hist.len;
        }

        if (self.denoise) {
            for (0..bins) |k| {
                if (!self.primed) {
                    self.noise[k] = mag[k];
                } else if (mag[k] < self.noise[k]) {
                    self.noise[k] = self.noise_down * self.noise[k] + self.noise_down_new * mag[k];
                } else {
                    self.noise[k] = self.noise_up * self.noise[k] + self.noise_up_new * mag[k];
                }
                var noise = self.noise[k];
                if (external) |ext| {
                    const floor = ext[k];
                    // A fine-resolution floor below this bin means the band is
                    // noise, not a harmonic. Suppress it further. Harmonics sit
                    // well above that floor and keep the normal gain.
                    if (floor > 1e-12 and mag[k] <= floor * 2.2) noise = @max(noise, floor);
                }
                var g = 1 - self.oversub * noise / mag[k];
                if (g < 0.06) g = 0.06;
                if (g > 1) g = 1;
                const prev = self.prev_gain[k];
                const smooth: f32 = if (g > prev) 0.35 else 0.65;
                g = prev + smooth * (g - prev);
                self.prev_gain[k] = g;
                const scale = g * mag[k] / (@sqrt(real[k] * real[k] + imag[k] * imag[k]) + 1e-12);
                real[k] *= scale;
                imag[k] *= scale;
                if (k > 0 and k < fft_size / 2) {
                    real[fft_size - k] *= scale;
                    imag[fft_size - k] *= scale;
                }
            }
            self.primed = true;
        } else if (self.dereverb) {
            for (0..bins) |k| {
                const orig = @sqrt(real[k] * real[k] + imag[k] * imag[k]) + 1e-12;
                const scale = mag[k] / orig;
                real[k] *= scale;
                imag[k] *= scale;
                if (k > 0 and k < fft_size / 2) {
                    real[fft_size - k] *= scale;
                    imag[fft_size - k] *= scale;
                }
            }
        }

        self.plan.run(real, imag, true);
        for (0..fft_size) |i| self.ola[i] += real[i] * self.window[i];
        @memcpy(output, self.ola[0..hop]);
        var shift: [fft_size]f32 = .{0} ** fft_size;
        @memcpy(shift[0 .. fft_size - hop], self.ola[hop..]);
        self.ola = shift;
    }
};

pub const Chain = struct {
    highpass: Biquad,
    shelf: Biquad,
    spectral: Spectral,
    agc: Agc,
    limiter: Limiter,
    use_spectral: bool,

    pub fn init(denoise: bool, dereverb: bool) Chain {
        return .{
            .highpass = Biquad.highpass(sample_rate, 80, 0.707),
            .shelf = Biquad.highShelf(sample_rate, 3500, 3),
            .spectral = Spectral.init(denoise, dereverb),
            .agc = Agc.init(),
            .limiter = .{},
            .use_spectral = denoise or dereverb,
        };
    }

    pub fn delaySamples(self: Chain) usize {
        return if (self.use_spectral) hop else 0;
    }

    pub fn name(self: Chain) []const u8 {
        if (self.spectral.denoise and self.spectral.dereverb) return "dsp-dereverb";
        if (self.spectral.denoise) return "dsp";
        if (self.spectral.dereverb) return "dereverb";
        return "leveler";
    }

    pub fn process(self: *Chain, input: []const f32, output: []f32) void {
        self.processWith(input, output, true);
    }

    pub fn processLinear(self: *Chain, input: []const f32, output: []f32) void {
        self.processWith(input, output, false);
    }

    fn processWith(self: *Chain, input: []const f32, output: []f32, level: bool) void {
        std.debug.assert(input.len == output.len);
        std.debug.assert(input.len % hop == 0);
        var offset: usize = 0;
        while (offset < input.len) : (offset += hop) {
            self.processHop(input[offset..][0..hop], output[offset..][0..hop], level);
        }
    }

    fn processHop(self: *Chain, input: []const f32, output: []f32, level: bool) void {
        var frame: [hop]f32 = undefined;
        var presence_sq: f32 = 0;
        for (input, 0..) |x, i| {
            frame[i] = self.highpass.process(x);
            presence_sq += frame[i] * frame[i];
        }
        const presence_rms = @sqrt(presence_sq / @as(f32, hop));
        if (self.use_spectral) {
            self.spectral.processHop(&frame, output);
        } else {
            @memcpy(output, &frame);
        }
        for (output) |*s| s.* = self.shelf.process(s.*);
        if (level) {
            var level_sq: f32 = 0;
            for (output) |s| level_sq += s * s;
            const level_rms = @sqrt(level_sq / @as(f32, hop));
            self.agc.process(presence_rms, level_rms, output);
            for (output) |*s| s.* = self.limiter.process(s.*);
        }
    }
};

pub const Resampler3 = struct {
    dec_hist: [48]f32 = .{0} ** 48,
    up_hist: [48]f32 = .{0} ** 48,
    coeff: [48]f32,
    phase: u8 = 0,

    pub fn init() Resampler3 {
        var c: [48]f32 = undefined;
        const fc: f32 = 0.15;
        var sum: f32 = 0;
        for (0..48) |i| {
            const x = @as(f32, @floatFromInt(i)) - 23.5;
            const w = 0.5 - 0.5 * @cos(2 * std.math.pi * @as(f32, @floatFromInt(i)) / 47);
            const s = if (@abs(x) < 1e-6) 2 * fc else @sin(2 * std.math.pi * fc * x) / (std.math.pi * x);
            c[i] = s * w;
            sum += c[i];
        }
        for (&c) |*v| v.* /= sum;
        return .{ .coeff = c };
    }

    pub fn decimate(self: *Resampler3, input: []const f32, output: []f32) usize {
        var produced: usize = 0;
        for (input) |x| {
            var i: usize = 47;
            while (i > 0) : (i -= 1) self.dec_hist[i] = self.dec_hist[i - 1];
            self.dec_hist[0] = x;
            self.phase += 1;
            if (self.phase == 3) {
                self.phase = 0;
                if (produced >= output.len) break;
                var acc: f32 = 0;
                for (self.coeff, self.dec_hist) |c, h| acc += c * h;
                output[produced] = acc;
                produced += 1;
            }
        }
        return produced;
    }

    pub fn interpolate(self: *Resampler3, input: []const f32, output: []f32) usize {
        var produced: usize = 0;
        for (input) |x| {
            var sub: usize = 0;
            while (sub < 3) : (sub += 1) {
                const sample: f32 = if (sub == 0) x else 0;
                var i: usize = 47;
                while (i > 0) : (i -= 1) self.up_hist[i] = self.up_hist[i - 1];
                self.up_hist[0] = sample;
                if (produced >= output.len) return produced;
                var acc: f32 = 0;
                for (self.coeff, self.up_hist) |c, h| acc += c * h;
                output[produced] = acc * 3;
                produced += 1;
            }
        }
        return produced;
    }
};

pub fn rms(samples: []const f32) f32 {
    if (samples.len == 0) return 0;
    var acc: f32 = 0;
    for (samples) |s| acc += s * s;
    return @sqrt(acc / @as(f32, @floatFromInt(samples.len)));
}

pub fn rmsDb(samples: []const f32) f32 {
    const r = rms(samples);
    if (r < 1e-10) return -120;
    return 20 * std.math.log10(r);
}

fn sine(freq: f32, n: usize, amp: f32, out: []f32) void {
    for (0..n) |i| {
        out[i] = amp * @sin(2 * std.math.pi * freq * @as(f32, @floatFromInt(i)) / sample_rate);
    }
}

test "fft512 roundtrip" {
    var real = [_]f32{0} ** fft_size;
    var imag = [_]f32{0} ** fft_size;
    real[0] = 1;
    real[3] = -0.25;
    real[40] = 0.5;
    const orig = real;
    var plan = FftPlan(fft_size).init();
    plan.run(&real, &imag, false);
    plan.run(&real, &imag, true);
    for (orig, real) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-4);
    for (imag) |im| try std.testing.expect(@abs(im) < 1e-4);
}

test "bursty voice stays near the target after denoise" {
    var chain = Chain.init(true, false);
    const n: usize = hop * 400;
    const input = try std.testing.allocator.alloc(f32, n);
    defer std.testing.allocator.free(input);
    const output = try std.testing.allocator.alloc(f32, n);
    defer std.testing.allocator.free(output);
    var rng = std.Random.DefaultPrng.init(11);
    const rand = rng.random();
    for (input, 0..) |*s, t| {
        s.* = (rand.float(f32) * 2 - 1) * 0.004;
        const sec = @as(f32, @floatFromInt(t)) / sample_rate;
        if (sec < 0.4) continue;
        const cycle = (sec - 0.4) / 0.32;
        const frac = cycle - @floor(cycle);
        if (frac < 0.62) {
            const env = @sin(std.math.pi * frac / 0.62);
            s.* += env * 0.05 * @sin(2 * std.math.pi * 180 * @as(f32, @floatFromInt(t)) / sample_rate);
            s.* += env * 0.02 * @sin(2 * std.math.pi * 360 * @as(f32, @floatFromInt(t)) / sample_rate);
        }
    }
    chain.process(input, output);
    const speech = rmsDb(output[n / 2 .. n * 3 / 4]);
    try std.testing.expect(speech > -26 and speech < -12);
}

test "fft roundtrip" {
    var real = [_]f32{0} ** 8;
    var imag = [_]f32{0} ** 8;
    real[0] = 1;
    real[1] = -0.5;
    real[2] = 0.25;
    const orig = real;
    fftRadix2(&real, &imag, false);
    fftRadix2(&real, &imag, true);
    for (orig, real) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-5);
}

test "highpass attenuates rumble" {
    var hp = Biquad.highpass(sample_rate, 80, 0.707);
    var low: [4800]f32 = undefined;
    var high: [4800]f32 = undefined;
    sine(30, low.len, 0.5, &low);
    sine(1000, high.len, 0.5, &high);
    for (&low) |*s| s.* = hp.process(s.*);
    hp = Biquad.highpass(sample_rate, 80, 0.707);
    for (&high) |*s| s.* = hp.process(s.*);
    const low_r = rms(low[2400..]);
    const high_r = rms(high[2400..]);
    try std.testing.expect(high_r > low_r * 3);
}

test "limiter holds the ceiling" {
    const lim = Limiter{};
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const x = @sin(0.1 * @as(f32, @floatFromInt(i))) * 2.0;
        try std.testing.expect(@abs(lim.process(x)) <= 0.981);
    }
}

test "agc lifts quiet speech and ducks silence" {
    var chain = Chain.init(false, false);
    const n: usize = hop * 200;
    var input = try std.testing.allocator.alloc(f32, n);
    defer std.testing.allocator.free(input);
    var output = try std.testing.allocator.alloc(f32, n);
    defer std.testing.allocator.free(output);
    @memset(input, 0);
    sine(440, n / 2, 0.02, input[n / 4 ..][0 .. n / 2]);
    chain.process(input, output);
    const speech = rmsDb(output[n / 4 + 8000 .. n / 4 + n / 2]);
    const pause = rmsDb(output[n - 4000 ..]);
    try std.testing.expect(speech > -24 and speech < -12);
    try std.testing.expect(pause < -45);
}

test "agc does not wind up on silence" {
    var agc = Agc.init();
    var frame = [_]f32{0} ** hop;
    var i: usize = 0;
    while (i < 200) : (i += 1) agc.process(0, 0, &frame);
    try std.testing.expect(agc.makeup < 1.05);
    try std.testing.expect(rms(&frame) < 1e-4);
}

test "denoise lowers stationary noise" {
    var chain = Chain.init(true, false);
    var rng = std.Random.DefaultPrng.init(7);
    const rand = rng.random();
    const n: usize = hop * 400;
    var input = try std.testing.allocator.alloc(f32, n);
    defer std.testing.allocator.free(input);
    var output = try std.testing.allocator.alloc(f32, n);
    defer std.testing.allocator.free(output);
    for (input) |*s| s.* = (rand.float(f32) * 2 - 1) * 0.05;
    chain.processLinear(input, output);
    const in_r = rms(input[n / 2 ..]);
    const out_r = rms(output[n / 2 ..]);
    try std.testing.expect(out_r < in_r * 0.55);
}

test "dereverb shortens a synthetic tail" {
    const n: usize = hop * 40;
    var input = try std.testing.allocator.alloc(f32, n);
    defer std.testing.allocator.free(input);
    @memset(input, 0);
    input[hop] = 1;
    input[hop + 2400] = 0.7;
    input[hop + 4800] = 0.45;
    var dry = Chain.init(false, false);
    var wet = Chain.init(false, true);
    var dry_out = try std.testing.allocator.alloc(f32, n);
    defer std.testing.allocator.free(dry_out);
    var wet_out = try std.testing.allocator.alloc(f32, n);
    defer std.testing.allocator.free(wet_out);
    dry.process(input, dry_out);
    wet.process(input, wet_out);
    const start = hop + 2000;
    const end = hop + 7000;
    try std.testing.expect(rms(wet_out[start..end]) < rms(dry_out[start..end]) * 0.85);
}

test "resampler keeps dc and a mid tone" {
    var rs = Resampler3.init();
    var dc_in = [_]f32{1} ** 4800;
    var dc_out = [_]f32{0} ** 1600;
    const nd = rs.decimate(&dc_in, &dc_out);
    try std.testing.expect(nd > 1000);
    var acc: f32 = 0;
    for (dc_out[nd - 400 .. nd]) |s| acc += s;
    try std.testing.expectApproxEqAbs(@as(f32, 1), acc / 400, 0.08);

    var tone_in: [4800]f32 = undefined;
    sine(1000, tone_in.len, 0.5, &tone_in);
    var tone_down = [_]f32{0} ** 1600;
    rs = Resampler3.init();
    const nt = rs.decimate(&tone_in, &tone_down);
    var up = [_]f32{0} ** 4800;
    const nu = rs.interpolate(tone_down[0..nt], &up);
    try std.testing.expect(nu > 3000);
    try std.testing.expect(rms(up[nu / 2 .. nu]) > 0.15);
}
