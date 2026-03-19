pub const Level = @import("Level.zig").Value;
pub const Field = @import("Field.zig").Field;
pub const Value = @import("Field.zig").Value;
pub const Record = @import("Record.zig");
pub const Handler = @import("Handler.zig");
pub const FlushThunk = Handler.FlushThunk;
pub const Middleware = @import("Middleware.zig");
pub const Logger = @import("Logger.zig").Logger;
pub const LoggerOptions = @import("Logger.zig").Options;
pub const AtomicLevel = @import("AtomicLevel.zig");

pub const JsonHandler = @import("handlers/json.zig");
pub const TextHandler = @import("handlers/text.zig");
pub const ColorHandler = @import("handlers/color.zig");

pub const NoopHandler = @import("handlers/noop.zig");

pub const BufferedWriter = @import("writers/buffered.zig");
pub const AsyncWriter = @import("writers/async.zig");

const fd = @import("writers/fd.zig");
pub const stderr = fd.stderr;
pub const stdout = fd.stdout;

pub const RedactMiddleware = @import("middleware/redact.zig");
pub const MaskMiddleware = @import("middleware/mask.zig");
pub const SimpleSamplingMiddleware = @import("middleware/sample.zig");
pub const LevelSamplingMiddleware = @import("middleware/level_sample.zig");

pub const std_log = @import("std_log.zig");
pub const setStdLogHandler = std_log.setHandler;
pub const stdLogFn = std_log.stdLogFn;

pub const fieldsFromStruct = @import("field_conversion.zig").fieldsFromStruct;
pub const toValue = @import("field_conversion.zig").toValue;

test {
    @import("std").testing.refAllDecls(@This());
}
