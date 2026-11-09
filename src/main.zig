const std = @import("std");
const app = @import("app.zig");
const bench = @import("bench.zig");

fn usage() void {
    std.debug.print(
        \\NearMic {s}
        \\Live virtual microphone for a far Comica VM40. One binary, Linux and PipeWire.
        \\
        \\  nearmic                     run until Ctrl-C
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
        \\Turn off the noise suppressor inside Discord or the browser. Two denoisers fight.
        \\listen plays the processed voice to the default speakers. Use headphones.
        \\
    , .{app.version});
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
    if (args.len == 1 or std.mem.eql(u8, args[1], "run")) {
        try app.runDaemon(allocator);
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
        std.debug.print("NearMic {s}\nengine={s}\npipewire_library={s}\n", .{
            app.version,
            app.engineName(),
            if (app.pipewireLibraryPresent()) "present" else "missing",
        });
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
        const reply = app.sendCommand(allocator, line) catch |err| switch (err) {
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
    usage();
    std.process.exit(2);
}
