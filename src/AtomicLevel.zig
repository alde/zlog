const std = @import("std");
const Level = @import("Level.zig").Value;

const AtomicLevel = @This();

value: std.atomic.Value(u8),

pub fn init(level: Level) AtomicLevel {
    return .{ .value = std.atomic.Value(u8).init(@intFromEnum(level)) };
}

pub fn load(self: *const AtomicLevel) Level {
    const raw = self.value.load(.acquire);
    return std.meta.intToEnum(Level, raw) catch .err;
}

pub fn set(self: *AtomicLevel, level: Level) void {
    self.value.store(@intFromEnum(level), .release);
}

test "init and load returns initial value" {
    const lvl = AtomicLevel.init(.warn);
    try std.testing.expectEqual(Level.warn, lvl.load());
}

test "set and load returns new value" {
    var lvl = AtomicLevel.init(.info);
    lvl.set(.debug);
    try std.testing.expectEqual(Level.debug, lvl.load());
}

test "invalid raw value falls back to err" {
    var lvl = AtomicLevel.init(.info);
    // Simulate corruption by storing an invalid enum value
    lvl.value.store(7, .release);
    try std.testing.expectEqual(Level.err, lvl.load());
}
