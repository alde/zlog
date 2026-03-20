# Quickstart

## Install

Add zlog as a dependency in `build.zig.zon`:

```sh
zig fetch --save https://github.com/alde/zlog/archive/refs/tags/v0.1.0.tar.gz
```

Then in `build.zig`, add it to your module:

```zig
const zlog_dep = b.dependency("zlog", .{
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("zlog", zlog_dep.module("zlog"));
```

## Setup

Every zlog program follows the same pattern:

1. Import zlog
2. Choose a logger type (comptime level + options)
3. Create a handler
4. Init a root logger with the handler and an allocator

```zig
const std = @import("std");
const zlog = @import("zlog");

// 1. Choose your logger type at comptime.
//    .info means debug calls are eliminated at compile time.
const Log = zlog.Logger(.info, .{});

pub fn main() !void {
    // 2. Create a handler. This controls output format.
    var handler = zlog.JsonHandler.init(zlog.stderr);

    // 3. Init the root logger. It owns an arena for child logger fields.
    var logger = try Log.init(.{
        .handler = handler.handler(),
        .allocator = std.heap.page_allocator,
    });
    defer logger.deinit();

    // 4. Log.
    logger.info("server started", .{ .port = 8080 });
}
```

Output:

```json
{"level":"info","time":1740062445.123456789,"msg":"server started","port":8080}
```

## Core Concepts

### Log Methods

Every logger has four level methods plus `logf`:

```zig
logger.debug("verbose detail", .{});
logger.info("normal operation", .{ .key = "value" });
logger.warn("something unexpected", .{ .count = 3 });
logger.err("something failed", .{ .err = error.Timeout });
logger.logf(.info, "request {s} took {d}ms", .{ "/api", 42 }, .{ .status = 200 });
```

The last argument is always an anonymous struct of fields. Pass `.{}` for no fields.

### Child Loggers

Child loggers add persistent context without allocating on every log call:

```zig
// Fields from a struct (supports both comptime and runtime values)
const req_log = logger.with(.{ .request_id = "abc-123" });

// Runtime fields from a slice
const fields = &[_]zlog.Field{
    zlog.Field.string("trace_id", trace_id),
    zlog.Field.int("attempt", retry_count),
};
const traced_log = logger.withFields(fields);

// Grouped fields (nested under a key)
const auth_log = logger.withGroup("auth");
auth_log.info("login", .{ .user = "alice" });
// JSON output: {"auth":{"user":"alice"}, ...}
```

Child loggers share the root's arena. Never call `deinit()` on them.

### Handlers

Three built-in handlers, all configurable via comptime `Config`:

```zig
// JSON (default keys: level, time, msg)
var h = zlog.JsonHandler.init(zlog.stderr);

// Plain text
var h = zlog.TextHandler.init(zlog.stderr);

// Colored terminal output
var h = zlog.ColorHandler.init(zlog.stderr);
```

For custom key names or RFC 3339 timestamps, use the generic form:

```zig
const MyJson = zlog.JsonHandler.Handler(.{
    .timestamp = .rfc3339,
    .level_key = "severity",
    .time_key = "timestamp",
    .msg_key = "message",
});
var h = MyJson.init(zlog.stderr);
```

### Middleware

Middleware processes records between the logger and handler:

```zig
var redactor = zlog.RedactMiddleware.init(&.{ "password", "ssn" });
var sampler = zlog.LevelSamplingMiddleware.init(100, .warn);

var logger = try Log.init(.{
    .handler = handler.handler(),
    .middlewares = &.{ redactor.middleware(), sampler.middleware() },
    .allocator = allocator,
});
```

### Runtime Level Control

Use `AtomicLevel` to change the log level at runtime (e.g. via an admin endpoint):

```zig
var level = zlog.AtomicLevel.init(.info);

var logger = try Log.init(.{
    .handler = handler.handler(),
    .allocator = allocator,
    .level = &level,
});

// Later, from another thread:
level.set(.debug);
```

### Source Location

Enable with `.src = true`. All log methods then require `@src()` as the last argument:

```zig
const Log = zlog.Logger(.info, .{ .src = true });
var logger = try Log.init(.{ .handler = h.handler(), .allocator = allocator });

logger.info("checkpoint", .{ .step = "init" }, @src());
// JSON output includes: "src":"main.zig:42"
```

`@src()` must be passed explicitly at the call site because Zig evaluates it where it's written, not where the calling function is. If zlog called `@src()` internally, every log line would report a location inside `Logger.zig` instead of your code. This is a Zig language constraint, not a zlog design choice.

## Next Steps

- [Best Practices](best-practices.md): memory model, long-running services, performance, production patterns
- [Custom Handlers and Middleware](custom-handlers-and-middleware.md): implement your own handler or middleware
- [examples/](../examples/): runnable examples (`zig build run-basic`, etc.)
