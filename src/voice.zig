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
/// - a downward-only leveler holds loud speech near -18 dBFS. It never adds
///   makeup gain, so pauses and room tone are not lifted; the configured
///   `gain_db` is the fixed makeup for the model
/// - a soft limiter at -1.5 dBFS catches the makeup gain
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

/// Downward-only loudness control. Estimates a 200 ms RMS, and above
/// `threshold` applies a 3:1 ratio with a 20 ms attack and a 300 ms release.
/// Below the threshold the gain is exactly 1: it never lifts the noise floor,
/// which is what made the old speech-gated AGC pump room tone and keyboard
/// tails in and out.
pub const Leveler = struct {
    threshold: f32 = dsp.dbToLin(-18),
    ratio: f32 = 3.0,
    envelope: f32 = 0,
    gain: f32 = 1,
    attack: f32,
    release: f32,

    pub fn init() Leveler {
        return .{
            .attack = secCoeff(0.020),
            .release = secCoeff(0.300),
        };
    }

    fn secCoeff(seconds: f32) f32 {
        return 1 - @exp(-(@as(f32, dsp.hop) / dsp.sample_rate) / seconds);
    }

    pub fn process(self: *Leveler, samples: []f32) void {
        var sum: f32 = 0;
        for (samples) |s| sum += s * s;
        const ms = sum / @as(f32, @floatFromInt(samples.len));
        // ~200 ms RMS over the 256-sample hop (5.33 ms).
        self.envelope += 0.027 * (ms - self.envelope);

        const level = @sqrt(self.envelope);
        var desired: f32 = 1;
        if (level > self.threshold and level > 1e-9) {
            const over = level / self.threshold;
            desired = std.math.pow(f32, over, 1.0 / self.ratio - 1.0);
        }
        if (desired < self.gain) {
            self.gain += self.attack * (desired - self.gain);
        } else {
            self.gain += self.release * (desired - self.gain);
        }
        for (samples) |*s| s.* *= self.gain;
    }
};

test "leveler never adds gain and compresses loud speech" {
    var lv = Leveler.init();
    var hop: [dsp.hop]f32 = undefined;

    // Quiet speech: unity gain, no noise-floor lift.
    for (&hop, 0..) |*s, i| s.* = 0.01 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
    var n: usize = 0;
    while (n < 200) : (n += 1) lv.process(&hop);
    try std.testing.expectApproxEqAbs(@as(f32, 1), lv.gain, 1e-4);

    // Loud speech drives the gain down and it comes back slowly.
    n = 0;
    while (n < 300) : (n += 1) {
        for (&hop, 0..) |*s, i| s.* = 0.6 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
        lv.process(&hop);
    }
    try std.testing.expect(lv.gain < 0.6);
    try std.testing.expect(lv.gain > 0.05);
}
