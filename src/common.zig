// Copyright (C) 2024  Ondřej Sabela
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
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

pub const logging = @import("common/log.zig");
pub const env = @import("common/env.zig");
pub const process = @import("common/process.zig");

const c = @cImport({
    if (builtin.os.tag == .windows) {
        @cInclude("windows.h");
        @cInclude("libloaderapi.h");
    } else if (builtin.os.tag == .linux) {
        @cInclude("link.h");
    } else @cInclude("dlfcn.h");
});

pub const log = logging.DeshaderLog;

const String = []const u8;
const CString = [*:0]const u8;
const ZString = [:0]const u8;

pub const GPA = std.heap.GeneralPurposeAllocator(.{
    .stack_trace_frames = options.memoryFrames,
});

pub var gpa = GPA{};
pub var allocator: std.mem.Allocator = undefined;
pub var initialized = false;
var self_exe: ?String = null;
pub const env_prefix = "DESHADER_";
pub const default_editor_port = "8080";
pub const default_editor_port_n = 8080;
pub const default_http_port = "8081";
pub const default_http_port_n = 8081;
pub const default_ws_port = "8082";
pub const default_ws_port_n = 8082;
pub const default_lsp_port = "8083";
pub const default_lsp_port_n = 8083;
pub const default_ws_url = "ws://127.0.0.1:" ++ default_ws_port;
pub const default_lsp_url = "ws://127.0.0.1:" ++ default_lsp_port;
pub const default_http_url = "http://127.0.0.1:" ++ default_http_port;

pub const null_trace = std.builtin.StackTrace{
    .index = 0,
    .instruction_addresses = &.{},
};

pub fn init() !void {
    if (!initialized) {
        allocator = gpa.allocator();
        try env.init(allocator);
        initialized = true;
    }
}

pub fn deinit() void {
    if (self_exe) |path| {
        allocator.free(path);
    }
    if (initialized) {
        _ = env.deinit();
        _ = gpa.deinit();
        initialized = false;
    }
}

pub fn joinInnerInnerZ(alloc: std.mem.Allocator, separator: []const u8, slices: [][]CString) std.mem.Allocator.Error![]u8 {
    // Calculate the total length of the resulting string.
    var lengths = try alloc.alloc(usize, slices.len * slices[0].len);
    defer alloc.free(lengths);

    const total_len = blk: {
        var sum: usize = separator.len * (slices.len * slices[0].len - 1);
        for (slices) |inner_slices| {
            for (inner_slices, 0..) |slice, i| {
                const len = std.mem.len(slice);
                sum += len;
                lengths[i] = len;
            }
        }
        break :blk sum;
    };

    // Allocate memory for the resulting string.
    const buf = try alloc.alloc(u8, total_len);
    errdefer alloc.free(buf);

    // Build the resulting string.
    var buf_index: usize = 0;
    for (slices) |inner_slices| {
        var first_inner = true;
        for (inner_slices, 0..) |slice, i| {
            if (!first_inner) {
                std.mem.copyForwards(u8, buf[buf_index..], separator);
                buf_index += separator.len;
            } else {
                first_inner = false;
            }
            copyForwardsZ(u8, buf[buf_index..], slice, lengths[i]);
            buf_index += lengths[i];
        }
    }

    // No need for shrink since buf is exactly the correct size.
    return buf;
}
pub fn joinInnerZ(alloc: std.mem.Allocator, separator: []const u8, slices: []const ?CString) std.mem.Allocator.Error![]u8 {
    if (slices.len == 0) return &[0]u8{};
    var lengths = try alloc.alloc(usize, slices.len);
    defer alloc.free(lengths);

    const total_len = blk: {
        var sum: usize = separator.len * (slices.len - 1);
        for (slices, 0..) |slice, i| {
            if (slice) |yes_slice| {
                const len = std.mem.len(yes_slice);
                sum += len;
                lengths[i] = len;
            }
        }
        break :blk sum;
    };

    const buf = try alloc.alloc(u8, total_len);
    errdefer alloc.free(buf);

    var buf_index: usize = 0;
    if (slices[0]) |yes_slice| {
        @memcpy(buf, yes_slice);
        buf_index = lengths[0];
    }
    for (slices[1..], 1..) |slice, i| {
        if (slice) |yes_slice| {
            std.mem.copyForwards(u8, buf[buf_index..], separator);
            buf_index += separator.len;
            copyForwardsZ(u8, buf[buf_index..], yes_slice, lengths[i]);
            buf_index += lengths[i];
        }
    }

    // No need for shrink since buf is exactly the correct size.
    return buf;
}

