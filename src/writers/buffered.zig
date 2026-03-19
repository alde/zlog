const std = @import("std");
const FlushThunk = @import("../Handler.zig").FlushThunk;

const BufferedWriter = @This();

buf: []u8,
pos: usize = 0,
underlying: std.io.AnyWriter,
allocator: std.mem.Allocator,
mutex: std.Thread.Mutex = .{},

pub const Options = struct {
    buffer_size: usize = 4096,
};

pub fn init(underlying: std.io.AnyWriter, allocator: std.mem.Allocator, options: Options) !BufferedWriter {
    const buf = try allocator.alloc(u8, options.buffer_size);
    return .{
        .buf = buf,
        .underlying = underlying,
        .allocator = allocator,
    };
}

pub fn writer(self: *BufferedWriter) std.io.AnyWriter {
    return .{
        .context = @ptrCast(self),
        .writeFn = &writeFn,
    };
}

/// Returns a `FlushThunk` for passing to a handler's `initWithFlush()`.
/// The thunk calls `flush()` and swallows errors (matching current manual boilerplate).
pub fn flushThunk(self: *BufferedWriter) FlushThunk {
    return .{
        .flush_fn = &struct {
            fn flush(ctx: *anyopaque) void {
                const bw: *BufferedWriter = @ptrCast(@alignCast(ctx));
                bw.flush() catch {};
            }
        }.flush,
        .flush_ctx = @ptrCast(self),
    };
}

pub fn flush(self: *BufferedWriter) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.flushLocked();
}

fn flushLocked(self: *BufferedWriter) !void {
    if (self.pos == 0) return;
    try self.underlying.writeAll(self.buf[0..self.pos]);
    self.pos = 0;
}

pub fn deinit(self: *BufferedWriter) void {
    self.mutex.lock();
    self.flushLocked() catch {};
    self.allocator.free(self.buf);
    self.mutex.unlock();
    self.* = undefined;
}

/// AnyWriter.writeFn callback. The @constCast is safe because AnyWriter requires
/// a `*const anyopaque` context, but BufferedWriter is always mutable.
/// The round-trip is: `*BufferedWriter` → `@ptrCast(*const anyopaque)` in `writer()` →
/// `@constCast` → `*BufferedWriter` here.
fn writeFn(context: *const anyopaque, bytes: []const u8) anyerror!usize {
    const self: *BufferedWriter = @ptrCast(@alignCast(@constCast(context)));

    self.mutex.lock();
    defer self.mutex.unlock();

    var remaining = bytes;

    while (remaining.len > 0) {
        const space = self.buf.len - self.pos;

        if (remaining.len <= space) {
            @memcpy(self.buf[self.pos..][0..remaining.len], remaining);
            self.pos += remaining.len;
            return bytes.len;
        }

        @memcpy(self.buf[self.pos..][0..space], remaining[0..space]);
        self.pos = self.buf.len;
        self.flushLocked() catch |e| return e;
        remaining = remaining[space..];
    }

    return bytes.len;
}


// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const TestWriter = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,
    write_count: usize = 0,

    fn writer(self: *TestWriter) std.io.AnyWriter {
        return .{
            .context = @ptrCast(self),
            .writeFn = &testWriteFn,
        };
    }

    fn written(self: *const TestWriter) []const u8 {
        return self.buf[0..self.len];
    }

    fn testWriteFn(context: *const anyopaque, bytes: []const u8) anyerror!usize {
        const self: *TestWriter = @ptrCast(@alignCast(@constCast(context)));
        self.write_count += 1;
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
        return bytes.len;
    }
};

test "small writes accumulate without reaching underlying" {
    var dest: TestWriter = .{};

    var bw = try BufferedWriter.init(dest.writer(), testing.allocator, .{ .buffer_size = 64 });
    defer bw.deinit();

    const w = bw.writer();
    _ = try w.write("hello");
    _ = try w.write(" world");

    try testing.expectEqual(0, dest.write_count);
    try testing.expectEqual(0, dest.len);
}

test "buffer full triggers flush to underlying" {
    var dest: TestWriter = .{};

    var bw = try BufferedWriter.init(dest.writer(), testing.allocator, .{ .buffer_size = 8 });
    defer bw.deinit();

    const w = bw.writer();
    _ = try w.write("12345678"); // exactly fills buffer
    _ = try w.write("9"); // triggers flush of first 8, then buffers "9"

    try testing.expect(dest.write_count > 0);
    try testing.expectEqualStrings("12345678", dest.written());
}

test "write larger than buffer flushes correctly" {
    var dest: TestWriter = .{};

    var bw = try BufferedWriter.init(dest.writer(), testing.allocator, .{ .buffer_size = 4 });
    defer bw.deinit();

    const w = bw.writer();
    _ = try w.write("abcdefghij"); // 10 bytes, buffer is 4

    // Should have flushed at least twice (4 + 4), with 2 remaining in buffer
    try bw.flush();
    try testing.expectEqualStrings("abcdefghij", dest.written());
}

test "explicit flush pushes buffered data" {
    var dest: TestWriter = .{};

    var bw = try BufferedWriter.init(dest.writer(), testing.allocator, .{ .buffer_size = 64 });
    defer bw.deinit();

    const w = bw.writer();
    _ = try w.write("pending");
    try testing.expectEqual(0, dest.len);

    try bw.flush();
    try testing.expectEqualStrings("pending", dest.written());
}

test "deinit flushes pending data" {
    var dest: TestWriter = .{};

    var bw = try BufferedWriter.init(dest.writer(), testing.allocator, .{ .buffer_size = 64 });

    const w = bw.writer();
    _ = try w.write("pending");
    try testing.expectEqual(0, dest.len);

    bw.deinit(); // should flush before freeing
    try testing.expectEqualStrings("pending", dest.written());
}

test "multiple small writes coalesce into fewer underlying writes" {
    var dest: TestWriter = .{};

    var bw = try BufferedWriter.init(dest.writer(), testing.allocator, .{ .buffer_size = 64 });
    defer bw.deinit();

    const w = bw.writer();
    for (0..10) |_| {
        _ = try w.write("data");
    }
    try bw.flush();

    // 10 small writes should coalesce into a single underlying write
    try testing.expectEqual(1, dest.write_count);
    try testing.expectEqual(40, dest.len);
}
