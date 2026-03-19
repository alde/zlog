const std = @import("std");
const Record = @import("../Record.zig");
const Middleware = @import("../Middleware.zig");
const Level = @import("../Level.zig").Value;

/// Samples records below a threshold level at 1-in-N rate. Records at or above
/// `min_pass_level` always pass through. Useful for high-traffic services where
/// debug/info records can be sampled but warnings and errors must never be dropped.
///
/// Example: sample debug/info at 1-in-100, always pass warn/err:
///   var sampler = LevelSamplingMiddleware.init(100, .warn);
const LevelSamplingMiddleware = @This();

rate: u32,
min_pass_level: Level,
counter: std.atomic.Value(u32),

pub fn init(rate: u32, min_pass_level: Level) LevelSamplingMiddleware {
    std.debug.assert(rate > 0);
    return .{
        .rate = rate,
        .min_pass_level = min_pass_level,
        .counter = std.atomic.Value(u32).init(0),
    };
}

pub fn middleware(self: *LevelSamplingMiddleware) Middleware {
    return .{
        .ptr = self,
        .processFn = &process,
    };
}

fn process(ptr: *anyopaque, record: *Record, _: std.mem.Allocator) bool {
    const self: *LevelSamplingMiddleware = @ptrCast(@alignCast(ptr));

    if (@intFromEnum(record.level) >= @intFromEnum(self.min_pass_level)) return true;
    if (self.rate <= 1) return true;

    const count = self.counter.fetchAdd(1, .monotonic);
    return count % self.rate == 0;
}

test "records at min_pass_level always pass" {
    const testing = std.testing;

    var s = LevelSamplingMiddleware.init(1000, .warn);
    const mw = s.middleware();

    var warn_record: Record = .{
        .level = .warn,
        .message = "test",
        .timestamp_ns = 0,
        .fields = &.{},
    };
    var err_record: Record = .{
        .level = .err,
        .message = "test",
        .timestamp_ns = 0,
        .fields = &.{},
    };
    for (0..100) |_| {
        try testing.expect(mw.process(&warn_record, testing.allocator));
        try testing.expect(mw.process(&err_record, testing.allocator));
    }
}

test "records below min_pass_level are sampled" {
    const testing = std.testing;

    var s = LevelSamplingMiddleware.init(10, .warn);
    const mw = s.middleware();

    var input: Record = .{
        .level = .info,
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

test "debug records are sampled, errors always pass" {
    const testing = std.testing;

    var s = LevelSamplingMiddleware.init(100, .err);
    const mw = s.middleware();

    var debug_record: Record = .{
        .level = .debug,
        .message = "noisy",
        .timestamp_ns = 0,
        .fields = &.{},
    };
    var err_record: Record = .{
        .level = .err,
        .message = "critical",
        .timestamp_ns = 0,
        .fields = &.{},
    };

    // First debug passes (counter=0), next 99 dropped
    try testing.expect(mw.process(&debug_record, testing.allocator));
    for (0..99) |_| {
        try testing.expect(!mw.process(&debug_record, testing.allocator));
    }

    // Errors always pass regardless of counter
    for (0..100) |_| {
        try testing.expect(mw.process(&err_record, testing.allocator));
    }
}

test "rate 1 passes all records at any level" {
    const testing = std.testing;

    var s = LevelSamplingMiddleware.init(1, .err);
    const mw = s.middleware();

    var input: Record = .{
        .level = .debug,
        .message = "test",
        .timestamp_ns = 0,
        .fields = &.{},
    };

    for (0..100) |_| {
        try testing.expect(mw.process(&input, testing.allocator));
    }
}

test "counter only increments for sampled levels" {
    const testing = std.testing;

    var s = LevelSamplingMiddleware.init(2, .warn);
    const mw = s.middleware();

    var info_record: Record = .{
        .level = .info,
        .message = "test",
        .timestamp_ns = 0,
        .fields = &.{},
    };
    var err_record: Record = .{
        .level = .err,
        .message = "test",
        .timestamp_ns = 0,
        .fields = &.{},
    };

    // info #1 passes (counter 0 % 2 == 0)
    try testing.expect(mw.process(&info_record, testing.allocator));
    // errors don't touch the counter
    for (0..50) |_| {
        try testing.expect(mw.process(&err_record, testing.allocator));
    }
    // info #2 dropped (counter 1 % 2 != 0)
    try testing.expect(!mw.process(&info_record, testing.allocator));
    // info #3 passes (counter 2 % 2 == 0)
    try testing.expect(mw.process(&info_record, testing.allocator));
}
