const std = @import("std");
const Record = @import("Record.zig");

/// Type-erased middleware interface for processing log records before they
/// reach the handler. Middleware can mutate fields (e.g. redaction, masking)
/// or drop records entirely by returning false.
///
/// Built-in middleware (redact, mask) recurses into group values by default.
/// Use `initWithConfig()` with `.recursive = false` to opt out.
const Middleware = @This();

ptr: *anyopaque,
processFn: *const fn (ptr: *anyopaque, record: *Record, allocator: std.mem.Allocator) bool,

pub fn process(self: Middleware, record: *Record, allocator: std.mem.Allocator) bool {
    return self.processFn(self.ptr, record, allocator);
}
