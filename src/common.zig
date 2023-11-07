const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    if (builtin.target.os.tag == .windows) //
        @cInclude("winbase.h") //SetEnvironmentVariable
    else
        @cInclude("stdlib.h"); //setenv
    @cInclude("string.h"); //strerror
});

const log = @import("log.zig").DeshaderLog;

const String = []const u8;

pub var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub var allocator: std.mem.Allocator = undefined;
pub var env: std.process.EnvMap = undefined;
pub var initialized = false;
pub fn init() !void {
    if (!initialized) {
        allocator = gpa.allocator();
        env = try std.process.getEnvMap(allocator);
        initialized = true;
    }
}

pub fn deinit() void {
    if (initialized) {
        _ = env.deinit();
        _ = gpa.deinit();
        initialized = false;
    }
}

pub fn setenv(name: String, value: String) void {
    const with_sentinel_name = std.mem.concatWithSentinel(allocator, u8, &.{name}, 0) catch |err| {
        log.err("Failed to allocate memory for env {s}={s}: {any}", .{ name, value, err });
        return;
    };
    defer allocator.free(with_sentinel_name);
    const with_sentinel_value = std.mem.concatWithSentinel(allocator, u8, &.{value}, 0) catch |err| {
        log.err("Failed to allocate memory for env {s}={s}: {any}", .{ name, value, err });
        return;
    };
    defer allocator.free(with_sentinel_value);
    if (builtin.target.os.tag == .windows) {
        const result = c.SetEnvironmentVariable(with_sentinel_name, with_sentinel_value);
        if (result == 0) {
            const err = c.GetLastError();
            log.err("Failed to set env {s}={s}: {d}", .{ name, value, err });
        }
    } else {
        const result = c.setenv(with_sentinel_name, with_sentinel_value, 1);
        if (result != 0) {
            log.err("Failed to set env {s}={s}: {s}", .{ name, value, c.strerror(@intFromEnum(std.os.errno(result))) });
        }
    }
}
