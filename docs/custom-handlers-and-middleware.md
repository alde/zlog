# Custom Handlers and Middleware

zlog's handler and middleware interfaces are each a pointer and a function pointer. No vtables, no traits, no generics required. This doc explains how to implement your own.

## Custom Handler

A handler receives a finalized `Record` and writes it somewhere. The interface is:

```zig
const Handler = struct {
    ptr: *anyopaque,
    emitFn: *const fn (ptr: *anyopaque, record: *const Record) void,
    flushFn: ?*const fn (ptr: *anyopaque) void = null,
};
```

### Minimal Example

A handler that writes one JSON field per line (for, say, a line-oriented log shipper):

```zig
const std = @import("std");
const zlog = @import("zlog");

const LineHandler = struct {
    writer: std.io.AnyWriter,
    mutex: std.Thread.Mutex = .{},

    fn init(writer: std.io.AnyWriter) LineHandler {
        return .{ .writer = writer };
    }

    fn handler(self: *LineHandler) zlog.Handler {
        return .{
            .ptr = self,
            .emitFn = &emit,
        };
    }

    fn emit(ptr: *anyopaque, record: *const zlog.Record) void {
        const self: *LineHandler = @ptrCast(@alignCast(ptr));

        // Format into a stack buffer before taking the lock.
        // This keeps the critical section short.
        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        formatRecord(fbs.writer().any(), record) catch return;

        self.mutex.lock();
        defer self.mutex.unlock();
        self.writer.writeAll(fbs.getWritten()) catch return;
    }

    fn formatRecord(w: std.io.AnyWriter, record: *const zlog.Record) !void {
        try w.print("[{s}] {s}", .{ record.level.asText(), record.message });
        for (record.fields) |f| {
            try w.writeByte(' ');
            try w.writeAll(f.key);
            try w.writeByte('=');
            try f.value.formatText(w);
        }
        try w.writeByte('\n');
    }
};
```

### Key Points

- *Type erasure*: `emitFn` receives `*anyopaque`. Cast it back to your concrete type with `@ptrCast(@alignCast(ptr))`.
- *Thread safety*: multiple threads may call `emit` concurrently. Use a mutex. The built-in handlers format into a stack buffer first, then lock only for the final `writeAll`. This minimizes contention.
- *Errors*: `emit` returns `void`. Handle write errors internally (log to stderr, increment a counter, drop silently). The caller has no way to retry.
- *Flush*: if your handler buffers output, implement `flushFn` so `logger.flush()` works. See below.

### Flush Support

If your handler wraps a `BufferedWriter` or `AsyncWriter`, wire up flush:

```zig
fn init(writer: std.io.AnyWriter, flush_thunk: zlog.FlushThunk) LineHandler {
    return .{
        .writer = writer,
        .flush_fn = flush_thunk.flush_fn,
        .flush_ctx = flush_thunk.flush_ctx,
    };
}

fn handler(self: *LineHandler) zlog.Handler {
    return .{
        .ptr = self,
        .emitFn = &emit,
        .flushFn = if (self.flush_fn != null) &flushThunk else null,
    };
}

fn flushThunk(ptr: *anyopaque) void {
    const self: *LineHandler = @ptrCast(@alignCast(ptr));
    if (self.flush_fn) |f| f(self.flush_ctx.?);
}
```

### Split Handler (routing by level)

A handler can delegate to other handlers:

```zig
const SplitHandler = struct {
    normal: zlog.Handler,
    error_handler: zlog.Handler,

    fn handler(self: *SplitHandler) zlog.Handler {
        return .{ .ptr = self, .emitFn = &emit };
    }

    fn emit(ptr: *anyopaque, record: *const zlog.Record) void {
        const self: *SplitHandler = @ptrCast(@alignCast(ptr));
        if (@intFromEnum(record.level) >= @intFromEnum(zlog.Level.warn)) {
            self.error_handler.emit(record);
        } else {
            self.normal.emit(record);
        }
    }
};
```

