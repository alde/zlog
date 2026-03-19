const std = @import("std");
const Record = @import("../Record.zig");
const handler_mod = @import("../Handler.zig");
const HandlerType = handler_mod;
const FlushThunk = handler_mod.FlushThunk;
const Field = @import("../Field.zig");
const Level = @import("../Level.zig").Value;
const fd = @import("../writers/fd.zig");

pub const Config = struct {
    /// Stack buffer size for formatting a single record. If a record exceeds this,
    /// a truncation fallback is emitted instead. Increase for records with many fields.
    buf_size: usize = 8192,
    timestamp: enum { unix, rfc3339 } = .unix,
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
                self.writer.print("{s}{s}{s} zlog: format error\n", .{ levelColor(record.level), levelTag(record.level), reset }) catch {};
                fd.stderr.writeAll("zlog: record dropped: format error\n") catch {};
                return;
            }

            if (truncated) {
                self.writer.print("{s}{s}{s} zlog: record truncated\n", .{ levelColor(record.level), levelTag(record.level), reset }) catch {};
                fd.stderr.writeAll("zlog: record truncated (increase buf_size if this recurs)\n") catch {};
                return;
            }
            const written = fbs.getWritten();

            self.writer.writeAll(written) catch {
                fd.stderr.writeAll("zlog: write failed\n") catch {};
                return;
            };
        }

        const message_width = 44;

        fn formatRecord(w: std.io.AnyWriter, record: *const Record) !void {
            const color = levelColor(record.level);
            try w.writeAll(color);
            try w.writeAll(levelTag(record.level));
            try w.writeAll(reset);

            try w.writeByte('[');
            switch (config.timestamp) {
                .unix => try writeTimestampMillis(w, record.timestamp_ns),
                .rfc3339 => try Record.writeTimestampRFC3339Millis(w, record.timestamp_ns),
            }
            try w.writeAll("] ");

            // Message padded to fixed width, accounting for escaped characters
            // (\" and \\) that produce more output bytes than the raw message.
            try writeTextEscaped(w, record.message);
            const escaped_len = escapedLen(record.message);
            if (escaped_len < message_width) {
                try w.writeByteNTimes(' ', message_width - escaped_len);
            }

            for (record.fields) |f| {
                try Field.writeFieldGeneric(w, "", f, writeColorKey);
            }

            if (record.src) |src| {
                try w.writeAll(" ");
                try w.writeAll(cyan);
                try w.writeAll("src");
                try w.writeAll(reset);
                try w.writeAll("=");
                try writeTextEscaped(w, src.file);
                try w.print(":{d}", .{src.line});
            }

            try w.writeByte('\n');
        }

        fn writeTimestampMillis(w: std.io.AnyWriter, timestamp_ns: i128) !void {
            const secs = @divTrunc(timestamp_ns, 1_000_000_000);
            const millis: u64 = @intCast(@abs(@rem(timestamp_ns, 1_000_000_000)) / 1_000_000);
            if (timestamp_ns < 0 and secs == 0) {
                try w.print("-0.{d:0>3}", .{millis});
            } else {
                try w.print("{d}.{d:0>3}", .{ secs, millis });
            }
        }

        const writeTextEscaped = Field.writeTextEscaped;

        /// Returns the byte length of a string after text escaping (\\ and \").
        fn escapedLen(s: []const u8) usize {
            var extra: usize = 0;
            for (s) |c| {
                if (c == '"' or c == '\\') extra += 1;
            }
            return s.len + extra;
        }
    };
}

fn writeColorKey(w: std.io.AnyWriter, prefix: []const u8, key: []const u8) anyerror!void {
    try w.writeAll(cyan);
    if (prefix.len > 0) {
        try w.writeAll(prefix);
        try w.writeByte('.');
    }
    try w.writeAll(key);
    try w.writeAll(reset);
}

// ANSI color codes
const cyan = "\x1b[36m";
const green = "\x1b[32m";
const yellow = "\x1b[33m";
const red = "\x1b[31m";
const reset = "\x1b[0m";

fn levelColor(level: Level) []const u8 {
    return switch (level) {
        .debug => cyan,
        .info => green,
        .warn => yellow,
        .err => red,
    };
}

fn levelTag(level: Level) []const u8 {
    return switch (level) {
        .debug => "DEBU",
        .info => "INFO",
        .warn => "WARN",
        .err => "ERRO",
    };
}

/// Convenience aliases for the default configuration.
pub const init = Handler(.{}).init;
pub const initWithFlush = Handler(.{}).initWithFlush;

test "color handler output contains ANSI codes" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();
    var h = Handler(.{}).init(writer.any());

    const record: Record = .{
        .level = Level.info,
        .message = "started",
        .timestamp_ns = 0,
        .fields = &.{
            .{ .key = "port", .value = .{ .uint = 8080 } },
        },
    };
    h.handler().emit(&record);

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, green) != null);
    try testing.expect(std.mem.indexOf(u8, output, "INFO") != null);
    try testing.expect(std.mem.indexOf(u8, output, reset) != null);
    try testing.expect(std.mem.indexOf(u8, output, "started") != null);
    try testing.expect(std.mem.indexOf(u8, output, cyan ++ "port" ++ reset ++ "=8080") != null);
}

test "color handler fields formatted" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();
    var h = Handler(.{}).init(writer.any());

    const record: Record = .{
        .level = Level.warn,
        .message = "slow",
        .timestamp_ns = 12_345_000_000,
        .fields = &.{
            .{ .key = "duration_ms", .value = .{ .uint = 1200 } },
            .{ .key = "path", .value = .{ .string = "/api" } },
        },
    };
    h.handler().emit(&record);

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, yellow) != null);
    try testing.expect(std.mem.indexOf(u8, output, "WARN") != null);
    try testing.expect(std.mem.indexOf(u8, output, cyan ++ "duration_ms" ++ reset ++ "=1200") != null);
    try testing.expect(std.mem.indexOf(u8, output, cyan ++ "path" ++ reset ++ "=\"/api\"") != null);
}

test "color handler groups use dots" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();
    var h = Handler(.{}).init(writer.any());

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

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, cyan ++ "request.method" ++ reset ++ "=\"GET\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, cyan ++ "request.url" ++ reset ++ "=\"/api\"") != null);
}

test "color handler src location" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();
    var h = Handler(.{}).init(writer.any());

    const record: Record = .{
        .level = Level.err,
        .message = "failed",
        .timestamp_ns = 0,
        .fields = &.{},
        .src = .{
            .file = "main.zig",
            .fn_name = "run",
            .line = 42,
            .column = 0,
            .module = "test",
        },
    };
    h.handler().emit(&record);

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, red) != null);
    try testing.expect(std.mem.indexOf(u8, output, "ERRO") != null);
    try testing.expect(std.mem.indexOf(u8, output, cyan ++ "src" ++ reset ++ "=main.zig:42") != null);
}

test "color handler level tags" {
    const testing = std.testing;

    try testing.expectEqualStrings("DEBU", levelTag(.debug));
    try testing.expectEqualStrings("INFO", levelTag(.info));
    try testing.expectEqualStrings("WARN", levelTag(.warn));
    try testing.expectEqualStrings("ERRO", levelTag(.err));
}

test "color handler rfc3339 timestamp" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();
    var h = Handler(.{ .timestamp = .rfc3339 }).init(writer.any());

    const record: Record = .{
        .level = Level.info,
        .message = "hello",
        .timestamp_ns = 1740062445_123456789,
        .fields = &.{},
    };
    h.handler().emit(&record);

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "[2025-02-20T14:40:45.123Z]") != null);
}
