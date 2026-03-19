const Record = @import("Record.zig");

/// A type-erased flush callback. Obtain one from `BufferedWriter.flushThunk()`
/// or `AsyncWriter.flushThunk()` and pass it to a handler's `initWithFlush()`.
pub const FlushThunk = struct {
    flush_fn: *const fn (*anyopaque) void,
    flush_ctx: *anyopaque,
};

const Handler = @This();

ptr: *anyopaque,
emitFn: *const fn (ptr: *anyopaque, record: *const Record) void,
/// Optional flush callback. Built-in handlers leave this null (they write to
/// AnyWriter which has no flush). Users wrapping BufferedWriter or AsyncWriter
/// in custom handlers can implement this to force pending data to the sink.
flushFn: ?*const fn (ptr: *anyopaque) void = null,

pub fn emit(self: Handler, record: *const Record) void {
    self.emitFn(self.ptr, record);
}

/// Flushes buffered output, if the handler implements flush. No-op otherwise.
pub fn flush(self: Handler) void {
    if (self.flushFn) |f| f(self.ptr);
}