test "joinInnerZ Empty" {
    const alloc = std.testing.allocator;
    const separator = "\n";
    const slices = [_]CString{};
    const result = try joinInnerZ(alloc, separator, &slices);
    defer alloc.free(result);
    const expected: String = "";
    try std.testing.expectEqualStrings(expected, result);
}

test "joinInnerZ Non-Empty" {
    const alloc = std.testing.allocator;
    const separator = "\n";
    const slices = [_]CString{ "a", "b", "c" };
    const result = try joinInnerZ(alloc, separator, &slices);
    defer alloc.free(result);
    const expected: String = "a\nb\nc";
    try std.testing.expectEqualStrings(expected, result);
}

pub fn copyForwardsZ(comptime T: type, dest: []T, source: [*]const T, source_len: usize) void {
    for (dest[0..source_len], source) |*d, s| d.* = s;
}

/// Spawns a short-lived server to check for port availability
pub fn isPortFree(address: ?String, port: u16) !bool {
    var check = try std.net.Address.parseIp4(address orelse "0.0.0.0", port);
    var server = check.listen(.{}) catch |err| switch (err) {
        error.AddressInUse => return false,
        else => return err,
    };
    server.deinit();
    return true;
}

var so_path: [:0]const u8 = undefined;
fn callback(info: ?*const c.struct_dl_phdr_info, _: usize, _: ?*anyopaque) callconv(.C) c_int {
    if (info) |i| if (i.dlpi_name[0] != 0) {
        const s = std.mem.span(i.dlpi_name);
        if (std.mem.endsWith(u8, s, options.deshaderLibName)) {
            so_path = s;
            return 1;
        }
    };
    return 0;
}

/// Gets the path of the Deshader DLL
pub fn selfDllPathAlloc(a: std.mem.Allocator, concat_with: String) !String {
    if (builtin.os.tag == .windows) {
        var hm: [*c]c.struct_HINSTANCE__ = undefined;
        if (c.GetModuleHandleExW(c.GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
            c.GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, @ptrCast(&options.version), &hm) != 0)
        {
            var path: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const length = c.GetModuleFileNameA(hm, &path, std.fs.MAX_PATH_BYTES);
            if (length == 0) {
                return std.os.windows.unexpectedError(std.os.windows.kernel32.GetLastError());
            } else {
                return try std.mem.concat(a, u8, &.{
                    if (std.fs.readLinkAbsolute(path[0..length], &path)) |full| full else |_| path[0..length],
                    concat_with,
                });
            }
        } else {
            return std.os.windows.unexpectedError(std.os.windows.kernel32.GetLastError());
        }
    } else if (builtin.os.tag == .linux) {
        _ = c.dl_iterate_phdr(callback, null);
    } else {
        var info: c.Dl_info = undefined;
        if (c.dladdr(&options.version, &info) == 0) {
            return error.DlAddr;
        } else {
            return a.dupe(u8, std.mem.span(info.dli_fname));
        }
    }
    return a.dupe(u8, so_path);
}

/// Wraps std.fs.selfExePathAlloc or gets argv[0] on Windows to workaround Wine bug
pub fn selfExePath() !String {
    if (self_exe) |path| {
        return path;
    }
    if (builtin.os.tag == .windows) // Wine fails on realpath
    {
        var arg = try std.process.argsWithAllocator(allocator);
        defer arg.deinit();
        self_exe = allocator.dupe(u8, arg.next().?);
    } else {
        self_exe = try std.fs.selfExePathAlloc(allocator);
    }
    return self_exe.?;
}

