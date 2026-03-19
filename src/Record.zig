const std = @import("std");
const Level = @import("Level.zig").Value;
const Field = @import("Field.zig");

/// A single log record passed through the middleware chain to the handler.
/// Middleware receives a mutable pointer and may replace `fields` with a new
/// allocation from the per-call arena. Handlers receive the final record.
const Record = @This();

level: Level,
message: []const u8,
timestamp_ns: i128,
/// May be mutated by middleware (e.g. redaction). Arena-allocated per log call.
fields: []const Field.Field,
src: ?std.builtin.SourceLocation = null,

/// Writes a timestamp as seconds.nanoseconds (9 decimal places).
/// Shared by json and text handlers.
pub fn writeTimestamp(w: std.io.AnyWriter, timestamp_ns: i128) !void {
    const secs = @divTrunc(timestamp_ns, 1_000_000_000);
    const nanos: u64 = @intCast(@abs(@rem(timestamp_ns, 1_000_000_000)));
    if (timestamp_ns < 0 and secs == 0) {
        try w.print("-0.{d:0>9}", .{nanos});
    } else {
        try w.print("{d}.{d:0>9}", .{ secs, nanos });
    }
}

/// Writes a timestamp in RFC 3339 format: 2025-02-20T14:30:45.123456789Z
/// For negative/pre-epoch timestamps, falls back to unix format.
pub fn writeTimestampRFC3339(w: std.io.AnyWriter, timestamp_ns: i128) !void {
    if (timestamp_ns < 0) return writeTimestamp(w, timestamp_ns);

    const total_secs: u64 = @intCast(@divTrunc(timestamp_ns, 1_000_000_000));
    const nanos: u64 = @intCast(@rem(timestamp_ns, 1_000_000_000));

    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = total_secs };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_secs.getDaySeconds();

    const year = year_day.year;
    const month = month_day.month.numeric();
    const day = month_day.day_index + 1;
    const hour = day_secs.getHoursIntoDay();
    const minute = day_secs.getMinutesIntoHour();
    const second = day_secs.getSecondsIntoMinute();

    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}Z", .{
        year, month, day, hour, minute, second, nanos,
    });
}

/// Writes a timestamp in RFC 3339 format with millisecond precision: 2025-02-20T14:30:45.123Z
/// For negative/pre-epoch timestamps, falls back to unix format.
pub fn writeTimestampRFC3339Millis(w: std.io.AnyWriter, timestamp_ns: i128) !void {
    if (timestamp_ns < 0) return writeTimestamp(w, timestamp_ns);

    const total_secs: u64 = @intCast(@divTrunc(timestamp_ns, 1_000_000_000));
    const millis: u64 = @intCast(@divTrunc(@rem(timestamp_ns, 1_000_000_000), 1_000_000));

    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = total_secs };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_secs.getDaySeconds();

    const year = year_day.year;
    const month = month_day.month.numeric();
    const day = month_day.day_index + 1;
    const hour = day_secs.getHoursIntoDay();
    const minute = day_secs.getMinutesIntoHour();
    const second = day_secs.getSecondsIntoMinute();

    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year, month, day, hour, minute, second, millis,
    });
}

test "writeTimestampRFC3339 positive timestamp" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeTimestampRFC3339(fbs.writer().any(), 1740062445_123456789);
    try std.testing.expectEqualStrings("2025-02-20T14:40:45.123456789Z", fbs.getWritten());
}

test "writeTimestampRFC3339 zero timestamp" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeTimestampRFC3339(fbs.writer().any(), 0);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000000000Z", fbs.getWritten());
}

test "writeTimestampRFC3339 sub-second only" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeTimestampRFC3339(fbs.writer().any(), 500_000_000);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.500000000Z", fbs.getWritten());
}

test "writeTimestampRFC3339 negative falls back to unix" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeTimestampRFC3339(fbs.writer().any(), -500_000_000);
    try std.testing.expectEqualStrings("-0.500000000", fbs.getWritten());
}

test "writeTimestampRFC3339Millis" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeTimestampRFC3339Millis(fbs.writer().any(), 1740062445_123456789);
    try std.testing.expectEqualStrings("2025-02-20T14:40:45.123Z", fbs.getWritten());
}
