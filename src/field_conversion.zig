const std = @import("std");
const Field = @import("Field.zig");
const Allocator = std.mem.Allocator;

/// Converts a Zig value to a Field.Value. Works with both comptime and runtime values.
/// The `alloc` parameter is only used for nested struct group allocation.
pub inline fn toValue(alloc: Allocator, val: anytype) Field.Value {
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
                return toValue(alloc, v);
            } else {
                return .null_value;
            }
        },
        .@"struct" => {
            const fields = fieldsFromStruct(alloc, val);
            return .{ .group = &fields };
        },
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

fn fieldCount(comptime T: type) comptime_int {
    return @typeInfo(T).@"struct".fields.len;
}

/// Converts an anonymous struct to a fixed-size array of Fields. Works with runtime values.
/// Field names come from comptime type info; values can be runtime.
pub inline fn fieldsFromStruct(alloc: Allocator, attrs: anytype) [fieldCount(@TypeOf(attrs))]Field.Field {
    const info = @typeInfo(@TypeOf(attrs)).@"struct";
    var result: [info.fields.len]Field.Field = undefined;
    inline for (info.fields, 0..) |f, i| {
        result[i] = .{
            .key = f.name,
            .value = toValue(alloc, @field(attrs, f.name)),
        };
    }
    return result;
}


test "fieldsFromStruct basic types" {
    const testing = std.testing;
    const fields = fieldsFromStruct(testing.allocator, .{
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
    const fields = fieldsFromStruct(std.testing.allocator, .{ .x = val });
    try std.testing.expectEqual(Field.Value.null_value, fields[0].value);
}

test "fieldsFromStruct optional with value" {
    const val: ?i32 = 42;
    const fields = fieldsFromStruct(std.testing.allocator, .{ .x = val });
    try std.testing.expectEqual(@as(i64, 42), fields[0].value.int);
}

test "toValue enum" {
    const Color = enum { red, green, blue };
    const v = toValue(std.testing.allocator, Color.green);
    try std.testing.expectEqualStrings("green", v.string);
}

test "toValue error" {
    const v = toValue(std.testing.allocator, error.OutOfMemory);
    try std.testing.expectEqualStrings("OutOfMemory", v.err_name);
}

test "fieldsFromStruct error field" {
    const fields = fieldsFromStruct(std.testing.allocator, .{ .err = error.FileNotFound });
    try std.testing.expectEqualStrings("err", fields[0].key);
    try std.testing.expectEqualStrings("FileNotFound", fields[0].value.err_name);
}

test "fieldsFromStruct nested struct becomes group" {
    const fields = fieldsFromStruct(std.testing.allocator, .{
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
    const fields = fieldsFromStruct(std.testing.allocator, .{
        .outer = .{ .inner = .{ .deep = 42 } },
    });
    const outer_group = fields[0].value.group;
    try std.testing.expectEqualStrings("inner", outer_group[0].key);
    const inner_group = outer_group[0].value.group;
    try std.testing.expectEqualStrings("deep", inner_group[0].key);
    try std.testing.expectEqual(42, inner_group[0].value.uint);
}

test "fieldsFromStruct with runtime values" {
    var runtime_int: i32 = 42;
    runtime_int += 0; // prevent comptime evaluation
    var runtime_str: []const u8 = "hello";
    runtime_str = runtime_str; // prevent comptime evaluation

    const fields = fieldsFromStruct(std.testing.allocator, .{
        .count = runtime_int,
        .name = runtime_str,
    });

    try std.testing.expectEqual(2, fields.len);
    try std.testing.expectEqualStrings("count", fields[0].key);
    try std.testing.expectEqual(@as(i64, 42), fields[0].value.int);
    try std.testing.expectEqualStrings("name", fields[1].key);
    try std.testing.expectEqualStrings("hello", fields[1].value.string);
}

test "fieldsFromStruct with runtime optional" {
    var runtime_val: ?i32 = 42;
    runtime_val = runtime_val; // prevent comptime evaluation

    const fields = fieldsFromStruct(std.testing.allocator, .{ .x = runtime_val });
    try std.testing.expectEqual(@as(i64, 42), fields[0].value.int);

    var null_val: ?i32 = null;
    null_val = null_val;
    const fields2 = fieldsFromStruct(std.testing.allocator, .{ .x = null_val });
    try std.testing.expectEqual(Field.Value.null_value, fields2[0].value);
}

test "fieldsFromStruct with comptime values still works" {
    const fields = fieldsFromStruct(std.testing.allocator, .{
        .name = "alice",
        .age = 30,
    });
    try std.testing.expectEqual(2, fields.len);
    try std.testing.expectEqualStrings("alice", fields[0].value.string);
    try std.testing.expectEqual(30, fields[1].value.uint);
}
