const std = @import("std");
const zlog = @import("zlog");
const runner = @import("runner.zig");
const helpers = @import("helpers.zig");

fn benchMaskFn(value: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    const at_pos = std.mem.indexOfScalar(u8, value, '@') orelse return null;
    if (at_pos == 0) return null;
    const domain = value[at_pos..];
    const result = allocator.alloc(u8, 1 + 3 + domain.len) catch return null;
    result[0] = value[0];
    @memcpy(result[1..4], "***");
    @memcpy(result[4..], domain);
    return result;
}

const iterations: u32 = 100_000;

pub fn runAll() void {
    runner.printHeader("Middleware Overhead");

    var json_h = zlog.JsonHandler.init(helpers.null_any_writer);
    const handler_iface = json_h.handler();
    const fields = .{ .user = "alice", .email = "alice@example.com", .password = "secret" };

    // No middleware baseline
    {
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = handler_iface, .allocator = std.heap.page_allocator }) catch @panic("init failed");
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
        runner.printResult(.{ .name = "no_middleware", .ops = iters, .elapsed_ns = elapsed });
    }

    // Redact - no match
    {
        var redactor = zlog.RedactMiddleware.init(&.{"api_key"});
        const middlewares = [_]zlog.Middleware{redactor.middleware()};
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
        runner.printResult(.{ .name = "redact_no_match", .ops = iters, .elapsed_ns = elapsed });
    }

    // Redact - match
    {
        var redactor = zlog.RedactMiddleware.init(&.{"password"});
        const middlewares = [_]zlog.Middleware{redactor.middleware()};
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
        runner.printResult(.{ .name = "redact_match", .ops = iters, .elapsed_ns = elapsed });
    }

    // Recursive redact with nested group fields
    {
        var redactor = zlog.RedactMiddleware.init(&.{"password"});
        const middlewares = [_]zlog.Middleware{redactor.middleware()};
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{
            .handler = handler_iface,
            .middlewares = &middlewares,
            .allocator = std.heap.page_allocator,
        }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        const nested_fields = .{
            .user = "alice",
            .auth = .{ .method = "oauth", .password = "secret" },
        };
        for (0..@min(1000, iters)) |_| {
            logger.info("warmup", nested_fields);
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.info("event", nested_fields);
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "recursive_redact", .ops = iters, .elapsed_ns = elapsed });
    }

    // Mask - match
    {
        var masker = zlog.MaskMiddleware.init("email", &benchMaskFn);
        const middlewares = [_]zlog.Middleware{masker.middleware()};
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
        runner.printResult(.{ .name = "mask_match", .ops = iters, .elapsed_ns = elapsed });
    }

    // Chain 2 - no match
    {
        var r1 = zlog.RedactMiddleware.init(&.{"api_key"});
        var r2 = zlog.RedactMiddleware.init(&.{"token"});
        const middlewares = [_]zlog.Middleware{ r1.middleware(), r2.middleware() };
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
        runner.printResult(.{ .name = "chain_2_no_match", .ops = iters, .elapsed_ns = elapsed });
    }

    // Chain 2 - both match
    {
        var redactor = zlog.RedactMiddleware.init(&.{"password"});
        var masker = zlog.MaskMiddleware.init("email", &benchMaskFn);
        const middlewares = [_]zlog.Middleware{ redactor.middleware(), masker.middleware() };
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
        runner.printResult(.{ .name = "chain_2_match", .ops = iters, .elapsed_ns = elapsed });
    }
}
