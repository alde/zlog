const std = @import("std");

pub const Value = enum(u3) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    pub fn asText(self: Value) []const u8 {
        return switch (self) {
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "error",
        };
    }
};

test "level ordering" {
    const testing = std.testing;
    try testing.expect(@intFromEnum(Value.debug) < @intFromEnum(Value.info));
    try testing.expect(@intFromEnum(Value.info) < @intFromEnum(Value.warn));
    try testing.expect(@intFromEnum(Value.warn) < @intFromEnum(Value.err));
}

test "level asText" {
    const testing = std.testing;
    try testing.expectEqualStrings("debug", Value.debug.asText());
    try testing.expectEqualStrings("info", Value.info.asText());
    try testing.expectEqualStrings("warn", Value.warn.asText());
    try testing.expectEqualStrings("error", Value.err.asText());
}
