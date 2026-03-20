const std = @import("std");
const Level = @import("Level.zig").Value;
const Field = @import("Field.zig");
const Record = @import("Record.zig");
const Handler = @import("Handler.zig");
const Middleware = @import("Middleware.zig");
const AtomicLevel = @import("AtomicLevel.zig");
const field_conversion = @import("field_conversion.zig");
const fd = @import("writers/fd.zig");

/// Maximum nesting depth for dot-separated group prefixes (e.g. "a.b.c" = 3).
const max_group_depth = 32;

/// Comptime options controlling Logger behavior.
pub const Options = struct {
    /// When true, all log methods require an explicit `@src()` as the last argument.
    src: bool = false,
};

pub fn Logger(comptime min_level: Level, comptime opts: Options) type {
    return struct {
        const Self = @This();

        handler: Handler,
        middlewares: []const Middleware = &.{},
        base_fields: []const Field.Field = &.{},
        /// Raw fields accumulated under the current group_prefix (not yet wrapped).
        /// Merged with call-site fields and wrapped together at emit time.
        group_fields: []const Field.Field = &.{},
        level: ?*AtomicLevel = null,
        group_prefix: []const u8 = "",
        shared: *Shared,
        is_owner: bool = false,

        /// Shared state owned by the root logger. All child loggers (via `with`/`withGroup`)
        /// point to the same Shared. Only the root logger should call `deinit()`.
        const Shared = struct {
            arena: std.heap.ArenaAllocator,
            backing_allocator: std.mem.Allocator,
        };

        pub const InitOptions = struct {
            handler: Handler,
            middlewares: []const Middleware = &.{},
            allocator: std.mem.Allocator,
            level: ?*AtomicLevel = null,
        };

        /// Creates a root logger. The caller must call `deinit()` when done.
        pub fn init(init_opts: InitOptions) !Self {
            const shared = try init_opts.allocator.create(Shared);
            shared.* = .{
                .arena = std.heap.ArenaAllocator.init(init_opts.allocator),
                .backing_allocator = init_opts.allocator,
            };
            return .{
                .handler = init_opts.handler,
                .middlewares = init_opts.middlewares,
                .shared = shared,
                .level = init_opts.level,
                .is_owner = true,
            };
        }

        /// Frees all memory owned by this logger and its children.
        /// Only call on the root logger (created via `init`). Never call on child
        /// loggers returned by `with()` or `withGroup()`.
        pub fn deinit(self: Self) void {
            std.debug.assert(self.is_owner);
            const allocator = self.shared.backing_allocator;
            self.shared.arena.deinit();
            allocator.destroy(self.shared);
        }

        /// Creates a child logger with additional base fields. The child shares
        /// the root's arena — do NOT call `deinit()` on children.
        /// Panics on arena OOM (should never happen in practice).
        pub fn with(self: Self, attrs: anytype) Self {
            const arena = self.shared.arena.allocator();
            const extra = field_conversion.fieldsFromStruct(arena, attrs);
            if (extra.len == 0) return self;
            return self.addFields(&extra);
        }

        /// Creates a child logger with runtime field slices. The child shares
        /// the root's arena — do NOT call `deinit()` on children.
        /// Panics on arena OOM (should never happen in practice).
        pub fn withFields(self: Self, fields: []const Field.Field) Self {
            if (fields.len == 0) return self;
            return self.addFields(fields);
        }

        /// Creates a child logger with a per-logger level override.
        /// The child shares the root's arena — do NOT call `deinit()` on children.
        pub fn withLevel(self: Self, lvl: *AtomicLevel) Self {
            var copy = self;
            copy.level = lvl;
            copy.is_owner = false;
            return copy;
        }

        fn addFields(self: Self, extra: []const Field.Field) Self {
            const arena = self.shared.arena.allocator();

            if (self.group_prefix.len > 0) {
                const total = self.group_fields.len + extra.len;
                const merged = arena.alloc(Field.Field, total) catch @panic("zlog: arena OOM");
                @memcpy(merged[0..self.group_fields.len], self.group_fields);
                @memcpy(merged[self.group_fields.len..], extra);

                return .{
                    .handler = self.handler,
                    .middlewares = self.middlewares,
                    .base_fields = self.base_fields,
                    .group_fields = merged,
                    .level = self.level,
                    .group_prefix = self.group_prefix,
                    .shared = self.shared,
                };
            }

            const total = self.base_fields.len + extra.len;
            const merged = arena.alloc(Field.Field, total) catch @panic("zlog: arena OOM");
            @memcpy(merged[0..self.base_fields.len], self.base_fields);
            @memcpy(merged[self.base_fields.len..], extra);
            return .{
                .handler = self.handler,
                .middlewares = self.middlewares,
                .base_fields = merged,
                .level = self.level,
                .group_prefix = self.group_prefix,
                .shared = self.shared,
            };
        }

        /// Creates a child logger with a group prefix. All subsequent fields
        /// (both base and per-call) are nested under the group name.
        /// Do NOT call `deinit()` on children.
        /// Panics on arena OOM (should never happen in practice).
        pub fn withGroup(self: Self, name: []const u8) Self {
            if (name.len == 0) return self;

            const arena = self.shared.arena.allocator();

            // Seal any pending group_fields: wrap them in the current prefix
            // and merge into base_fields before switching to the new prefix.
            var base = self.base_fields;
            if (self.group_fields.len > 0 and self.group_prefix.len > 0) {
                const wrapped = wrapInGroup(arena, self.group_prefix, self.group_fields) catch @panic("zlog: arena OOM");
                base = mergeFields(arena, self.base_fields, wrapped) catch @panic("zlog: arena OOM");
            }

            if (self.group_prefix.len > 0) {
                const buf = arena.alloc(u8, self.group_prefix.len + 1 + name.len) catch @panic("zlog: arena OOM");
                @memcpy(buf[0..self.group_prefix.len], self.group_prefix);
                buf[self.group_prefix.len] = '.';
                @memcpy(buf[self.group_prefix.len + 1 ..], name);
                return .{
                    .handler = self.handler,
                    .middlewares = self.middlewares,
                    .base_fields = base,
                    .group_fields = &.{},
                    .level = self.level,
                    .group_prefix = buf,
                    .shared = self.shared,
                };
            }
            return .{
                .handler = self.handler,
                .middlewares = self.middlewares,
                .base_fields = base,
                .group_fields = &.{},
                .level = self.level,
                .group_prefix = name,
                .shared = self.shared,
            };
        }

        /// Flushes buffered output in the handler, if the handler implements flush.
        pub fn flush(self: Self) void {
            self.handler.flush();
        }

        /// Returns true if the given level would pass both comptime and runtime filters.
        pub fn isEnabled(self: Self, level: Level) bool {
            if (@intFromEnum(level) < @intFromEnum(min_level)) return false;
            if (self.level) |runtime_level| {
                return @intFromEnum(level) >= @intFromEnum(runtime_level.load());
            }
            return true;
        }

        // Comptime-selected signatures: with .src=true, each method requires
        // an explicit @src() as the last argument. Without it, no src parameter
        // exists at all — avoiding an unused parameter that Zig would reject.

        pub const debug = if (opts.src) logFns(.debug).withSrc else logFns(.debug).noSrc;
        pub const info = if (opts.src) logFns(.info).withSrc else logFns(.info).noSrc;
        pub const warn = if (opts.src) logFns(.warn).withSrc else logFns(.warn).noSrc;
        pub const err = if (opts.src) logFns(.err).withSrc else logFns(.err).noSrc;
        /// Format-string log method for the rare case where format strings are needed.
        pub const logf = if (opts.src) logfWithSrc else logfNoSrc;

        fn logFns(comptime level: Level) type {
            return struct {
                fn withSrc(self: Self, msg: []const u8, attrs: anytype, src: std.builtin.SourceLocation) void {
                    if (comptime @intFromEnum(level) < @intFromEnum(min_level)) return;
                    self.logImpl(level, src, msg, attrs);
                }

                fn noSrc(self: Self, msg: []const u8, attrs: anytype) void {
                    if (comptime @intFromEnum(level) < @intFromEnum(min_level)) return;
                    self.logImpl(level, null, msg, attrs);
                }
            };
        }

        fn logfWithSrc(self: Self, comptime level: Level, comptime fmt: []const u8, args: anytype, attrs: anytype, src: std.builtin.SourceLocation) void {
            if (comptime @intFromEnum(level) < @intFromEnum(min_level)) return;
            var buf: [8192]u8 = undefined;
            self.logImpl(level, src, fmtBuf(&buf, fmt, args), attrs);
        }

        fn logfNoSrc(self: Self, comptime level: Level, comptime fmt: []const u8, args: anytype, attrs: anytype) void {
            if (comptime @intFromEnum(level) < @intFromEnum(min_level)) return;
            var buf: [8192]u8 = undefined;
            self.logImpl(level, null, fmtBuf(&buf, fmt, args), attrs);
        }

        /// Formats into buf, returning the written slice. On overflow, returns
        /// the truncated output (whatever fit in the buffer).
        fn fmtBuf(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
            var fbs = std.io.fixedBufferStream(buf);
            fbs.writer().print(fmt, args) catch return fbs.getWritten();
            return fbs.getWritten();
        }

        fn logImpl(self: Self, level: Level, src: ?std.builtin.SourceLocation, msg: []const u8, attrs: anytype) void {
            if (self.level) |runtime_level| {
                if (@intFromEnum(level) < @intFromEnum(runtime_level.load())) return;
            }

            // Stack FBA used for field conversion (nested structs) and merge/wrap.
            var stack_buf: [8192]u8 = undefined;
            var stack_fba = std.heap.FixedBufferAllocator.init(&stack_buf);
            const stack_alloc = stack_fba.allocator();

            const raw_call_fields = field_conversion.fieldsFromStruct(stack_alloc, attrs);

            // Fast path: no merge, no group wrapping, no middleware — skip arena entirely
            if (self.base_fields.len == 0 and self.group_fields.len == 0 and self.group_prefix.len == 0 and self.middlewares.len == 0) {
                const record: Record = .{
                    .level = level,
                    .message = msg,
                    .timestamp_ns = std.time.nanoTimestamp(),
                    .fields = &raw_call_fields,
                    .src = src,
                };
                self.handler.emit(&record);
                return;
            }

            const merge_alloc = stack_alloc;

            // Merge group_fields (from with() under a group prefix) with call-site fields,
            // then wrap the combined set in the group prefix. This produces a single group
            // instead of duplicate sibling keys.
            const grouped_fields = mergeFields(merge_alloc, self.group_fields, &raw_call_fields) catch blk: {
                fd.stderr.writeAll("zlog: group fields dropped: merge OOM\n") catch {};
                break :blk &raw_call_fields;
            };
            const call_fields = if (self.group_prefix.len > 0 and grouped_fields.len > 0)
                wrapInGroup(merge_alloc, self.group_prefix, grouped_fields) catch |e| switch (e) {
                    error.GroupDepthExceeded => blk: {
                        fd.stderr.writeAll("zlog: group depth exceeded, fields emitted flat\n") catch {};
                        break :blk grouped_fields;
                    },
                    error.OutOfMemory => grouped_fields,
                }
            else
                grouped_fields;

            const all_fields = mergeFields(merge_alloc, self.base_fields, call_fields) catch blk: {
                fd.stderr.writeAll("zlog: base fields dropped: merge OOM\n") catch {};
                break :blk call_fields;
            };

            var record: Record = .{
                .level = level,
                .message = msg,
                .timestamp_ns = std.time.nanoTimestamp(),
                .fields = all_fields,
                .src = src,
            };

            if (self.middlewares.len > 0) {
                // All middlewares share a single per-call FBA. Allocations
                // (e.g. redacted/masked field slices) must survive until emit().
                var mw_buf: [8192]u8 = undefined;
                var mw_fba = std.heap.FixedBufferAllocator.init(&mw_buf);
                const mw_alloc = mw_fba.allocator();
                for (self.middlewares) |mw| {
                    if (!mw.process(&record, mw_alloc)) return;
                }
            }

            self.handler.emit(&record);
        }

        fn mergeFields(allocator: std.mem.Allocator, base: []const Field.Field, extra: []const Field.Field) ![]const Field.Field {
            if (base.len == 0) return extra;
            if (extra.len == 0) return base;
            const merged = try allocator.alloc(Field.Field, base.len + extra.len);
            @memcpy(merged[0..base.len], base);
            @memcpy(merged[base.len..], extra);
            return merged;
        }

        /// Wraps fields in nested group(s) according to a dot-separated prefix.
        /// e.g. prefix="a.b", fields=[{key:"x"}] -> [{key:"a", value:group([{key:"b", value:group([{key:"x",...}])}])}]
        fn wrapInGroup(allocator: std.mem.Allocator, prefix: []const u8, fields: []const Field.Field) ![]const Field.Field {
            var parts_buf: [max_group_depth][]const u8 = undefined;
            const part_count = try splitPrefix(prefix, &parts_buf);

            const wrappers = try allocator.alloc(Field.Field, part_count);

            var current_fields = fields;
            var i: usize = part_count;
            while (i > 0) {
                i -= 1;
                wrappers[i] = .{
                    .key = parts_buf[i],
                    .value = .{ .group = current_fields },
                };
                current_fields = wrappers[i .. i + 1];
            }
            return wrappers[0..1];
        }

        /// Splits a dot-separated prefix into parts. Returns the number of parts.
        fn splitPrefix(prefix: []const u8, parts: *[max_group_depth][]const u8) error{GroupDepthExceeded}!usize {
            var count: usize = 0;
            var start: usize = 0;
            for (prefix, 0..) |c, i| {
                if (c == '.') {
                    if (count >= max_group_depth) return error.GroupDepthExceeded;
                    parts[count] = prefix[start..i];
                    count += 1;
                    start = i + 1;
                }
            }
            if (count >= max_group_depth) return error.GroupDepthExceeded;
            parts[count] = prefix[start..];
            return count + 1;
        }
    };
}

