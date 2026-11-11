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
/// - a speech gate: between phrases the output fades by 20 dB, so the
///   residual noise the leveler and makeup gain would lift stays out of the
///   way without the hard on/off of a deep gate. It is keyed on the engine's own speech detector
///   (RNNoise VAD, DeepFilterNet local SNR), which leads the audio by the
///   model delay, so it opens before the first syllable
/// - a look-ahead limiter at -2.0 dBFS catches peaks with 5.3 ms of look-ahead,
///   so the level can be loud without clipping or the flat-topped "popping"
///   sound of a limiter that reacts after the peak
pub const Post = struct {
    highpass: dsp.Biquad,
    low: dsp.Biquad,
    presence: dsp.Biquad,
    air: dsp.Biquad,
    leveler: Leveler,
    gate: Gate,
    limiter: LookaheadLimiter,
    level: bool,
    /// NEARMIC_NO_GATE=1 turns the gate off (A/B listening tests).
    gate_on: bool,
    /// The engine's speech detector is reliable enough to key the gate alone.
    trust_vad: bool = false,

    fn envDb(name: []const u8) ?f32 {
        const v = std.posix.getenv(name) orelse return null;
        return std.fmt.parseFloat(f32, v) catch null;
    }

    pub fn init(level: bool) Post {
        var post = Post{
            .highpass = dsp.Biquad.highpass(dsp.sample_rate, 90, 0.707),
            .low = dsp.Biquad.lowShelf(dsp.sample_rate, 300, -2.0),
            .presence = dsp.Biquad.peaking(dsp.sample_rate, 3200, 1.0, 4.0),
            .air = dsp.Biquad.highShelf(dsp.sample_rate, 8000, 2.0),
            .leveler = Leveler.init(),
            .gate = Gate.init(),
            .limiter = .{ .ceiling = dsp.dbToLin(-2.0) },
            .level = level,
            .gate_on = std.posix.getenv("NEARMIC_NO_GATE") == null,
        };
        // Listening-test overrides (dB): gate depth, leveler trim and lift.
        if (envDb("NEARMIC_GATE_DB")) |v| {
            post.gate.closed_db = v;
            post.gate.gain_db = v;
        }
        if (envDb("NEARMIC_TRIM_DB")) |v| post.leveler.trim = dsp.dbToLin(v);
        if (envDb("NEARMIC_LIFT_DB")) |v| post.leveler.max_lift_db = v;
        return post;
    }

    /// Samples of added latency from the look-ahead limiter.
    pub const latency: usize = 256;

    /// `speech` is the engine's speech confidence (0..1) for the newest frame,
    /// or a negative value when the engine has no detector.
    pub fn process(self: *Post, samples: []f32, speech: f32) void {
        for (samples) |*s| {
            var x = self.highpass.process(s.*);
            x = self.low.process(x);
            x = self.presence.process(x);
            x = self.air.process(x);
            s.* = x;
        }
        if (self.level) self.leveler.process(samples);
        // RNNoise's VAD reads most room noise as speech (mean 0.94 on noisy
        // clips), so the level-based presence must agree. DeepFilterNet's
        // local SNR is clean enough on its own (see engines.lsnrToSpeech).
        const key = if (speech < 0)
            self.leveler.presence
        else if (self.trust_vad)
            speech
        else
            @min(speech, self.leveler.presence);
        if (self.gate_on) self.gate.process(samples, key);
        self.limiter.process(samples);
        // Safety clamp: the look-ahead limiter should already hold the peak at
        // `ceiling`, and this makes a single overshoot impossible (it only
        // touches samples above -2 dBFS, so it is inaudible).
        const c = self.limiter.ceiling;
        for (samples) |*s| s.* = std.math.clamp(s.*, -c, c);
    }
};

