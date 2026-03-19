const std = @import("std");

fn stderrWriteFn(_: *const anyopaque, bytes: []const u8) anyerror!usize {
    return std.posix.write(std.posix.STDERR_FILENO, bytes);
}

fn stdoutWriteFn(_: *const anyopaque, bytes: []const u8) anyerror!usize {
    return std.posix.write(std.posix.STDOUT_FILENO, bytes);
}

/// Provides a valid, stable address for AnyWriter's required non-null context pointer.
/// The write functions ignore the context value; this just satisfies the pointer constraint.
const no_context: u8 = 0;
pub const stderr: std.io.AnyWriter = .{ .context = @ptrCast(&no_context), .writeFn = &stderrWriteFn };
pub const stdout: std.io.AnyWriter = .{ .context = @ptrCast(&no_context), .writeFn = &stdoutWriteFn };