test "logger comptime level filtering" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.warn, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    logger.info("should not appear", .{});
    try testing.expectEqual(0, fbs.getWritten().len);

    logger.warn("should appear", .{});
    try testing.expect(fbs.getWritten().len > 0);
    try testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "\"should appear\"") != null);
}

test "logger with base fields" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{
        .handler = h.handler(),
        .allocator = testing.allocator,
    });
    defer logger.deinit();

    const child = logger.with(.{ .request_id = "abc-123" });
    child.info("request", .{ .status = 200 });

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"request_id\":\"abc-123\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"status\":200") != null);
}

test "runtime level filters messages below threshold" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    var lvl = AtomicLevel.init(.info);
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator, .level = &lvl });
    defer logger.deinit();

    logger.debug("should not appear", .{});
    try testing.expectEqual(0, fbs.getWritten().len);

    logger.info("should appear", .{});
    try testing.expect(fbs.getWritten().len > 0);
}

test "runtime level allows after set" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    var lvl = AtomicLevel.init(.warn);
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator, .level = &lvl });
    defer logger.deinit();

    logger.debug("blocked", .{});
    try testing.expectEqual(0, fbs.getWritten().len);

    lvl.set(.debug);
    logger.debug("now allowed", .{});
    try testing.expect(fbs.getWritten().len > 0);
}

