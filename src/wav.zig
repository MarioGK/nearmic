const std = @import("std");

pub const Pcm = struct {
    samples: []f32,
    channels: u16,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Pcm) void {
        self.allocator.free(self.samples);
        self.* = undefined;
    }
};

pub fn readWav(allocator: std.mem.Allocator, path: []const u8) !Pcm {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(data);
    if (data.len < 44) return error.BadWav;
    if (!std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WAVE")) return error.BadWav;
    var offset: usize = 12;
    var format: u16 = 0;
    var channels: u16 = 0;
    var rate: u32 = 0;
    var bits: u16 = 0;
    var pcm: []const u8 = &.{};
    while (offset + 8 <= data.len) {
        const id = data[offset..][0..4];
        const size = std.mem.readInt(u32, data[offset + 4 ..][0..4], .little);
        const body = offset + 8;
        if (body + size > data.len) return error.BadWav;
        if (std.mem.eql(u8, id, "fmt ")) {
            if (size < 16) return error.BadWav;
            format = std.mem.readInt(u16, data[body..][0..2], .little);
            channels = std.mem.readInt(u16, data[body + 2 ..][0..2], .little);
            rate = std.mem.readInt(u32, data[body + 4 ..][0..4], .little);
            bits = std.mem.readInt(u16, data[body + 14 ..][0..2], .little);
        } else if (std.mem.eql(u8, id, "data")) {
            pcm = data[body .. body + size];
        }
        offset = body + size + (size & 1);
    }
    if (rate != 48000) return error.UnsupportedRate;
    if (channels == 0 or channels > 2) return error.UnsupportedChannels;
    const samples_n = switch (format) {
        1 => blk: {
            if (bits != 16) return error.UnsupportedFormat;
            break :blk pcm.len / 2 / channels;
        },
        3 => blk: {
            if (bits != 32) return error.UnsupportedFormat;
            break :blk pcm.len / 4 / channels;
        },
        else => return error.UnsupportedFormat,
    };
    const mono = try allocator.alloc(f32, samples_n);
    errdefer allocator.free(mono);
    var i: usize = 0;
    while (i < samples_n) : (i += 1) {
        if (format == 1) {
            var acc: f32 = 0;
            var c: usize = 0;
            while (c < channels) : (c += 1) {
                const o = (i * channels + c) * 2;
                const s = std.mem.readInt(i16, pcm[o..][0..2], .little);
                acc += @as(f32, @floatFromInt(s)) / 32768.0;
            }
            mono[i] = acc / @as(f32, @floatFromInt(channels));
        } else {
            var acc: f32 = 0;
            var c: usize = 0;
            while (c < channels) : (c += 1) {
                const o = (i * channels + c) * 4;
                acc += @as(f32, @bitCast(std.mem.readInt(u32, pcm[o..][0..4], .little)));
            }
            mono[i] = acc / @as(f32, @floatFromInt(channels));
        }
    }
    return .{ .samples = mono, .channels = 1, .allocator = allocator };
}

pub fn writeWav(path: []const u8, samples: []const f32) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    const data_bytes: u32 = @intCast(samples.len * 2);
    var header: [44]u8 = undefined;
    @memcpy(header[0..4], "RIFF");
    std.mem.writeInt(u32, header[4..8], 36 + data_bytes, .little);
    @memcpy(header[8..12], "WAVE");
    @memcpy(header[12..16], "fmt ");
    std.mem.writeInt(u32, header[16..20], 16, .little);
    std.mem.writeInt(u16, header[20..22], 1, .little);
    std.mem.writeInt(u16, header[22..24], 1, .little);
    std.mem.writeInt(u32, header[24..28], 48000, .little);
    std.mem.writeInt(u32, header[28..32], 48000 * 2, .little);
    std.mem.writeInt(u16, header[32..34], 2, .little);
    std.mem.writeInt(u16, header[34..36], 16, .little);
    @memcpy(header[36..40], "data");
    std.mem.writeInt(u32, header[40..44], data_bytes, .little);
    try file.writeAll(&header);
    var buf: [4096]u8 = undefined;
    var pending: usize = 0;
    for (samples) |s| {
        const clipped = std.math.clamp(s, -1, 1);
        const iv: i16 = @intFromFloat(clipped * 32767);
        std.mem.writeInt(i16, buf[pending..][0..2], iv, .little);
        pending += 2;
        if (pending == buf.len) {
            try file.writeAll(&buf);
            pending = 0;
        }
    }
    if (pending > 0) try file.writeAll(buf[0..pending]);
}

test "wav roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath(".", &path_buf);
    const file_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/t.wav", .{path});
    defer std.testing.allocator.free(file_path);
    const tone = [_]f32{ 0, 0.25, -0.5, 0.75, -1, 1 };
    try writeWav(file_path, &tone);
    var pcm = try readWav(std.testing.allocator, file_path);
    defer pcm.deinit();
    try std.testing.expectEqual(tone.len, pcm.samples.len);
    try std.testing.expectApproxEqAbs(tone[2], pcm.samples[2], 1.0 / 32768.0);
}
