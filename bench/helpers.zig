const std = @import("std");

// --- Null Writer ---
// Discards output but prevents dead-code elimination.

fn discardWriteFn(_: *const anyopaque, bytes: []const u8) anyerror!usize {
    std.mem.doNotOptimizeAway(bytes.ptr);
    return bytes.len;
}

pub const null_any_writer: std.io.AnyWriter = .{
    .context = undefined,
    .writeFn = &discardWriteFn,
};

// --- Counting Writer ---
// Tracks total bytes written.

pub const CountingWriter = struct {
    total_bytes: u64 = 0,

    pub fn writer(self: *CountingWriter) std.io.AnyWriter {
        return .{
            .context = @ptrCast(self),
            .writeFn = &writeFn,
        };
    }

    fn writeFn(context: *const anyopaque, bytes: []const u8) anyerror!usize {
        const self: *CountingWriter = @ptrCast(@alignCast(@constCast(context)));
        self.total_bytes += bytes.len;
        std.mem.doNotOptimizeAway(bytes.ptr);
        return bytes.len;
    }
};

// --- Counting Allocator ---
// Lightweight wrapper that counts allocs and total bytes.

pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    alloc_count: u64 = 0,
    free_count: u64 = 0,
    total_bytes: u64 = 0,

    pub fn init(backing: std.mem.Allocator) CountingAllocator {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn reset(self: *CountingAllocator) void {
        self.alloc_count = 0;
        self.free_count = 0;
        self.total_bytes = 0;
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = &allocFn,
        .resize = &resizeFn,
        .remap = &remapFn,
        .free = &freeFn,
    };

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, alignment, ret_addr);
        if (result != null) {
            self.alloc_count += 1;
            self.total_bytes += len;
        }
        return result;
    }

    fn resizeFn(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawResize(buf, alignment, new_len, ret_addr);
        if (result) {
            if (new_len > buf.len) {
                self.total_bytes += new_len - buf.len;
            }
        }
        return result;
    }

    fn remapFn(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(buf, alignment, new_len, ret_addr);
        if (result != null) {
            if (new_len > buf.len) {
                self.total_bytes += new_len - buf.len;
            }
        }
        return result;
    }

    fn freeFn(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.free_count += 1;
        self.backing.rawFree(buf, alignment, ret_addr);
    }
};