test "null runtime level uses comptime only" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    logger.debug("should appear", .{});
    try testing.expect(fbs.getWritten().len > 0);
}

test "with propagates runtime level" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    var lvl = AtomicLevel.init(.warn);
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator, .level = &lvl });
    defer logger.deinit();
    const child = logger.with(.{ .component = "auth" });

    child.debug("blocked", .{});
    try testing.expectEqual(0, fbs.getWritten().len);

    lvl.set(.debug);
    child.debug("now allowed", .{});
    try testing.expect(fbs.getWritten().len > 0);
}

test "src option captures source location" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.debug, .{ .src = true });
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    logger.info("with source", .{}, @src());
    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"src\":\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Logger.zig:") != null);
}

test "logf with src option" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.debug, .{ .src = true });
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    logger.logf(.info, "request {s}", .{"/api"}, .{ .status = 200 }, @src());
    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"request /api\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"src\":\"") != null);
}

test "info without src has no src field" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    logger.info("no source", .{});
    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"src\":") == null);
}

test "logger with middleware" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    const redact = @import("middleware/redact.zig");
    const mask = @import("middleware/mask.zig");

    const starMask = struct {
        fn f(value: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
            _ = value;
            return alloc.dupe(u8, "***") catch null;
        }
    }.f;

    var h = json.init(writer.any());
    var r = redact.init(&.{"password"});
    var m = mask.init("email", &starMask);

    const handler_iface = h.handler();
    const middlewares = [_]@import("Middleware.zig"){ r.middleware(), m.middleware() };

    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{
        .handler = handler_iface,
        .middlewares = &middlewares,
        .allocator = testing.allocator,
    });
    defer logger.deinit();

    logger.info("login", .{ .email = "john@example.com", .password = "secret" });

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"***\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"[REDACTED]\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "secret") == null);
}