pub fn LoadLibraryEx(path_or_name: String, only_system: bool) !std.os.windows.HMODULE {
    if (!only_system) {
        if (std.fs.path.dirname(path_or_name)) |dirname| {
            const dir = try std.unicode.utf8ToUtf16LeWithNull(allocator, dirname);
            defer allocator.free(dir);
            if (c.AddDllDirectory(dir) == null) {
                log.err("Failed to add DLL directory {s}: {}", .{ dirname, std.os.windows.kernel32.GetLastError() });
            }
        }
    }
    const path_w = (try std.os.windows.sliceToPrefixedFileW(null, std.fs.path.basename(path_or_name))).span().ptr;
    var offset: usize = 0;
    if (path_w[0] == '\\' and path_w[1] == '?' and path_w[2] == '?' and path_w[3] == '\\') {
        // + 4 to skip over the \??\
        offset = 4;
    }
    const handle = c.LoadLibraryExW(path_w + offset, null, if (only_system) c.LOAD_LIBRARY_SEARCH_SYSTEM32 else c.LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (handle == null) {
        return std.os.windows.unexpectedError(std.os.windows.kernel32.GetLastError());
    }
    return @ptrCast(handle.?);
}

pub fn getFullPath(alloc: std.mem.Allocator, path: String) !ZString {
    if (builtin.os.tag == .windows) {
        const path16 = try std.os.windows.sliceToPrefixedFileW(null, path);
        var buffer: [std.fs.MAX_PATH_BYTES]u16 = undefined;
        const length = std.os.windows.kernel32.GetFullPathNameW(path16.span().ptr, std.fs.MAX_PATH_BYTES, &buffer, null);
        if (length == 0) {
            return std.os.windows.unexpectedError(std.os.windows.kernel32.GetLastError());
        }
        return try std.unicode.wtf16LeToWtf8AllocZ(alloc, buffer[0..length]);
    } else {
        var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const out = try std.fs.cwd().realpath(path, &buffer);
        return try alloc.dupeZ(u8, out);
    }
}

pub fn readLinkAbsolute(alloc: std.mem.Allocator, path: String) !String {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    return alloc.dupe(u8, try std.fs.readLinkAbsolute(path, &buffer));
}

/// Handles WINE workaround
pub fn symlinkOrCopy(cwd: std.fs.Dir, target_path: String, symlink_path: String) !void {
    (blk: {
        if (env.get("WINELOADER") != null) {
            break :blk error.Wine;
        }
        break :blk cwd.symLink(target_path, symlink_path, .{});
    }) catch |err| {
        if (err == error.Unexpected or err == error.Wine or err == error.PathAlreadyExists) {
            // Workaround for Wine bugs
            if (cwd.updateFile(target_path, cwd, symlink_path, .{})) |status| {
                if (status == .stale) {
                    log.info("Copied from {s} to {s}", .{ target_path, symlink_path });
                } else {
                    log.debug("{s} is still fresh.", .{symlink_path});
                }
            } else |_| {
                try cwd.copyFile(target_path, cwd, symlink_path, .{});
            }
        } else {
            return err;
        }
    };
}

pub fn oneStartsWithOtherNotEqual(a: String, b: String) bool {
    if (a.len < b.len) {
        return std.mem.eql(u8, a, b[0..a.len]);
    } else if (a.len > b.len) {
        return std.mem.eql(u8, a[0..b.len], b);
    } else {
        return !std.mem.eql(u8, a, b);
    }
}

pub const ArgumentsMap = std.StringHashMapUnmanaged(String);
pub fn queryToArgsMap(allocato: std.mem.Allocator, query: []u8) !ArgumentsMap {
    var list = ArgumentsMap{};
    var iterator = std.mem.splitScalar(u8, query, '&');
    while (iterator.next()) |arg| {
        var arg_iterator = std.mem.splitScalar(u8, arg, '=');
        const key = arg_iterator.first();
        const value = arg_iterator.rest();
        try list.put(allocato, key, std.Uri.percentDecodeInPlace(@constCast(value)));
    }
    return list;
}

pub fn argsFromFullCommand(alloc: std.mem.Allocator, uri: String) !?ArgumentsMap {
    var command_query = std.mem.splitScalar(u8, uri, '?');
    _ = command_query.first();
    const query = command_query.rest();
    return if (query.len > 0) try queryToArgsMap(alloc, @constCast(query)) else null;
}

pub const CliArgsIterator = struct {
    i: usize = 0,
    s: String,
    pub fn next(self: *@This()) ?String {
        var token: ?String = null;
        if (self.i < self.s.len) {
            if (self.s[self.i] == '"') {
                var end = self.i + 1;
                while (end < self.s.len) {
                    if (self.s[end] == '\\' and end + 1 < self.s.len and self.s[end + 1] == '"') {
                        end += 2;
                    } else if (self.s[end] == '"') {
                        break;
                    } else {
                        end += 1;
                    }
                }
                if (end >= self.s.len) return null;
                token = self.s[self.i + 1 .. end];
                self.i = end + 1;
            } else {
                const end = std.mem.indexOfScalar(u8, self.s[self.i..], ' ') orelse (self.s.len - self.i);
                token = self.s[self.i .. self.i + end];
                self.i += end;
            }
            if (self.i < self.s.len and self.s[self.i] == ' ') {
                self.i += 1;
            }
        }
        return token;
    }
};

pub fn nullOrEmpty(s: ?String) bool {
    return if (s) |ys| ys.len == 0 else true;
}

pub fn indexOfSliceMember(comptime T: type, slice: []const T, needle: *T) ?usize {
    for (slice) |*entry| {
        if (entry == needle) {
            return (@intFromPtr(entry) - @intFromPtr(slice.ptr)) / @sizeOf(T);
        }
    }
    return null;
}

pub fn nullishEq(a: anytype, b: anytype) bool {
    return (a == null) == (b == null);
}
