const std = @import("std");
const zlog = @import("zlog");
const runner = @import("runner.zig");
const helpers = @import("helpers.zig");

const iterations: u32 = 100_000;
const fields = .{ .user = "alice", .status = @as(i64, 200), .port = @as(u64, 8080), .latency = @as(f64, 1.23), .ok = true };

pub fn runAll() void {
    runner.printHeader("Writers");

    jsonBuffered();
    jsonAsync();
    jsonAsyncBuffered();
    jsonAsyncConcurrent();
}

fn jsonBuffered() void {
    var bw = zlog.BufferedWriter.init(helpers.null_any_writer, std.heap.page_allocator, .{}) catch @panic("BufferedWriter init failed");
    defer bw.deinit();

    var json_h = zlog.JsonHandler.init(bw.writer());
    const Log = zlog.Logger(.debug, .{});
    const logger = Log.init(.{ .handler = json_h.handler(), .allocator = std.heap.page_allocator }) catch @panic("init failed");
    defer logger.deinit();

    const iters = runner.scaledIterations(iterations);
    for (0..@min(1000, iters)) |_| {
        logger.info("warmup", fields);
    }
    bw.flush() catch {};

    var timer = std.time.Timer.start() catch @panic("timer unavailable");
    for (0..iters) |_| {
        logger.info("benchmark message", fields);
    }
    bw.flush() catch {};
    const elapsed = timer.read();
    runner.printResult(.{ .name = "json_buffered", .ops = iters, .elapsed_ns = elapsed });
}

fn jsonAsync() void {
    var aw = zlog.AsyncWriter.init(helpers.null_any_writer, std.heap.page_allocator, .{}) catch @panic("AsyncWriter init failed");
    defer aw.deinit();

    var json_h = zlog.JsonHandler.init(aw.writer());
    const Log = zlog.Logger(.debug, .{});
    const logger = Log.init(.{ .handler = json_h.handler(), .allocator = std.heap.page_allocator }) catch @panic("init failed");
    defer logger.deinit();

    const iters = runner.scaledIterations(iterations);
    for (0..@min(1000, iters)) |_| {
        logger.info("warmup", fields);
    }
    aw.flush();

    var timer = std.time.Timer.start() catch @panic("timer unavailable");
    for (0..iters) |_| {
        logger.info("benchmark message", fields);
    }
    aw.flush();
    const elapsed = timer.read();
    runner.printResult(.{ .name = "json_async", .ops = iters, .elapsed_ns = elapsed });
}

fn jsonAsyncBuffered() void {
    var bw = zlog.BufferedWriter.init(helpers.null_any_writer, std.heap.page_allocator, .{}) catch @panic("BufferedWriter init failed");
    defer bw.deinit();

    var aw = zlog.AsyncWriter.init(bw.writer(), std.heap.page_allocator, .{}) catch @panic("AsyncWriter init failed");
    defer aw.deinit();

    var json_h = zlog.JsonHandler.init(aw.writer());
    const Log = zlog.Logger(.debug, .{});
    const logger = Log.init(.{ .handler = json_h.handler(), .allocator = std.heap.page_allocator }) catch @panic("init failed");
    defer logger.deinit();

    const iters = runner.scaledIterations(iterations);
    for (0..@min(1000, iters)) |_| {
        logger.info("warmup", fields);
    }
    aw.flush();
    bw.flush() catch {};

    var timer = std.time.Timer.start() catch @panic("timer unavailable");
    for (0..iters) |_| {
        logger.info("benchmark message", fields);
    }
    aw.flush();
    bw.flush() catch {};
    const elapsed = timer.read();
    runner.printResult(.{ .name = "json_async_buffered", .ops = iters, .elapsed_ns = elapsed });
}

const concurrent_ops = runner.scaledIterations(50_000);

fn jsonAsyncConcurrent() void {
    var aw = zlog.AsyncWriter.init(helpers.null_any_writer, std.heap.page_allocator, .{}) catch @panic("AsyncWriter init failed");
    defer aw.deinit();

    var json_h = zlog.JsonHandler.init(aw.writer());
    const handler_iface = json_h.handler();

    inline for (.{ 1, 2, 4, 8 }) |thread_count| {
        const Worker = struct {
            fn work(h: zlog.Handler) void {
                const Log = zlog.Logger(.debug, .{});
                const logger = Log.init(.{ .handler = h, .allocator = std.heap.page_allocator }) catch @panic("init failed");
                defer logger.deinit();
                for (0..concurrent_ops) |_| {
                    logger.info("concurrent message", fields);
                }
            }
        };

        // Warmup
        Worker.work(handler_iface);
        aw.flush();

        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        var threads: [thread_count]std.Thread = undefined;
        for (&threads) |*t| {
            t.* = std.Thread.spawn(.{}, Worker.work, .{handler_iface}) catch @panic("spawn failed");
        }
        for (&threads) |*t| t.join();
        aw.flush();
        const elapsed = timer.read();

        const total_ops: u64 = @as(u64, thread_count) * concurrent_ops;
        runner.printConcurrent("json_async", thread_count, total_ops, elapsed);
    }
}
