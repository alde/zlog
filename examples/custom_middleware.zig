const std = @import("std");
const zlog = @import("zlog");

/// A custom middleware that overrides the record's timestamp with a fixed value.
/// Demonstrates record mutation without allocation.
const TimestampOverrideMiddleware = struct {
    fixed_ns: i128,

    fn init(fixed_ns: i128) TimestampOverrideMiddleware {
        return .{ .fixed_ns = fixed_ns };
    }

    fn middleware(self: *TimestampOverrideMiddleware) zlog.Middleware {
        return .{
            .ptr = self,
            .processFn = &process,
        };
    }

    fn process(ptr: *anyopaque, record: *zlog.Record, _: std.mem.Allocator) bool {
        const self: *TimestampOverrideMiddleware = @ptrCast(@alignCast(ptr));
        record.timestamp_ns = self.fixed_ns;
        return true;
    }
};

pub fn main() !void {
    const Rfc3339Text = zlog.TextHandler.Handler(.{ .timestamp = .rfc3339 });
    var text_handler = Rfc3339Text.init(zlog.stderr);

    // Custom middleware: pin all timestamps to a fixed value
    var ts_override = TimestampOverrideMiddleware.init(1_000_000_000); // 1 second

    // Compose with SimpleSamplingMiddleware: only 1 in 2 records pass through
    var sampler = zlog.SimpleSamplingMiddleware.init(2);

    const Log = zlog.Logger(.debug, .{});
    var logger = try Log.init(.{
        .handler = text_handler.handler(),
        .middlewares = &.{ ts_override.middleware(), sampler.middleware() },
        .allocator = std.heap.page_allocator,
    });
    defer logger.deinit();

    // Log several messages — timestamps are overridden and only every other record passes
    logger.info("first message", .{ .seq = 1 });
    logger.info("second message (sampled out)", .{ .seq = 2 });
    logger.info("third message", .{ .seq = 3 });
    logger.info("fourth message (sampled out)", .{ .seq = 4 });

    // ── Level-aware sampling ────────────────────────────────────────────
    // Sample debug/info at 1-in-3, but always pass warn/err.
    zlog.stderr.writeAll("\n--- Level-aware sampling: warn+ always pass, info sampled 1-in-3 ---\n") catch {};

    var level_sampler = zlog.LevelSamplingMiddleware.init(3, .warn);

    var level_logger = try Log.init(.{
        .handler = text_handler.handler(),
        .middlewares = &.{level_sampler.middleware()},
        .allocator = std.heap.page_allocator,
    });
    defer level_logger.deinit();

    level_logger.info("info 1 (passes)", .{});
    level_logger.info("info 2 (sampled out)", .{});
    level_logger.info("info 3 (sampled out)", .{});
    level_logger.info("info 4 (passes)", .{});
    level_logger.warn("warn always passes", .{});
    level_logger.err("error always passes", .{});
}