This sends warn/err to one destination and debug/info to another. Each inner handler has its own mutex, so there's no extra contention.

## Custom Middleware

Middleware inspects or mutates a `Record` before it reaches the handler. The interface is:

```zig
const Middleware = struct {
    ptr: *anyopaque,
    processFn: *const fn (ptr: *anyopaque, record: *Record, allocator: std.mem.Allocator) bool,
};
```

Return `true` to pass the record through, `false` to drop it.

### Minimal Example: Add a Field

A middleware that stamps every record with a `hostname` field:

```zig
const HostnameMiddleware = struct {
    hostname: []const u8,

    fn init(hostname: []const u8) HostnameMiddleware {
        return .{ .hostname = hostname };
    }

    fn middleware(self: *HostnameMiddleware) zlog.Middleware {
        return .{
            .ptr = self,
            .processFn = &process,
        };
    }

    fn process(ptr: *anyopaque, record: *zlog.Record, allocator: std.mem.Allocator) bool {
        const self: *HostnameMiddleware = @ptrCast(@alignCast(ptr));

        const new_fields = allocator.alloc(zlog.Field, record.fields.len + 1) catch return true;
        new_fields[0] = zlog.Field.string("hostname", self.hostname);
        @memcpy(new_fields[1..], record.fields);
        record.fields = new_fields;
        return true;
    }
};
```

### Minimal Example: Drop Records

A middleware that suppresses health check noise:

```zig
const HealthCheckFilter = struct {
    fn middleware(self: *HealthCheckFilter) zlog.Middleware {
        return .{ .ptr = self, .processFn = &process };
    }

    fn process(_: *anyopaque, record: *zlog.Record, _: std.mem.Allocator) bool {
        return !std.mem.eql(u8, record.message, "health check");
    }
};
```

### Key Points

- *Allocator*: the `allocator` argument is a per-call fixed buffer allocator (8KB). Allocations from it are freed automatically after `emit`. If it runs out, decide whether to pass the record through unmodified or drop it.
- *Security*: if your middleware handles sensitive data (like the built-in redact/mask), drop the record on allocation failure rather than risk emitting unprocessed fields. Return `false` and log a warning to stderr.
- *Mutation*: you can modify any field on the record: `fields`, `message`, `level`, `timestamp_ns`. Changes are visible to subsequent middleware and the handler.
- *Ordering*: middleware runs in array order. Put filtering middleware (sampling) before transformation middleware (redact) to avoid unnecessary work on records that will be dropped.
- *No allocation needed*: middleware that only reads or mutates existing fields (like the timestamp override or health check filter above) can ignore the allocator entirely.

### Record Mutation Without Allocation

You can mutate the record directly without allocating:

```zig
fn process(ptr: *anyopaque, record: *zlog.Record, _: std.mem.Allocator) bool {
    const self: *TimestampOverride = @ptrCast(@alignCast(ptr));
    record.timestamp_ns = self.fixed_ns;
    return true;
}
```

This is useful for overriding timestamps in tests, forcing log levels, or rewriting messages.

## Composing Middleware

Middleware composes naturally as an array:

```zig
var redactor = zlog.RedactMiddleware.init(&.{"password"});
var sampler = zlog.LevelSamplingMiddleware.init(100, .warn);
var hostname_mw = HostnameMiddleware.init("web-01");

var logger = try Log.init(.{
    .handler = handler_iface,
    .middlewares = &.{
        sampler.middleware(),      // filter first: skip work on dropped records
        redactor.middleware(),     // then redact sensitive fields
        hostname_mw.middleware(),  // then enrich
    },
    .allocator = allocator,
});
```

## See Also

- [examples/custom_handler.zig](../examples/custom_handler.zig): CSV handler and split handler
- [examples/custom_middleware.zig](../examples/custom_middleware.zig): timestamp override and level-aware sampling
