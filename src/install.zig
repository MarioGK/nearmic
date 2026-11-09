const std = @import("std");
const config = @import("config.zig");

pub const Options = struct {
    home: []const u8,
    exe_path: []const u8,
    start_service: bool,
};

pub fn binPath(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.local/bin/nearmic", .{home});
}

pub fn unitPath(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.config/systemd/user/nearmic.service", .{home});
}

pub fn desktopPath(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.local/share/applications/nearmic.desktop", .{home});
}

pub fn serviceText(allocator: std.mem.Allocator, exe: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\[Unit]
        \\Description=NearMic virtual microphone
        \\After=pipewire.service
        \\
        \\[Service]
        \\ExecStart={s} run
        \\Restart=on-failure
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    , .{exe});
}

pub fn desktopText(allocator: std.mem.Allocator, exe: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\[Desktop Entry]
        \\Type=Application
        \\Name=NearMic
        \\Comment=Virtual microphone
        \\Exec={s}
        \\Terminal=false
        \\Categories=Audio;
        \\
    , .{exe});
}

fn sameFile(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    var ba: [std.fs.max_path_bytes]u8 = undefined;
    var bb: [std.fs.max_path_bytes]u8 = undefined;
    const ra = std.fs.cwd().realpath(a, &ba) catch return false;
    const rb = std.fs.cwd().realpath(b, &bb) catch return false;
    return std.mem.eql(u8, ra, rb);
}

fn writeFresh(path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
}

pub fn installUser(allocator: std.mem.Allocator, opts: Options) !void {
    const dest = try binPath(allocator, opts.home);
    defer allocator.free(dest);
    if (std.fs.path.dirname(dest)) |dir| try std.fs.cwd().makePath(dir);
    if (!sameFile(opts.exe_path, dest)) {
        const tmp = try std.fmt.allocPrint(allocator, "{s}.new", .{dest});
        defer allocator.free(tmp);
        try std.fs.copyFileAbsolute(opts.exe_path, tmp, .{});
        try std.posix.rename(tmp, dest);
        const file = try std.fs.cwd().openFile(dest, .{});
        defer file.close();
        try file.chmod(0o755);
    }

    const unit = try unitPath(allocator, opts.home);
    defer allocator.free(unit);
    const unit_body = try serviceText(allocator, dest);
    defer allocator.free(unit_body);
    try writeFresh(unit, unit_body);

    const desktop = try desktopPath(allocator, opts.home);
    defer allocator.free(desktop);
    const desktop_body = try desktopText(allocator, dest);
    defer allocator.free(desktop_body);
    try writeFresh(desktop, desktop_body);

    const cfg = try config.configPath(allocator, opts.home);
    defer allocator.free(cfg);
    if (std.fs.path.dirname(cfg)) |dir| try std.fs.cwd().makePath(dir);
    if (std.fs.cwd().openFile(cfg, .{})) |file| {
        file.close();
    } else |err| switch (err) {
        error.FileNotFound => try writeFresh(cfg, config.default_text),
        else => return err,
    }

    if (!opts.start_service) return;
    try systemctl(allocator, &.{ "systemctl", "--user", "daemon-reload" });
    try systemctl(allocator, &.{ "systemctl", "--user", "enable", "--now", "nearmic.service" });
}

fn systemctl(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const res = std.process.Child.run(.{ .allocator = allocator, .argv = argv }) catch return error.Systemd;
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    switch (res.term) {
        .Exited => |code| if (code != 0) {
            if (res.stderr.len != 0) std.debug.print("{s}\n", .{res.stderr});
            return error.Systemd;
        },
        else => return error.Systemd,
    }
}

test "installer writes unit desktop and config once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &buf);
    const exe = try std.fmt.allocPrint(std.testing.allocator, "{s}/nearmic-src", .{root});
    defer std.testing.allocator.free(exe);
    try writeFresh(exe, "near-mic-binary");

    try installUser(std.testing.allocator, .{ .home = root, .exe_path = exe, .start_service = false });

    const dest = try binPath(std.testing.allocator, root);
    defer std.testing.allocator.free(dest);
    const copied = try std.fs.cwd().readFileAlloc(std.testing.allocator, dest, 64);
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("near-mic-binary", copied);

    const unit = try unitPath(std.testing.allocator, root);
    defer std.testing.allocator.free(unit);
    const unit_body = try std.fs.cwd().readFileAlloc(std.testing.allocator, unit, 4096);
    defer std.testing.allocator.free(unit_body);
    try std.testing.expect(std.mem.indexOf(u8, unit_body, "After=pipewire.service") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit_body, "Restart=on-failure") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit_body, "Restart=always") == null);
    try std.testing.expect(std.mem.indexOf(u8, unit_body, "WantedBy=default.target") != null);
    const exec_line = try std.fmt.allocPrint(std.testing.allocator, "ExecStart={s} run\n", .{dest});
    defer std.testing.allocator.free(exec_line);
    try std.testing.expect(std.mem.indexOf(u8, unit_body, exec_line) != null);

    const desktop = try desktopPath(std.testing.allocator, root);
    defer std.testing.allocator.free(desktop);
    const desktop_body = try std.fs.cwd().readFileAlloc(std.testing.allocator, desktop, 4096);
    defer std.testing.allocator.free(desktop_body);
    const desktop_exec = try std.fmt.allocPrint(std.testing.allocator, "Exec={s}\n", .{dest});
    defer std.testing.allocator.free(desktop_exec);
    try std.testing.expect(std.mem.indexOf(u8, desktop_body, desktop_exec) != null);

    const cfg = try config.configPath(std.testing.allocator, root);
    defer std.testing.allocator.free(cfg);
    try std.testing.expect(std.mem.endsWith(u8, cfg, "/.config/nearmic/config.toml"));
    const cfg_body = try std.fs.cwd().readFileAlloc(std.testing.allocator, cfg, 8192);
    defer std.testing.allocator.free(cfg_body);
    try std.testing.expect(std.mem.indexOf(u8, cfg_body, "engine = \"dsp-dereverb\"") != null);

    try std.fs.cwd().writeFile(.{ .sub_path = cfg, .data = "engine = \"leveler\"\n# mine\n" });
    try writeFresh(dest, "STAY");
    try installUser(std.testing.allocator, .{ .home = root, .exe_path = dest, .start_service = false });
    const stayed = try std.fs.cwd().readFileAlloc(std.testing.allocator, dest, 64);
    defer std.testing.allocator.free(stayed);
    try std.testing.expectEqualStrings("STAY", stayed);
    const cfg_again = try std.fs.cwd().readFileAlloc(std.testing.allocator, cfg, 8192);
    defer std.testing.allocator.free(cfg_again);
    try std.testing.expectEqualStrings("engine = \"leveler\"\n# mine\n", cfg_again);
}
