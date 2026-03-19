const std = @import("std");
const zlog = @import("zlog");
const runner = @import("runner.zig");
const helpers = @import("helpers.zig");

const iterations: u32 = 1_000;

pub fn runAll() void {
    runner.printHeader("Allocations");

    var json_h = zlog.JsonHandler.init(helpers.null_any_writer);
    const handler_iface = json_h.handler();

    // No fields, no middleware
    {
        var counting = helpers.CountingAllocator.init(std.heap.page_allocator);
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = handler_iface, .allocator = counting.allocator() }) catch @panic("init failed");
        defer logger.deinit();
        counting.reset(); // reset after init allocation
        const iters = runner.scaledIterations(iterations);
        for (0..iters) |_| {
            logger.info("message", .{});
        }
        printAllocResult("no_fields_no_mw", iters, &counting);
    }

    // 3 fields, no base fields (no merge)
    {
        var counting = helpers.CountingAllocator.init(std.heap.page_allocator);
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = handler_iface, .allocator = counting.allocator() }) catch @panic("init failed");
        defer logger.deinit();
        counting.reset();
        const iters = runner.scaledIterations(iterations);
        for (0..iters) |_| {
            logger.info("message", .{ .user = "alice", .status = @as(i64, 200), .ok = true });
        }
        printAllocResult("3_fields_no_base", iters, &counting);
    }

    // 3 fields + base fields (merge required)
    {
        var counting = helpers.CountingAllocator.init(std.heap.page_allocator);
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = handler_iface, .allocator = counting.allocator() }) catch @panic("init failed");
        defer logger.deinit();
        const child = logger.with(.{ .request_id = "abc-123" });
        // Reset after with() allocation so we only measure per-call allocs
        counting.reset();
        const iters = runner.scaledIterations(iterations);
        for (0..iters) |_| {
            child.info("message", .{ .user = "alice", .status = @as(i64, 200) });
        }
        printAllocResult("merge_fields", iters, &counting);
    }

    // Middleware no match
    {
        var counting = helpers.CountingAllocator.init(std.heap.page_allocator);
        var redactor = zlog.RedactMiddleware.init(&.{"api_key"});
        const middlewares = [_]zlog.Middleware{redactor.middleware()};
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{
            .handler = handler_iface,
            .middlewares = &middlewares,
            .allocator = counting.allocator(),
        }) catch @panic("init failed");
        defer logger.deinit();
        counting.reset();
        const iters = runner.scaledIterations(iterations);
        for (0..iters) |_| {
            logger.info("message", .{ .user = "alice" });
        }
        printAllocResult("mw_no_match", iters, &counting);
    }

    // Middleware match
    {
        var counting = helpers.CountingAllocator.init(std.heap.page_allocator);
        var redactor = zlog.RedactMiddleware.init(&.{"password"});
        const middlewares = [_]zlog.Middleware{redactor.middleware()};
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{
            .handler = handler_iface,
            .middlewares = &middlewares,
            .allocator = counting.allocator(),
        }) catch @panic("init failed");
        defer logger.deinit();
        counting.reset();
        const iters = runner.scaledIterations(iterations);
        for (0..iters) |_| {
            logger.info("message", .{ .password = "secret" });
        }
        printAllocResult("mw_match", iters, &counting);
    }

    // with() call cost
    {
        var counting = helpers.CountingAllocator.init(std.heap.page_allocator);
        const Log = zlog.Logger(.debug, .{});
        const logger = Log.init(.{ .handler = handler_iface, .allocator = counting.allocator() }) catch @panic("init failed");
        defer logger.deinit();
        counting.reset();
        const iters = runner.scaledIterations(iterations);
        for (0..iters) |_| {
            _ = logger.with(.{ .request_id = "abc-123" });
        }
        printAllocResult("with_call", iters, &counting);
    }
}

fn printAllocResult(name: []const u8, iters: u32, counting: *helpers.CountingAllocator) void {
    const ops: f64 = @floatFromInt(iters);
    const allocs: f64 = @floatFromInt(counting.alloc_count);
    const bytes: f64 = @floatFromInt(counting.total_bytes);
    runner.printResult(.{
        .name = name,
        .ops = iters,
        .elapsed_ns = 0,
        .allocs_per_op = allocs / ops,
        .bytes_per_op = bytes / ops,
    });
}
