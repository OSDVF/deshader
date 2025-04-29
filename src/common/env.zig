// Copyright (C) 2025  Ondřej Sabela
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const log = @import("log.zig").DeshaderLog;
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("stdlib.h"); //setenv or _putenv_s, unsetenv
    @cInclude("string.h"); //strerror
});

var env: std.process.EnvMap = undefined;
var allocator: std.mem.Allocator = undefined;

pub fn init(allocat: std.mem.Allocator) !void {
    env = try std.process.getEnvMap(allocat);
    allocator = allocat;
}

pub fn deinit() void {
    env.deinit();
}

const String = []const u8;

pub fn getMap() *const std.process.EnvMap {
    return &env;
}

pub fn set(name: String, value: String) void {
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
            log.err("Failed to set env {s}={s}: {s}", .{ name, value, c.strerror(@intFromEnum(std.posix.errno(result))) });
        }
    }
    env.put(name, value) catch |err| {
        log.err("Failed to set env {s}={s}: {any}", .{ name, value, err });
    };
}

pub fn remove(name: String) void {
    const with_sentinel_name = std.mem.concatWithSentinel(allocator, u8, &.{name}, 0) catch |err| {
        log.err("Failed to allocate memory for unsetenv {s}: {any}", .{ name, err });
        return;
    };
    defer allocator.free(with_sentinel_name);
    if (builtin.target.os.tag == .windows) {
        const result = c._putenv_s(with_sentinel_name, "");
        if (result != 0) {
            log.err("Failed to remove env {s}: {d}", .{ name, result });
        }
    } else {
        const result = c.unsetenv(with_sentinel_name);
        if (result != 0) {
            log.err("Failed to remove env {s}: {s}", .{ name, c.strerror(@intFromEnum(std.posix.errno(result))) });
        }
    }
    env.remove(name);
}

pub fn get(name: String) ?String {
    return env.get(name);
}

/// Append to colon-separated list
pub fn appendList(name: String, value: String) !void {
    return appendListWith(name, value, ":");
}

pub fn appendListWith(name: String, value: String, separator: String) !void {
    const old = env.get(name);
    const new = if (old) |o| try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ o, separator, value }) else value;
    defer if (old != null) allocator.free(new);

    set(name, new);
}

pub fn removeList(name: String, needle: String) !void {
    if (env.get(name)) |old| {
        var it = std.mem.splitScalar(u8, old, ':');
        var new = std.ArrayList(u8).init(allocator);
        defer new.deinit();

        while (it.next()) |part| {
            if (std.mem.eql(u8, part, needle)) {
                continue;
            }
            if (new.items.len > 0) {
                try new.append(':');
            }
            try new.appendSlice(part);
        }
        if (new.items.len == 0) {
            remove(name);
        } else {
            set(name, new.items);
        }
    }
}

pub const library_preload = switch (builtin.os.tag) {
    .macos => "DYLD_INSERT_LIBRARIES",
    .linux => "LD_PRELOAD",
    else => @compileError("Unsupported OS"),
};

pub fn isYes(s: ?String) bool {
    return if (s) |ys| std.ascii.eqlIgnoreCase(ys, "true") or std.ascii.eqlIgnoreCase(ys, "yes") or std.ascii.eqlIgnoreCase(ys, "y") or std.mem.eql(u8, ys, "1") else false;
}
