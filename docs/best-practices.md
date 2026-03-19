# Best Practices

Practical patterns for using zlog in production services. See [quickstart.md](quickstart.md) for setup and core concepts.

Code examples below assume this common preamble unless shown otherwise:

```zig
const zlog = @import("zlog");
const Log = zlog.Logger(.info, .{});
```

## Memory Model

zlog uses an *arena allocator* for child logger fields. Understanding the lifecycle is key to avoiding unbounded memory growth.

- *Root logger* (`Logger.init`): owns the arena. Call `deinit()` when done.
- *Child loggers* (`with`, `withGroup`, `withFields`, `withLevel`): share the root's arena. Never call `deinit()` on children.
- *Per-call fields* (the `.{ .key = val }` argument to log methods): allocated on the stack. Zero heap cost.

The arena *never shrinks* until the root logger is deinitialized. Every `with()` or `withGroup()` call appends to it. For short-lived loggers (CLI tools, request handlers), this is fine. For long-running processes, read the next section.

## Long-Running Services

### The Problem

If you create one root logger at startup and call `with()` in a loop, the arena grows forever:

```zig
// BAD: arena grows on every iteration, never freed
var logger = try Log.init(.{ .handler = h.handler(), .allocator = allocator });
defer logger.deinit();

while (true) {
    const item = queue.pop();
    const log = logger.with(.{ .item_id = item.id }); // leaks into arena
    log.info("processing", .{});
}
```

### The Fix: Per-Unit-of-Work Root Loggers

Create a root logger per logical unit of work. Share the handler as it's just a pointer.

```zig
// Handler lives for the process lifetime
var json_handler = zlog.JsonHandler.init(zlog.stderr);
const handler_iface = json_handler.handler();

while (true) {
    const item = queue.pop();

    // Root logger per work item -> arena freed at end of iteration
    var logger = try Log.init(.{ .handler = handler_iface, .allocator = allocator });
    defer logger.deinit();

    const log = logger.with(.{ .item_id = item.id });
    processItem(log, item);
}
```

### Kubernetes Operator Pattern

For a k8s operator, create a root logger per reconcile call:

```zig
const zlog = @import("zlog");

const Log = zlog.Logger(.info, .{});

// Process-lifetime setup
var json_handler = zlog.JsonHandler.Handler(.{
    .level_key = "severity",
    .time_key = "timestamp",
    .msg_key = "message",
    .timestamp = .rfc3339,
}).init(zlog.stderr);

fn reconcile(request: Request, allocator: std.mem.Allocator) !Result {
    var logger = try Log.init(.{
        .handler = json_handler.handler(),
        .allocator = allocator,
    });
    defer logger.deinit();

    const log = logger.with(.{
        .controller = "MyController",
        .name = request.name,
        .namespace = request.namespace,
    });

    log.info("reconciling", .{});

    const obj = fetchObject(request) catch |e| {
        log.err("fetch failed", .{ .err = e });
        return .requeue;
    };

    const status_log = log.withGroup("status");
    status_log.info("current state", .{
        .phase = obj.status.phase,
        .ready = obj.status.ready,
    });

    // All arena memory freed here by defer
    return .ok;
}
```

### HTTP Server Pattern

Same idea here, a root logger per request.

```zig
fn handleRequest(req: Request, allocator: std.mem.Allocator) !Response {
    var logger = try Log.init(.{
        .handler = handler_iface,
        .allocator = allocator,
    });
    defer logger.deinit();

    const log = logger.with(.{
        .method = req.method,
        .path = req.path,
        .request_id = req.id,
    });

    log.info("request started", .{});
    defer log.info("request completed", .{ .status = 200 });

    // Pass `log` to service functions that need logging
    return processRequest(log, req);
}
```

### When a Single Root Logger is Fine

If you never call `with()` or `withGroup()`, the arena stays empty. A single root logger works for:

- CLI tools that run and exit
- Services that only log with per-call fields (the `.{}` argument)
- Processes where the set of child loggers is bounded (e.g. one per known subsystem at startup)

