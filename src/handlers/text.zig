const std = @import("std");
const Record = @import("../Record.zig");
const handler_mod = @import("../Handler.zig");
const HandlerType = handler_mod;
const FlushThunk = handler_mod.FlushThunk;
const Field = @import("../Field.zig");
const fd = @import("../writers/fd.zig");

pub const Config = struct {
    /// Stack buffer size for formatting a single record. If a record exceeds this,
    /// a truncation fallback is emitted instead. Increase for records with many fields.
    buf_size: usize = 8192,
    timestamp: enum { unix, rfc3339 } = .unix,
    /// Key name for the level field. Use "severity" for GCP Cloud Logging.
    level_key: []const u8 = "level",
    /// Key name for the timestamp field. Use "timestamp" for GCP Cloud Logging.
    time_key: []const u8 = "time",
    /// Key name for the message field. Use "message" for GCP Cloud Logging.
    msg_key: []const u8 = "msg",
};

pub fn Handler(comptime config: Config) type {
    return struct {
        const Self = @This();

        writer: std.io.AnyWriter,
        mutex: std.Thread.Mutex = .{},
        /// Optional flush callback and context. Set these when the underlying
        /// writer is buffered (e.g. BufferedWriter or AsyncWriter) so that
        /// `logger.flush()` propagates through to the sink.
        flush_fn: ?*const fn (*anyopaque) void = null,
        flush_ctx: ?*anyopaque = null,

        pub fn init(writer: std.io.AnyWriter) Self {
            return .{ .writer = writer };
        }

        pub fn initWithFlush(writer: std.io.AnyWriter, thunk: FlushThunk) Self {
            return .{ .writer = writer, .flush_fn = thunk.flush_fn, .flush_ctx = thunk.flush_ctx };
        }

        pub fn handler(self: *Self) HandlerType {
            return .{
                .ptr = self,
                .emitFn = &emit,
                .flushFn = if (self.flush_fn != null) &flushThunk else null,
            };
        }

        fn flushThunk(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.flush_fn) |f| f(self.flush_ctx.?);
        }

        fn emit(ptr: *anyopaque, record: *const Record) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            var buf: [config.buf_size]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            const format_ok = if (formatRecord(fbs.writer().any(), record)) true else |_| false;
            const truncated = !format_ok and fbs.getWritten().len == config.buf_size;

            self.mutex.lock();
            defer self.mutex.unlock();

            if (!format_ok and !truncated) {
                self.writer.print(config.level_key ++ "={s} " ++ config.msg_key ++ "=\"zlog: format error\"\n", .{record.level.asText()}) catch {};
                fd.stderr.writeAll("zlog: record dropped: format error\n") catch {};
                return;
            }

            if (truncated) {
                self.writer.print(config.level_key ++ "={s} " ++ config.msg_key ++ "=\"zlog: record truncated\"\n", .{record.level.asText()}) catch {};
                fd.stderr.writeAll("zlog: record truncated (increase buf_size if this recurs)\n") catch {};
                return;
            }
            const written = fbs.getWritten();

            self.writer.writeAll(written) catch {
                fd.stderr.writeAll("zlog: write failed\n") catch {};
                return;
            };
        }

        fn formatRecord(w: std.io.AnyWriter, record: *const Record) !void {
            try w.writeAll(config.level_key ++ "=");
            try w.writeAll(record.level.asText());
            try w.writeAll(" " ++ config.time_key ++ "=");
            switch (config.timestamp) {
                .unix => try Record.writeTimestamp(w, record.timestamp_ns),
                .rfc3339 => {
                    try w.writeByte('"');
                    try Record.writeTimestampRFC3339(w, record.timestamp_ns);
                    try w.writeByte('"');
                },
            }
            try w.writeAll(" " ++ config.msg_key ++ "=\"");
            try writeTextEscaped(w, record.message);
            try w.writeByte('"');

            for (record.fields) |f| {
                try Field.writeTextField(w, "", f);
            }

            if (record.src) |src| {
                try w.writeAll(" src=");
                try writeTextEscaped(w, src.file);
                try w.print(":{d}", .{src.line});
            }

            try w.writeByte('\n');
        }

        const writeTextEscaped = Field.writeTextEscaped;
    };
}

/// Convenience aliases for the default configuration.
pub const init = Handler(.{}).init;
pub const initWithFlush = Handler(.{}).initWithFlush;

test "text handler output" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();
    var h = Handler(.{}).init(writer.any());

    const Level = @import("../Level.zig").Value;
    const record: Record = .{
        .level = Level.info,
        .message = "started",
        .timestamp_ns = 0,
        .fields = &.{
            .{ .key = "port", .value = .{ .uint = 8080 } },
        },
    };
    h.handler().emit(&record);

    try testing.expectEqualStrings("level=info time=0.000000000 msg=\"started\" port=8080\n", fbs.getWritten());
}

test "text handler group fields" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();
    var h = Handler(.{}).init(writer.any());

    const Level = @import("../Level.zig").Value;
    const record: Record = .{
        .level = Level.info,
        .message = "handled",
        .timestamp_ns = 0,
        .fields = &.{
            .{ .key = "request", .value = .{ .group = &.{
                .{ .key = "method", .value = .{ .string = "GET" } },
                .{ .key = "url", .value = .{ .string = "/api" } },
            } } },
        },
    };
    h.handler().emit(&record);

    try testing.expectEqualStrings("level=info time=0.000000000 msg=\"handled\" request.method=\"GET\" request.url=\"/api\"\n", fbs.getWritten());
}

test "text handler negative sub-second timestamp" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();
    var h = Handler(.{}).init(writer.any());

    const record: Record = .{
        .level = @import("../Level.zig").Value.info,
        .message = "neg",
        .timestamp_ns = -500_000_000,
        .fields = &.{},
    };
    h.handler().emit(&record);

    try testing.expectEqualStrings("level=info time=-0.500000000 msg=\"neg\"\n", fbs.getWritten());
}

test "text handler rfc3339 timestamp" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();
    var h = Handler(.{ .timestamp = .rfc3339 }).init(writer.any());

    const record: Record = .{
        .level = @import("../Level.zig").Value.info,
        .message = "hello",
        .timestamp_ns = 1740062445_123456789,
        .fields = &.{},
    };
    h.handler().emit(&record);

    try testing.expectEqualStrings("level=info time=\"2025-02-20T14:40:45.123456789Z\" msg=\"hello\"\n", fbs.getWritten());
}
