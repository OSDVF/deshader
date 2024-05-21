const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const commands = @import("commands.zig");
const c = @cImport({
    @cInclude("stdlib.h"); //setenv or _putenv_s
    @cInclude("string.h"); //strerror
    if (builtin.os.tag == .windows) {
        @cInclude("windows.h");
        @cInclude("libloaderapi.h");
    } else {
        @cInclude("link.h");
    }
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
pub const env_prefix = "DESHADER_";
pub const default_http_port = "8081";
pub const default_ws_port = "8082";
pub const default_lsp_port = "8083";
pub var command_listener: ?*commands.CommandListener = null;

pub const null_trace = std.builtin.StackTrace{
    .index = 0,
    .instruction_addresses = &.{},
};

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
            log.err("Failed to set env {s}={s}: {s}", .{ name, value, c.strerror(@intFromEnum(std.posix.errno(result))) });
        }
    }
    env.put(name, value) catch |err| {
        log.err("Failed to set env {s}={s}: {any}", .{ name, value, err });
    };
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

pub fn isPortFree(address: ?String, port: u16) !bool {
    var check = try std.net.Address.parseIp4(address orelse "0.0.0.0", port);
    var server = check.listen(.{ .reuse_address = true }) catch |err| switch (err) {
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
                return try std.mem.concat(a, u8, &.{ path[0..length], concat_with });
            }
        } else {
            return std.os.windows.unexpectedError(std.os.windows.kernel32.GetLastError());
        }
    } else {
        _ = c.dl_iterate_phdr(callback, null);
    }
    return a.dupe(u8, so_path);
}

/// Wraps std.fs.selfExePathAlloc or gets argv[0] on Windows to workaround Wine bug
pub fn selfExePathAlloc(alloc: std.mem.Allocator) !String {
    if (builtin.os.tag == .windows) // Wine fails on realpath
    {
        var arg = try std.process.argsWithAllocator(alloc);
        defer arg.deinit();
        return alloc.dupe(u8, arg.next().?);
    } else {
        return std.fs.selfExePathAlloc(alloc);
    }
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

pub fn dupeSliceOfSlices(alloc: std.mem.Allocator, comptime t: type, input: []const []const t) ![]const []const t {
    var result = try alloc.alloc([]const t, input.len);
    for (0..input.len) |i| {
        result[i] = try alloc.dupe(t, input[i]);
    }
    return result;
}

pub fn dupeHashMap(comptime H: type, alloc: std.mem.Allocator, input: H) !H {
    var result = H.init(alloc);
    var iter = input.iterator();
    while (iter.next()) |item| {
        try result.put(item.key_ptr.*, item.value_ptr.*);
    }
    return result;
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

pub const CliArgsIterator = struct {
    i: usize = 0,
    s: String,
    pub fn next(self: *@This()) ?String {
        var token: ?String = null;
        if (self.i < self.s.len) {
            if (self.s[self.i] == '\"') {
                const end = std.mem.indexOfScalar(u8, self.s[self.i + 1 ..], '\"') orelse return null;
                token = self.s[self.i + 1 .. self.i + 1 + end];
                self.i += end + 2;
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
