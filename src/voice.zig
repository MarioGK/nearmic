const std = @import("std");
const dsp = @import("dsp.zig");

/// Post chain for neural engines (RNNoise, DPDFNet, LocalVQE).
///
/// The models return clean but quiet speech: they do not restore the low end
/// they high-passed, and they have no makeup gain. The chain is tuned for a
/// loud, close-sounding voice that does not pop:
///
/// - 90 Hz high-pass removes rumble and plosive energy below the voice
/// - a -2 dB low shelf at 300 Hz takes out the boxy "room" body that makes a
///   talker sound distant
/// - +4 dB at 3.2 kHz (Q 1.0) restores consonant energy, which is most of the
///   intelligibility and closeness cue
/// - +2 dB at 8 kHz puts back the air that distance and room absorption eat
/// - a speech leveler holds close speech at a fixed level and lifts quiet
///   (far) speech by up to +12 dB, gated on speech presence so the noise
///   RNNoise removed is not lifted with it
/// - a look-ahead limiter at -2.0 dBFS catches peaks with 5.3 ms of look-ahead,
///   so the level can be loud without clipping or the flat-topped "popping"
///   sound of a limiter that reacts after the peak
pub const Post = struct {
    highpass: dsp.Biquad,
    low: dsp.Biquad,
    presence: dsp.Biquad,
    air: dsp.Biquad,
    leveler: Leveler,
    limiter: LookaheadLimiter,
    level: bool,

    pub fn init(level: bool) Post {
        return .{
            .highpass = dsp.Biquad.highpass(dsp.sample_rate, 90, 0.707),
            .low = dsp.Biquad.lowShelf(dsp.sample_rate, 300, -2.0),
            .presence = dsp.Biquad.peaking(dsp.sample_rate, 3200, 1.0, 4.0),
            .air = dsp.Biquad.highShelf(dsp.sample_rate, 8000, 2.0),
            .leveler = Leveler.init(),
            .limiter = .{ .ceiling = dsp.dbToLin(-2.0) },
            .level = level,
        };
    }

    /// Samples of added latency from the look-ahead limiter.
    pub const latency: usize = 256;

    pub fn process(self: *Post, samples: []f32) void {
        for (samples) |*s| {
            var x = self.highpass.process(s.*);
            x = self.low.process(x);
            x = self.presence.process(x);
            x = self.air.process(x);
            s.* = x;
        }
        if (self.level) self.leveler.process(samples);
        self.limiter.process(samples);
    }
};

/// Speech level control for neural engines.
///
/// - 4:1 downward compression above -24 dBFS (peak control)
/// - 1:1 lift below it, capped at +12 dB, scaled by how far the level sits
///   above the tracked noise floor (silence and room tone stay at unity)
/// - 60 ms detector, 10 ms attack / 300 ms release, gain ramped per sample
/// - a +6 dB trim so the voice sits at a normal call level
pub const Leveler = struct {
    threshold_db: f32 = -24,
    ratio: f32 = 4.0,
    max_lift_db: f32 = 12,
    trim: f32 = 1.995, // +6 dB
    envelope: f32 = 0,
    floor: f32 = 0,
    gain: f32 = 1,

    pub fn init() Leveler {
        return .{};
    }

    fn coeff(seconds: f32, samples: usize) f32 {
        const block = @as(f32, @floatFromInt(samples)) / dsp.sample_rate;
        return 1 - @exp(-block / seconds);
    }

    pub fn process(self: *Leveler, samples: []f32) void {
        if (samples.len == 0) return;
        var sum: f32 = 0;
        for (samples) |s| sum += s * s;
        const ms = sum / @as(f32, @floatFromInt(samples.len));

        // ~60 ms RMS: follows syllables, so short phrases reach the target
        // level instead of passing at full level until the envelope catches up.
        self.envelope += coeff(0.060, samples.len) * (ms - self.envelope);

        // Noise floor: seed from the first block, fall immediately to a new
        // minimum, rise over ~15 s. A slow rise keeps a sustained talker from
        // being absorbed into the floor.
        if (self.floor <= 1e-12) {
            self.floor = ms;
        } else if (ms < self.floor) {
            self.floor = ms;
        } else {
            self.floor += coeff(15.0, samples.len) * (ms - self.floor);
        }

        // Presence: 0 at the floor, 1 at 6 dB above it.
        var presence: f32 = 0;
        if (self.floor > 1e-12) {
            presence = std.math.clamp((self.envelope / self.floor - 1.0) / 3.0, 0, 1);
        } else if (self.envelope > 1e-12) {
            presence = 1;
        }

        const level = @sqrt(self.envelope);
        var desired: f32 = self.trim;
        if (level > 1e-9) {
            const level_db = 20 * std.math.log10(level);
            const gain_db = if (level_db > self.threshold_db)
                (self.threshold_db - level_db) * (1 - 1 / self.ratio)
            else
                @min(self.max_lift_db, self.threshold_db - level_db) * presence;
            desired = dsp.dbToLin(gain_db) * self.trim;
        }

        const rate = if (desired < self.gain)
            coeff(0.010, samples.len)
        else
            coeff(0.300, samples.len);

        // Ramp the gain across the block: a constant per-block gain steps at
        // 187 Hz and is audible as a rough edge on speech.
        const start = self.gain;
        self.gain += rate * (desired - self.gain);
        const end = self.gain;
        const n = @as(f32, @floatFromInt(samples.len));
        for (samples, 0..) |*s, i| {
            const t = @as(f32, @floatFromInt(i + 1)) / n;
            s.* *= start + (end - start) * t;
        }
    }
};

