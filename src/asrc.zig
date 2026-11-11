const std = @import("std");

/// Fractional-rate sample-rate converter for the worker.
///
/// The Maono capture clock and the UAC2 gadget clock are not the same
/// oscillator. On this board PipeWire delivers about 47,761 capture samples
/// per second while the gadget sink consumes 48,006, a 0.5% deficit that
/// drains any fixed jitter buffer within minutes. Because NearMic copies
/// samples through its own ring, PipeWire cannot absorb that ratio for us.
///
/// This converter pulls `ratio` input samples per output sample. A slow
/// servo (in app.zig) steers the ratio around 1.0 from the output-ring fill,
/// so the ring holds its latency instead of underrunning. Interpolation is
/// 4-point Catmull-Rom: flat enough in the voice band that a 0.5% ratio is
/// inaudible, unlike 2-point linear interpolation.
///
/// Invariants: `1 <= pos` and `pos + 2 < len` whenever `canRead(n)` is true.
/// Every path that drops samples moves `pos` with them; the previous version
/// only shifted the array, so a full buffer or a ratio slightly above 1 could
/// leave `pos` past `len` and underflow the next compaction (the 24/7 crash:
/// SIGSEGV every few seconds, restarted by systemd).
pub const Asrc = struct {
    buf: [8192]f32 = undefined,
    len: usize = 0,
    pos: f64 = 1,
    ratio: f64 = 1,

    pub fn space(self: *const Asrc) usize {
        return self.buf.len - self.len;
    }

    /// Drop already-consumed samples from the front. Never drops more than is
    /// buffered and never moves `pos` below 1, so read() always has i-1.
    fn compact(self: *Asrc) void {
        if (self.len == 0) return;
        const whole: usize = @intFromFloat(@floor(self.pos));
        if (whole < 2) return;
        const want = whole - 1;
        if (want > self.len) return;
        const keep = self.len - want;
        std.mem.copyForwards(f32, self.buf[0..keep], self.buf[want..self.len]);
        self.len = keep;
        self.pos -= @floatFromInt(want);
        if (self.pos < 1) self.pos = 1;
    }

    pub fn write(self: *Asrc, src: []const f32) void {
        if (src.len == 0) return;
        if (self.len + src.len > self.buf.len) self.compact();
        if (self.len + src.len > self.buf.len) {
            // Still not enough room: drop the oldest samples and move the read
            // cursor with them so the timeline stays continuous.
            const want = self.len + src.len - self.buf.len;
            const drop = @min(want, self.len);
            std.mem.copyForwards(f32, self.buf[0 .. self.len - drop], self.buf[drop..self.len]);
            self.len -= drop;
            self.pos = @max(self.pos - @as(f64, @floatFromInt(drop)), 1);
        }
        @memcpy(self.buf[self.len..][0..src.len], src);
        self.len += src.len;
    }

    /// Input samples buffered but not consumed yet. They are latency.
    pub fn pending(self: *const Asrc) usize {
        const used: usize = @intFromFloat(@floor(self.pos));
        return if (self.len > used) self.len - used else 0;
    }

    pub fn canRead(self: *const Asrc, n: usize) bool {
        const need: usize = @intFromFloat(@floor(self.pos));
        return need >= 1 and self.len >= need + 3 and self.len >= need + n;
    }

    pub fn read(self: *Asrc, out: []f32) void {
        for (out) |*s| {
            const i: usize = @intFromFloat(@floor(self.pos));
            const t: f32 = @floatCast(self.pos - @floor(self.pos));
            // canRead() guarantees this; the check keeps a logic error from
            // turning into an out-of-bounds read on a 24/7 appliance.
            if (i < 1 or i + 2 >= self.len) {
                s.* = 0;
                self.pos += self.ratio;
                continue;
            }
            s.* = cubic(self.buf[i - 1], self.buf[i], self.buf[i + 1], self.buf[i + 2], t);
            self.pos += self.ratio;
        }
        if (self.pos >= 2048) self.compact();
    }
};

