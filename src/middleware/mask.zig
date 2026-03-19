const std = @import("std");
const Record = @import("../Record.zig");
const Middleware = @import("../Middleware.zig");
const Field = @import("../Field.zig");
const fd = @import("../writers/fd.zig");

/// User-provided masking function. Receives the original string value and an
/// allocator for the masked replacement. Return `null` to leave the field
/// unchanged (pass-through).
pub const MaskFn = *const fn ([]const u8, std.mem.Allocator) ?[]const u8;

const MaskMiddleware = @This();

key: []const u8,
maskFn: MaskFn,
recursive: bool,

pub const Config = struct {
    recursive: bool = true,
};

pub fn init(key: []const u8, mask_fn: MaskFn) MaskMiddleware {
    return initWithConfig(key, mask_fn, .{});
}

pub fn initWithConfig(key: []const u8, mask_fn: MaskFn, config: Config) MaskMiddleware {
    return .{ .key = key, .maskFn = mask_fn, .recursive = config.recursive };
}

pub fn middleware(self: *MaskMiddleware) Middleware {
    return .{
        .ptr = self,
        .processFn = &process,
    };
}

/// Processes the record, masking the configured key. If allocation fails during
/// masking, the entire record is dropped rather than risk emitting sensitive data.
fn process(ptr: *anyopaque, record: *Record, allocator: std.mem.Allocator) bool {
    const self: *MaskMiddleware = @ptrCast(@alignCast(ptr));

    const new_fields = self.processFields(record.fields, allocator) catch {
        // Safety: if we can't allocate to mask the requested field, drop the
        // entire record rather than risk emitting sensitive data.
        fd.stderr.writeAll("zlog: record dropped: failed to allocate for masking key: ") catch {};
        fd.stderr.writeAll(self.key) catch {};
        fd.stderr.writeAll("\n") catch {};
        return false;
    };
    if (new_fields) |nf| record.fields = nf;
    return true;
}

/// Processes a field slice. Returns a new slice if changes were made, null if
/// no changes were needed (zero-alloc fast path), or OutOfMemory if allocation
/// failed (caller must drop the record to avoid emitting sensitive data).
fn processFields(self: *const MaskMiddleware, fields: []const Field.Field, allocator: std.mem.Allocator) error{OutOfMemory}!?[]const Field.Field {
    // First pass: check if any changes are needed (no allocations)
    var needs_change = false;
    for (fields) |f| {
        if (std.mem.eql(u8, f.key, self.key) and f.value == .string) {
            needs_change = true;
            break;
        }
        if (self.recursive and f.value == .group) {
            if (self.needsMasking(f.value.group)) {
                needs_change = true;
                break;
            }
        }
    }

    if (!needs_change) return null;

    // Second pass: allocate and build new fields
    const new_fields = try allocator.alloc(Field.Field, fields.len);
    var changed = false;
    for (fields, 0..) |f, i| {
        if (std.mem.eql(u8, f.key, self.key) and f.value == .string) {
            if (self.maskFn(f.value.string, allocator)) |masked| {
                new_fields[i] = .{ .key = f.key, .value = .{ .string = masked } };
                changed = true;
                continue;
            }
        }
        if (self.recursive and f.value == .group) {
            if (try self.processFields(f.value.group, allocator)) |new_sub| {
                new_fields[i] = .{ .key = f.key, .value = .{ .group = new_sub } };
                changed = true;
                continue;
            }
        }
        new_fields[i] = f;
    }

    if (!changed) {
        allocator.free(new_fields);
        return null;
    }
    return new_fields;
}

/// Allocation-free check: returns true if any field (recursively) needs masking.
fn needsMasking(self: *const MaskMiddleware, fields: []const Field.Field) bool {
    for (fields) |f| {
        if (std.mem.eql(u8, f.key, self.key) and f.value == .string) return true;
        if (self.recursive and f.value == .group) {
            if (self.needsMasking(f.value.group)) return true;
        }
    }
    return false;
}

test "mask middleware replaces matched field" {
    const testing = std.testing;

    const testMask = struct {
        fn mask(value: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
            _ = value;
            return allocator.dupe(u8, "***") catch null;
        }
    }.mask;

    var m = MaskMiddleware.init("secret", &testMask);
    const mw = m.middleware();

    const Level = @import("../Level.zig").Value;
    var input: Record = .{
        .level = Level.info,
        .message = "login",
        .timestamp_ns = 0,
        .fields = &.{
            .{ .key = "secret", .value = .{ .string = "hunter2" } },
            .{ .key = "role", .value = .{ .string = "admin" } },
        },
    };

    try testing.expect(mw.process(&input, testing.allocator));
    try testing.expectEqualStrings("***", input.fields[0].value.string);
    try testing.expectEqualStrings("admin", input.fields[1].value.string);

    testing.allocator.free(input.fields[0].value.string);
    testing.allocator.free(input.fields);
}

