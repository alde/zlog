const std = @import("std");

pub const BenchResult = struct {
    name: []const u8,
    ops: u64,
    elapsed_ns: u64,
    allocs_per_op: ?f64 = null,
    bytes_per_op: ?f64 = null,
};

const warmup_iterations: u32 = 1000;

pub fn scaledIterations(iterations: u32) u32 {
    return switch (comptime std.debug.runtime_safety) {
        true => @max(iterations / 100, 1),
        false => iterations,
    };
}

// --- Stdout writer ---

fn stdoutWriteFn(_: *const anyopaque, bytes: []const u8) anyerror!usize {
    return std.posix.write(std.posix.STDOUT_FILENO, bytes);
}

pub const stdout_writer: std.io.AnyWriter = .{
    .context = undefined,
    .writeFn = &stdoutWriteFn,
};

// --- Printing ---

pub fn printHeader(group_name: []const u8) void {
    stdout_writer.print("\n{s}\n", .{group_name}) catch return;
}

pub fn printResult(r: BenchResult) void {
    // Allocation-only results (no timing)
    if (r.elapsed_ns == 0 and r.allocs_per_op != null) {
        stdout_writer.print("  {s:<40}", .{r.name}) catch return;
        if (r.allocs_per_op) |a| {
            stdout_writer.print("  {d:>6.1} allocs/op", .{a}) catch return;
        }
        if (r.bytes_per_op) |b| {
            stdout_writer.print("  {d:>8.1} bytes/op", .{b}) catch return;
        }
        stdout_writer.writeByte('\n') catch return;
        return;
    }

    const elapsed_f: f64 = @floatFromInt(r.elapsed_ns);
    const ops_f: f64 = @floatFromInt(r.ops);
    const ns_per_op = if (r.ops > 0) elapsed_f / ops_f else 0.0;

    // Sub-nanosecond means the operation was eliminated at comptime; only loop overhead remains.
    if (ns_per_op < 1.0) {
        stdout_writer.print("  {s:<40}      (sub-nanosecond, loop overhead)\n", .{r.name}) catch return;
        return;
    }

    const ops_per_sec: u64 = @intFromFloat(ops_f * 1_000_000_000.0 / elapsed_f);

    stdout_writer.print("  {s:<40} {d:>12} ops/s  {d:>8.1} ns/op", .{
        r.name,
        ops_per_sec,
        ns_per_op,
    }) catch return;

    if (r.allocs_per_op) |a| {
        stdout_writer.print("  {d:>6.1} allocs/op", .{a}) catch return;
    }
    if (r.bytes_per_op) |b| {
        stdout_writer.print("  {d:>8.1} bytes/op", .{b}) catch return;
    }
    stdout_writer.writeByte('\n') catch return;
}

pub fn printLatency(name: []const u8, samples: []u64) void {
    if (samples.len == 0) return;

    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const n = samples.len;

    stdout_writer.print("  {s:<40} p50={d}ns  p95={d}ns  p99={d}ns  p99.9={d}ns  min={d}ns  max={d}ns\n", .{
        name,
        samples[n / 2],
        samples[n * 95 / 100],
        samples[n * 99 / 100],
        samples[n * 999 / 1000],
        samples[0],
        samples[n - 1],
    }) catch return;
}

pub fn printConcurrent(name: []const u8, threads: u32, total_ops: u64, elapsed_ns: u64) void {
    const ops_per_sec = if (elapsed_ns > 0) total_ops * 1_000_000_000 / elapsed_ns else 0;

    stdout_writer.print("  {s:<32} {d:>2} threads  {d:>12} ops/s\n", .{
        name,
        threads,
        ops_per_sec,
    }) catch return;
}
