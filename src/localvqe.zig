const std = @import("std");
const dsp = @import("dsp.zig");

const rtld_now: c_int = 2;

extern "c" fn dlopen(filename: [*:0]const u8, flags: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern "c" fn dlclose(handle: ?*anyopaque) c_int;

const OptionsNew = *const fn () callconv(.C) usize;
const OptionsFree = *const fn (usize) callconv(.C) void;
const SetPath = *const fn (usize, [*:0]const u8) callconv(.C) c_int;
const SetInt = *const fn (usize, c_int) callconv(.C) c_int;
const NewCtx = *const fn (usize) callconv(.C) usize;
const ProcessFrame = *const fn (usize, [*]const f32, [*]const f32, c_int, [*]f32) callconv(.C) c_int;
const FreeCtx = *const fn (usize) callconv(.C) void;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    lib: *anyopaque,
    ctx: usize,
    down: dsp.Resampler3,
    up: dsp.Resampler3,
    process_frame: ProcessFrame,
    free_ctx: FreeCtx,

    pub fn open(allocator: std.mem.Allocator, name: []const u8) !Engine {
        var lib_buf: [std.fs.max_path_bytes]u8 = undefined;
        var model_buf: [std.fs.max_path_bytes]u8 = undefined;
        const lib_path = findLib(&lib_buf) orelse return error.Unavailable;
        const model_path = findModel(&model_buf, modelFile(name) orelse return error.Unavailable) orelse return error.Unavailable;
        const lib_z = try allocator.dupeZ(u8, lib_path);
        defer allocator.free(lib_z);
        const model_z = try allocator.dupeZ(u8, model_path);
        defer allocator.free(model_z);

        const lib = dlopen(lib_z, rtld_now) orelse return error.Unavailable;
        errdefer _ = dlclose(lib);
        const options_new = cast(OptionsNew, dlsym(lib, "localvqe_options_new")) orelse return error.Unavailable;
        const options_free = cast(OptionsFree, dlsym(lib, "localvqe_options_free")) orelse return error.Unavailable;
        const set_model = cast(SetPath, dlsym(lib, "localvqe_options_set_model_path")) orelse return error.Unavailable;
        const set_threads = cast(SetInt, dlsym(lib, "localvqe_options_set_threads")) orelse return error.Unavailable;
        const new_ctx = cast(NewCtx, dlsym(lib, "localvqe_new_with_options")) orelse return error.Unavailable;
        const process_frame = cast(ProcessFrame, dlsym(lib, "localvqe_process_frame_f32")) orelse return error.Unavailable;
        const free_ctx = cast(FreeCtx, dlsym(lib, "localvqe_free")) orelse return error.Unavailable;

        const opts = options_new();
        if (opts == 0) return error.Unavailable;
        defer options_free(opts);
        if (set_model(opts, model_z) != 0) return error.Unavailable;
        if (set_threads(opts, 1) != 0) return error.Unavailable;
        const ctx = new_ctx(opts);
        if (ctx == 0) return error.Unavailable;

        return .{
            .allocator = allocator,
            .lib = lib,
            .ctx = ctx,
            .down = dsp.Resampler3.init(),
            .up = dsp.Resampler3.init(),
            .process_frame = process_frame,
            .free_ctx = free_ctx,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.free_ctx(self.ctx);
        _ = dlclose(self.lib);
    }
};

pub fn process(ctx: *anyopaque, input: []const f32, output: []f32) void {
    const eng: *Engine = @ptrCast(@alignCast(ctx));
    var mic: [256]f32 = undefined;
    var model_out: [256]f32 = undefined;
    const silent = [_]f32{0} ** 256;
    const got = eng.down.decimate(input, &mic);
    if (got < mic.len) @memset(mic[got..], 0);
    if (eng.process_frame(eng.ctx, &mic, &silent, 256, &model_out) != 0) {
        @memset(output, 0);
        return;
    }
    const up = eng.up.interpolate(&model_out, output);
    if (up < output.len) @memset(output[up..], 0);
}

pub fn probe(name: []const u8) struct { ok: bool, reason: []const u8 } {
    const file = modelFile(name) orelse return .{ .ok = false, .reason = "unknown LocalVQE model" };
    var lib_buf: [std.fs.max_path_bytes]u8 = undefined;
    var model_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (findLib(&lib_buf) == null) {
        return .{ .ok = false, .reason = "liblocalvqe.so not found; GGML cannot be statically linked" };
    }
    if (findModel(&model_buf, file) == null) {
        return .{ .ok = false, .reason = "gguf not found in ~/.local/share/nearmic or /tmp/models" };
    }
    return .{ .ok = true, .reason = "" };
}

fn modelFile(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "localvqe-v1.2")) return "localvqe-v1.2-1.3M-f32.gguf";
    if (std.mem.eql(u8, name, "localvqe-v1.3")) return "localvqe-v1.3-4.8M-f32.gguf";
    return null;
}

fn cast(comptime T: type, ptr: ?*anyopaque) ?T {
    const raw = ptr orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn exists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn findLib(buf: []u8) ?[]const u8 {
    if (std.posix.getenv("NEARMIC_LOCALVQE_LIB")) |path| {
        if (exists(path) and path.len < buf.len) {
            @memcpy(buf[0..path.len], path);
            return buf[0..path.len];
        }
    }
    const fixed = "/tmp/LocalVQE/ggml/build/bin/liblocalvqe.so";
    if (exists(fixed)) {
        @memcpy(buf[0..fixed.len], fixed);
        return buf[0..fixed.len];
    }
    const home = std.posix.getenv("HOME") orelse return null;
    const path = std.fmt.bufPrint(buf, "{s}/.local/share/nearmic/liblocalvqe.so", .{home}) catch return null;
    if (exists(path)) return path;
    return null;
}

fn findModel(buf: []u8, filename: []const u8) ?[]const u8 {
    if (std.posix.getenv("HOME")) |home| {
        const path = std.fmt.bufPrint(buf, "{s}/.local/share/nearmic/{s}", .{ home, filename }) catch return null;
        if (exists(path)) return path;
    }
    const tmp = std.fmt.bufPrint(buf, "/tmp/models/{s}", .{filename}) catch return null;
    if (exists(tmp)) return tmp;
    const third = std.fmt.bufPrint(buf, "third_party/localvqe/{s}", .{filename}) catch return null;
    std.fs.cwd().access(third, .{}) catch return null;
    return third;
}
