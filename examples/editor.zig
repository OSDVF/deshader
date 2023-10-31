const std = @import("std");
const deshader = @import("deshader");

pub fn main() !void {
    std.log.info("Showing Deshader Editor window on demand");

    _ = deshader.showEditorWindow();
}
