const std = @import("std");
const deshader = @import("deshader");

pub fn main() !void {
    std.log.info("Showing Deshader Library version from Zig", .{});
    const stdout = std.io.getStdOut();
    var version: [*:0]const u8 = undefined;
    deshader.version(&version);
    try stdout.writeAll(std.mem.span(version));
    try stdout.writeAll("\n");
}