## Performance

### Comptime Level Filtering

The most important optimization. Set `min_level` to the lowest level you actually need:

```zig
const build_options = @import("build_options");

const Log = zlog.Logger(if (build_options.debug_logging) .debug else .info, .{});
```

Filtered-out levels compile to nothing. No function call, no timestamp, no field evaluation.

### Guard Expensive Fields

Use `isEnabled()` to skip expensive computation when the level is filtered:

```zig
if (logger.isEnabled(.debug)) {
    const snapshot = try serializeState(state); // expensive
    logger.debug("state dump", .{ .snapshot = snapshot });
}
```

This matters most with runtime level filtering (`AtomicLevel`), where the comptime check passes but the runtime check might not.

### Sampling for High-Volume Paths

Use `LevelSamplingMiddleware` to sample verbose levels while keeping all errors:

```zig
// Sample debug/info at 1-in-100, always keep warn and err
var sampler = zlog.LevelSamplingMiddleware.init(100, .warn);

var logger = try Log.init(.{
    .handler = handler_iface,
    .middlewares = &.{sampler.middleware()},
    .allocator = allocator,
});
```

For uniform sampling across all levels, use `SimpleSamplingMiddleware`.

### Buffered and Async Writers

For high-throughput services, wrap the output in a `BufferedWriter` or `AsyncWriter`:

```zig
// Buffered: batches small writes (4KB default buffer)
var bw = try zlog.BufferedWriter.init(zlog.stderr, allocator, .{});
defer bw.deinit();

// Async: offloads I/O to a background thread
var aw = try zlog.AsyncWriter.init(zlog.stderr, allocator, .{});
defer aw.deinit();
```

For latency-critical paths, use `drop_if_full` to avoid blocking:

```zig
var aw = try zlog.AsyncWriter.init(zlog.stderr, allocator, .{
    .drop_if_full = true,
});
```

Monitor `aw.droppedBytes()` to detect back-pressure.

### Wire Flush Through to Writers

When using buffered or async writers, use `initWithFlush` so that `logger.flush()` propagates:

```zig
var bw = try zlog.BufferedWriter.init(zlog.stderr, allocator, .{});
defer bw.deinit();

var json_handler = zlog.JsonHandler.initWithFlush(bw.writer(), bw.flushThunk());
```

## Production Checklist

### Shutdown

Always flush before exit to avoid losing buffered records:

```zig
// In your shutdown handler / signal handler
logger.flush();
aw.deinit();  // AsyncWriter: drains remaining bytes, joins thread
bw.deinit();  // BufferedWriter: flushes pending data
```

`deinit()` on both `AsyncWriter` and `BufferedWriter` flushes automatically, but calling `flush()` on the logger first ensures the handler's internal buffer is also drained.

### Cloud Logging

Configure JSON key names to match your log aggregator:

```zig
// GCP Cloud Logging
const GcpJson = zlog.JsonHandler.Handler(.{
    .level_key = "severity",
    .time_key = "timestamp",
    .msg_key = "message",
    .timestamp = .rfc3339,
});
```

### Sensitive Data

Use redact/mask middleware for fields that might contain PII:

```zig
var redactor = zlog.RedactMiddleware.init(&.{ "password", "token", "ssn" });
var masker = zlog.MaskMiddleware.init("email", &emailMaskFn);

var logger = try Log.init(.{
    .handler = handler_iface,
    .middlewares = &.{ redactor.middleware(), masker.middleware() },
    .allocator = allocator,
});
```

If a redact or mask middleware cannot allocate, the *entire record is dropped* rather than risk emitting sensitive data. A warning is written to stderr.

### Buffer Sizing

The default handler buffer (`buf_size = 8192`) handles most records. If you log very large fields (e.g. serialized objects), increase it:

```zig
const BigJson = zlog.JsonHandler.Handler(.{ .buf_size = 32768 });
```

When a record exceeds the buffer, a truncation fallback is emitted with the level and a `"zlog: record truncated"` message, and a warning is written to stderr.
