const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const path = std.fs.path;
const String = []const u8;
const c = @cImport({
    @cInclude("link.h");
    @cInclude("dlfcn.h");
});

const RunLogger = std.log.scoped(.DeshaderRun);
const PathContainer = [std.fs.MAX_PATH_BYTES - 2:0]u8;
var deshader_path: []u8 = undefined;
var allocator: std.mem.Allocator = undefined;
var specified_libs_dir: ?String = null;
const OriginalLibDir = switch (builtin.os.tag) {
    .macos => "/usr/lib",
    .linux => "/usr/lib",
    .windows => "C:\\Windows\\System32",
    else => unreachable,
};

fn processLibrary(lib_name: String, target_dir: *std.fs.Dir, pending_symlinks: *std.ArrayList(String)) !?String {
    var buffer: [*:0]u8 = try allocator.create(PathContainer);
    defer allocator.free(@as(*[std.fs.MAX_PATH_BYTES - 1:0]u8, @ptrCast(buffer)));
    if (specified_libs_dir == null) {
        @memcpy(buffer, lib_name);
        buffer[lib_name.len] = 0;
    } else {
        _ = try std.fmt.bufPrintZ(@as(*PathContainer, @ptrCast(buffer)), "{s}{s}{s}", .{ specified_libs_dir.?, path.sep_str, lib_name });
    }
    const absolute_lib_name = std.mem.span(buffer);
    const other_lib = std.DynLib.open(absolute_lib_name) catch |err| {
        RunLogger.err("Failed to open library {s}: {any}", .{ absolute_lib_name, err });
        return null;
    };
    if (c.dlinfo(other_lib.handle, c.RTLD_DI_ORIGIN, buffer) != 0) {
        const err = c.dlerror();
        RunLogger.err("Failed to get library path for {s}: {s}", .{ lib_name, err });
        return null;
    }
    const lib_dir_slice = try allocator.dupe(u8, std.mem.span(buffer));
    var lib_path_or_symlink = try std.fs.path.join(allocator, &[_]String{ lib_dir_slice, lib_name });
    // Also resolve symlinked libraries
    var lib_paths: []const String = &[_]String{lib_path_or_symlink};
    var buffer2: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    if (std.fs.readLinkAbsolute(lib_path_or_symlink, &buffer2)) |target| {
        lib_paths = &[_]String{ lib_path_or_symlink, try std.fs.path.resolve(allocator, &[_]String{ lib_dir_slice, target }) };
    } else |err| {
        _ = err catch {};
    }

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    const answers = enum { y, n, other };

    for (lib_paths) |lib_path| {
        const lib_basename = path.basename(lib_path);
        // If the file does not exist, we will create a symlink to it.
        if (target_dir.access(lib_basename, .{})) {
            RunLogger.debug("File {s} already in library directory", .{lib_basename});
            if (target_dir.readLink(lib_basename, &buffer2)) |target| {
                if (std.mem.eql(u8, try target_dir.realpathAlloc(allocator, target), deshader_path)) {
                    RunLogger.debug("Symlink for {s} already exists", .{lib_basename});
                    return lib_dir_slice;
                } else {
                    RunLogger.warn("Symlink for {s} already exists, but points to {s}.", .{ lib_basename, target });
                    try stdout.print("Replace symlink for {s} with symlink to Deshader? Y/n\n", .{lib_basename});
                    var input = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 10);
                    if (input != null) {
                        defer allocator.free(input.?);
                        _ = std.ascii.lowerString(input.?, input.?);
                        switch (std.meta.stringToEnum(answers, input.?) orelse .other) {
                            .n => return null,
                            else => {},
                        }
                        try target_dir.deleteFile(lib_basename);
                    }
                }
            } else |err| {
                RunLogger.warn("Failed to read link for {s}: {any}.", .{ lib_basename, err });
                try stdout.print("Replace file {s} with symlink to Deshader? Y/n\n", .{lib_basename});
                var input = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 10);
                if (input != null) {
                    defer allocator.free(input.?);
                    input = std.ascii.lowerString(input.?, input.?);
                    switch (std.meta.stringToEnum(answers, input.?) orelse .other) {
                        .n => return null,
                        else => {},
                    }
                    try target_dir.deleteFile(lib_basename);
                }
            }
        } else |err| {
            // Dir.access also reports error.FileNotFound for broken symlinks
            RunLogger.debug("File {s} not accesible in library directory: {any}", .{ lib_basename, err });
            if (target_dir.readLink(lib_basename, &buffer2)) |target| {
                if (target_dir.access(target, .{})) {
                    RunLogger.err("Symlink for {s} already exists, but points to inaccessible {s}.", .{ lib_basename, target });
                } else |err2| {
                    _ = err2 catch {};
                    const abs = try path.join(allocator, &[_]String{ try target_dir.realpath(".", &buffer2), target });
                    defer allocator.free(abs);
                    try std.os.unlink(abs);
                }
            } else |err2| {
                _ = err2 catch {};
            }
        }
        try pending_symlinks.append(try allocator.dupe(u8, lib_basename));
    }
    return lib_dir_slice;
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    allocator = gpa.allocator();
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var errors: u8 = 0;
    if (args.len <= 1) {
        RunLogger.info("Program not specified. Only performing library symlinks", .{});
    }

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    const cwd = std.fs.cwd();

    const target_lib_dir_name = try cwd.realpathAlloc(allocator, env.get("DESHADER_REPLACE_ROOT") orelse ".");
    defer allocator.free(target_lib_dir_name);
    specified_libs_dir = env.get("DESHADER_LIB_ROOT");
    if (specified_libs_dir == null) {
        specified_libs_dir = OriginalLibDir;
    } else {
        specified_libs_dir = try cwd.realpathAlloc(allocator, specified_libs_dir.?);
    }

    const deshader_lib_name = env.get("DESHADER_LIB") orelse options.deshaderLibName;
    var deshader_lib: std.DynLib = std.DynLib.open(deshader_lib_name) catch
        fallback: {
        if (builtin.os.tag == .linux and builtin.link_libc) {
            RunLogger.debug("Failed to open deshader at CWD: {s}", .{c.dlerror()});
        }
        break :fallback std.DynLib.open(try path.join(allocator, &[_]String{ target_lib_dir_name, deshader_lib_name })) catch
            fallback2: {
            if (builtin.os.tag == .linux and builtin.link_libc) {
                RunLogger.debug("Failed to open deshader at DESHADER_REPLACE_ROOT: {s}", .{c.dlerror()});
            }
            break :fallback2 std.DynLib.open(try path.join(allocator, &[_]String{ specified_libs_dir.?, deshader_lib_name })) catch {
                if (builtin.os.tag == .linux and builtin.link_libc) {
                    RunLogger.err("Failed to open deshader at DESHADER_LIB_ROOT: {s}", .{c.dlerror()});
                }
                errors += 1;
                return errors;
            };
        };
    };
    defer deshader_lib.close();
    const deshader_dir_name: [*:0]u8 = try allocator.create(PathContainer);
    defer allocator.free(@as(*[std.fs.MAX_PATH_BYTES - 1:0]u8, @ptrCast(deshader_dir_name)));

    var target_lib_dir = try cwd.openDir(target_lib_dir_name, .{ .no_follow = true });
    defer target_lib_dir.close();
    RunLogger.debug("Using target replacement directory {s}", .{target_lib_dir_name});

    if (c.dlinfo(deshader_lib.handle, c.RTLD_DI_ORIGIN, deshader_dir_name) != 0) {
        const err = c.dlerror();
        RunLogger.err("Failed to get deshader library path: {s}", .{err});
        errors += 1;
        return errors;
    }
    const deshader_dir_name_span = std.mem.span(deshader_dir_name);
    deshader_path = try path.join(allocator, &[_]String{ deshader_dir_name_span, options.deshaderLibName });
    defer allocator.free(deshader_path);

    RunLogger.info("Using deshader at {s}", .{deshader_path});
    var original_libs_dir: ?String = null;

    if (builtin.os.tag != .macos) {
        var pending_symlinks = std.ArrayList(String).init(allocator);
        defer pending_symlinks.deinit();

        inline for (options.ICDLibNames) |lib_name| {
            const next_original_lib_dir = try processLibrary(lib_name, &target_lib_dir, &pending_symlinks);
            if (next_original_lib_dir != null) {
                if (original_libs_dir == null) {
                    original_libs_dir = next_original_lib_dir;
                } else if (!std.mem.eql(u8, next_original_lib_dir.?, original_libs_dir.?)) {
                    RunLogger.info("{s} original location {s} differs from the first resolved {s}", .{ lib_name, next_original_lib_dir.?, original_libs_dir.? });
                }
            }
        }
        const runtime_custom_libs = env.get("DESHADER_HOOK_LIBS");
        if (runtime_custom_libs != null) {
            var it = std.mem.splitScalar(u8, runtime_custom_libs.?, ',');
            while (it.next()) |lib| {
                _ = try processLibrary(lib, &target_lib_dir, &pending_symlinks);
            }
        }

        // Symlink missing libraries
        if (pending_symlinks.items.len > 0) {
            for (pending_symlinks.items) |item| {
                try stdout.print("{s}\n", .{item});
            }
            try stdout.print("Pending {d} libraries to symlink\n", .{pending_symlinks.items.len});
            try stdout.print("Approve? Y/n\n", .{});
            const input = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 10);
            if (input != null) {
                defer allocator.free(input.?);
                _ = std.ascii.lowerString(input.?, input.?);
                const answers = enum { y, n, other };
                switch (std.meta.stringToEnum(answers, input.?) orelse .other) {
                    .n => return errors,
                    else => {},
                }
                for (pending_symlinks.items) |lib| {
                    target_lib_dir.symLink(deshader_path, lib, .{}) catch |err| {
                        RunLogger.err("Failed to symlink {s}: {any}", .{ lib, err });
                        errors += 1;
                    };
                }
            }
        }
    }

    if (original_libs_dir == null) {
        RunLogger.err("No original library found", .{});
        errors += 1;
        return errors;
    }

    if (args.len >= 2) {
        // Run the specified program with deshader
        const target_program = args[1];
        cwd.access(target_program, .{}) catch |err| {
            RunLogger.err("Program {s} not accessible {any}", .{ target_program, err });
            errors += 1;
            return errors;
        };
        var child = std.ChildProcess.init(args[1..], allocator);
        var child_envs = try std.process.getEnvMap(allocator);
        defer child_envs.deinit();
        {
            const result_lib_root = original_libs_dir orelse OriginalLibDir;
            try child_envs.put("DESHADER_LIB_ROOT", result_lib_root);
            RunLogger.debug("Setting DESHADER_LIB_ROOT to {s}", .{result_lib_root});
        }
        if (builtin.os.tag != .windows) {
            const insert_libraries_var = switch (builtin.os.tag) {
                .macos => "DYLD_INSERT_LIBRARIES",
                .linux => "LD_LIBRARY_PATH",
                else => unreachable,
            };
            const old_ld_path = child_envs.get(insert_libraries_var);
            const target_lib_dir_path = if (builtin.os.tag == .macos) deshader_path else try target_lib_dir.realpathAlloc(allocator, ".");
            var ld_path = target_lib_dir_path;
            defer allocator.free(ld_path);
            if (old_ld_path != null) {
                ld_path = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ target_lib_dir_path, ld_path });
            }
            try child_envs.put(insert_libraries_var, ld_path);
        }
        child.env_map = &child_envs;
        child.stderr_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stdin_behavior = .Inherit;
        const term = try child.spawnAndWait();
        switch (term) {
            .Exited => |status| {
                if (status != 0) {
                    RunLogger.err("Child process exited with status {d}", .{status});
                    errors += 1;
                }
            },
            .Signal => |signal| {
                RunLogger.err("Child process terminated with signal {d}", .{signal});
                errors += 1;
            },
            .Stopped => |signal| {
                RunLogger.err("Child process stopped with signal {d}", .{signal});
                errors += 1;
            },
            .Unknown => |result| {
                RunLogger.err("Child process terminated with unknown result {d}", .{result});
                errors += 1;
            },
        }
    }
    return errors;
}
