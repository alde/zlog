const std = @import("std");
const zlog = @import("zlog");

pub fn main() !void {
    // JSON handler
    var json_handler = zlog.JsonHandler.init(zlog.stderr);
    const Log = zlog.Logger(.info, .{});
    var logger = try Log.init(.{ .handler = json_handler.handler(), .allocator = std.heap.page_allocator });
    defer logger.deinit();

    logger.info("server started", .{ .port = 8080, .env = "prod" });
    logger.debug("this won't appear", .{}); // filtered at comptime

    // Child logger with persistent fields — infallible, shares root's arena
    const req_log = logger.with(.{ .request_id = "abc-123" });
    req_log.warn("slow response", .{ .duration_ms = 1200 });

    // Error values — no manual @errorName() needed
    req_log.err("db query failed", .{ .err = error.ConnectionRefused, .retries = 3 });

    // Runtime values in attrs — variables resolved at runtime, not just comptime literals
    var status: u16 = 200;
    status += 0;
    req_log.info("response sent", .{ .status = status, .path = "/api/users" });

    // Runtime fields — dynamic keys from Field constructors
    const fields = &[_]zlog.Field{
        zlog.Field.string("trace_id", "xyz-789"),
        zlog.Field.int("attempt", 2),
        zlog.Field.boolean("retryable", true),
    };
    const traced_log = logger.withFields(fields);
    traced_log.info("retrying request", .{ .endpoint = "/api/users" });

    // Source location — use Logger with .src = true and pass @src() as last argument
    const SrcLog = zlog.Logger(.info, .{ .src = true });
    {
        var src_log = try SrcLog.init(.{ .handler = json_handler.handler(), .allocator = std.heap.page_allocator });
        defer src_log.deinit();
        src_log.info("checkpoint reached", .{ .step = "init" }, @src());
    }

    // Nested struct → grouped JSON output
    logger.info("handled", .{ .request = .{ .method = "GET", .url = "/api", .status = 200 } });

    // withGroup — namespaces all subsequent fields
    const auth_log = logger.withGroup("auth");
    auth_log.info("login attempt", .{ .user = "alice", .method = "oauth2" });

    // logf — format-string messages with structured fields
    logger.logf(.info, "request {s} took {d}ms", .{ "/api/users", 42 }, .{ .status = 200 });

    // Per-logger level override
    var verbose_level = zlog.AtomicLevel.init(.debug);
    const verbose_log = logger.withLevel(&verbose_level);
    verbose_log.debug("this appears because of per-logger level override", .{});

    // JSON handler with RFC 3339 timestamps — human-readable ISO format
    const Rfc3339Json = zlog.JsonHandler.Handler(.{ .timestamp = .rfc3339 });
    var rfc3339_handler = Rfc3339Json.init(zlog.stderr);
    var rfc3339_logger = try Log.init(.{ .handler = rfc3339_handler.handler(), .allocator = std.heap.page_allocator });
    defer rfc3339_logger.deinit();
    rfc3339_logger.info("human-readable timestamps", .{ .format = "RFC 3339" });

    // Text handler with RFC 3339 timestamps
    const Rfc3339Text = zlog.TextHandler.Handler(.{ .timestamp = .rfc3339 });
    var text_handler = Rfc3339Text.init(zlog.stderr);
    var text_logger = try Log.init(.{ .handler = text_handler.handler(), .allocator = std.heap.page_allocator });
    defer text_logger.deinit();
    text_logger.info("server started", .{ .port = 8080, .env = "prod" });
    text_logger.err("connection failed", .{ .host = "db.local", .err = error.TimedOut });

    // Text handler with groups — dot-prefixed keys
    text_logger.info("handled", .{ .request = .{ .method = "GET", .url = "/api" } });

    // Color handler with RFC 3339 timestamps — logrus-style colored output for terminals
    const Rfc3339Color = zlog.ColorHandler.Handler(.{ .timestamp = .rfc3339 });
    var color_handler = Rfc3339Color.init(zlog.stderr);
    var color_logger = try Log.init(.{ .handler = color_handler.handler(), .allocator = std.heap.page_allocator });
    defer color_logger.deinit();
    color_logger.info("server started", .{ .port = 8080, .env = "prod" });
    color_logger.warn("slow response", .{ .duration_ms = 1200 });
    color_logger.err("connection failed", .{ .host = "db.local", .err = error.TimedOut });

    // Color handler with groups — dot-prefixed keys
    color_logger.info("handled", .{ .request = .{ .method = "GET", .url = "/api" } });
}
