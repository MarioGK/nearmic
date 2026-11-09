const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shipped = b.option([]const u8, "engine", "Shipped engine: dsp, dsp-dereverb, or leveler") orelse "dsp-dereverb";

    const exe = addExe(b, target, optimize, "nearmic", shipped, false);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run NearMic").dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/test_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);

    const bake = addExe(b, target, optimize, "nearmic-bakeoff", shipped, true);
    const bake_run = b.addRunArtifact(bake);
    bake_run.addArgs(&.{ "bakeoff", "--write", "bench/RESULTS.md" });
    bake_run.setCwd(.{ .cwd_relative = b.build_root.path orelse "." });
    b.step("bakeoff", "Run the bake-off and write bench/RESULTS.md").dependOn(&bake_run.step);

    const ldd = b.addSystemCommand(&.{ "sh", "-c", "ldd zig-out/bin/nearmic | awk 'NR>0 {print}'" });
    ldd.step.dependOn(b.getInstallStep());
    b.step("ldd", "Show dynamic libraries of the release binary").dependOn(&ldd.step);
}

fn addExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    shipped: []const u8,
    with_speex: bool,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const opts = b.addOptions();
    opts.addOption([]const u8, "shipped", shipped);
    opts.addOption(bool, "with_speex", with_speex);
    exe.root_module.addOptions("build_options", opts);
    exe.linkLibC();
    exe.linkSystemLibrary("dl");
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/pipewire-0.3" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/spa-0.2" });
    exe.addCSourceFile(.{
        .file = b.path("src/c/pw_glue.c"),
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE", "-Wall" },
    });
    if (with_speex) {
        exe.addCSourceFile(.{
            .file = b.path("src/c/speex_eng.c"),
            .flags = &.{"-std=c11"},
        });
        exe.addObjectFile(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu/libspeexdsp.a" });
        exe.linkSystemLibrary("m");
    }
    return exe;
}