test "nested struct produces grouped json output" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    logger.info("handled", .{ .request = .{ .method = "GET", .url = "/api" } });

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"request\":{\"method\":\"GET\",\"url\":\"/api\"}") != null);
}

test "withGroup namespaces fields" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    const req_log = logger.withGroup("request");
    req_log.info("handled", .{ .method = "GET" });

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"request\":{\"method\":\"GET\"}") != null);
}

test "chained withGroup nesting" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    const nested = logger.withGroup("a").withGroup("b");
    nested.info("deep", .{ .x = 1 });

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"a\":{\"b\":{\"x\":1}}") != null);
}

test "with fields before withGroup remain top-level" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    const with_service = logger.with(.{ .service = "api" });
    const child = with_service.withGroup("request");
    child.info("handled", .{ .method = "GET" });

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"service\":\"api\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"request\":{\"method\":\"GET\"}") != null);
}

test "with after withGroup merges into single group" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    const child = logger.withGroup("request").with(.{ .method = "GET" });
    child.info("handled", .{ .url = "/api" });

    const output = fbs.getWritten();
    // All fields under the same group prefix are merged into a single group object
    try testing.expect(std.mem.indexOf(u8, output, "\"request\":{\"method\":\"GET\",\"url\":\"/api\"}") != null);
    // Must NOT have duplicate "request" keys
    const first = std.mem.indexOf(u8, output, "\"request\":") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, output[first + 1 ..], "\"request\":") == null);
}

