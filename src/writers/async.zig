const std = @import("std");
const FlushThunk = @import("../Handler.zig").FlushThunk;

const AsyncWriter = @This();

state: *State,

const State = struct {
    ring: []u8,
    read_pos: usize = 0,
    write_pos: usize = 0,
    count: usize = 0,
    shutdown: bool = false,
    flush_requested: bool = false,
    drop_if_full: bool,
    dropped_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    allocator: std.mem.Allocator,
    underlying: std.io.AnyWriter,
    mutex: std.Thread.Mutex = .{},
    not_empty: std.Thread.Condition = .{},
    not_full: std.Thread.Condition = .{},
    flush_done: std.Thread.Condition = .{},
    thread: std.Thread = undefined,
};

pub const Options = struct {
    queue_size: usize = 64 * 1024,
    /// When true, writes are silently dropped if the ring buffer is full instead
    /// of blocking the caller. Use this in high-traffic services where logging
    /// must never block the application. Check `droppedBytes()` for observability.
    drop_if_full: bool = false,
};

pub fn init(underlying: std.io.AnyWriter, allocator: std.mem.Allocator, options: Options) !AsyncWriter {
    const ring = try allocator.alloc(u8, options.queue_size);
    errdefer allocator.free(ring);

    const state = try allocator.create(State);
    errdefer allocator.destroy(state);

    state.* = .{
        .ring = ring,
        .allocator = allocator,
        .underlying = underlying,
        .drop_if_full = options.drop_if_full,
    };
    state.thread = try std.Thread.spawn(.{}, drainLoop, .{state});

    return .{ .state = state };
}

pub fn writer(self: *AsyncWriter) std.io.AnyWriter {
    return .{
        .context = @ptrCast(self.state),
        .writeFn = &writeFn,
    };
}

/// Returns the total number of bytes dropped due to a full ring buffer.
/// Only meaningful when `drop_if_full` is true.
pub fn droppedBytes(self: *AsyncWriter) u64 {
    return self.state.dropped_bytes.load(.monotonic);
}

/// Returns a `FlushThunk` for passing to a handler's `initWithFlush()`.
pub fn flushThunk(self: *AsyncWriter) FlushThunk {
    return .{
        .flush_fn = &struct {
            fn flush(ctx: *anyopaque) void {
                const aw: *AsyncWriter = @ptrCast(@alignCast(ctx));
                aw.flush();
            }
        }.flush,
        .flush_ctx = @ptrCast(self),
    };
}

pub fn flush(self: *AsyncWriter) void {
    const s = self.state;
    s.mutex.lock();
    defer s.mutex.unlock();

    if (s.count == 0) return;

    s.flush_requested = true;
    s.not_empty.signal();

    while (s.flush_requested) {
        s.flush_done.wait(&s.mutex);
    }
}

pub fn deinit(self: *AsyncWriter) void {
    const s = self.state;

    self.flush();

    s.mutex.lock();
    s.shutdown = true;
    s.not_empty.signal();
    s.mutex.unlock();

    s.thread.join();

    const allocator = s.allocator;
    allocator.free(s.ring);
    allocator.destroy(s);
    self.* = undefined;
}

/// AnyWriter.writeFn callback. The @constCast is safe because AnyWriter requires
/// a `*const anyopaque` context, but our State is always heap-allocated and mutable.
/// The round-trip is: `*State` → `@ptrCast(*const anyopaque)` in `writer()` →
/// `@constCast` → `*State` here.
fn writeFn(context: *const anyopaque, bytes: []const u8) anyerror!usize {
    const s: *State = @ptrCast(@alignCast(@constCast(context)));
    var remaining = bytes;

    s.mutex.lock();
    defer s.mutex.unlock();

    while (remaining.len > 0) {
        if (s.count == s.ring.len) {
            if (s.drop_if_full) {
                _ = s.dropped_bytes.fetchAdd(remaining.len, .monotonic);
                return bytes.len;
            }
            while (s.count == s.ring.len) {
                s.not_full.wait(&s.mutex);
            }
        }

        const space = s.ring.len - s.count;
        const to_write = @min(remaining.len, space);

        // Copy into ring, handling wrap-around
        const first = @min(to_write, s.ring.len - s.write_pos);
        @memcpy(s.ring[s.write_pos..][0..first], remaining[0..first]);
        if (to_write > first) {
            @memcpy(s.ring[0..to_write - first], remaining[first..to_write]);
        }

        s.write_pos = (s.write_pos + to_write) % s.ring.len;
        s.count += to_write;
        remaining = remaining[to_write..];

        s.not_empty.signal();
    }

    return bytes.len;
}

