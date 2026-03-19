const std = @import("std");
const Record = @import("../Record.zig");
const Middleware = @import("../Middleware.zig");
const Field = @import("../Field.zig");
const fd = @import("../writers/fd.zig");

const RedactMiddleware = @This();

redact_keys: []const []const u8,
recursive: bool,

pub const Config = struct {
    recursive: bool = true,
};

pub fn init(redact_keys: []const []const u8) RedactMiddleware {
    return initWithConfig(redact_keys, .{});
}

pub fn initWithConfig(redact_keys: []const []const u8, config: Config) RedactMiddleware {
    return .{ .redact_keys = redact_keys, .recursive = config.recursive };
}

pub fn middleware(self: *RedactMiddleware) Middleware {
    return .{
        .ptr = self,
        .processFn = &process,
    };
}

/// Processes the record, redacting configured keys. If allocation fails during
/// redaction, the entire record is dropped rather than risk emitting sensitive data.
fn process(ptr: *anyopaque, record: *Record, allocator: std.mem.Allocator) bool {
    const self: *RedactMiddleware = @ptrCast(@alignCast(ptr));

    const new_fields = self.processFields(record.fields, allocator) catch {
        // Safety: if we can't allocate to redact requested fields, drop the
        // entire record rather than risk emitting sensitive data.
        fd.stderr.writeAll("zlog: record dropped: failed to allocate for redaction of keys: ") catch {};
        self.writeKeys(fd.stderr) catch {};
        fd.stderr.writeAll("\n") catch {};
        return false;
    };
    if (new_fields) |nf| record.fields = nf;
    return true;
}

fn writeKeys(self: *const RedactMiddleware, w: std.io.AnyWriter) !void {
    for (self.redact_keys, 0..) |key, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(key);
    }
}

/// Processes a field slice. Returns a new slice if changes were made, null if
/// no changes were needed (zero-alloc fast path), or OutOfMemory if allocation
/// failed (caller must drop the record to avoid emitting sensitive data).
fn processFields(self: *const RedactMiddleware, fields: []const Field.Field, allocator: std.mem.Allocator) error{OutOfMemory}!?[]const Field.Field {
    // First pass: check if any changes are needed (no allocations)
    var needs_change = false;
    for (fields) |f| {
        if (self.shouldRedact(f.key)) {
            needs_change = true;
            break;
        }
        if (self.recursive and f.value == .group) {
            if (self.needsRedaction(f.value.group)) {
                needs_change = true;
                break;
            }
        }
    }

    if (!needs_change) return null;

    // Second pass: allocate and build new fields
    const new_fields = try allocator.alloc(Field.Field, fields.len);
    for (fields, 0..) |f, i| {
        if (self.shouldRedact(f.key)) {
            new_fields[i] = .{ .key = f.key, .value = .{ .string = "[REDACTED]" } };
        } else if (self.recursive and f.value == .group) {
            if (try self.processFields(f.value.group, allocator)) |new_sub| {
                new_fields[i] = .{ .key = f.key, .value = .{ .group = new_sub } };
            } else {
                new_fields[i] = f;
            }
        } else {
            new_fields[i] = f;
        }
    }

    return new_fields;
}

/// Allocation-free check: returns true if any field (recursively) needs redaction.
fn needsRedaction(self: *const RedactMiddleware, fields: []const Field.Field) bool {
    for (fields) |f| {
        if (self.shouldRedact(f.key)) return true;
        if (self.recursive and f.value == .group) {
            if (self.needsRedaction(f.value.group)) return true;
        }
    }
    return false;
}

fn shouldRedact(self: *const RedactMiddleware, key: []const u8) bool {
    for (self.redact_keys) |rk| {
        if (std.mem.eql(u8, key, rk)) return true;
    }
    return false;
}

