const std = @import("std");
const zlog = @import("zlog");
const runner = @import("runner.zig");
const helpers = @import("helpers.zig");

const iterations: u32 = 100_000;

pub fn runAll() void {
    runner.printHeader("Sampling");

    var json_h = zlog.JsonHandler.init(helpers.null_any_writer);
    const handler_iface = json_h.handler();
    const fields = .{ .user = "alice", .action = "login" };

    // Rate 1 — passthrough baseline
    {
        var sampler = zlog.SimpleSamplingMiddleware.init(1);
        const middlewares = [_]zlog.Middleware{sampler.middleware()};
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{
            .handler = handler_iface,
            .middlewares = &middlewares,
            .allocator = std.heap.page_allocator,
        }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        for (0..@min(1000, iters)) |_| {
            logger.info("warmup", fields);
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.info("event", fields);
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "sample_rate_1", .ops = iters, .elapsed_ns = elapsed });
    }

    // Rate 10 — 90% dropped
    {
        var sampler = zlog.SimpleSamplingMiddleware.init(10);
        const middlewares = [_]zlog.Middleware{sampler.middleware()};
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{
            .handler = handler_iface,
            .middlewares = &middlewares,
            .allocator = std.heap.page_allocator,
        }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        for (0..@min(1000, iters)) |_| {
            logger.info("warmup", fields);
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.info("event", fields);
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "sample_rate_10", .ops = iters, .elapsed_ns = elapsed });
    }

    // Rate 100 — 99% dropped
    {
        var sampler = zlog.SimpleSamplingMiddleware.init(100);
        const middlewares = [_]zlog.Middleware{sampler.middleware()};
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{
            .handler = handler_iface,
            .middlewares = &middlewares,
            .allocator = std.heap.page_allocator,
        }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        for (0..@min(1000, iters)) |_| {
            logger.info("warmup", fields);
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.info("event", fields);
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "sample_rate_100", .ops = iters, .elapsed_ns = elapsed });
    }

    // Rate 1000 — 99.9% dropped
    {
        var sampler = zlog.SimpleSamplingMiddleware.init(1000);
        const middlewares = [_]zlog.Middleware{sampler.middleware()};
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{
            .handler = handler_iface,
            .middlewares = &middlewares,
            .allocator = std.heap.page_allocator,
        }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        for (0..@min(1000, iters)) |_| {
            logger.info("warmup", fields);
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.info("event", fields);
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "sample_rate_1000", .ops = iters, .elapsed_ns = elapsed });
    }

    // Level-aware: rate 100, info sampled, warn+ always passes
    {
        var sampler = zlog.LevelSamplingMiddleware.init(100, .warn);
        const middlewares = [_]zlog.Middleware{sampler.middleware()};
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{
            .handler = handler_iface,
            .middlewares = &middlewares,
            .allocator = std.heap.page_allocator,
        }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        for (0..@min(1000, iters)) |_| {
            logger.info("warmup", fields);
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.info("event", fields);
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "level_sample_info", .ops = iters, .elapsed_ns = elapsed });
    }

    // Level-aware: warn always passes (measures the bypass path)
    {
        var sampler = zlog.LevelSamplingMiddleware.init(100, .warn);
        const middlewares = [_]zlog.Middleware{sampler.middleware()};
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{
            .handler = handler_iface,
            .middlewares = &middlewares,
            .allocator = std.heap.page_allocator,
        }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        for (0..@min(1000, iters)) |_| {
            logger.warn("warmup", fields);
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.warn("event", fields);
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "level_sample_warn_pass", .ops = iters, .elapsed_ns = elapsed });
    }
}
