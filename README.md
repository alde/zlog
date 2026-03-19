# zlog

Structured logging for Zig. Inspired by Go's [slog](https://pkg.go.dev/log/slog).

Zero dependencies. Comptime level filtering. Type-erased handlers and middleware.

## Features

- Comptime level filtering: disabled levels are completely eliminated
- Runtime level filtering: `AtomicLevel` for dynamic level changes
- Handlers: JSON, text, and logrus-style color output (configurable keys and timestamps)
- Middleware: redact, mask, and sample log records
- Child loggers: `with()` for persistent fields, `withGroup()` for namespacing
- Source location: opt-in `@src()` capture
- Struct-to-fields: pass anonymous structs as fields, nested structs become groups
- Format strings: `logf` for the rare case where `std.fmt` is needed
- `isEnabled()`: guard expensive field computation
- `std.log` bridge: drop-in replacement for Zig's built-in logging
- Buffered and async writers with optional drop-on-full for high-traffic services
- Custom handlers/middleware: implement a single function pointer

## Quick Start

```zig
const std = @import("std");
const zlog = @import("zlog");

pub fn main() !void {
    var handler = zlog.ColorHandler.init(zlog.stderr);
    const Log = zlog.Logger(.info, .{});
    var logger = try Log.init(.{
        .handler = handler.handler(),
        .allocator = std.heap.page_allocator,
    });
    defer logger.deinit();

    logger.info("server started", .{ .port = 8080, .env = "prod" });
    logger.warn("slow response", .{ .duration_ms = 1200 });
    logger.err("query failed", .{ .err = error.ConnectionRefused, .retries = 3 });
}
```

## Handlers

| Handler | Output |
|---------|--------|
| `JsonHandler` | `{"level":"info","time":1740062445.123456789,"msg":"started","port":8080}` |
| `TextHandler` | `level=info time=1740062445.123456789 msg="started" port=8080` |
| `ColorHandler` | `INFO[1740062445.123] started  port=8080` (with ANSI colors) |

All handlers accept a comptime `Config` for timestamp format (`.unix` or `.rfc3339`), buffer size, and key names. JSON and text handlers support custom keys for cloud logging platforms (e.g. GCP Cloud Logging):

```zig
const GcpJson = zlog.JsonHandler.Handler(.{
    .level_key = "severity",
    .time_key = "timestamp",
    .msg_key = "message",
    .timestamp = .rfc3339,
});
```

## Documentation

- [Quickstart](docs/quickstart.md): install, setup, core concepts
- [Best Practices](docs/best-practices.md): memory model, long-running services, performance, production patterns
- [Custom Handlers and Middleware](docs/custom-handlers-and-middleware.md): implement your own

## Examples

```sh
zig build run-basic
zig build run-with_middleware
zig build run-buffered_async
zig build run-custom_middleware
zig build run-custom_handler
```

## Benchmarks

```sh
zig build bench
```

## License

[MIT](LICENSE)