fn cubic(p0: f32, p1: f32, p2: f32, p3: f32, t: f32) f32 {
    // Catmull-Rom, the same 4-tap kernel used for streaming SRC.
    const a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3;
    const b = p0 - 2.5 * p1 + 2.0 * p2 - 0.5 * p3;
    const c = -0.5 * p0 + 0.5 * p2;
    return ((a * t + b) * t + c) * t + p1;
}

test "asrc at unity is transparent and preserves a sine" {
    var a = Asrc{};
    var phase: f32 = 0;
    const n: usize = 4096;
    var in: [256]f32 = undefined;
    var out: [256]f32 = undefined;
    var sum_in: f32 = 0;
    var sum_out: f32 = 0;
    var produced: usize = 0;
    var written: usize = 0;
    while (written < n * 2) {
        for (&in) |*s| {
            s.* = @sin(phase);
            phase += 2 * std.math.pi * 1000 / @as(f32, 48000);
        }
        for (in) |s| sum_in += s * s;
        a.write(&in);
        written += in.len;
        while (a.canRead(out.len)) {
            a.read(&out);
            for (out) |s| sum_out += s * s;
            produced += out.len;
        }
    }
    // Unity ratio: mean square must match (edge trim is under one hop).
    const mean_in = sum_in / @as(f32, @floatFromInt(written));
    const mean_out = sum_out / @as(f32, @floatFromInt(produced));
    try std.testing.expectApproxEqAbs(mean_in, mean_out, 0.01);
}

test "asrc at a 0.5 percent ratio tracks a slow clock" {
    var a = Asrc{ .ratio = 0.995 };
    var phase: f32 = 0;
    var in: [1024]f32 = undefined;
    var out: [256]f32 = undefined;
    var consumed: usize = 0;
    var produced: usize = 0;
    var steps: usize = 0;
    while (steps < 40) : (steps += 1) {
        for (&in) |*s| {
            s.* = @sin(phase);
            phase += 2 * std.math.pi * 1000 / @as(f32, 48000);
        }
        a.write(&in);
        while (a.canRead(out.len)) {
            a.read(&out);
            produced += out.len;
            for (out) |s| try std.testing.expect(std.math.isFinite(s));
        }
        consumed += in.len;
    }
    // 10240 input samples at 0.995 -> about 10291 output samples.
    try std.testing.expect(produced >= consumed);
    try std.testing.expect(produced - consumed < (consumed / 100) + 512);
}

test "asrc survives a ratio above 1 with a starved buffer" {
    // This is the shape that used to segfault: the cursor advances slightly
    // faster than the buffer drains, so a compaction can ask for more samples
    // than are buffered.
    var a = Asrc{ .ratio = 1.015 };
    var in: [64]f32 = undefined;
    var out: [256]f32 = undefined;
    var step: usize = 0;
    while (step < 4000) : (step += 1) {
        for (&in, 0..) |*s, i| s.* = @as(f32, @floatFromInt(i)) * 1e-4;
        // Irregular, often tiny writes: the buffer hovers at its minimum.
        a.write(in[0 .. (step % 5) + 1]);
        while (a.canRead(out.len)) {
            a.read(&out);
            for (out) |s| try std.testing.expect(std.math.isFinite(s));
        }
        try std.testing.expect(a.pos >= 1);
        try std.testing.expect(a.len <= a.buf.len);
    }
}

test "asrc survives a completely full buffer" {
    var a = Asrc{ .ratio = 1.013 };
    var in: [1024]f32 = undefined;
    var out: [256]f32 = undefined;
    for (&in, 0..) |*s, i| s.* = @as(f32, @floatFromInt(i % 64)) * 1e-3;
    var step: usize = 0;
    while (step < 2000) : (step += 1) {
        a.write(&in);
        if (step % 7 == 0) {
            while (a.canRead(out.len)) a.read(&out);
        }
        try std.testing.expect(a.len <= a.buf.len);
        try std.testing.expect(a.pos >= 1);
    }
}
