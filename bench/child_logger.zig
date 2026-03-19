const std = @import("std");
const zlog = @import("zlog");
const runner = @import("runner.zig");
const helpers = @import("helpers.zig");

const iterations: u32 = 100_000;

pub fn runAll() void {
    runner.printHeader("Child Logger");

    var json_h = zlog.JsonHandler.init(helpers.null_any_writer);
    const handler_iface = json_h.handler();

    // Cost of with() creation
    {
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = handler_iface, .allocator = std.heap.page_allocator }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);

        for (0..@min(1000, iters)) |_| {
            _ = logger.with(.{ .request_id = "abc-123" });
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            _ = logger.with(.{ .request_id = "abc-123" });
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "with_creation", .ops = iters, .elapsed_ns = elapsed });
    }

    // Cost of withFields() creation
    {
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = handler_iface, .allocator = std.heap.page_allocator }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);

        const fields = &[_]zlog.Field{
            zlog.Field.string("request_id", "abc-123"),
            zlog.Field.int("attempt", 1),
        };

        for (0..@min(1000, iters)) |_| {
            _ = logger.withFields(fields);
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            _ = logger.withFields(fields);
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "withFields_creation", .ops = iters, .elapsed_ns = elapsed });
    }

    // Logging through child vs root
    {
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = handler_iface, .allocator = std.heap.page_allocator }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);

        // Root logger
        for (0..@min(1000, iters)) |_| {
            logger.info("warmup", .{ .status = @as(i64, 200) });
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.info("benchmark message", .{ .status = @as(i64, 200) });
        }
        var elapsed = timer.read();
        runner.printResult(.{ .name = "root_logger_log", .ops = iters, .elapsed_ns = elapsed });

        // Child logger (has base fields, so merge happens per-call)
        const child = logger.with(.{ .request_id = "abc-123", .service = "bench" });
        for (0..@min(1000, iters)) |_| {
            child.info("warmup", .{ .status = @as(i64, 200) });
        }
        timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            child.info("benchmark message", .{ .status = @as(i64, 200) });
        }
        elapsed = timer.read();
        runner.printResult(.{ .name = "child_logger_log", .ops = iters, .elapsed_ns = elapsed });

        // withFields child logger
        const fields = &[_]zlog.Field{
            zlog.Field.string("request_id", "abc-123"),
            zlog.Field.string("service", "bench"),
        };
        const wf_child = logger.withFields(fields);
        for (0..@min(1000, iters)) |_| {
            wf_child.info("warmup", .{ .status = @as(i64, 200) });
        }
        timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            wf_child.info("benchmark message", .{ .status = @as(i64, 200) });
        }
        elapsed = timer.read();
        runner.printResult(.{ .name = "withFields_log", .ops = iters, .elapsed_ns = elapsed });
    }
}
