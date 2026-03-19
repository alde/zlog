const std = @import("std");
const zlog = @import("zlog");
const runner = @import("runner.zig");
const helpers = @import("helpers.zig");

const ops_per_thread: u32 = 50_000;
const scaled_ops = runner.scaledIterations(ops_per_thread);

pub fn runAll() void {
    runner.printHeader("Concurrent Throughput");

    var json_h = zlog.JsonHandler.init(helpers.null_any_writer);
    const handler_iface = json_h.handler();

    inline for (.{ 1, 2, 4, 8 }) |thread_count| {
        benchThreads("json_3_fields", handler_iface, thread_count);
    }
}

fn benchThreads(name: []const u8, handler_iface: zlog.Handler, comptime thread_count: u32) void {
    const Worker = struct {
        fn work(h: zlog.Handler) void {
            const Log = zlog.Logger(.debug, .{});
            const logger = Log.init(.{ .handler = h, .allocator = std.heap.page_allocator }) catch @panic("init failed");
            defer logger.deinit();
            for (0..scaled_ops) |_| {
                logger.info("concurrent message", .{ .user = "alice", .status = @as(i64, 200), .ok = true });
            }
        }
    };

    // Warmup
    Worker.work(handler_iface);

    var timer = std.time.Timer.start() catch @panic("timer unavailable");
    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = std.Thread.spawn(.{}, Worker.work, .{handler_iface}) catch @panic("spawn failed");
    }
    for (&threads) |*t| {
        t.join();
    }
    const elapsed = timer.read();

    const total_ops: u64 = @as(u64, thread_count) * scaled_ops;
    runner.printConcurrent(name, thread_count, total_ops, elapsed);
}