fn drainLoop(s: *State) void {
    var stack_buf: [4096]u8 = undefined;

    while (true) {
        var chunk_len: usize = 0;
        var should_signal_flush = false;

        {
            s.mutex.lock();
            defer s.mutex.unlock();

            while (s.count == 0 and !s.shutdown) {
                if (s.flush_requested) {
                    s.flush_requested = false;
                    s.flush_done.signal();
                }
                s.not_empty.wait(&s.mutex);
            }

            if (s.count == 0 and s.shutdown) {
                if (s.flush_requested) {
                    s.flush_requested = false;
                    s.flush_done.signal();
                }
                return;
            }

            chunk_len = @min(s.count, stack_buf.len);
            const read_from = s.read_pos;

            // Copy from ring into stack buffer, handling wrap-around
            const first = @min(chunk_len, s.ring.len - read_from);
            @memcpy(stack_buf[0..first], s.ring[read_from..][0..first]);
            if (chunk_len > first) {
                @memcpy(stack_buf[first..chunk_len], s.ring[0..chunk_len - first]);
            }

            s.read_pos = (s.read_pos + chunk_len) % s.ring.len;
            s.count -= chunk_len;
            s.not_full.signal();

            // Defer flush signal until after the write completes
            if (s.count == 0 and s.flush_requested) {
                should_signal_flush = true;
            }
        }

        // Write outside the lock
        s.underlying.writeAll(stack_buf[0..chunk_len]) catch return;

        // Signal flush completion after data is written to underlying
        if (should_signal_flush) {
            s.mutex.lock();
            s.flush_requested = false;
            s.flush_done.signal();
            s.mutex.unlock();
        }
    }
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const TestWriter = struct {
    buf: [65536]u8 = undefined,
    len: usize = 0,
    mutex: std.Thread.Mutex = .{},

    fn writer(self: *TestWriter) std.io.AnyWriter {
        return .{
            .context = @ptrCast(self),
            .writeFn = &testWriteFn,
        };
    }

    fn written(self: *TestWriter) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.buf[0..self.len];
    }

    fn testWriteFn(context: *const anyopaque, bytes: []const u8) anyerror!usize {
        const self: *TestWriter = @ptrCast(@alignCast(@constCast(context)));
        self.mutex.lock();
        defer self.mutex.unlock();
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
        return bytes.len;
    }
};

test "written bytes arrive after flush" {
    var dest: TestWriter = .{};

    var aw = try AsyncWriter.init(dest.writer(), testing.allocator, .{ .queue_size = 1024 });
    defer aw.deinit();

    const w = aw.writer();
    _ = try w.write("hello async");
    aw.flush();

    try testing.expectEqualStrings("hello async", dest.written());
}

test "multiple writes coalesce correctly" {
    var dest: TestWriter = .{};

    var aw = try AsyncWriter.init(dest.writer(), testing.allocator, .{ .queue_size = 1024 });
    defer aw.deinit();

    const w = aw.writer();
    _ = try w.write("one ");
    _ = try w.write("two ");
    _ = try w.write("three");
    aw.flush();

    try testing.expectEqualStrings("one two three", dest.written());
}

test "deinit drains remaining bytes" {
    var dest: TestWriter = .{};

    var aw = try AsyncWriter.init(dest.writer(), testing.allocator, .{ .queue_size = 1024 });

    const w = aw.writer();
    _ = try w.write("drained on deinit");
    aw.deinit();

    try testing.expectEqualStrings("drained on deinit", dest.written());
}

test "concurrent writers do not lose data" {
    var dest: TestWriter = .{};

    var aw = try AsyncWriter.init(dest.writer(), testing.allocator, .{ .queue_size = 64 * 1024 });
    defer aw.deinit();

    const thread_count = 4;
    const writes_per_thread = 100;
    const payload = "ABCDEFGHIJKLMNOP"; // 16 bytes

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn work(w: std.io.AnyWriter) void {
                for (0..writes_per_thread) |_| {
                    _ = w.write(payload) catch return;
                }
            }
        }.work, .{aw.writer()});
    }
    for (&threads) |*t| t.join();

    aw.flush();

    const expected_len = thread_count * writes_per_thread * payload.len;
    try testing.expectEqual(expected_len, dest.written().len);
}

test "drop_if_full drops data instead of blocking" {
    var dest: TestWriter = .{};

    // Tiny ring buffer (32 bytes) with drop_if_full enabled
    var aw = try AsyncWriter.init(dest.writer(), testing.allocator, .{
        .queue_size = 32,
        .drop_if_full = true,
    });
    defer aw.deinit();

    const w = aw.writer();

    // Fill the ring buffer completely
    _ = try w.write("a" ** 32);

    // This should not block — it should drop and return immediately
    _ = try w.write("should be dropped");

    try testing.expect(aw.droppedBytes() > 0);
}

test "drop_if_full reports correct dropped byte count" {
    var dest: TestWriter = .{};

    var aw = try AsyncWriter.init(dest.writer(), testing.allocator, .{
        .queue_size = 32,
        .drop_if_full = true,
    });
    defer aw.deinit();

    const w = aw.writer();
    _ = try w.write("a" ** 32); // fill ring

    const before = aw.droppedBytes();
    _ = try w.write("12345"); // 5 bytes dropped
    try testing.expectEqual(before + 5, aw.droppedBytes());
}
