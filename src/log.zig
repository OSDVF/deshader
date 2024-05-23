const std = @import("std");
const common = @import("common.zig");

pub const DeshaderLog = std.log.scoped(.Deshader);
pub var log_listener: ?*const fn (level: std.log.Level, scope: []const u8, message: []const u8) void = null;

pub fn logFn(comptime level: std.log.Level, comptime scope: @TypeOf(.EnumLiteral), comptime format: []const u8, args: anytype) void {
    if (log_listener != null) {
        if (std.fmt.allocPrint(common.allocator, format, args)) |message| {
            log_listener.?(level, @tagName(scope), message);
        } else |err| {
            _ = err catch {};
        }
    }
    std.log.defaultLog(level, scope, format, args);
}
pub const std_options = std.Options{
    .logFn = logFn,
};
