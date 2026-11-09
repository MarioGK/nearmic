const std = @import("std");
const toml = @import("toml.zig");

pub const Mode = enum(u8) { suppress, bypass, mute };

pub const Profile = enum { desktop, rock_pi_plus };

pub fn parseProfile(text: []const u8) ?Profile {
    if (std.mem.eql(u8, text, "desktop")) return .desktop;
    if (std.mem.eql(u8, text, "rock-pi-plus")) return .rock_pi_plus;
    return null;
}

pub fn profileName(profile: Profile) []const u8 {
    return switch (profile) {
        .desktop => "desktop",
        .rock_pi_plus => "rock-pi-plus",
    };
}

pub const default_text =
    \\# NearMic reads this file from $HOME/.config/nearmic/config.toml.
    \\# engine, mode, listen, gain_db, profile, threads, and cpu_budget reload
    \\# between audio blocks while nearmic run is up. The thread pool is rebuilt
    \\# then. A bad edit is ignored and the previous values stay in effect.
    \\# source is the PipeWire node.name of the real microphone. Empty means
    \\# whichever source was the default when the daemon started. A new source
    \\# is used the next time the daemon starts, so it does not race PipeWire.
    \\# profile selects the machine budget. desktop keeps the bake-off gate:
    \\# cpu_budget 0.05 and one DSP thread, engine dsp-dereverb.
    \\# rock-pi-plus is the Radxa ROCK 4 Plus V1.73 (Rockchip OP1 / RK3399:
    \\# 2x Cortex-A72 + 4x Cortex-A53, Mali-T860MP4, no RKNPU). It sets
    \\# cpu_budget to 0.90 and threads to 0, which means every core, never
    \\# more than nproc. The PipeWire callback still only moves samples.
    \\# An explicit threads or cpu_budget line overrides the profile.
    \\# threads applies between blocks; you do not need to restart for it.
    \\profile = "desktop"
    \\
    \\source = ""
    \\
    \\# suppress, bypass, or mute. Bypass and mute keep the active engine's delay.
    \\mode = "suppress"
    \\
    \\# true plays the processed voice to the default speakers. Headphones only.
    \\listen = false
    \\
    \\# Runtime engine. The bake-off winner, and the default here, is dsp-dereverb.
    \\# leveler, dsp, dsp-dereverb, speex-dereverb,
    \\# rnnoise, dpdfnet2, dpdfnet8,
    \\# localvqe-v1.2, localvqe-v1.3,
    \\# mossformer2-48k, frcrn-16k, mossformer-gan-16k
    \\engine = "dsp-dereverb"
    \\
    \\# Extra gain in dB after the engine. Leave this at 0 for dsp-dereverb.
    \\# On the synthetic fixture DPDFNet8 leaves speech near -32 dBFS. About +6 dB
    \\# brings that model inside the loudness gate. It does not replace dsp-dereverb.
    \\gain_db = 0
    \\
    \\# threads = 0 uses every core and is capped at nproc. Leave this commented
    \\# to take the profile default: 1 on desktop, every core on rock-pi-plus.
    \\# threads = 1
    \\
    \\# cpu_budget is the fraction of the machine the worker may use. It is a
    \\# ceiling, not a spin. desktop is 0.05. rock-pi-plus is 0.90.
    \\# cpu_budget = 0.05
    \\
;

pub const Config = struct {
    source: []u8,
    mode: Mode,
    listen: bool,
    engine: []u8,
    gain_db: f32,
    profile: Profile = .desktop,
    threads: u32 = 1,
    cpu_budget: f32 = 0.05,
    threads_explicit: bool = false,
    budget_explicit: bool = false,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.source);
        self.allocator.free(self.engine);
    }

    pub fn effectiveThreads(self: Config) u32 {
        if (self.threads_explicit) return self.threads;
        return switch (self.profile) {
            .desktop => 1,
            .rock_pi_plus => 0,
        };
    }

    pub fn effectiveBudget(self: Config) f32 {
        if (self.budget_explicit) return self.cpu_budget;
        return switch (self.profile) {
            .desktop => 0.05,
            .rock_pi_plus => 0.90,
        };
    }

    pub fn dupe(self: Config) !Config {
        return .{
            .source = try self.allocator.dupe(u8, self.source),
            .mode = self.mode,
            .listen = self.listen,
            .engine = try self.allocator.dupe(u8, self.engine),
            .gain_db = self.gain_db,
            .profile = self.profile,
            .threads = self.threads,
            .cpu_budget = self.cpu_budget,
            .threads_explicit = self.threads_explicit,
            .budget_explicit = self.budget_explicit,
            .allocator = self.allocator,
        };
    }
};

pub const Load = union(enum) {
    ok: Config,
    err: []u8,
};