test "withGroup seals group_fields from previous group" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    // with(.{service="api"}) before withGroup ensures base_fields are preserved,
    // then withGroup("req") + with(.{method="GET"}) + withGroup("resp") seals
    // method into "req" and new call fields go under "req.resp".
    const child = logger.with(.{ .service = "api" }).withGroup("req").with(.{ .method = "GET" }).withGroup("resp");
    child.info("test", .{ .status = 200 });

    const output = fbs.getWritten();
    // Base field stays top-level
    try testing.expect(std.mem.indexOf(u8, output, "\"service\":\"api\"") != null);
    // Sealed group_fields wrapped in "req"
    try testing.expect(std.mem.indexOf(u8, output, "\"req\":{\"method\":\"GET\"}") != null);
    // Call-site fields wrapped in "req.resp"
    try testing.expect(std.mem.indexOf(u8, output, "\"req\":{\"resp\":{\"status\":200}}") != null);
}

test "logf formats message" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    logger.logf(.info, "request {s} took {d}ms", .{ "/api", 42 }, .{ .status = 200 });

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"request /api took 42ms\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"status\":200") != null);
}

test "logf overflow returns truncated output" {
    const testing = std.testing;
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    const long = "x" ** 5000;
    logger.logf(.info, "{s}", .{long}, .{});

    const output = fbs.getWritten();
    // Truncated "x" chars should appear, not the raw format string
    try testing.expect(std.mem.indexOf(u8, output, "xxxx") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"{s}\"") == null);
}