test "redact middleware" {
    const testing = std.testing;
    var r = RedactMiddleware.init(&.{ "password", "ssn" });
    const mw = r.middleware();

    const Level = @import("../Level.zig").Value;
    var input: Record = .{
        .level = Level.info,
        .message = "test",
        .timestamp_ns = 0,
        .fields = &.{
            .{ .key = "user", .value = .{ .string = "alice" } },
            .{ .key = "password", .value = .{ .string = "secret" } },
            .{ .key = "ssn", .value = .{ .string = "123-45-6789" } },
        },
    };

    try testing.expect(mw.process(&input, testing.allocator));
    try testing.expectEqualStrings("alice", input.fields[0].value.string);
    try testing.expectEqualStrings("[REDACTED]", input.fields[1].value.string);
    try testing.expectEqualStrings("[REDACTED]", input.fields[2].value.string);

    testing.allocator.free(input.fields);
}

test "redact middleware no match passthrough" {
    const testing = std.testing;
    var r = RedactMiddleware.init(&.{"password"});
    const mw = r.middleware();

    const Level = @import("../Level.zig").Value;
    const original_fields: []const Field.Field = &.{
        .{ .key = "user", .value = .{ .string = "alice" } },
    };
    var input: Record = .{
        .level = Level.info,
        .message = "test",
        .timestamp_ns = 0,
        .fields = original_fields,
    };

    try testing.expect(mw.process(&input, testing.allocator));
    // Should return the original record unchanged (no allocation)
    try testing.expectEqual(original_fields.ptr, input.fields.ptr);
}

test "redact middleware recurses into groups" {
    const testing = std.testing;
    var r = RedactMiddleware.init(&.{"password"});
    const mw = r.middleware();

    const Level = @import("../Level.zig").Value;
    var input: Record = .{
        .level = Level.info,
        .message = "test",
        .timestamp_ns = 0,
        .fields = &.{
            .{ .key = "user", .value = .{ .string = "alice" } },
            .{ .key = "auth", .value = .{ .group = &.{
                .{ .key = "method", .value = .{ .string = "oauth" } },
                .{ .key = "password", .value = .{ .string = "secret" } },
            } } },
        },
    };

    try testing.expect(mw.process(&input, testing.allocator));
    try testing.expectEqualStrings("alice", input.fields[0].value.string);
    // Group should have been recursed into
    const group_fields = input.fields[1].value.group;
    try testing.expectEqualStrings("oauth", group_fields[0].value.string);
    try testing.expectEqualStrings("[REDACTED]", group_fields[1].value.string);

    testing.allocator.free(group_fields);
    testing.allocator.free(input.fields);
}

test "redact middleware non-recursive skips groups" {
    const testing = std.testing;
    var r = RedactMiddleware.initWithConfig(&.{"password"}, .{ .recursive = false });
    const mw = r.middleware();

    const Level = @import("../Level.zig").Value;
    const sub_fields: []const Field.Field = &.{
        .{ .key = "password", .value = .{ .string = "secret" } },
    };
    const original_fields: []const Field.Field = &.{
        .{ .key = "auth", .value = .{ .group = sub_fields } },
    };
    var input: Record = .{
        .level = Level.info,
        .message = "test",
        .timestamp_ns = 0,
        .fields = original_fields,
    };

    try testing.expect(mw.process(&input, testing.allocator));
    // Non-recursive: group fields should be untouched
    try testing.expectEqual(original_fields.ptr, input.fields.ptr);
    try testing.expectEqualStrings("secret", input.fields[0].value.group[0].value.string);
}

test "redact middleware drops record on allocation failure" {
    const testing = std.testing;
    var r = RedactMiddleware.init(&.{"password"});
    const mw = r.middleware();

    const Level = @import("../Level.zig").Value;
    var input: Record = .{
        .level = Level.info,
        .message = "test",
        .timestamp_ns = 0,
        .fields = &.{
            .{ .key = "password", .value = .{ .string = "secret" } },
        },
    };

    // A 1-byte FBA cannot allocate the replacement field slice → OOM → drop.
    var tiny_buf: [1]u8 = undefined;
    var tiny_fba = std.heap.FixedBufferAllocator.init(&tiny_buf);
    try testing.expect(!mw.process(&input, tiny_fba.allocator()));
}
