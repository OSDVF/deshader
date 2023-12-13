const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const c = @cImport({
    @cInclude("stdlib.h"); //setenv or _putenv_s
    @cInclude("string.h"); //strerror
});

const log = @import("log.zig").DeshaderLog;

const String = []const u8;
const CString = [*:0]const u8;

pub var gpa = std.heap.GeneralPurposeAllocator(.{
    .stack_trace_frames = options.memoryFrames,
}){};
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
        const result = c._putenv_s(with_sentinel_name, with_sentinel_value);
        if (result != 0) {
            log.err("Failed to set env {s}={s}: {d}", .{ name, value, result });
        }
    } else {
        const result = c.setenv(with_sentinel_name, with_sentinel_value, 1);
        if (result != 0) {
            log.err("Failed to set env {s}={s}: {s}", .{ name, value, c.strerror(@intFromEnum(std.os.errno(result))) });
        }
    }
    env.put(name, value) catch |err| {
        log.err("Failed to set env {s}={s}: {any}", .{ name, value, err });
    };
}

pub fn joinInnerZ(alloc: std.mem.Allocator, separator: []const u8, slices: []const CString) std.mem.Allocator.Error![]u8 {
    if (slices.len == 0) return &[0]u8{};
    var lengths = try alloc.alloc(usize, slices.len);
    defer alloc.free(lengths);

    const total_len = blk: {
        var sum: usize = separator.len * (slices.len - 1);
        for (slices, 0..) |slice, i| {
            const len = std.mem.len(slice);
            sum += len;
            lengths[i] = len;
        }
        break :blk sum;
    };

    const buf = try alloc.alloc(u8, total_len);
    errdefer alloc.free(buf);

    @memcpy(buf, slices[0]);
    var buf_index: usize = lengths[0];
    for (slices[1..], 1..) |slice, i| {
        std.mem.copyForwards(u8, buf[buf_index..], separator);
        buf_index += separator.len;
        copyForwardsZ(u8, buf[buf_index..], slice, lengths[i]);
        buf_index += lengths[i];
    }

    // No need for shrink since buf is exactly the correct size.
    return buf;
}

pub fn copyForwardsZ(comptime T: type, dest: []T, source: [*]const T, source_len: usize) void {
    for (dest[0..source_len], source) |*d, s| d.* = s;
}

pub fn isPortFree(address: ?String, port: u16) !bool {
    var check = std.net.StreamServer.init(.{ .reuse_address = true });
    defer check.deinit();
    _ = check.listen(try std.net.Address.parseIp4(address orelse "0.0.0.0", port)) catch |err| switch (err) {
        error.AddressInUse => return false,
        else => check.close(),
    };
    return true;
}
