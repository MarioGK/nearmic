const std = @import("std");
const dsp = @import("dsp.zig");

/// Turns an engine that eats a fixed frame into the 256-sample worker hop.
/// When the frame is larger than the hop, `pad` zeros sit in front of the
/// engine output so a hop is always ready. Bypass uses `delaySamples`, which
/// is the engine delay plus that pad.
pub const Adapter = struct {
    frame: usize,
    algo_delay: usize,
    pad: usize = 0,
    gain_lin: f32 = 1,
    in_buf: [2048]f32 = undefined,
    in_len: usize = 0,
    out_buf: [8192]f32 = undefined,
    out_len: usize = 0,
    ctx: *anyopaque = undefined,
    process_frame: *const fn (*anyopaque, []const f32, []f32) void = undefined,
    /// Optional: the engine's speech confidence (0..1) for the frame it just
    /// processed. Read after every frame; `vad` is -1 for engines without one.
    vad_fn: ?*const fn (*anyopaque) f32 = null,
    vad: f32 = -1,
    started: bool = false,

    pub fn begin(self: *Adapter) void {
        self.pad = if (self.frame == dsp.hop) 0 else self.frame;
        self.in_len = 0;
        self.out_len = self.pad;
        @memset(self.out_buf[0..self.pad], 0);
        self.started = true;
    }

    pub fn delaySamples(self: Adapter) usize {
        const pad = if (self.started) self.pad else if (self.frame == dsp.hop) 0 else self.frame;
        return self.algo_delay + pad;
    }

    pub fn setGainDb(self: *Adapter, db: f32) void {
        if (db == 0) {
            self.gain_lin = 1;
            return;
        }
        self.gain_lin = std.math.pow(f32, 10, db / 20);
    }

    pub fn pushHop(self: *Adapter, input: []const f32, output: []f32) void {
        std.debug.assert(input.len == dsp.hop and output.len == dsp.hop);
        std.debug.assert(self.frame > 0 and self.frame <= 1024);
        std.debug.assert(self.in_len + dsp.hop <= self.in_buf.len);
        @memcpy(self.in_buf[self.in_len..][0..dsp.hop], input);
        self.in_len += dsp.hop;
        while (self.in_len >= self.frame) {
            var frame_out: [1024]f32 = undefined;
            self.process_frame(self.ctx, self.in_buf[0..self.frame], frame_out[0..self.frame]);
            if (self.vad_fn) |vad_fn| self.vad = vad_fn(self.ctx);
            std.debug.assert(self.out_len + self.frame <= self.out_buf.len);
            @memcpy(self.out_buf[self.out_len..][0..self.frame], frame_out[0..self.frame]);
            self.out_len += self.frame;
            std.mem.copyForwards(f32, self.in_buf[0 .. self.in_len - self.frame], self.in_buf[self.frame..self.in_len]);
            self.in_len -= self.frame;
        }
        if (self.out_len < dsp.hop) {
            @memset(output, 0);
            return;
        }
        const g = self.gain_lin;
        if (g == 1) {
            @memcpy(output, self.out_buf[0..dsp.hop]);
        } else {
            for (output, self.out_buf[0..dsp.hop]) |*sample, raw| sample.* = raw * g;
        }
        std.mem.copyForwards(f32, self.out_buf[0 .. self.out_len - dsp.hop], self.out_buf[dsp.hop..self.out_len]);
        self.out_len -= dsp.hop;
    }
};

fn identityFrame(ctx: *anyopaque, in: []const f32, out: []f32) void {
    _ = ctx;
    @memcpy(out, in);
}

test "480-frame identity is delayed by one frame and never underruns the hop" {
    var adapter = Adapter{ .frame = 480, .algo_delay = 2400 };
    adapter.begin();
    adapter.ctx = &adapter;
    adapter.process_frame = identityFrame;
    try std.testing.expectEqual(@as(usize, 2880), adapter.delaySamples());
    const n: usize = dsp.hop * 40;
    const input = try std.testing.allocator.alloc(f32, n);
    defer std.testing.allocator.free(input);
    const output = try std.testing.allocator.alloc(f32, n);
    defer std.testing.allocator.free(output);
    @memset(input, 0);
    input[0] = 0.5;
    var offset: usize = 0;
    while (offset < n) : (offset += dsp.hop) {
        adapter.pushHop(input[offset..][0..dsp.hop], output[offset..][0..dsp.hop]);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), output[480], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), output[479], 1e-6);
    try std.testing.expect(adapter.out_len < adapter.out_buf.len);
}

test "256-frame engine adds no fifo pad" {
    var adapter = Adapter{ .frame = dsp.hop, .algo_delay = dsp.hop };
    adapter.begin();
    adapter.process_frame = identityFrame;
    adapter.ctx = &adapter;
    try std.testing.expectEqual(dsp.hop, adapter.delaySamples());
    var input = [_]f32{0} ** dsp.hop;
    var output = [_]f32{0} ** dsp.hop;
    input[0] = 1;
    adapter.pushHop(&input, &output);
    try std.testing.expectApproxEqAbs(@as(f32, 1), output[0], 1e-6);
}
