const std = @import("std");
const app = @import("app.zig");
const bench = @import("bench.zig");
const config = @import("config.zig");
const engines = @import("engines.zig");
const install = @import("install.zig");
const qa = @import("qa.zig");
const weights = @import("weights.zig");

fn usage() void {
    std.debug.print(
        \\NearMic {s}
        \\Live virtual microphone for a far Comica VM40. One binary, Linux and PipeWire.
        \\
        \\  nearmic                     install the user service and start it
        \\  nearmic setup               same as no arguments
        \\  nearmic run                 the daemon (what the service runs)
        \\  nearmic engines
        \\  nearmic engine NAME
        \\  nearmic gain DB
        \\  nearmic qa
        \\  nearmic fetch [dpdfnet2|dpdfnet8]
        \\  nearmic enhance in.wav out.wav
        \\  nearmic bench               print the bake-off
        \\  nearmic bakeoff --write bench/RESULTS.md
        \\  nearmic fixture DIR         write the shared far-mic files
        \\  nearmic score NAME CPU_S P99_NS BLOCK RATE AUDIO_SAMPLES far.f32 impulse.f32 [--level]
        \\  nearmic doctor
        \\  nearmic status
        \\  nearmic mode suppress|bypass|mute
        \\  nearmic listen on|off
        \\  nearmic quit
        \\
        \\Config is $HOME/.config/nearmic/config.toml. The default engine is dsp-dereverb.
        \\Turn off the noise suppressor inside Discord or the browser. Two denoisers fight.
        \\listen plays the processed voice to the default speakers. Use headphones.
        \\
    , .{app.version});
}

fn setup(allocator: std.mem.Allocator) !void {
    const exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe);
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    install.installUser(allocator, .{
        .home = home,
        .exe_path = exe,
        .start_service = true,
    }) catch |err| switch (err) {
        error.Systemd => {
            std.debug.print("systemd --user is unavailable; running in the foreground\n", .{});
            try app.runDaemon(allocator);
            return;
        },
        else => return err,
    };
    std.debug.print("NearMic {s} is installed. The user service runs ~/.local/bin/nearmic run.\n", .{app.version});
}

fn liveOrSave(allocator: std.mem.Allocator, command: []const u8, key: []const u8, rendered: []const u8) !void {
    const reply = app.sendCommand(allocator, command) catch |err| switch (err) {
        error.NotRunning => {
            const home = std.posix.getenv("HOME") orelse return error.NoHome;
            const path = try config.configPath(allocator, home);
            defer allocator.free(path);
            try config.patchFile(allocator, path, key, rendered);
            std.debug.print("{s} saved in {s}. NearMic is not running.\n", .{ key, path });
            return;
        },
        else => return err,
    };
    defer allocator.free(reply);
    std.debug.print("{s}", .{reply});
}

fn fetchOne(allocator: std.mem.Allocator, which: u8) !void {
    const path = weights.fetchDpdf(allocator, which) catch |err| {
        const name = if (which == 2) "dpdfnet2" else "dpdfnet8";
        std.debug.print("fetch {s} failed ({s}). QA skips it until the weights are present.\n", .{ name, @errorName(err) });
        return err;
    };
    defer allocator.free(path);
    std.debug.print("weights {s}\n", .{path});
}