pub fn defaults(allocator: std.mem.Allocator) !Config {
    return .{
        .source = try allocator.dupe(u8, ""),
        .mode = .suppress,
        .listen = false,
        .engine = try allocator.dupe(u8, "dsp-dereverb"),
        .gain_db = 0,
        .profile = .desktop,
        .threads = 1,
        .cpu_budget = 0.05,
        .threads_explicit = false,
        .budget_explicit = false,
        .allocator = allocator,
    };
}

pub fn configPath(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.config/nearmic/config.toml", .{home});
}

pub fn userConfigPath(allocator: std.mem.Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return configPath(allocator, home);
}

pub fn load(allocator: std.mem.Allocator, text: []const u8) !Load {
    var base = try defaults(allocator);
    const loaded = try loadKeeping(allocator, &base, text);
    switch (loaded) {
        .err => base.deinit(),
        .ok => {},
    }
    return loaded;
}

pub fn loadKeeping(allocator: std.mem.Allocator, prev: *Config, text: []const u8) !Load {
    var parsed = try toml.parse(allocator, text);
    switch (parsed) {
        .err => |msg| return .{ .err = msg },
        .ok => |*doc| {
            defer doc.deinit();
            var next = try prev.dupe();
            const bad = overlay(allocator, doc, &next) catch |err| {
                next.deinit();
                return err;
            };
            if (bad) |msg| {
                next.deinit();
                return .{ .err = msg };
            }
            prev.deinit();
            return .{ .ok = next };
        },
    }
}

fn overlay(allocator: std.mem.Allocator, doc: *toml.Document, next: *Config) !?[]u8 {
    if (doc.get("source")) |value| switch (value) {
        .string => |s| {
            const copy = try allocator.dupe(u8, s);
            allocator.free(next.source);
            next.source = copy;
        },
        else => return try typeMsg(allocator, "source"),
    };
    if (doc.get("mode")) |value| switch (value) {
        .string => |s| next.mode = std.meta.stringToEnum(Mode, s) orelse {
            return try std.fmt.allocPrint(allocator, "config.toml: mode must be suppress, bypass, or mute", .{});
        },
        else => return try typeMsg(allocator, "mode"),
    };
    if (doc.get("listen")) |value| switch (value) {
        .boolean => |b| next.listen = b,
        else => return try typeMsg(allocator, "listen"),
    };
    if (doc.get("engine")) |value| switch (value) {
        .string => |s| {
            if (s.len == 0 or s.len > 64) return try allocator.dupe(u8, "config.toml: engine name is empty");
            const copy = try allocator.dupe(u8, s);
            allocator.free(next.engine);
            next.engine = copy;
        },
        else => return try typeMsg(allocator, "engine"),
    };
    if (doc.get("gain_db")) |value| switch (value) {
        .number => |n| {
            const g: f32 = @floatCast(n);
            if (!std.math.isFinite(g)) return try allocator.dupe(u8, "config.toml: gain_db is not finite");
            next.gain_db = g;
        },
        else => return try typeMsg(allocator, "gain_db"),
    };
    if (doc.get("profile")) |value| switch (value) {
        .string => |s| next.profile = parseProfile(s) orelse {
            return try allocator.dupe(u8, "config.toml: profile must be desktop or rock-pi-plus");
        },
        else => return try typeMsg(allocator, "profile"),
    };
    if (doc.get("threads")) |value| switch (value) {
        .number => |n| {
            if (!std.math.isFinite(n)) return try allocator.dupe(u8, "config.toml: threads is not finite");
            const rounded = @round(n);
            if (@abs(n - rounded) > 1e-6 or rounded < 0 or rounded > 256) {
                return try allocator.dupe(u8, "config.toml: threads must be a whole number from 0 to 256");
            }
            next.threads = @intFromFloat(rounded);
            next.threads_explicit = true;
        },
        else => return try typeMsg(allocator, "threads"),
    };
    if (doc.get("cpu_budget")) |value| switch (value) {
        .number => |n| {
            const g: f32 = @floatCast(n);
            if (!std.math.isFinite(g) or g < 0 or g > 1) {
                return try allocator.dupe(u8, "config.toml: cpu_budget must be from 0 to 1");
            }
            next.cpu_budget = g;
            next.budget_explicit = true;
        },
        else => return try typeMsg(allocator, "cpu_budget"),
    };
    return null;
}

fn typeMsg(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "config.toml: {s} has the wrong type", .{key});
}

pub fn patchText(allocator: std.mem.Allocator, text: []const u8, key: []const u8, rendered: []const u8) ![]u8 {
    return toml.patch(allocator, text, key, rendered);
}

