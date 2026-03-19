const std = @import("std");
const Record = @import("../Record.zig");
const Middleware = @import("../Middleware.zig");

/// Samples records uniformly: passes 1-in-N records regardless of level.
/// All levels are sampled at the same rate. For level-aware sampling (e.g.
/// always pass errors, sample debug), use `LevelSamplingMiddleware`.
const SimpleSamplingMiddleware = @This();

rate: u32,
counter: std.atomic.Value(u32),

pub fn init(rate: u32) SimpleSamplingMiddleware {
    std.debug.assert(rate > 0);
    return .{ .rate = rate, .counter = std.atomic.Value(u32).init(0) };
}

pub fn middleware(self: *SimpleSamplingMiddleware) Middleware {
    return .{
        .ptr = self,
        .processFn = &process,
    };
}

fn process(ptr: *anyopaque, _: *Record, _: std.mem.Allocator) bool {
    const self: *SimpleSamplingMiddleware = @ptrCast(@alignCast(ptr));

    if (self.rate <= 1) return true;

    const count = self.counter.fetchAdd(1, .monotonic);
    return count % self.rate == 0;
}

test "rate 1 passes all records" {
    const testing = std.testing;
    const Level = @import("../Level.zig").Value;

    var s = SimpleSamplingMiddleware.init(1);
    const mw = s.middleware();

    var input: Record = .{
        .level = Level.info,
        .message = "test",
        .timestamp_ns = 0,
        .fields = &.{},
    };

    for (0..100) |_| {
        try testing.expect(mw.process(&input, testing.allocator));
    }
}

test "rate 2 passes every other record" {
    const testing = std.testing;
    const Level = @import("../Level.zig").Value;

    var s = SimpleSamplingMiddleware.init(2);
    const mw = s.middleware();

    var input: Record = .{
        .level = Level.info,
        .message = "test",
        .timestamp_ns = 0,
        .fields = &.{},
    };

    var passed: u32 = 0;
    for (0..100) |_| {
        if (mw.process(&input, testing.allocator)) passed += 1;
    }
    try testing.expectEqual(50, passed);
}

test "rate 10 passes 10% of records" {
    const testing = std.testing;
    const Level = @import("../Level.zig").Value;

    var s = SimpleSamplingMiddleware.init(10);
    const mw = s.middleware();

    var input: Record = .{
        .level = Level.info,
        .message = "test",
        .timestamp_ns = 0,
        .fields = &.{},
    };

    var passed: u32 = 0;
    for (0..1000) |_| {
        if (mw.process(&input, testing.allocator)) passed += 1;
    }
    try testing.expectEqual(100, passed);
}

test "dropped records return false" {
    const testing = std.testing;
    const Level = @import("../Level.zig").Value;

    var s = SimpleSamplingMiddleware.init(100);
    const mw = s.middleware();

    var input: Record = .{
        .level = Level.info,
        .message = "test",
        .timestamp_ns = 0,
        .fields = &.{},
    };

    // First record passes (counter=0, 0 % 100 == 0)
    try testing.expect(mw.process(&input, testing.allocator));
    // Next 99 should be dropped
    for (0..99) |_| {
        try testing.expect(!mw.process(&input, testing.allocator));
    }
}

test "passed records are returned unmodified" {
    const testing = std.testing;
    const Level = @import("../Level.zig").Value;

    var s = SimpleSamplingMiddleware.init(5);
    const mw = s.middleware();

    const fields = &[_]@import("../Field.zig").Field{
        .{ .key = "user", .value = .{ .string = "alice" } },
    };
    var input: Record = .{
        .level = Level.info,
        .message = "test",
        .timestamp_ns = 42,
        .fields = fields,
    };

    try testing.expect(mw.process(&input, testing.allocator));
    try testing.expectEqual(fields.ptr, input.fields.ptr);
    try testing.expectEqual(42, input.timestamp_ns);
    try testing.expectEqualStrings("test", input.message);
}
