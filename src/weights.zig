const std = @import("std");

pub const dpdfnet8_file = "dpdfnet8_48khz_hr.weights.f32";
pub const dpdfnet2_file = "dpdfnet2_48khz_hr.weights.f32";
pub const dpdfnet8_sha256 = "5a5bb67a8619090c54dc2793536fe813fe38123b236d445f3433aafe3075529d";
pub const dpdfnet2_sha256 = "cb7248b8fccbff7b32f254ec2ed0061e604514b2ccd98d997cd081a876424e7b";

pub const dpdfnet8_urls = [_][]const u8{
    "https://raw.githubusercontent.com/ceva-ip/DPDFNet/afa8292f3b8083c3daadd06dbcfe4ff877dd3172/optimized_inference/models/dpdfnet8_48khz_hr/weights.f32",
    "https://github.com/Fovty/hushmic/releases/download/v0.10.0/dpdfnet8_48khz_hr.weights.f32",
};
pub const dpdfnet2_urls = [_][]const u8{
    "https://raw.githubusercontent.com/ceva-ip/DPDFNet/afa8292f3b8083c3daadd06dbcfe4ff877dd3172/optimized_inference/models/dpdfnet2_48khz_hr/weights.f32",
    "https://github.com/Fovty/hushmic/releases/download/v0.10.0/dpdfnet2_48khz_hr.weights.f32",
};

pub fn shareDir(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.local/share/nearmic", .{home});
}

pub fn fileSha256(path: []const u8) ![32]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [1 << 16]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

pub fn hexEq(sum: [32]u8, hex: []const u8) bool {
    if (hex.len != 64) return false;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const hi = hexDigit(hex[i * 2]) orelse return false;
        const lo = hexDigit(hex[i * 2 + 1]) orelse return false;
        if (sum[i] != (hi << 4) | lo) return false;
    }
    return true;
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

pub fn matches(path: []const u8, sha_hex: []const u8) bool {
    const sum = fileSha256(path) catch return false;
    return hexEq(sum, sha_hex);
}

fn candidate(allocator: std.mem.Allocator, dir: []const u8, filename: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, filename });
}

/// First path whose bytes match sha_hex. Caller frees the returned path.
pub fn find(allocator: std.mem.Allocator, filename: []const u8, sha_hex: []const u8) ?[]u8 {
    const home = std.posix.getenv("HOME") orelse "";
    var share: ?[]u8 = null;
    if (home.len != 0) share = shareDir(allocator, home) catch null;
    defer if (share) |p| allocator.free(p);

    const dirs = [_][]const u8{
        share orelse "",
        "third_party/dpdfnet",
        "third_party/models",
        "/tmp/hushmic/assets/models",
        "/usr/share/hushmic/models",
    };
    for (dirs) |dir| {
        if (dir.len == 0) continue;
        const path = candidate(allocator, dir, filename) catch continue;
        if (matches(path, sha_hex)) return path;
        allocator.free(path);
    }
    return null;
}

pub fn readF32(allocator: std.mem.Allocator, path: []const u8) ![]f32 {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(data);
    if (data.len % 4 != 0) return error.BadWeights;
    const out = try allocator.alloc(f32, data.len / 4);
    for (out, 0..) |*sample, i| {
        sample.* = @bitCast(std.mem.readInt(u32, data[i * 4 ..][0..4], .little));
    }
    return out;
}

fn copyVerified(allocator: std.mem.Allocator, src: []const u8, dest: []const u8, sha_hex: []const u8) !void {
    if (!matches(src, sha_hex)) return error.Checksum;
    if (std.fs.path.dirname(dest)) |dir| try std.fs.cwd().makePath(dir);
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{dest});
    defer allocator.free(tmp);
    try std.fs.copyFileAbsolute(src, tmp, .{});
    if (!matches(tmp, sha_hex)) {
        std.fs.cwd().deleteFile(tmp) catch {};
        return error.Checksum;
    }
    try std.posix.rename(tmp, dest);
}

pub fn fetchDpdf(allocator: std.mem.Allocator, which: u8) ![]u8 {
    const filename = if (which == 2) dpdfnet2_file else dpdfnet8_file;
    const sha_hex = if (which == 2) dpdfnet2_sha256 else dpdfnet8_sha256;
    const urls = if (which == 2) &dpdfnet2_urls else &dpdfnet8_urls;
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    const dir = try shareDir(allocator, home);
    defer allocator.free(dir);
    const dest = try candidate(allocator, dir, filename);
    errdefer allocator.free(dest);
    if (matches(dest, sha_hex)) return dest;

    if (find(allocator, filename, sha_hex)) |src| {
        defer allocator.free(src);
        if (!std.mem.eql(u8, src, dest)) try copyVerified(allocator, src, dest, sha_hex);
        if (matches(dest, sha_hex)) return dest;
    }

    const tmp = try std.fmt.allocPrint(allocator, "{s}.dl", .{dest});
    defer allocator.free(tmp);
    if (std.fs.path.dirname(dest)) |parent| try std.fs.cwd().makePath(parent);
    for (urls) |url| {
        const res = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "curl", "-fsSL", "--retry", "2", "-o", tmp, url },
        }) catch continue;
        allocator.free(res.stdout);
        allocator.free(res.stderr);
        switch (res.term) {
            .Exited => |code| if (code != 0) continue,
            else => continue,
        }
        if (!matches(tmp, sha_hex)) {
            std.fs.cwd().deleteFile(tmp) catch {};
            continue;
        }
        try std.posix.rename(tmp, dest);
        return dest;
    }
    allocator.free(dest);
    return error.FetchFailed;
}

test "sha256 of abc" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "abc", .data = "abc" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &buf);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/abc", .{root});
    defer std.testing.allocator.free(path);
    const sum = try fileSha256(path);
    try std.testing.expect(hexEq(sum, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
}