/// One-block look-ahead peak limiter.
///
/// The block that is emitted is the one received in the previous call, and the
/// gain applied to it is the minimum of what that block needs and what the new
/// block needs. That is a real look-ahead: the gain is already down when the
/// peak arrives, so there is no overshoot and no flat-topped clipping (the
/// "popping" sound). Attack drops immediately inside the look-ahead window;
/// recovery ramps up over the block.
pub const LookaheadLimiter = struct {
    ceiling: f32 = dsp.dbToLin(-1.0),
    pending: [dsp.hop]f32 = undefined,
    pending_peak: f32 = 0,
    primed: bool = false,
    gain: f32 = 1,

    pub fn process(self: *LookaheadLimiter, samples: []f32) void {
        if (samples.len != self.pending.len) {
            // Only the fixed DSP hop is supported; degrade to a soft clip so a
            // different caller cannot read uninitialised memory.
            for (samples) |*s| s.* = std.math.clamp(s.*, -self.ceiling, self.ceiling);
            return;
        }
        const n = samples.len;

        var peak: f32 = 0;
        for (samples) |x| peak = @max(peak, @abs(x));

        var current: [dsp.hop]f32 = undefined;
        @memcpy(current[0..n], samples[0..n]);

        if (self.primed) {
            const need_pending = if (self.pending_peak > 1e-9)
                self.ceiling / self.pending_peak
            else
                1;
            const need_next = if (peak > 1e-9) self.ceiling / peak else 1;
            const g = @min(@min(need_pending, need_next), 1);

            if (g < self.gain) {
                // Inside the look-ahead window: go down now, that is audible
                // as a gentle gain change, not as a click.
                for (self.pending[0..n]) |*s| s.* *= g;
            } else {
                const start = self.gain;
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const t = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(n));
                    self.pending[i] *= start + (g - start) * t;
                }
            }
            self.gain = g;
            @memcpy(samples[0..n], self.pending[0..n]);
        } else {
            for (samples) |*s| s.* = 0;
            self.primed = true;
            self.gain = 1;
        }

        @memcpy(self.pending[0..n], current[0..n]);
        self.pending_peak = peak;
    }
};

test "leveler compresses loud speech and ramps smoothly" {
    var lv = Leveler.init();
    var hop: [dsp.hop]f32 = undefined;

    // Quiet room first, so the noise floor is established.
    var n: usize = 0;
    while (n < 400) : (n += 1) {
        for (&hop, 0..) |*s, i| s.* = 0.001 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
        lv.process(&hop);
    }
    // Only the +6 dB trim should be applied to steady room tone.
    try std.testing.expectApproxEqAbs(@as(f32, 1.995), lv.gain, 0.12);

    // Loud speech: gain comes down, output stays controlled.
    n = 0;
    while (n < 400) : (n += 1) {
        for (&hop, 0..) |*s, i| s.* = 0.6 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
        lv.process(&hop);
    }
    try std.testing.expect(lv.gain < 0.5);
    try std.testing.expect(lv.gain > 0.02);
}

test "leveler lifts far speech by at most 12 dB over the noise floor" {
    var lv = Leveler.init();
    var hop: [dsp.hop]f32 = undefined;

    var n: usize = 0;
    while (n < 400) : (n += 1) {
        for (&hop, 0..) |*s, i| s.* = 0.0005 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
        lv.process(&hop);
    }

    n = 0;
    while (n < 800) : (n += 1) {
        for (&hop, 0..) |*s, i| s.* = 0.02 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
        lv.process(&hop);
    }
    try std.testing.expect(lv.gain > 1.0);
    try std.testing.expect(lv.gain <= dsp.dbToLin(12.0) * 1.995 + 1e-3);
}

test "limiter never exceeds the ceiling even on a step" {
    var lim = LookaheadLimiter{ .ceiling = dsp.dbToLin(-2.0) };
    var block: [dsp.hop]f32 = .{0} ** dsp.hop;
    var peak: f32 = 0;
    var b: usize = 0;
    while (b < 40) : (b += 1) {
        // Alternate full-scale steps and silence; the look-ahead must catch
        // every one without overshooting.
        for (&block, 0..) |*s, i| {
            s.* = if (b % 2 == 0) 0.95 * @sin(@as(f32, @floatFromInt(i)) * 0.2) else 0;
        }
        lim.process(&block);
        for (block) |s| peak = @max(peak, @abs(s));
    }
    try std.testing.expect(peak <= dsp.dbToLin(-2.0) + 1e-4);
}
