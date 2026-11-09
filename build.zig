const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shipped = b.option([]const u8, "engine", "Shipped bake-off engine. The runtime engine comes from config.toml") orelse "dsp-dereverb";
    const bundle = b.option(bool, "bundle", "Statically link RNNoise and native DPDFNet") orelse false;

    const libs = if (bundle) findBundle(b) else Bundle{};
    const exe = addExe(b, target, optimize, "nearmic", shipped, libs);
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
    linkRuntime(b, tests, shipped, libs);
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);

    const bake = addExe(b, target, optimize, "nearmic-bakeoff", shipped, .{});
    const bake_run = b.addRunArtifact(bake);
    bake_run.addArgs(&.{ "bakeoff", "--write", "bench/RESULTS.md" });
    bake_run.setCwd(.{ .cwd_relative = b.build_root.path orelse "." });
    b.step("bakeoff", "Run the bake-off and write bench/RESULTS.md").dependOn(&bake_run.step);

    const ldd = b.addSystemCommand(&.{ "sh", "-c", "ldd zig-out/bin/nearmic | awk 'NR>0 {print}'" });
    ldd.step.dependOn(b.getInstallStep());
    b.step("ldd", "Show dynamic libraries of the release binary").dependOn(&ldd.step);
}

const Bundle = struct {
    rnnoise_a: ?[]const u8 = null,
    rnnoise_inc: ?[]const u8 = null,
    dpdf_a: ?[]const u8 = null,
    dpdf_inc: ?[]const u8 = null,
    fftw_a: ?[]const u8 = null,
    cpuinfo_o: ?[]const u8 = null,
};

fn firstExisting(paths: []const []const u8) ?[]const u8 {
    for (paths) |path| {
        std.fs.accessAbsolute(path, .{}) catch {
            std.fs.cwd().access(path, .{}) catch continue;
            return path;
        };
        return path;
    }
    return null;
}

fn findBundle(b: *std.Build) Bundle {
    const rnnoise_a = firstExisting(&.{
        b.pathFromRoot("third_party/rnnoise/librnnoise.a"),
        "/tmp/librnnoise.a",
    });
    const rnnoise_inc = firstExisting(&.{
        b.pathFromRoot("third_party/rnnoise/include"),
        "/tmp/rnnoise/include",
    });
    const dpdf_a = firstExisting(&.{
        b.pathFromRoot("third_party/dpdfnet/libdpdfnet.a"),
        "/tmp/dpdf-build/libdpdfnet.a",
    });
    const dpdf_inc = firstExisting(&.{
        b.pathFromRoot("third_party/dpdfnet/include"),
        "/tmp/hushmic/crates/hushmic-denoiser/native/include",
    });
    const fftw_a = firstExisting(&.{
        b.pathFromRoot("third_party/fftw/libfftw3f.a"),
        "/usr/lib/x86_64-linux-gnu/libfftw3f.a",
        "/usr/lib/libfftw3f.a",
    });
    if (rnnoise_a == null or rnnoise_inc == null or dpdf_a == null or dpdf_inc == null or fftw_a == null) {
        std.debug.print(
            \\-Dbundle=true needs RNNoise, native DPDFNet, and libfftw3f.a.
            \\Looked in third_party/ and /tmp. Run scripts/bundle.sh first.
            \\
        , .{});
        std.process.exit(1);
    }
    return .{
        .rnnoise_a = rnnoise_a,
        .rnnoise_inc = rnnoise_inc,
        .dpdf_a = dpdf_a,
        .dpdf_inc = dpdf_inc,
        .fftw_a = fftw_a,
        .cpuinfo_o = ensureCpuinfo(b),
    };
}

fn ensureCpuinfo(b: *std.Build) []const u8 {
    const cached = firstExisting(&.{
        b.pathFromRoot("third_party/dpdfnet/cpuinfo.o"),
    });
    if (cached) |path| return path;
    const dest = std.fs.path.join(b.allocator, &.{ b.cache_root.path orelse ".", "nearmic-cpuinfo.o" }) catch @panic("oom");
    const script = std.fmt.allocPrint(b.allocator,
        \\set -eu
        \\src=$(gcc -print-file-name=libgcc.a)
        \\tmp=$(mktemp -d)
        \\(cd "$tmp" && ar x "$src" cpuinfo.o)
        \\mv "$tmp/cpuinfo.o" "{s}"
        \\rm -rf "$tmp"
    , .{dest}) catch @panic("oom");
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "sh", "-c", script },
    }) catch {
        std.debug.print("failed to extract cpuinfo.o from libgcc.a (gcc and ar are required for -Dbundle)\n", .{});
        std.process.exit(1);
    };
    if (result.stderr.len != 0) std.debug.print("{s}\n", .{result.stderr});
    switch (result.term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("cpuinfo extract failed\n", .{});
            std.process.exit(1);
        },
        else => std.process.exit(1),
    }
    return dest;
}

fn addExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    shipped: []const u8,
    bundle: Bundle,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkRuntime(b, exe, shipped, bundle);
    return exe;
}

fn linkRuntime(
    b: *std.Build,
    step: *std.Build.Step.Compile,
    shipped: []const u8,
    bundle: Bundle,
) void {
    const opts = b.addOptions();
    opts.addOption([]const u8, "shipped", shipped);
    opts.addOption(bool, "with_speex", true);
    opts.addOption(bool, "with_rnnoise", bundle.rnnoise_a != null);
    opts.addOption(bool, "with_dpdfnet", bundle.dpdf_a != null);
    step.root_module.addOptions("build_options", opts);
    step.linkLibC();
    step.linkSystemLibrary("m");
    step.linkSystemLibrary("dl");
    step.addIncludePath(.{ .cwd_relative = "/usr/include/pipewire-0.3" });
    step.addIncludePath(.{ .cwd_relative = "/usr/include/spa-0.2" });
    step.addCSourceFile(.{
        .file = b.path("src/c/pw_glue.c"),
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE", "-Wall" },
    });
    step.addCSourceFile(.{
        .file = b.path("src/c/speex_eng.c"),
        .flags = &.{"-std=c11"},
    });
    step.addObjectFile(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu/libspeexdsp.a" });
    if (bundle.rnnoise_a) |lib| {
        step.addIncludePath(.{ .cwd_relative = bundle.rnnoise_inc.? });
        step.addCSourceFile(.{
            .file = b.path("src/c/rnnoise_eng.c"),
            .flags = &.{"-std=c11"},
        });
        step.addObjectFile(.{ .cwd_relative = lib });
    }
    if (bundle.dpdf_a) |lib| {
        step.addIncludePath(.{ .cwd_relative = bundle.dpdf_inc.? });
        step.addIncludePath(.{ .cwd_relative = "/usr/include" });
        step.addCSourceFile(.{
            .file = b.path("src/c/dpdf_eng.c"),
            .flags = &.{ "-std=c11", "-D_GNU_SOURCE" },
        });
        step.addObjectFile(.{ .cwd_relative = lib });
        step.addObjectFile(.{ .cwd_relative = bundle.fftw_a.? });
        step.addObjectFile(.{ .cwd_relative = bundle.cpuinfo_o.? });
    }
}
