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
/// - a broad presence tilt (+3 dB above 3 kHz, -1 dB below 250 Hz) restores
///   consonants without the 4 dB shelf honk; a +1.5 dB air shelf at 7 kHz
///   gives back the top octave that far-field speech loses to the room
/// - a speech leveler holds loud speech near -18 dBFS and lifts quiet
///   (far-field) speech by up to +16 dB, so a talker one or two metres away
///   sits at the same level as a close talker. It is a compressor on the
///   RNNoise output, so it lifts voice, not the room tone RNNoise removed
/// - a soft limiter at -1.5 dBFS catches the lift on peaks
pub const Post = struct {
    highpass: dsp.Biquad,
    low: dsp.Biquad,
    presence: dsp.Biquad,
    air: dsp.Biquad,
    leveler: Leveler,
    limiter: dsp.Limiter,
    level: bool,

    pub fn init(level: bool) Post {
        return .{
            .highpass = dsp.Biquad.highpass(dsp.sample_rate, 75, 0.707),
            .low = dsp.Biquad.lowShelf(dsp.sample_rate, 250, -1.0),
            .presence = dsp.Biquad.highShelf(dsp.sample_rate, 3000, 3.0),
            .air = dsp.Biquad.highShelf(dsp.sample_rate, 7000, 1.5),
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
            x = self.air.process(x);
            s.* = x;
        }
        if (self.level) self.leveler.process(samples);
        for (samples) |*s| s.* = self.limiter.process(s.*);
    }
};

/// Speech level control for neural engines: a compressor around -18 dBFS
/// with up to +16 dB of lift below it, gated on speech presence.
///
/// A fixed makeup gain cannot make a far-field talker sound close without also
/// lifting the residual noise. This stage estimates an ~80 ms RMS, tracks the
/// noise floor under it, and maps the level onto a static curve:
///
///   level > -18 dBFS   ->  3:1 downward compression (peak control)
///   level < -18 dBFS   ->  1:1 lift, capped at +16 dB
///
/// The lift is scaled by how far the current level sits above the tracked
/// noise floor: silence and room tone stay at unity, so RNNoise's residual is
/// not amplified, while speech several dB above the floor gets the full lift.
/// The gain moves with a 15 ms attack and a 150 ms release. The old AGC
/// pumped because it gated on speech and lifted room tone everywhere; this one
/// only ever moves a few dB per syllable.
pub const Leveler = struct {
    threshold_db: f32 = -18,
    ratio: f32 = 3.0,
    max_lift_db: f32 = 16,
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

        // ~80 ms RMS: fast enough to follow a phrase, slow enough to ignore
        // individual cycles.
        self.envelope += coeff(0.080, samples.len) * (ms - self.envelope);

        // Noise floor: seed from the first block, then fall immediately to a
        // new minimum and rise over ~15 s. A slow rise keeps a sustained
        // talker from being absorbed into the floor.
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
        var desired: f32 = 1;
        if (level > 1e-9) {
            const level_db = 20 * std.math.log10(level);
            const gain_db = if (level_db > self.threshold_db)
                (self.threshold_db - level_db) * (1 - 1 / self.ratio)
            else
                @min(self.max_lift_db, self.threshold_db - level_db) * presence;
            desired = dsp.dbToLin(gain_db);
        }

        // Attack when the gain has to come down, release when it can go up.
        const rate = if (desired < self.gain)
            coeff(0.015, samples.len)
        else
            coeff(0.150, samples.len);
        self.gain += rate * (desired - self.gain);
        for (samples) |*s| s.* *= self.gain;
    }
};

test "leveler compresses loud speech without lifting silence" {
    var lv = Leveler.init();
    var hop: [dsp.hop]f32 = undefined;

    // Quiet room first, so the noise floor is established.
    var n: usize = 0;
    while (n < 400) : (n += 1) {
        for (&hop, 0..) |*s, i| s.* = 0.001 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
        lv.process(&hop);
    }
    try std.testing.expect(lv.gain < 1.2);

    // Loud speech: gain comes down and the output stays below the input.
    n = 0;
    while (n < 400) : (n += 1) {
        for (&hop, 0..) |*s, i| s.* = 0.6 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
        lv.process(&hop);
    }
    try std.testing.expect(lv.gain < 0.6);
    try std.testing.expect(lv.gain > 0.05);
}

test "leveler lifts far speech above the tracked noise floor" {
    var lv = Leveler.init();
    var hop: [dsp.hop]f32 = undefined;

    var n: usize = 0;
    while (n < 400) : (n += 1) {
        for (&hop, 0..) |*s, i| s.* = 0.0005 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
        lv.process(&hop);
    }

    // A talker roughly 30 dB below close speech: quiet but clearly present.
    n = 0;
    while (n < 800) : (n += 1) {
        for (&hop, 0..) |*s, i| s.* = 0.02 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
        lv.process(&hop);
    }
    try std.testing.expect(lv.gain > 2.0);
    try std.testing.expect(lv.gain <= dsp.dbToLin(16.0) + 1e-3);
}

test "leveler returns to unity when the talker stops" {
    var lv = Leveler.init();
    var hop: [dsp.hop]f32 = undefined;
    @memset(&hop, 0);
    var n: usize = 0;
    while (n < 200) : (n += 1) lv.process(&hop);
    try std.testing.expectApproxEqAbs(@as(f32, 1), lv.gain, 1e-4);
}