pub fn patchFile(allocator: std.mem.Allocator, path: []const u8, key: []const u8, rendered: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    const existing = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, default_text),
        else => return err,
    };
    defer allocator.free(existing);
    const next = try patchText(allocator, existing, key, rendered);
    defer allocator.free(next);
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp);
    try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = next });
    try std.posix.rename(tmp, path);
}

pub fn loadUser(allocator: std.mem.Allocator) !Config {
    const path = userConfigPath(allocator) catch return defaults(allocator);
    defer allocator.free(path);
    const text = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => return defaults(allocator),
        else => return err,
    };
    defer allocator.free(text);
    switch (try load(allocator, text)) {
        .ok => |cfg| return cfg,
        .err => |msg| {
            std.debug.print("{s}\nkeeping the previous config\n", .{msg});
            allocator.free(msg);
            return defaults(allocator);
        },
    }
}

pub fn quote(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.append('"');
    for (text) |c| {
        switch (c) {
            '\\' => try out.appendSlice("\\\\"),
            '"' => try out.appendSlice("\\\""),
            '\n' => try out.appendSlice("\\n"),
            else => try out.append(c),
        }
    }
    try out.append('"');
    return out.toOwnedSlice();
}

test "default text loads the shipped engine" {
    var loaded = try load(std.testing.allocator, default_text);
    defer switch (loaded) {
        .ok => |*cfg| cfg.deinit(),
        .err => |msg| std.testing.allocator.free(msg),
    };
    switch (loaded) {
        .err => |msg| {
            std.debug.print("{s}\n", .{msg});
            return error.BadDefault;
        },
        .ok => |cfg| {
            try std.testing.expectEqualStrings("dsp-dereverb", cfg.engine);
            try std.testing.expectEqual(Mode.suppress, cfg.mode);
            try std.testing.expect(!cfg.listen);
            try std.testing.expectApproxEqAbs(@as(f32, 0), cfg.gain_db, 0.0001);
            try std.testing.expectEqualStrings("", cfg.source);
            try std.testing.expectEqual(Profile.desktop, cfg.profile);
            try std.testing.expectEqual(@as(u32, 1), cfg.effectiveThreads());
            try std.testing.expectApproxEqAbs(@as(f32, 0.05), cfg.effectiveBudget(), 0.0001);
        },
    }
}

test "rock-pi-plus profile allows every core and a 0.90 budget" {
    var loaded = try load(std.testing.allocator, "profile = \"rock-pi-plus\"\n");
    defer switch (loaded) {
        .ok => |*cfg| cfg.deinit(),
        .err => |msg| std.testing.allocator.free(msg),
    };
    switch (loaded) {
        .err => |msg| {
            std.debug.print("{s}\n", .{msg});
            return error.BadProfile;
        },
        .ok => |cfg| {
            try std.testing.expectEqualStrings("dsp-dereverb", cfg.engine);
            try std.testing.expectEqual(Profile.rock_pi_plus, cfg.profile);
            try std.testing.expectEqual(@as(u32, 0), cfg.effectiveThreads());
            try std.testing.expectApproxEqAbs(@as(f32, 0.90), cfg.effectiveBudget(), 0.0001);
            try std.testing.expect(!cfg.threads_explicit);
            try std.testing.expect(!cfg.budget_explicit);
        },
    }
}

test "explicit threads and cpu_budget override the rock profile" {
    const text =
        \\profile = "rock-pi-plus"
        \\threads = 2
        \\cpu_budget = 0.40
        \\
    ;
    var loaded = try load(std.testing.allocator, text);
    defer switch (loaded) {
        .ok => |*cfg| cfg.deinit(),
        .err => |msg| std.testing.allocator.free(msg),
    };
    switch (loaded) {
        .err => return error.BadOverride,
        .ok => |cfg| {
            try std.testing.expectEqual(@as(u32, 2), cfg.effectiveThreads());
            try std.testing.expectApproxEqAbs(@as(f32, 0.40), cfg.effectiveBudget(), 0.0001);
        },
    }
}

test "bad toml keeps the previous config" {
    var prev = try defaults(std.testing.allocator);
    prev.gain_db = 4;
    var loaded = try loadKeeping(std.testing.allocator, &prev, "gain_db = \n");
    defer switch (loaded) {
        .ok => |*cfg| cfg.deinit(),
        .err => |msg| std.testing.allocator.free(msg),
    };
    switch (loaded) {
        .ok => return error.ShouldFail,
        .err => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "config.toml:") != null),
    }
    try std.testing.expectApproxEqAbs(@as(f32, 4), prev.gain_db, 0.0001);
    prev.deinit();
}

test "patch file keeps comments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &buf);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.toml", .{root});
    defer std.testing.allocator.free(path);
    try patchFile(std.testing.allocator, path, "engine", "\"dsp\"");
    const text = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, 64 * 1024);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "About +6 dB") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "engine = \"dsp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "gain_db = 0") != null);
}
