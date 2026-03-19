const std = @import("std");
const Field = @import("Field.zig");

pub fn toValue(comptime val: anytype) Field.Value {
    const T = @TypeOf(val);
    const info = @typeInfo(T);

    if (T == Field.Value) return val;

    if (comptime isStringType(T)) {
        return .{ .string = val };
    }

    switch (info) {
        .bool => return .{ .boolean = val },
        .int => |int_info| {
            if (int_info.signedness == .signed) {
                return .{ .int = @intCast(val) };
            } else {
                return .{ .uint = @intCast(val) };
            }
        },
        .comptime_int => {
            if (val < 0) {
                return .{ .int = val };
            } else {
                return .{ .uint = val };
            }
        },
        .float, .comptime_float => return .{ .float = @floatCast(val) },
        .optional => {
            if (val) |v| {
                return comptime toValue(v);
            } else {
                return .null_value;
            }
        },
        .@"struct" => return .{ .group = fieldsFromStruct(val) },
        .@"enum" => return .{ .string = @tagName(val) },
        .error_set => return .{ .err_name = @errorName(val) },
        else => @compileError("unsupported field type: " ++ @typeName(T)),
    }
}

fn isStringType(comptime T: type) bool {
    if (T == []const u8) return true;
    if (T == [:0]const u8) return true;

    const info = @typeInfo(T);
    if (info == .pointer) {
        const ptr = info.pointer;
        if (ptr.size == .one) {
            const child = @typeInfo(ptr.child);
            if (child == .array) {
                return child.array.child == u8;
            }
        }
    }
    return false;
}

pub fn fieldsFromStruct(comptime attrs: anytype) []const Field.Field {
    const info = @typeInfo(@TypeOf(attrs)).@"struct";
    comptime var result: [info.fields.len]Field.Field = undefined;
    inline for (info.fields, 0..) |f, i| {
        result[i] = .{
            .key = f.name,
            .value = comptime toValue(@field(attrs, f.name)),
        };
    }
    const final = result;
    return &final;
}

test "fieldsFromStruct basic types" {
    const testing = std.testing;
    const fields = fieldsFromStruct(.{
        .name = "alice",
        .age = 30,
        .score = 9.5,
        .active = true,
    });

    try testing.expectEqual(4, fields.len);
    try testing.expectEqualStrings("name", fields[0].key);
    try testing.expectEqualStrings("alice", fields[0].value.string);
    try testing.expectEqual(30, fields[1].value.uint);
    try testing.expectEqual(true, fields[3].value.boolean);
}

test "fieldsFromStruct optional null" {
    const val: ?i32 = null;
    const fields = fieldsFromStruct(.{ .x = val });
    try std.testing.expectEqual(Field.Value.null_value, fields[0].value);
}

test "fieldsFromStruct optional with value" {
    const val: ?i32 = 42;
    const fields = fieldsFromStruct(.{ .x = val });
    try std.testing.expectEqual(@as(i64, 42), fields[0].value.int);
}

test "toValue enum" {
    const Color = enum { red, green, blue };
    const v = comptime toValue(Color.green);
    try std.testing.expectEqualStrings("green", v.string);
}

test "toValue error" {
    const v = comptime toValue(error.OutOfMemory);
    try std.testing.expectEqualStrings("OutOfMemory", v.err_name);
}

test "fieldsFromStruct error field" {
    const fields = fieldsFromStruct(.{ .err = error.FileNotFound });
    try std.testing.expectEqualStrings("err", fields[0].key);
    try std.testing.expectEqualStrings("FileNotFound", fields[0].value.err_name);
}

test "fieldsFromStruct nested struct becomes group" {
    const fields = fieldsFromStruct(.{
        .request = .{ .method = "GET", .url = "/api" },
    });
    try std.testing.expectEqual(1, fields.len);
    try std.testing.expectEqualStrings("request", fields[0].key);
    const group = fields[0].value.group;
    try std.testing.expectEqual(2, group.len);
    try std.testing.expectEqualStrings("method", group[0].key);
    try std.testing.expectEqualStrings("GET", group[0].value.string);
    try std.testing.expectEqualStrings("url", group[1].key);
    try std.testing.expectEqualStrings("/api", group[1].value.string);
}

test "fieldsFromStruct deeply nested struct" {
    const fields = fieldsFromStruct(.{
        .outer = .{ .inner = .{ .deep = 42 } },
    });
    const outer_group = fields[0].value.group;
    try std.testing.expectEqualStrings("inner", outer_group[0].key);
    const inner_group = outer_group[0].value.group;
    try std.testing.expectEqualStrings("deep", inner_group[0].key);
    try std.testing.expectEqual(42, inner_group[0].value.uint);
}