fn fetchCmd(allocator: std.mem.Allocator, name: ?[]const u8) !void {
    if (name == null or std.mem.eql(u8, name.?, "dpdfnet8")) try fetchOne(allocator, 8);
    if (name == null or std.mem.eql(u8, name.?, "dpdfnet2")) try fetchOne(allocator, 2);
    if (name) |engine| {
        if (std.mem.eql(u8, engine, "localvqe-v1.2") or std.mem.eql(u8, engine, "localvqe-v1.3")) {
            const avail = engines.availability(engine);
            if (avail.ok) {
                std.debug.print("{s} is already available via dlopen\n", .{engine});
            } else {
                std.debug.print("{s}: {s}\n", .{ engine, avail.reason });
                std.debug.print("Put liblocalvqe.so and the matching gguf in ~/.local/share/nearmic/. GGML is a shared library, so it is not inside this binary. QA skips the engine when either file is missing.\n", .{});
            }
            return;
        }
        if (std.mem.eql(u8, engine, "mossformer2-48k") or std.mem.eql(u8, engine, "frcrn-16k") or std.mem.eql(u8, engine, "mossformer-gan-16k")) {
            std.debug.print("{s}: {s}\nQA skips it.\n", .{ engine, engines.availability(engine).reason });
            return;
        }
        if (!std.mem.eql(u8, engine, "dpdfnet2") and !std.mem.eql(u8, engine, "dpdfnet8")) {
            std.debug.print("fetch knows dpdfnet2 and dpdfnet8\n", .{});
            return error.UnknownEngine;
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len >= 2 and (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help"))) {
        usage();
        return;
    }
    if (args.len == 1 or std.mem.eql(u8, args[1], "setup")) {
        try setup(allocator);
        return;
    }
    if (std.mem.eql(u8, args[1], "run")) {
        try app.runDaemon(allocator);
        return;
    }
    if (std.mem.eql(u8, args[1], "engines")) {
        try engines.printList(std.io.getStdOut().writer());
        return;
    }
    if (std.mem.eql(u8, args[1], "qa")) {
        const code = try qa.run(allocator);
        if (code != 0) std.process.exit(code);
        return;
    }
    if (std.mem.eql(u8, args[1], "fetch")) {
        if (args.len > 3) return usage();
        const name = if (args.len == 3) args[2] else null;
        try fetchCmd(allocator, name);
        return;
    }
    if (std.mem.eql(u8, args[1], "engine")) {
        if (args.len != 3) return usage();
        const avail = engines.availability(args[2]);
        const weights_later = std.mem.indexOf(u8, avail.reason, "weights missing") != null;
        if (!avail.ok and !weights_later) {
            std.debug.print("{s}: {s}\n", .{ args[2], avail.reason });
            std.process.exit(1);
        }
        const line = try std.fmt.allocPrint(allocator, "engine {s}", .{args[2]});
        defer allocator.free(line);
        const rendered = try config.quote(allocator, args[2]);
        defer allocator.free(rendered);
        try liveOrSave(allocator, line, "engine", rendered);
        return;
    }
    if (std.mem.eql(u8, args[1], "gain")) {
        if (args.len != 3) return usage();
        const value = std.fmt.parseFloat(f32, args[2]) catch {
            std.debug.print("gain must be a number of dB\n", .{});
            std.process.exit(2);
        };
        if (!std.math.isFinite(value)) {
            std.debug.print("gain must be finite\n", .{});
            std.process.exit(2);
        }
        const line = try std.fmt.allocPrint(allocator, "gain {d}", .{value});
        defer allocator.free(line);
        var buf: [64]u8 = undefined;
        const rendered = std.fmt.bufPrint(&buf, "{d}", .{value}) catch "0";
        try liveOrSave(allocator, line, "gain_db", rendered);
        return;
    }
    if (std.mem.eql(u8, args[1], "enhance")) {
        if (args.len != 4) return usage();
        try app.enhance(allocator, args[2], args[3]);
        return;
    }
    if (std.mem.eql(u8, args[1], "bench") or std.mem.eql(u8, args[1], "bakeoff")) {
        var body = std.ArrayList(u8).init(allocator);
        defer body.deinit();
        const winner = try bench.run(allocator, body.writer());
        const stdout = std.io.getStdOut();
        try stdout.writeAll(body.items);
        if (args.len == 4 and std.mem.eql(u8, args[2], "--write")) {
            if (std.fs.path.dirname(args[3])) |dir| try std.fs.cwd().makePath(dir);
            try std.fs.cwd().writeFile(.{ .sub_path = args[3], .data = body.items });
        }
        if (!std.mem.eql(u8, winner, app.engineName())) {
            const shown = if (winner.len == 0) "none" else winner;
            std.debug.print("measured winner is {s}; this binary ships {s}\n", .{ shown, app.engineName() });
            std.process.exit(1);
        }
        return;
    }
    if (std.mem.eql(u8, args[1], "fixture")) {
        if (args.len != 3) return usage();
        try bench.writeFixture(allocator, args[2]);
        std.debug.print("wrote fixture in {s}\n", .{args[2]});
        return;
    }
    if (std.mem.eql(u8, args[1], "score")) {
        if (args.len != 10 and args.len != 11) return usage();
        const level = args.len == 11 and std.mem.eql(u8, args[10], "--level");
        const cpu_s = try std.fmt.parseFloat(f64, args[3]);
        const p99_ns = try std.fmt.parseInt(u64, args[4], 10);
        const block = try std.fmt.parseInt(usize, args[5], 10);
        const rate = try std.fmt.parseFloat(f64, args[6]);
        const audio_samples = try std.fmt.parseInt(usize, args[7], 10);
        try bench.scoreExternal(allocator, std.io.getStdOut().writer(), args[2], cpu_s, p99_ns, block, rate, audio_samples, level, args[8], args[9]);
        return;
    }
    if (std.mem.eql(u8, args[1], "doctor")) {
        const home = std.posix.getenv("HOME") orelse "/tmp";
        const cfg_path = try config.configPath(allocator, home);
        defer allocator.free(cfg_path);
        std.debug.print("NearMic {s}\nshipped={s}\nconfig={s}\npipewire_library={s}\n", .{
            app.version,
            app.engineName(),
            cfg_path,
            if (app.pipewireLibraryPresent()) "present" else "missing",
        });
        const accel = @import("accel.zig");
        accel.write(std.io.getStdOut().writer(), accel.probe()) catch {};
        const reply = app.sendCommand(allocator, "status") catch |err| switch (err) {
            error.NotRunning => {
                std.debug.print("daemon=not running\n", .{});
                return;
            },
            else => return err,
        };
        defer allocator.free(reply);
        std.debug.print("daemon=running\n{s}", .{reply});
        return;
    }
    if (std.mem.eql(u8, args[1], "status") or std.mem.eql(u8, args[1], "quit")) {
        const reply = app.sendCommand(allocator, args[1]) catch |err| switch (err) {
            error.NotRunning => {
                std.debug.print("NearMic is not running\n", .{});
                std.process.exit(1);
            },
            else => return err,
        };
        defer allocator.free(reply);
        std.debug.print("{s}", .{reply});
        return;
    }
    if (std.mem.eql(u8, args[1], "mode") or std.mem.eql(u8, args[1], "listen")) {
        if (args.len != 3) return usage();
        const line = try std.fmt.allocPrint(allocator, "{s} {s}", .{ args[1], args[2] });
        defer allocator.free(line);
        const rendered = if (std.mem.eql(u8, args[1], "listen"))
            if (std.mem.eql(u8, args[2], "on")) "true" else "false"
        else
            null;
        if (std.mem.eql(u8, args[1], "mode")) {
            const quoted = try config.quote(allocator, args[2]);
            defer allocator.free(quoted);
            try liveOrSave(allocator, line, "mode", quoted);
        } else {
            try liveOrSave(allocator, line, "listen", rendered.?);
        }
        return;
    }
    usage();
    std.process.exit(2);
}