test "logf filtered at comptime" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.warn, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    logger.logf(.debug, "should not appear {d}", .{42}, .{});
    try testing.expectEqual(0, fbs.getWritten().len);
}

test "nested with() shares arena" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    // Nested with() calls: children share the root's arena
    const child = logger.with(.{ .x = 1 });
    const grandchild = child.with(.{ .y = 2 });

    grandchild.info("test", .{});
    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"x\":1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"y\":2") != null);
}

test "withGroup empty name is noop" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    const same = logger.withGroup("");
    same.info("test", .{ .x = 1 });

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"x\":1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"\":{") == null);
}

test "middleware returning false drops record" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    const zlog = @import("zlog.zig");

    var h = json.init(writer.any());

    var sampler = zlog.SimpleSamplingMiddleware.init(100);
    const middlewares = [_]@import("Middleware.zig"){sampler.middleware()};

    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{
        .handler = h.handler(),
        .middlewares = &middlewares,
        .allocator = testing.allocator,
    });
    defer logger.deinit();

    logger.info("first", .{});
    try testing.expect(fbs.getWritten().len > 0);

    fbs.reset();
    logger.info("dropped", .{});
    try testing.expectEqual(0, fbs.getWritten().len);
}

test "withFields adds runtime field slice" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    const fields = &[_]Field.Field{
        Field.Field.string("request_id", "abc-123"),
        Field.Field.int("attempt", 3),
    };
    const child = logger.withFields(fields);
    child.info("test", .{});

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"request_id\":\"abc-123\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"attempt\":3") != null);
}

test "withFields under group prefix" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    const fields = &[_]Field.Field{
        Field.Field.string("method", "GET"),
    };
    const child = logger.withGroup("request").withFields(fields);
    child.info("test", .{ .url = "/api" });

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"request\":{\"method\":\"GET\",\"url\":\"/api\"}") != null);
}

test "withFields empty slice is noop" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    const child = logger.withFields(&.{});
    // Same struct — no allocation happened
    try testing.expectEqual(logger.base_fields.ptr, child.base_fields.ptr);
}

test "withLevel overrides parent level" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    var child_level = AtomicLevel.init(.warn);
    const child = logger.withLevel(&child_level);

    // Parent allows debug, child blocks it
    child.debug("blocked", .{});
    try testing.expectEqual(0, fbs.getWritten().len);

    child.warn("allowed", .{});
    try testing.expect(fbs.getWritten().len > 0);

    // Parent still allows debug
    fbs.reset();
    logger.debug("parent still works", .{});
    try testing.expect(fbs.getWritten().len > 0);
}

test "isEnabled checks comptime and runtime levels" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    var lvl = AtomicLevel.init(.warn);
    const Log = Logger(.info, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator, .level = &lvl });
    defer logger.deinit();

    // debug filtered at comptime
    try testing.expect(!logger.isEnabled(.debug));
    // info filtered at runtime (runtime level is warn)
    try testing.expect(!logger.isEnabled(.info));
    // warn passes both
    try testing.expect(logger.isEnabled(.warn));

    lvl.set(.info);
    try testing.expect(logger.isEnabled(.info));
}

test "runtime values in attrs" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    // The exact reproduction case: runtime variable in attrs
    var result: i32 = 200;
    result += 0;
    logger.info("done", .{ .result = result });

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"result\":200") != null);
}

test "with() with runtime values" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const json = @import("handlers/json.zig");
    var h = json.init(writer.any());
    const Log = Logger(.debug, .{});
    const logger = try Log.init(.{ .handler = h.handler(), .allocator = testing.allocator });
    defer logger.deinit();

    var request_id: []const u8 = "req-456";
    request_id = request_id;
    const child = logger.with(.{ .request_id = request_id });
    child.info("handled", .{});

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "\"request_id\":\"req-456\"") != null);
}
