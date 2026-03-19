const std = @import("std");
const Handler = @import("Handler.zig");
const Record = @import("Record.zig");
const Level = @import("Level.zig").Value;
const Field = @import("Field.zig");

/// Global handler for std.log bridge. Thread-safe via atomic pointer.
/// The pointed-to Handler must outlive all logging calls.
var global_handler: std.atomic.Value(?*const Handler) = std.atomic.Value(?*const Handler).init(null);

/// Sets the handler used by the std.log bridge. The handler pointer must remain
/// valid for the lifetime of the program (or until replaced).
pub fn setHandler(handler: *const Handler) void {
    global_handler.store(handler, .release);
}

/// Clears the std.log handler. Subsequent std.log calls become noops.
pub fn clearHandler() void {
    global_handler.store(null, .release);
}

pub fn stdLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const handler_ptr = global_handler.load(.acquire) orelse return;

    const level: Level = switch (message_level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    };

    const scope_fields: []const Field.Field = if (scope == .default)
        &.{}
    else
        &.{.{ .key = "scope", .value = .{ .string = @tagName(scope) } }};

    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    fbs.writer().print(format, args) catch {
        const record: Record = .{
            .level = level,
            .message = format,
            .timestamp_ns = std.time.nanoTimestamp(),
            .fields = scope_fields,
        };
        handler_ptr.emit(&record);
        return;
    };

    const record: Record = .{
        .level = level,
        .message = fbs.getWritten(),
        .timestamp_ns = std.time.nanoTimestamp(),
        .fields = scope_fields,
    };
    handler_ptr.emit(&record);
}

test "std.log bridge emits records" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const handler_iface = h.handler();
    setHandler(&handler_iface);
    defer clearHandler();

    stdLogFn(.info, .default, "hello {s}", .{"world"});

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"hello world\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"level\":\"info\"") != null);
}

test "std.log bridge with no handler is noop" {
    clearHandler();
    stdLogFn(.info, .default, "should not crash", .{});
}

test "std.log bridge preserves non-default scope" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const handler_iface = h.handler();
    setHandler(&handler_iface);
    defer clearHandler();

    stdLogFn(.info, .auth, "login attempt", .{});

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"scope\":\"auth\"") != null);
}

test "std.log bridge omits scope for .default" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const handler_iface = h.handler();
    setHandler(&handler_iface);
    defer clearHandler();

    stdLogFn(.info, .default, "no scope", .{});

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"scope\"") == null);
}