test "mask middleware null return passes through unchanged" {
    const testing = std.testing;

    const noopMask = struct {
        fn mask(_: []const u8, _: std.mem.Allocator) ?[]const u8 {
            return null;
        }
    }.mask;

    var m = MaskMiddleware.init("token", &noopMask);
    const mw = m.middleware();

    const Level = @import("../Level.zig").Value;
    const original_fields: []const Field.Field = &.{
        .{ .key = "token", .value = .{ .string = "abc123" } },
    };
    var input: Record = .{
        .level = Level.info,
        .message = "test",
        .timestamp_ns = 0,
        .fields = original_fields,
    };

    try testing.expect(mw.process(&input, testing.allocator));
    // Unchanged — no allocation, same pointer
    try testing.expectEqual(original_fields.ptr, input.fields.ptr);
    try testing.expectEqualStrings("abc123", input.fields[0].value.string);
}

test "mask middleware ignores non-string fields" {
    const testing = std.testing;

    const testMask = struct {
        fn mask(_: []const u8, _: std.mem.Allocator) ?[]const u8 {
            return "should not be called";
        }
    }.mask;

    var m = MaskMiddleware.init("count", &testMask);
    const mw = m.middleware();

    const Level = @import("../Level.zig").Value;
    const original_fields: []const Field.Field = &.{
        .{ .key = "count", .value = .{ .uint = 42 } },
    };
    var input: Record = .{
        .level = Level.info,
        .message = "test",
        .timestamp_ns = 0,
        .fields = original_fields,
    };

    try testing.expect(mw.process(&input, testing.allocator));
    try testing.expectEqual(original_fields.ptr, input.fields.ptr);
}

test "mask middleware recurses into groups" {
    const testing = std.testing;

    const testMask = struct {
        fn mask(value: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
            _ = value;
            return allocator.dupe(u8, "***") catch null;
        }
    }.mask;

    var m = MaskMiddleware.init("email", &testMask);
    const mw = m.middleware();

    const Level = @import("../Level.zig").Value;
    var input: Record = .{
        .level = Level.info,
        .message = "test",
        .timestamp_ns = 0,
        .fields = &.{
            .{ .key = "user", .value = .{ .group = &.{
                .{ .key = "name", .value = .{ .string = "alice" } },
                .{ .key = "email", .value = .{ .string = "alice@example.com" } },
            } } },
        },
    };

    try testing.expect(mw.process(&input, testing.allocator));
    const group_fields = input.fields[0].value.group;
    try testing.expectEqualStrings("alice", group_fields[0].value.string);
    try testing.expectEqualStrings("***", group_fields[1].value.string);

    testing.allocator.free(group_fields[1].value.string);
    testing.allocator.free(group_fields);
    testing.allocator.free(input.fields);
}

test "mask middleware non-recursive skips groups" {
    const testing = std.testing;

    const testMask = struct {
        fn mask(value: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
            _ = value;
            return allocator.dupe(u8, "***") catch null;
        }
    }.mask;

    var m = MaskMiddleware.initWithConfig("email", &testMask, .{ .recursive = false });
    const mw = m.middleware();

    const Level = @import("../Level.zig").Value;
    const sub_fields: []const Field.Field = &.{
        .{ .key = "email", .value = .{ .string = "alice@example.com" } },
    };
    const original_fields: []const Field.Field = &.{
        .{ .key = "user", .value = .{ .group = sub_fields } },
    };
    var input: Record = .{
        .level = Level.info,
        .message = "test",
        .timestamp_ns = 0,
        .fields = original_fields,
    };

    try testing.expect(mw.process(&input, testing.allocator));
    // Non-recursive: should be unchanged
    try testing.expectEqual(original_fields.ptr, input.fields.ptr);
    try testing.expectEqualStrings("alice@example.com", input.fields[0].value.group[0].value.string);
}

test "mask middleware drops record on allocation failure" {
    const testing = std.testing;

    const testMask = struct {
        fn mask(value: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
            _ = value;
            return allocator.dupe(u8, "***") catch null;
        }
    }.mask;

    var m = MaskMiddleware.init("secret", &testMask);
    const mw = m.middleware();

    const Level = @import("../Level.zig").Value;
    var input: Record = .{
        .level = Level.info,
        .message = "test",
        .timestamp_ns = 0,
        .fields = &.{
            .{ .key = "secret", .value = .{ .string = "hunter2" } },
        },
    };

    // A 1-byte FBA cannot allocate the replacement field slice → OOM → drop.
    var tiny_buf: [1]u8 = undefined;
    var tiny_fba = std.heap.FixedBufferAllocator.init(&tiny_buf);
    try testing.expect(!mw.process(&input, tiny_fba.allocator()));
}
