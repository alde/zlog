const std = @import("std");
const zlog = @import("zlog");
const runner = @import("runner.zig");
const helpers = @import("helpers.zig");

const iterations: u32 = 100_000;

pub fn runAll() void {
    runner.printHeader("Throughput");

    var json_h = zlog.JsonHandler.init(helpers.null_any_writer);
    var text_h = zlog.TextHandler.init(helpers.null_any_writer);
    var color_h = zlog.ColorHandler.init(helpers.null_any_writer);

    // JSON no fields
    {
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = json_h.handler(), .allocator = std.heap.page_allocator }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        for (0..@min(1000, iters)) |_| {
            logger.info("warmup", .{});
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.info("benchmark message", .{});
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "json_no_fields", .ops = iters, .elapsed_ns = elapsed });
    }

    // JSON 1 field
    {
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = json_h.handler(), .allocator = std.heap.page_allocator }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        for (0..@min(1000, iters)) |_| {
            logger.info("warmup", .{ .user = "alice" });
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.info("benchmark message", .{ .user = "alice" });
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "json_1_field", .ops = iters, .elapsed_ns = elapsed });
    }

    // JSON 5 fields (mixed types)
    {
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = json_h.handler(), .allocator = std.heap.page_allocator }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        const fields = .{ .user = "alice", .status = @as(i64, 200), .port = @as(u64, 8080), .latency = @as(f64, 1.23), .ok = true };
        for (0..@min(1000, iters)) |_| {
            logger.info("warmup", fields);
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.info("benchmark message", fields);
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "json_5_fields", .ops = iters, .elapsed_ns = elapsed });
    }

    // JSON 10 fields
    {
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = json_h.handler(), .allocator = std.heap.page_allocator }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        const fields = .{
            .field1 = "value1", .field2 = "value2", .field3 = "value3",
            .field4 = @as(i64, 100), .field5 = @as(u64, 200),
            .field6 = @as(f64, 3.14), .field7 = true, .field8 = "value8",
            .field9 = @as(i64, -42), .field10 = @as(u64, 999),
        };
        for (0..@min(1000, iters)) |_| {
            logger.info("warmup", fields);
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.info("benchmark message", fields);
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "json_10_fields", .ops = iters, .elapsed_ns = elapsed });
    }

    // Text no fields
    {
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = text_h.handler(), .allocator = std.heap.page_allocator }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        for (0..@min(1000, iters)) |_| {
            logger.info("warmup", .{});
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.info("benchmark message", .{});
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "text_no_fields", .ops = iters, .elapsed_ns = elapsed });
    }

    // Text 5 fields
    {
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = text_h.handler(), .allocator = std.heap.page_allocator }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        const fields = .{ .user = "alice", .status = @as(i64, 200), .port = @as(u64, 8080), .latency = @as(f64, 1.23), .ok = true };
        for (0..@min(1000, iters)) |_| {
            logger.info("warmup", fields);
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.info("benchmark message", fields);
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "text_5_fields", .ops = iters, .elapsed_ns = elapsed });
    }

    // Color no fields
    {
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = color_h.handler(), .allocator = std.heap.page_allocator }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        for (0..@min(1000, iters)) |_| {
            logger.info("warmup", .{});
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.info("benchmark message", .{});
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "color_no_fields", .ops = iters, .elapsed_ns = elapsed });
    }

    // Color 5 fields
    {
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = color_h.handler(), .allocator = std.heap.page_allocator }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        const fields = .{ .user = "alice", .status = @as(i64, 200), .port = @as(u64, 8080), .latency = @as(f64, 1.23), .ok = true };
        for (0..@min(1000, iters)) |_| {
            logger.info("warmup", fields);
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.info("benchmark message", fields);
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "color_5_fields", .ops = iters, .elapsed_ns = elapsed });
    }

    // JSON logf (fmt-style)
    {
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = json_h.handler(), .allocator = std.heap.page_allocator }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        for (0..@min(1000, iters)) |_| {
            logger.logf(.info, "request {s} took {d}ms", .{ "/api", 42 }, .{ .status = @as(i64, 200) });
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.logf(.info, "request {s} took {d}ms", .{ "/api", 42 }, .{ .status = @as(i64, 200) });
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "json_logf", .ops = iters, .elapsed_ns = elapsed });
    }

    // JSON with error field
    {
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = json_h.handler(), .allocator = std.heap.page_allocator }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        for (0..@min(1000, iters)) |_| {
            logger.info("warmup", .{ .err = error.OutOfMemory });
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.info("benchmark message", .{ .err = error.OutOfMemory });
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "json_error_field", .ops = iters, .elapsed_ns = elapsed });
    }

    // JSON with @src()
    {
        const Log = zlog.Logger(.debug, .{ .src = true });
        const logger = Log.init(.{ .handler = json_h.handler(), .allocator = std.heap.page_allocator }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        for (0..@min(1000, iters)) |_| {
            logger.info("warmup", .{}, @src());
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.info("benchmark message", .{}, @src());
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "json_with_src", .ops = iters, .elapsed_ns = elapsed });
    }

    // Text with @src()
    {
        const Log = zlog.Logger(.debug, .{ .src = true });
        const logger = Log.init(.{ .handler = text_h.handler(), .allocator = std.heap.page_allocator }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        for (0..@min(1000, iters)) |_| {
            logger.info("warmup", .{}, @src());
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.info("benchmark message", .{}, @src());
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "text_with_src", .ops = iters, .elapsed_ns = elapsed });
    }

    // JSON with @src() + fields
    {
        const Log = zlog.Logger(.debug, .{ .src = true });
        const logger = Log.init(.{ .handler = json_h.handler(), .allocator = std.heap.page_allocator }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        const fields = .{ .user = "alice", .err = error.AccessDenied };
        for (0..@min(1000, iters)) |_| {
            logger.info("warmup", fields, @src());
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.info("benchmark message", fields, @src());
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "json_src_and_fields", .ops = iters, .elapsed_ns = elapsed });
    }

    // Filtered out (comptime elimination)
    {
        const Log = zlog.Logger(.warn, .{});
        const logger = Log.init(.{ .handler = json_h.handler(), .allocator = std.heap.page_allocator }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        for (0..@min(1000, iters)) |_| {
            logger.debug("should be eliminated", .{});
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.debug("should be eliminated", .{ .user = "alice", .status = @as(i64, 200) });
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "filtered_out", .ops = iters, .elapsed_ns = elapsed });
    }

    // Runtime level filtering — allowed (level permits logging)
    {
        var lvl = zlog.AtomicLevel.init(.debug);
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = json_h.handler(), .allocator = std.heap.page_allocator, .level = &lvl }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        for (0..@min(1000, iters)) |_| {
            logger.info("warmup", .{});
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.info("benchmark message", .{ .user = "alice", .status = @as(i64, 200) });
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "runtime_level_allowed", .ops = iters, .elapsed_ns = elapsed });
    }

    // JSON with group field (nested struct)
    {
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = json_h.handler(), .allocator = std.heap.page_allocator }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        const fields = .{ .request = .{ .method = "GET", .url = "/api", .status = @as(i64, 200) } };
        for (0..@min(1000, iters)) |_| {
            logger.info("warmup", fields);
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.info("benchmark message", fields);
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "json_group_field", .ops = iters, .elapsed_ns = elapsed });
    }

    // JSON with withGroup logger
    {
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = json_h.handler(), .allocator = std.heap.page_allocator }) catch @panic("init failed");
        defer logger.deinit();
        const grouped = logger.withGroup("request");
        const iters = runner.scaledIterations(iterations);
        for (0..@min(1000, iters)) |_| {
            grouped.info("warmup", .{ .method = "GET" });
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            grouped.info("benchmark message", .{ .method = "GET", .url = "/api" });
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "json_with_group", .ops = iters, .elapsed_ns = elapsed });
    }

    // Runtime level filtering — blocked (level rejects logging)
    {
        var lvl = zlog.AtomicLevel.init(.warn);
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = json_h.handler(), .allocator = std.heap.page_allocator, .level = &lvl }) catch @panic("init failed");
        defer logger.deinit();
        const iters = runner.scaledIterations(iterations);
        for (0..@min(1000, iters)) |_| {
            logger.debug("should be filtered", .{});
        }
        var timer = std.time.Timer.start() catch @panic("timer unavailable");
        for (0..iters) |_| {
            logger.debug("should be filtered", .{ .user = "alice", .status = @as(i64, 200) });
        }
        const elapsed = timer.read();
        runner.printResult(.{ .name = "runtime_level_blocked", .ops = iters, .elapsed_ns = elapsed });
    }
}
