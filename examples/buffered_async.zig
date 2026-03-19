const std = @import("std");
const zlog = @import("zlog");

pub fn main() !void {
    const Log = zlog.Logger(.debug, .{});

    // ── Buffered with flush propagation ─────────────────────────────────
    // Use initWithFlush so logger.flush() propagates to the BufferedWriter.
    {
        var bw = try zlog.BufferedWriter.init(zlog.stderr, std.heap.page_allocator, .{});
        defer bw.deinit();

        var json_h = zlog.JsonHandler.initWithFlush(bw.writer(), bw.flushThunk());

        const logger = try Log.init(.{ .handler = json_h.handler(), .allocator = std.heap.page_allocator });
        defer logger.deinit();

        logger.info("buffered write", .{ .mode = "buffered", .buffer_size = @as(u64, 4096) });
        logger.info("second message", .{ .coalesced = true });

        // logger.flush() now propagates to bw.flush() automatically
        logger.flush();
    }

    // ── Async only ──────────────────────────────────────────────────────
    {
        var aw = try zlog.AsyncWriter.init(zlog.stderr, std.heap.page_allocator, .{});
        defer aw.deinit();

        var json_h = zlog.JsonHandler.init(aw.writer());
        const logger = try Log.init(.{ .handler = json_h.handler(), .allocator = std.heap.page_allocator });
        defer logger.deinit();

        logger.info("async write", .{ .mode = "async", .queue_size = @as(u64, 65536) });
        logger.info("non-blocking", .{ .background = true });

        aw.flush();
    }

    // ── Async with drop-on-full (high-traffic) ──────────────────────────
    // When the ring buffer fills up, writes are dropped instead of blocking.
    // Useful for k8s operators and other latency-sensitive services.
    {
        var aw = try zlog.AsyncWriter.init(zlog.stderr, std.heap.page_allocator, .{
            .drop_if_full = true,
        });
        defer aw.deinit();

        var json_h = zlog.JsonHandler.init(aw.writer());
        const logger = try Log.init(.{ .handler = json_h.handler(), .allocator = std.heap.page_allocator });
        defer logger.deinit();

        logger.info("never blocks", .{ .mode = "async+drop" });

        // Check how many bytes were dropped (for observability).
        // droppedBytes() returns a runtime value, so use withFields.
        const dropped = aw.droppedBytes();
        if (dropped > 0) {
            const fields = &[_]zlog.Field{zlog.Field.uint("dropped_bytes", dropped)};
            logger.withFields(fields).warn("bytes dropped", .{});
        }

        aw.flush();
    }

    // ── Composed: async feeds into buffered ─────────────────────────────
    {
        var bw = try zlog.BufferedWriter.init(zlog.stderr, std.heap.page_allocator, .{});
        defer bw.deinit();

        var aw = try zlog.AsyncWriter.init(bw.writer(), std.heap.page_allocator, .{});
        defer aw.deinit();

        var json_h = zlog.JsonHandler.init(aw.writer());
        const logger = try Log.init(.{ .handler = json_h.handler(), .allocator = std.heap.page_allocator });
        defer logger.deinit();

        logger.info("composed write", .{ .mode = "async+buffered" });
        logger.info("best of both worlds", .{ .batched = true, .non_blocking = true });

        aw.flush();
        try bw.flush();
    }
}
