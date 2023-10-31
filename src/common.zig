const std = @import("std");
pub var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub var allocator: std.mem.Allocator = undefined;
pub var env: std.process.EnvMap = undefined;
pub fn init() !void {
    allocator = gpa.allocator();
    env = try std.process.getEnvMap(allocator);
}
