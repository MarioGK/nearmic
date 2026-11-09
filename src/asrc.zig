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
pub const Asrc = struct {
    buf: [8192]f32 = undefined,
    len: usize = 0,
    pos: f64 = 1,
    ratio: f64 = 1,

    pub fn space(self: *const Asrc) usize {
        return self.buf.len - self.len;
    }

    fn compact(self: *Asrc) void {
        const whole: usize = @intFromFloat(@floor(self.pos));
        if (whole < 2) return;
        // Keep one sample of history so read() always has i-1.
        const drop = whole - 1;
        const keep = self.len - drop;
        std.mem.copyForwards(f32, self.buf[0..keep], self.buf[drop..self.len]);
        self.len = keep;
        self.pos -= @floatFromInt(drop);
    }

    pub fn write(self: *Asrc, src: []const f32) void {
        if (src.len == 0) return;
        if (self.len + src.len > self.buf.len) self.compact();
        if (self.len + src.len > self.buf.len) {
            const skip = self.len + src.len - self.buf.len;
            std.mem.copyForwards(f32, self.buf[0 .. self.len - skip], self.buf[skip..self.len]);
            self.len -= skip;
        }
        @memcpy(self.buf[self.len..][0..src.len], src);
        self.len += src.len;
    }

    pub fn canRead(self: *const Asrc, n: usize) bool {
        const need: usize = @intFromFloat(@floor(self.pos));
        return self.len >= need + 3 and self.len >= need + n;
    }

    pub fn read(self: *Asrc, out: []f32) void {
        for (out) |*s| {
            const i: usize = @intFromFloat(@floor(self.pos));
            const t: f32 = @floatCast(self.pos - @floor(self.pos));
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
