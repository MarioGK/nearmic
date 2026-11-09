const std = @import("std");

/// A small TOML subset: one key per line, strings, numbers, booleans, and comments.
/// It exists so NearMic can patch one key and leave the rest of the file, including
/// comments, byte-for-byte. A full parser that rebuilds a document drops those comments.
pub const Value = union(enum) {
    string: []u8,
    number: f64,
    boolean: bool,

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            else => {},
        }
    }
};

pub const Pair = struct {
    key: []u8,
    value: Value,
};

pub const Document = struct {
    pairs: []Pair,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Document) void {
        for (self.pairs) |*pair| {
            self.allocator.free(pair.key);
            pair.value.deinit(self.allocator);
        }
        self.allocator.free(self.pairs);
    }

    pub fn get(self: Document, key: []const u8) ?Value {
        var found: ?Value = null;
        for (self.pairs) |pair| {
            if (std.mem.eql(u8, pair.key, key)) found = pair.value;
        }
        return found;
    }
};

pub const Parsed = union(enum) {
    ok: Document,
    err: []u8,

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*doc| doc.deinit(),
            .err => |msg| allocator.free(msg),
        }
    }
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Parsed {
    var pairs = std.ArrayList(Pair).init(allocator);
    errdefer {
        for (pairs.items) |*pair| {
            allocator.free(pair.key);
            pair.value.deinit(allocator);
        }
        pairs.deinit();
    }
    var line_no: usize = 1;
    var rest = text;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = stripCr(rest[0..nl]);
        if (try parseLine(allocator, line, line_no, &pairs)) |msg| {
            for (pairs.items) |*pair| {
                allocator.free(pair.key);
                pair.value.deinit(allocator);
            }
            pairs.deinit();
            return .{ .err = msg };
        }
        if (nl == rest.len) break;
        rest = rest[nl + 1 ..];
        line_no += 1;
    }
    return .{ .ok = .{ .pairs = try pairs.toOwnedSlice(), .allocator = allocator } };
}

fn stripCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn fail(allocator: std.mem.Allocator, line_no: usize, msg: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "config.toml:{d}: {s}", .{ line_no, msg });
}

fn parseLine(allocator: std.mem.Allocator, line: []const u8, line_no: usize, pairs: *std.ArrayList(Pair)) !?[]u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    if (trimmed[0] == '[') return try fail(allocator, line_no, "tables are not used");
    var i: usize = 0;
    if (!isKeyChar(trimmed[0])) return try fail(allocator, line_no, "expected a key");
    while (i < trimmed.len and isKeyChar(trimmed[i])) i += 1;
    const key = trimmed[0..i];
    var j = i;
    while (j < trimmed.len and (trimmed[j] == ' ' or trimmed[j] == '\t')) j += 1;
    if (j >= trimmed.len or trimmed[j] != '=') return try fail(allocator, line_no, "expected '='");
    j += 1;
    while (j < trimmed.len and (trimmed[j] == ' ' or trimmed[j] == '\t')) j += 1;
    if (j >= trimmed.len or trimmed[j] == '#') return try fail(allocator, line_no, "missing value");
    var value: Value = undefined;
    const end = parseValue(allocator, trimmed[j..], line_no, &value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadValue => return try fail(allocator, line_no, "bad value"),
    };
    const after = std.mem.trim(u8, trimmed[j + end ..], " \t");
    if (after.len != 0 and after[0] != '#') {
        value.deinit(allocator);
        return try fail(allocator, line_no, "trailing junk");
    }
    try pairs.append(.{ .key = try allocator.dupe(u8, key), .value = value });
    return null;
}

fn isKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

const ValueError = error{ BadValue, OutOfMemory };

fn parseValue(allocator: std.mem.Allocator, text: []const u8, line_no: usize, out: *Value) ValueError!usize {
    _ = line_no;
    if (text.len == 0) return error.BadValue;
    if (text[0] == '"') {
        var i: usize = 1;
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        while (i < text.len) {
            const c = text[i];
            if (c == '"') {
                out.* = .{ .string = try buf.toOwnedSlice() };
                return i + 1;
            }
            if (c == '\\') {
                if (i + 1 >= text.len) return error.BadValue;
                const e = text[i + 1];
                const decoded: u8 = switch (e) {
                    '\\' => '\\',
                    '"' => '"',
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    else => return error.BadValue,
                };
                try buf.append(decoded);
                i += 2;
                continue;
            }
            if (c < 0x20) return error.BadValue;
            try buf.append(c);
            i += 1;
        }
        return error.BadValue;
    }
    if (std.mem.startsWith(u8, text, "true") and (text.len == 4 or !isKeyChar(text[4]))) {
        out.* = .{ .boolean = true };
        return 4;
    }
    if (std.mem.startsWith(u8, text, "false") and (text.len == 5 or !isKeyChar(text[5]))) {
        out.* = .{ .boolean = false };
        return 5;
    }
    var i: usize = 0;
    if (text[i] == '+' or text[i] == '-') i += 1;
    if (i >= text.len or !std.ascii.isDigit(text[i])) return error.BadValue;
    const start = 0;
    while (i < text.len and (std.ascii.isDigit(text[i]) or text[i] == '.' or text[i] == 'e' or text[i] == 'E' or text[i] == '+' or text[i] == '-')) : (i += 1) {}
    const token = text[start..i];
    const number = std.fmt.parseFloat(f64, token) catch return error.BadValue;
    if (!std.math.isFinite(number)) return error.BadValue;
    out.* = .{ .number = number };
    return i;
}

