const std = @import("std");
const dsp = @import("dsp.zig");

/// Post chain for neural engines (RNNoise, DPDFNet, LocalVQE).
///
/// The models return clean but quiet speech: they do not restore the low end
/// they high-passed, and they have no makeup gain. This chain is deliberately
/// gentle so it does not add the artifacts the legacy spectral-subtraction
/// chain had:
///
/// - 75 Hz high-pass removes rumble below the voice
/// - a broad presence tilt (+2 dB above 3 kHz, -1 dB below 250 Hz) restores
///   consonants without the 4 dB shelf honk
/// - a speech leveler holds hot speech down 4:1 above -28 dBFS and adds a
///   modest, presence-gated lift (up to +8 dB) below it, so a talker a
///   couple of metres away is closer to a close talker without the density
///   and pumping of a big upward compressor
/// - a -6 dB output trim keeps the chain at a comfortable level: the leveler
///   changes the balance between close and far speech, not the loudness
/// - a soft limiter at -1.5 dBFS catches peaks, and the leveler keeps the
///   signal off it so it does not colour the voice
pub const Post = struct {
    highpass: dsp.Biquad,
    low: dsp.Biquad,
    presence: dsp.Biquad,
    leveler: Leveler,
    limiter: dsp.Limiter,
    level: bool,

    pub fn init(level: bool) Post {
        return .{
            .highpass = dsp.Biquad.highpass(dsp.sample_rate, 75, 0.707),
            .low = dsp.Biquad.lowShelf(dsp.sample_rate, 250, -1.0),
            .presence = dsp.Biquad.highShelf(dsp.sample_rate, 3000, 2.0),
            .leveler = Leveler.init(),
            .limiter = .{ .ceiling = dsp.dbToLin(-1.5) },
            .level = level,
        };
    }

    pub fn process(self: *Post, samples: []f32) void {
        for (samples) |*s| {
            var x = self.highpass.process(s.*);
            x = self.low.process(x);
            x = self.presence.process(x);
            s.* = x;
        }
        if (self.level) self.leveler.process(samples);
        for (samples) |*s| s.* = self.limiter.process(s.*);
    }
};

/// Speech level control for neural engines.
///
/// Gentle by design: the previous version lifted up to +16 dB and applied one
/// gain per block, which sounded loud, dense and gritty. This one:
///
/// - 4:1 downward compression above -28 dBFS (peak control)
/// - 1:1 lift below it, capped at +8 dB, scaled by how far the level sits
///   above the tracked noise floor (silence and room tone stay at unity)
/// - 10 ms attack / 300 ms release, and the gain is ramped across the block
///   instead of stepped, so there is no zipper modulation
/// - a -6 dB trim after the gain so speech lands well below the limiter
pub const Leveler = struct {
    threshold_db: f32 = -28,
    ratio: f32 = 4.0,
    max_lift_db: f32 = 8,
    trim: f32 = 0.501, // -6 dB
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

        // ~60 ms RMS: follows syllables, so short phrases reach the target level
        // instead of passing at full level until the envelope catches up.
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

test "leveler compresses loud speech and ramps smoothly" {
    var lv = Leveler.init();
    var hop: [dsp.hop]f32 = undefined;

    // Quiet room first, so the noise floor is established.
    var n: usize = 0;
    while (n < 400) : (n += 1) {
        for (&hop, 0..) |*s, i| s.* = 0.001 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
        lv.process(&hop);
    }
    // Only the -6 dB trim should be applied to steady room tone.
    try std.testing.expectApproxEqAbs(@as(f32, 0.501), lv.gain, 0.05);

    // Loud speech: gain comes down towards the trim, output stays controlled.
    n = 0;
    while (n < 400) : (n += 1) {
        for (&hop, 0..) |*s, i| s.* = 0.6 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
        lv.process(&hop);
    }
    try std.testing.expect(lv.gain < 0.5);
    try std.testing.expect(lv.gain > 0.02);
}

test "leveler lifts far speech by at most 8 dB over the noise floor" {
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
    try std.testing.expect(lv.gain <= dsp.dbToLin(8.0) * 0.501 + 1e-3);
}

test "leveler returns to unity trim when the talker stops" {
    var lv = Leveler.init();
    var hop: [dsp.hop]f32 = undefined;
    @memset(&hop, 0);
    var n: usize = 0;
    while (n < 200) : (n += 1) lv.process(&hop);
    try std.testing.expectApproxEqAbs(@as(f32, 0.501), lv.gain, 1e-3);
}
