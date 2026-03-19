const std = @import("std");
const zlog = @import("zlog");

/// A custom handler that emits records as CSV lines.
/// Format: level,timestamp,message,field1,field2,...
const CsvHandler = struct {
    writer: std.io.AnyWriter,
    mutex: std.Thread.Mutex = .{},

    fn init(writer: std.io.AnyWriter) CsvHandler {
        return .{ .writer = writer };
    }

    fn handler(self: *CsvHandler) zlog.Handler {
        return .{
            .ptr = self,
            .emitFn = &emit,
        };
    }

    fn emit(ptr: *anyopaque, record: *const zlog.Record) void {
        const self: *CsvHandler = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        self.writeRecord(record) catch return;
    }

    fn writeRecord(self: *CsvHandler, record: *const zlog.Record) !void {
        const w = self.writer;
        const secs = @divTrunc(record.timestamp_ns, 1_000_000_000);
        const nanos: u64 = @intCast(@abs(@rem(record.timestamp_ns, 1_000_000_000)));

        // level
        try w.writeAll(record.level.asText());
        try w.writeByte(',');

        // timestamp
        try w.print("{d}.{d:0>9}", .{ secs, nanos });
        try w.writeByte(',');

        // message (quoted for CSV safety)
        try writeCsvField(w, record.message);

        // fields
        for (record.fields) |f| {
            try w.writeByte(',');
            try writeFieldValue(w, f);
        }

        try w.writeByte('\n');
    }

    fn writeFieldValue(w: std.io.AnyWriter, f: zlog.Field) !void {
        switch (f.value) {
            .string => |s| try writeCsvField(w, s),
            .int => |v| try w.print("{d}", .{v}),
            .uint => |v| try w.print("{d}", .{v}),
            .float => |v| try w.print("{d}", .{v}),
            .boolean => |v| try w.writeAll(if (v) "true" else "false"),
            .err_name => |s| try writeCsvField(w, s),
            .null_value => {},
            .group => |sub_fields| {
                for (sub_fields, 0..) |sf, i| {
                    if (i > 0) try w.writeByte(',');
                    try writeFieldValue(w, sf);
                }
            },
        }
    }

    fn writeCsvField(w: std.io.AnyWriter, s: []const u8) !void {
        const needs_quoting = std.mem.indexOfAny(u8, s, ",\"\n") != null;
        if (needs_quoting) {
            try w.writeByte('"');
            for (s) |c| {
                if (c == '"') try w.writeByte('"');
                try w.writeByte(c);
            }
            try w.writeByte('"');
        } else {
            try w.writeAll(s);
        }
    }
};

/// A handler that routes records by level: info/debug to one writer, warn/err to another.
/// Useful for sending normal logs to stdout and errors to stderr.
const SplitHandler = struct {
    normal: zlog.Handler,
    error_handler: zlog.Handler,

    fn init(normal: zlog.Handler, error_handler: zlog.Handler) SplitHandler {
        return .{ .normal = normal, .error_handler = error_handler };
    }

    fn handler(self: *SplitHandler) zlog.Handler {
        return .{
            .ptr = self,
            .emitFn = &emit,
        };
    }

    fn emit(ptr: *anyopaque, record: *const zlog.Record) void {
        const self: *SplitHandler = @ptrCast(@alignCast(ptr));
        if (@intFromEnum(record.level) >= @intFromEnum(zlog.Level.warn)) {
            self.error_handler.emit(record);
        } else {
            self.normal.emit(record);
        }
    }
};

pub fn main() !void {
    // ── CSV handler demo ────────────────────────────────────────────────
    {
        var csv_handler = CsvHandler.init(zlog.stderr);

        const Log = zlog.Logger(.debug, .{});
        const logger = try Log.init(.{
            .handler = csv_handler.handler(),
            .allocator = std.heap.page_allocator,
        });
        defer logger.deinit();

        zlog.stderr.writeAll("level,timestamp,message,fields...\n") catch {};

        logger.info("server started", .{ .port = 8080, .env = "prod" });
        logger.warn("slow response", .{ .duration_ms = 1200 });
        logger.err("connection failed", .{ .host = "db.local", .err = error.TimedOut });
        logger.debug("field with comma", .{ .note = "hello, world" });
    }

    zlog.stderr.writeAll("\n--- Split handler: info/debug → stdout JSON, warn/err → stderr text ---\n") catch {};

    // ── Split handler demo ──────────────────────────────────────────────
    // Routes info/debug to stdout (JSON) and warn/err to stderr (text).
    {
        var json_h = zlog.JsonHandler.init(zlog.stdout);
        const Rfc3339Text = zlog.TextHandler.Handler(.{ .timestamp = .rfc3339 });
        var text_h = Rfc3339Text.init(zlog.stderr);

        var split = SplitHandler.init(json_h.handler(), text_h.handler());

        const Log = zlog.Logger(.debug, .{});
        const logger = try Log.init(.{
            .handler = split.handler(),
            .allocator = std.heap.page_allocator,
        });
        defer logger.deinit();

        logger.info("server started", .{ .port = 8080 }); // → stdout JSON
        logger.debug("cache hit", .{ .key = "user:42" }); // → stdout JSON
        logger.warn("slow query", .{ .duration_ms = 1200 }); // → stderr text
        logger.err("connection lost", .{ .host = "db.local" }); // → stderr text
    }
}

