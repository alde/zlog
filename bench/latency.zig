const std = @import("std");
const zlog = @import("zlog");
const runner = @import("runner.zig");
const helpers = @import("helpers.zig");

const sample_count: u32 = 10_000;

pub fn runAll() void {
    runner.printHeader("Latency Distribution");

    var json_h = zlog.JsonHandler.init(helpers.null_any_writer);
    const handler_iface = json_h.handler();
    const fields = .{ .user = "alice", .status = @as(i64, 200), .ok = true };
    const samples = runner.scaledIterations(sample_count);

    // JSON + 3 fields, no middleware
    {
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = handler_iface, .allocator = std.heap.page_allocator }) catch @panic("init failed");
        defer logger.deinit();
        var timings = std.heap.page_allocator.alloc(u64, samples) catch @panic("alloc failed");
        defer std.heap.page_allocator.free(timings);

        // Warmup
        for (0..@min(1000, samples)) |_| {
            logger.info("warmup", fields);
        }

        for (0..samples) |i| {
            var timer = std.time.Timer.start() catch @panic("timer unavailable");
            logger.info("benchmark message", fields);
            timings[i] = timer.read();
        }
        runner.printLatency("json_3_fields", timings);
    }

    // JSON + 3 fields, with redact middleware
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
        var timings = std.heap.page_allocator.alloc(u64, samples) catch @panic("alloc failed");
        defer std.heap.page_allocator.free(timings);

        for (0..@min(1000, samples)) |_| {
            logger.info("warmup", fields);
        }

        for (0..samples) |i| {
            var timer = std.time.Timer.start() catch @panic("timer unavailable");
            logger.info("benchmark message", fields);
            timings[i] = timer.read();
        }
        runner.printLatency("json_3_fields_with_redact", timings);
    }
}
