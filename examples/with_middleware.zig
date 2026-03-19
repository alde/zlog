const std = @import("std");
const zlog = @import("zlog");

/// Example: mask an email to "j***@example.com".
fn maskEmail(email: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    const at_pos = std.mem.indexOfScalar(u8, email, '@') orelse return null;
    if (at_pos == 0) return null;
    const domain = email[at_pos..];
    const result = allocator.alloc(u8, 1 + 3 + domain.len) catch return null;
    result[0] = email[0];
    @memcpy(result[1..4], "***");
    @memcpy(result[4..], domain);
    return result;
}

pub fn main() !void {
    var json_handler = zlog.JsonHandler.init(zlog.stderr);

    // Set up middleware — recursive by default, so nested groups are processed too
    var redactor = zlog.RedactMiddleware.init(&.{ "password", "ssn" });
    var masker = zlog.MaskMiddleware.init("email", &maskEmail);

    const Log = zlog.Logger(.info, .{});
    var secure_logger = try Log.init(.{
        .handler = json_handler.handler(),
        .middlewares = &.{ redactor.middleware(), masker.middleware() },
        .allocator = std.heap.page_allocator,
    });
    defer secure_logger.deinit();

    secure_logger.info("user login", .{
        .email = "john@example.com",
        .password = "super-secret-123",
        .role = "admin",
    });

    secure_logger.info("user profile", .{
        .email = "alice@company.org",
        .ssn = "123-45-6789",
        .name = "Alice Smith",
    });

    // Recursive middleware — redacts fields inside nested groups
    secure_logger.info("nested redaction", .{
        .user = .{
            .name = "Bob",
            .password = "hidden-in-group",
            .email = "bob@example.com",
        },
    });

    // Without middleware — shows unredacted output
    var plain_logger = try Log.init(.{ .handler = json_handler.handler(), .allocator = std.heap.page_allocator });
    defer plain_logger.deinit();
    plain_logger.info("comparison (no middleware)", .{
        .email = "john@example.com",
        .password = "visible",
    });
}
