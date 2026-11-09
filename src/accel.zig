const std = @import("std");
const builtin = @import("builtin");
const dsp = @import("dsp.zig");

extern "c" fn dlopen(path: [*:0]const u8, flags: c_int) ?*anyopaque;
extern "c" fn dlclose(handle: *anyopaque) c_int;

pub const rknn_model_file = "enhancer.rknn";

pub const Probe = struct {
    simd: []const u8,
    cpu_model: []const u8,
    rknn_library: bool,
    rknn_device: bool,
    rknn_model: bool,
    opencl: bool,
    /// Speech enhancement does not call the NPU. ROCK 4 Plus has no RKNPU,
    /// and this tree does not ship a converted RKNN speech model.
    npu_invoked: bool,
    backend: []const u8,
};

pub fn probe() Probe {
    return .{
        .simd = dsp.compiledSimd(),
        .cpu_model = dsp.cpuModelName(),
        .rknn_library = libraryPresent(&.{ "librknnrt.so", "librknnrt.so.1" }),
        .rknn_device = devicePresent(&.{
            "/dev/rknpu",
            "/dev/rknpu0",
            "/sys/devices/platform/rknpu",
            "/sys/devices/platform/fdab0000.npu",
        }),
        .rknn_model = modelPresent(),
        .opencl = libraryPresent(&.{ "libOpenCL.so.1", "libOpenCL.so", "libmali.so", "libmali.so.1" }),
        .npu_invoked = false,
        .backend = "cpu",
    };
}

pub fn write(writer: anytype, item: Probe) !void {
    try writer.print(
        "simd={s} cpu_model={s} rknn_library={s} rknn_device={s} rknn_model={s} opencl={s} backend={s} npu_invoked={s}\n",
        .{
            item.simd,
            item.cpu_model,
            yn(item.rknn_library),
            yn(item.rknn_device),
            yn(item.rknn_model),
            yn(item.opencl),
            item.backend,
            yn(item.npu_invoked),
        },
    );
}

fn yn(on: bool) []const u8 {
    return if (on) "yes" else "no";
}

fn libraryPresent(names: []const [:0]const u8) bool {
    for (names) |name| {
        const handle = dlopen(name, 1) orelse continue;
        _ = dlclose(handle);
        return true;
    }
    return false;
}

fn devicePresent(paths: []const []const u8) bool {
    for (paths) |path| {
        std.fs.accessAbsolute(path, .{}) catch continue;
        return true;
    }
    return false;
}

fn modelPresent() bool {
    const home = std.posix.getenv("HOME") orelse return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/.local/share/nearmic/{s}", .{ home, rknn_model_file }) catch return false;
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

/// Runtime hook for an RKNN speech enhancer. Returns false on this tree:
/// there is no converted model, and the ROCK 4 Plus SoC has no NPU.
/// A future model would be `~/.local/share/nearmic/enhancer.rknn`, loaded
/// only when librknnrt.so and a device node are both present. Until that
/// file has a known tensor map, the CPU ensemble stays selected.
pub fn selectNpu() bool {
    const item = probe();
    if (!item.rknn_library or !item.rknn_device or !item.rknn_model) return false;
    return false;
}

test "accel probe stays on the cpu" {
    const item = probe();
    try std.testing.expect(item.simd.len != 0);
    try std.testing.expect(item.cpu_model.len != 0);
    try std.testing.expect(!item.npu_invoked);
    try std.testing.expectEqualStrings("cpu", item.backend);
    try std.testing.expect(!selectNpu());
    try std.testing.expect(builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64);
}
