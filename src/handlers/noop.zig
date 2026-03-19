const Handler = @import("../Handler.zig");
const Record = @import("../Record.zig");

const NoopHandler = @This();

pub fn init() NoopHandler {
    return .{};
}

pub fn handler(self: *NoopHandler) Handler {
    return .{
        .ptr = self,
        .emitFn = &emit,
    };
}

fn emit(_: *anyopaque, _: *const Record) void {}

test "noop handler discards records" {
    const std = @import("std");
    const Level = @import("../Level.zig").Value;

    var h = NoopHandler.init();
    const iface = h.handler();

    // Should not crash or produce output
    const record: Record = .{
        .level = Level.info,
        .message = "discarded",
        .timestamp_ns = 0,
        .fields = &.{},
    };
    iface.emit(&record);

    try std.testing.expect(true);
}
