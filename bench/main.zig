const std = @import("std");
const runner = @import("runner.zig");
const throughput = @import("throughput.zig");
const middleware_bench = @import("middleware.zig");
const latency = @import("latency.zig");
const allocations = @import("allocations.zig");
const concurrent = @import("concurrent.zig");
const child_logger = @import("child_logger.zig");
const writers_bench = @import("writers.zig");
const sampling = @import("sampling.zig");

pub fn main() void {
    const optimize = comptime if (std.debug.runtime_safety) "Debug" else "ReleaseFast";
    runner.stdout_writer.print("\nzlog benchmarks ({s})\n", .{optimize}) catch return;
    runner.stdout_writer.writeAll("============================================================\n") catch return;

    throughput.runAll();
    middleware_bench.runAll();
    latency.runAll();
    allocations.runAll();
    concurrent.runAll();
    child_logger.runAll();
    writers_bench.runAll();
    sampling.runAll();

    runner.stdout_writer.writeAll("\n") catch return;
}