const Span = struct { start: usize, end: usize };

fn valueSpan(line: []const u8, key: []const u8) ?Span {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len or line[i] == '#') return null;
    const key_at = i;
    if (!std.mem.startsWith(u8, line[key_at..], key)) return null;
    i = key_at + key.len;
    if (i < line.len and isKeyChar(line[i])) return null;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len or line[i] != '=') return null;
    i += 1;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len or line[i] == '#') return null;
    const start = i;
    if (line[i] == '"') {
        i += 1;
        while (i < line.len) {
            if (line[i] == '\\') {
                i += 2;
                continue;
            }
            if (line[i] == '"') {
                i += 1;
                return .{ .start = start, .end = i };
            }
            i += 1;
        }
        return null;
    }
    while (i < line.len and line[i] != ' ' and line[i] != '\t' and line[i] != '#') i += 1;
    if (i == start) return null;
    return .{ .start = start, .end = i };
}

pub fn patch(allocator: std.mem.Allocator, text: []const u8, key: []const u8, rendered: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var found = false;
    var rest = text;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = rest[0..nl];
        const has_nl = nl < rest.len;
        if (valueSpan(stripCr(line), key)) |span| {
            const end = if (!has_nl and line.len > 0 and line[line.len - 1] == '\r') span.end else span.end;
            try out.appendSlice(line[0..span.start]);
            try out.appendSlice(rendered);
            try out.appendSlice(line[end..]);
            found = true;
        } else {
            try out.appendSlice(line);
        }
        if (has_nl) try out.append('\n');
        if (!has_nl) break;
        rest = rest[nl + 1 ..];
    }
    if (!found) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append('\n');
        try out.appendSlice(key);
        try out.appendSlice(" = ");
        try out.appendSlice(rendered);
        try out.append('\n');
    }
    return out.toOwnedSlice();
}

fn expectParse(text: []const u8, key: []const u8, want: []const u8) !void {
    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit(std.testing.allocator);
    switch (parsed) {
        .err => |msg| std.debug.print("{s}\n", .{msg}),
        .ok => |doc| {
            const value = doc.get(key) orelse return error.Missing;
            switch (value) {
                .string => |s| try std.testing.expectEqualStrings(want, s),
                else => return error.Type,
            }
            return;
        },
    }
    return error.ShouldParse;
}

test "parse strings numbers bools and comments" {
    const text =
        \\# header
        \\source = ""
        \\engine = "dsp-dereverb" # winner
        \\listen = false
        \\gain_db = 6
        \\gain_more = -1.5
        \\
    ;
    try expectParse(text, "engine", "dsp-dereverb");
    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit(std.testing.allocator);
    const doc = parsed.ok;
    try std.testing.expect(doc.get("listen").?.boolean == false);
    try std.testing.expectApproxEqAbs(@as(f64, 6), doc.get("gain_db").?.number, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, -1.5), doc.get("gain_more").?.number, 0.0001);
    try std.testing.expectEqualStrings("", doc.get("source").?.string);
}

test "bad toml reports the line" {
    const text = "engine = \nmode = \"suppress\"\n";
    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit(std.testing.allocator);
    switch (parsed) {
        .ok => return error.ShouldFail,
        .err => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "config.toml:1:") != null),
    }
}

test "patch keeps comments and appends a missing key" {
    const text =
        \\# keep me
        \\engine = "dsp-dereverb"  # winner
        \\gain_db = 0
        \\
    ;
    const next = try patch(std.testing.allocator, text, "engine", "\"dsp\"");
    defer std.testing.allocator.free(next);
    try std.testing.expect(std.mem.indexOf(u8, next, "# keep me") != null);
    try std.testing.expect(std.mem.indexOf(u8, next, "engine = \"dsp\"  # winner") != null);
    try std.testing.expect(std.mem.indexOf(u8, next, "gain_db = 0") != null);
    const added = try patch(std.testing.allocator, next, "listen", "true");
    defer std.testing.allocator.free(added);
    try std.testing.expect(std.mem.endsWith(u8, added, "listen = true\n"));
    try std.testing.expect(std.mem.indexOf(u8, added, "# winner") != null);
}
