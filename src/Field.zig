const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    uint: u64,
    float: f64,
    boolean: bool,
    err_name: []const u8,
    null_value,
    group: []const Field,

    pub fn formatJson(self: Value, writer: std.io.AnyWriter) !void {
        switch (self) {
            .string => |s| {
                try writer.writeByte('"');
                try writeJsonEscaped(writer, s);
                try writer.writeByte('"');
            },
            .int => |v| try writer.print("{d}", .{v}),
            .uint => |v| try writer.print("{d}", .{v}),
            .float => |v| try writer.print("{d}", .{v}),
            .boolean => |v| try writer.writeAll(if (v) "true" else "false"),
            .err_name => |s| {
                try writer.writeByte('"');
                try writeJsonEscaped(writer, s);
                try writer.writeByte('"');
            },
            .null_value => try writer.writeAll("null"),
            .group => |fields| {
                try writer.writeByte('{');
                for (fields, 0..) |f, i| {
                    if (i > 0) try writer.writeByte(',');
                    try writer.writeByte('"');
                    try writeJsonEscaped(writer, f.key);
                    try writer.writeAll("\":");
                    try f.value.formatJson(writer);
                }
                try writer.writeByte('}');
            },
        }
    }

    pub fn formatText(self: Value, writer: std.io.AnyWriter) !void {
        switch (self) {
            .string => |s| {
                try writer.writeByte('"');
                try writeTextEscaped(writer, s);
                try writer.writeByte('"');
            },
            .int => |v| try writer.print("{d}", .{v}),
            .uint => |v| try writer.print("{d}", .{v}),
            .float => |v| try writer.print("{d}", .{v}),
            .boolean => |v| try writer.writeAll(if (v) "true" else "false"),
            .err_name => |s| {
                try writer.writeByte('"');
                try writeTextEscaped(writer, s);
                try writer.writeByte('"');
            },
            .null_value => try writer.writeAll("null"),
            .group => {}, // Text handler handles group flattening directly
        }
    }
};

pub const Field = struct {
    key: []const u8,
    value: Value,

    pub fn string(key: []const u8, val: []const u8) Field {
        return .{ .key = key, .value = .{ .string = val } };
    }

    pub fn int(key: []const u8, val: i64) Field {
        return .{ .key = key, .value = .{ .int = val } };
    }

    pub fn uint(key: []const u8, val: u64) Field {
        return .{ .key = key, .value = .{ .uint = val } };
    }

    pub fn float(key: []const u8, val: f64) Field {
        return .{ .key = key, .value = .{ .float = val } };
    }

    pub fn boolean(key: []const u8, val: bool) Field {
        return .{ .key = key, .value = .{ .boolean = val } };
    }

    pub fn errName(key: []const u8, val: []const u8) Field {
        return .{ .key = key, .value = .{ .err_name = val } };
    }

    pub fn nullValue(key: []const u8) Field {
        return .{ .key = key, .value = .{ .null_value = {} } };
    }

    pub fn group(key: []const u8, fields: []const Field) Field {
        return .{ .key = key, .value = .{ .group = fields } };
    }
};

pub fn writeTextEscaped(writer: std.io.AnyWriter, s: []const u8) !void {
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const escape: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            else => null,
        };
        if (escape) |esc| {
            if (i > start) try writer.writeAll(s[start..i]);
            try writer.writeAll(esc);
            start = i + 1;
        }
    }
    if (start < s.len) try writer.writeAll(s[start..]);
}

pub fn writeJsonEscaped(writer: std.io.AnyWriter, s: []const u8) !void {
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const escape: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => if (c < 0x20) "" else null, // empty string = control char sentinel
        };
        if (escape) |esc| {
            if (i > start) try writer.writeAll(s[start..i]);
            if (esc.len > 0) {
                try writer.writeAll(esc);
            } else {
                // Control character: \u00XX
                try writer.print("\\u{x:0>4}", .{c});
            }
            start = i + 1;
        }
    }
    if (start < s.len) try writer.writeAll(s[start..]);
}

