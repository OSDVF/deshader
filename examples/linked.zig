const std = @import("std");
const deshader = @import("deshader");

pub fn main() !void {
    std.log.info("Showing Deshader Library version from Zig", .{});
    const stdout = std.io.getStdOut();
    try stdout.writeAll(std.mem.span(deshader.version()));
    try stdout.writeAll("\n");
}