/// Speech level control for neural engines.
///
/// - 4:1 downward compression above -24 dBFS (peak control)
/// - 1:1 lift below it, capped at +12 dB, scaled by how far the level sits
///   above the tracked noise floor (silence and room tone stay at unity)
/// - 60 ms detector, 10 ms attack / 300 ms release, gain ramped per sample
/// - a +9 dB trim so the voice sits at a normal call level
pub const Leveler = struct {
    threshold_db: f32 = -24,
    ratio: f32 = 4.0,
    max_lift_db: f32 = 12,
    trim: f32 = 2.818, // +9 dB: far speech lands near -17 dBFS instead of -20
    envelope: f32 = 0,
    floor: f32 = 0,
    gain: f32 = 1,
    presence: f32 = 0,

    /// -80 dBFS (mean square). Neural engines output exact zeros in silence;
    /// without a lower bound the floor collapses to zero, re-seeds on the next
    /// block (often a speech onset) and then reads that speech as "floor".
    const min_floor: f32 = 1e-8;

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
            self.floor = @max(ms, min_floor);
        } else if (ms < self.floor) {
            self.floor = @max(ms, min_floor);
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

        self.presence = presence;
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

/// Speech gate (downward expander with hysteresis and hold).
///
/// Opens within one hop when `speech` reaches `open_at`, stays open while it
/// is at least `keep_at`, holds for `hold_s` after the last speech frame, then
/// fades to `closed` over `release_s`. The fade is linear in dB, so word
/// tails and room decay go down smoothly instead of being chopped.
pub const Gate = struct {
    open_at: f32 = 0.5,
    keep_at: f32 = 0.35,
    hold_s: f32 = 0.30,
    release_s: f32 = 0.15,
    // -20 dB, not a hard mute: with the model already removing the noise, a
    // deeper gate only adds audible on/off "dead air" between words. On the
    // operator's far-field recording DNSMOS is the same at -20 and -45.
    closed_db: f32 = -20,
    hold_left: f32 = 0,
    gain_db: f32 = -20,

    pub fn init() Gate {
        return .{};
    }

    pub fn process(self: *Gate, samples: []f32, speech: f32) void {
        if (samples.len == 0) return;
        const block = @as(f32, @floatFromInt(samples.len)) / dsp.sample_rate;
        const open = self.hold_left > 0;
        if (speech >= self.open_at or (open and speech >= self.keep_at)) {
            self.hold_left = self.hold_s;
        } else {
            self.hold_left = @max(0, self.hold_left - block);
        }

        const start_db = self.gain_db;
        if (self.hold_left > 0) {
            // Attack within this hop. The detector leads the audio by the
            // model delay (10-30 ms), so the onset is already inside.
            self.gain_db = 0;
        } else {
            const step = -self.closed_db * block / self.release_s;
            self.gain_db = @max(self.closed_db, self.gain_db - step);
        }
        if (start_db == 0 and self.gain_db == 0) return;

        const g0 = dsp.dbToLin(start_db);
        const g1 = dsp.dbToLin(self.gain_db);
        const n = @as(f32, @floatFromInt(samples.len));
        for (samples, 0..) |*s, i| {
            const t = @as(f32, @floatFromInt(i + 1)) / n;
            s.* *= g0 + (g1 - g0) * t;
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
    // Only the trim should be applied to steady room tone.
    try std.testing.expectApproxEqAbs(lv.trim, lv.gain, 0.12 * lv.trim / 1.995);

    // Loud speech: gain comes down, output stays controlled.
    n = 0;
    while (n < 400) : (n += 1) {
        for (&hop, 0..) |*s, i| s.* = 0.6 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
        lv.process(&hop);
    }
    try std.testing.expect(lv.gain < 0.5 * lv.trim / 1.995);
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
    try std.testing.expect(lv.gain <= dsp.dbToLin(12.0) * lv.trim + 1e-3);
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

test "gate opens on speech, holds, then fades to the closed level" {
    var gate = Gate.init();
    var block: [dsp.hop]f32 = undefined;

    // Noise only: stays closed.
    var n: usize = 0;
    while (n < 50) : (n += 1) {
        @memset(&block, 0.01);
        gate.process(&block, 0.1);
    }
    try std.testing.expectApproxEqAbs(0.01 * dsp.dbToLin((Gate{}).closed_db), block[block.len - 1], 1e-6);

    // Speech: fully open by the end of the first hop.
    @memset(&block, 0.5);
    gate.process(&block, 0.9);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), block[block.len - 1], 1e-5);

    // Speech confidence drops below open but stays above keep: still open.
    n = 0;
    while (n < 200) : (n += 1) {
        @memset(&block, 0.5);
        gate.process(&block, 0.4);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), block[0], 1e-5);

    // Silence: open for the hold (~56 hops), closed after hold + release.
    n = 0;
    while (n < 50) : (n += 1) {
        @memset(&block, 0.5);
        gate.process(&block, 0);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), block[0], 1e-5);
    n = 0;
    while (n < 40) : (n += 1) {
        @memset(&block, 0.5);
        gate.process(&block, 0);
    }
    try std.testing.expectApproxEqAbs(0.5 * dsp.dbToLin((Gate{}).closed_db), block[block.len - 1], 1e-5);
}