pub fn buildDotKey(buf: []u8, prefix: []const u8, key: []const u8) ?[]const u8 {
    const total = prefix.len + 1 + key.len;
    if (total > buf.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    buf[prefix.len] = '.';
    @memcpy(buf[prefix.len + 1 ..][0..key.len], key);
    return buf[0..total];
}

/// Generic group-traversal for text-style field output. Recurses into groups
/// using dot-separated prefixes. The `writeKey` callback controls how the
/// fully-qualified key is written (plain text, ANSI-colored, etc.).
pub fn writeFieldGeneric(
    w: std.io.AnyWriter,
    prefix: []const u8,
    f: Field,
    comptime writeKey: fn (std.io.AnyWriter, []const u8, []const u8) anyerror!void,
) anyerror!void {
    switch (f.value) {
        .group => |sub_fields| {
            for (sub_fields) |sf| {
                if (prefix.len > 0) {
                    var buf: [1024]u8 = undefined;
                    const new_prefix = buildDotKey(&buf, prefix, f.key) orelse {
                        // Buffer overflow (>1024 byte key path) — emit leaf fields
                        // with just the field key to avoid silent data loss.
                        try writeFieldGeneric(w, f.key, sf, writeKey);
                        continue;
                    };
                    try writeFieldGeneric(w, new_prefix, sf, writeKey);
                } else {
                    try writeFieldGeneric(w, f.key, sf, writeKey);
                }
            }
        },
        else => {
            try w.writeByte(' ');
            try writeKey(w, prefix, f.key);
            try w.writeByte('=');
            try f.value.formatText(w);
        },
    }
}

fn writeTextKey(w: std.io.AnyWriter, prefix: []const u8, key: []const u8) anyerror!void {
    if (prefix.len > 0) {
        try w.writeAll(prefix);
        try w.writeByte('.');
    }
    try w.writeAll(key);
}

pub fn writeTextField(w: std.io.AnyWriter, prefix: []const u8, f: Field) anyerror!void {
    return writeFieldGeneric(w, prefix, f, writeTextKey);
}

test "value formatJson" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer().any();

    try (Value{ .string = "hello" }).formatJson(writer);
    try testing.expectEqualStrings("\"hello\"", fbs.getWritten());

    fbs.reset();
    try (Value{ .int = -42 }).formatJson(writer);
    try testing.expectEqualStrings("-42", fbs.getWritten());

    fbs.reset();
    try (Value{ .boolean = true }).formatJson(writer);
    try testing.expectEqualStrings("true", fbs.getWritten());

    fbs.reset();
    try (Value{ .null_value = {} }).formatJson(writer);
    try testing.expectEqualStrings("null", fbs.getWritten());
}

test "json escaping" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer().any();

    try (Value{ .string = "line1\nline2" }).formatJson(writer);
    try testing.expectEqualStrings("\"line1\\nline2\"", fbs.getWritten());

    fbs.reset();
    try (Value{ .string = "say \"hi\"" }).formatJson(writer);
    try testing.expectEqualStrings("\"say \\\"hi\\\"\"", fbs.getWritten());
}

test "value formatJson group" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer().any();

    const sub_fields = &[_]Field{
        .{ .key = "method", .value = .{ .string = "GET" } },
        .{ .key = "status", .value = .{ .uint = 200 } },
    };
    try (Value{ .group = sub_fields }).formatJson(writer);
    try testing.expectEqualStrings("{\"method\":\"GET\",\"status\":200}", fbs.getWritten());
}

test "field constructors" {
    const testing = std.testing;

    const s = Field.string("name", "alice");
    try testing.expectEqualStrings("name", s.key);
    try testing.expectEqualStrings("alice", s.value.string);

    const i = Field.int("count", -42);
    try testing.expectEqual(@as(i64, -42), i.value.int);

    const u = Field.uint("size", 100);
    try testing.expectEqual(@as(u64, 100), u.value.uint);

    const f = Field.float("ratio", 3.14);
    try testing.expectEqual(@as(f64, 3.14), f.value.float);

    const b = Field.boolean("active", true);
    try testing.expectEqual(true, b.value.boolean);

    const e = Field.errName("err", "ConnectionRefused");
    try testing.expectEqualStrings("ConnectionRefused", e.value.err_name);

    const n = Field.nullValue("missing");
    try testing.expectEqual(Value.null_value, n.value);

    const sub = &[_]Field{Field.string("x", "1")};
    const g = Field.group("nested", sub);
    try testing.expectEqual(@as(usize, 1), g.value.group.len);
}

test "value formatJson nested group" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer().any();

    const inner = &[_]Field{
        .{ .key = "port", .value = .{ .uint = 443 } },
    };
    const outer = &[_]Field{
        .{ .key = "host", .value = .{ .string = "example.com" } },
        .{ .key = "tls", .value = .{ .group = inner } },
    };
    try (Value{ .group = outer }).formatJson(writer);
    try testing.expectEqualStrings("{\"host\":\"example.com\",\"tls\":{\"port\":443}}", fbs.getWritten());
}
