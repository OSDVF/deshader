const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const c = @cImport({
    @cInclude("stdlib.h"); //setenv or _putenv_s
    @cInclude("string.h"); //strerror
    if (builtin.os.tag == .windows) {
        @cInclude("windows.h");
        @cInclude("libloaderapi.h");
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

/// Gets the path of the Deshader DLL
pub fn selfDllPathAlloc(a: std.mem.Allocator, concat_with: String) !String {
    var path: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var hm: [*c]c.struct_HINSTANCE__ = undefined;
    if (c.GetModuleHandleExW(c.GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
        c.GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, @ptrCast(&options.version), &hm) != 0)
    {
        const length = c.GetModuleFileNameA(hm, &path, std.fs.MAX_PATH_BYTES);
        if (length == 0) {
            return std.os.windows.unexpectedError(std.os.windows.kernel32.GetLastError());
        } else {
            return try std.mem.concat(a, u8, &.{ path[0..length], concat_with });
        }
    } else {
        return std.os.windows.unexpectedError(std.os.windows.kernel32.GetLastError());
    }

    return path;
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
