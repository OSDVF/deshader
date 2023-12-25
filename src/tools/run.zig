const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const path = std.fs.path;
const String = []const u8;
const c = @cImport({
    if (builtin.target.os.tag == .windows) {
        @cInclude("processthreadsapi.h");
        @cInclude("libloaderapi.h");
    } else @cInclude("dlfcn.h");
});
const common = @import("../common.zig");

const RunLogger = std.log.scoped(.DeshaderRun);
var specified_libs_dir: ?String = null;
const OriginalLibDir = switch (builtin.os.tag) {
    .macos => "/usr/lib",
    .linux => "/usr/lib",
    .windows => "C:\\Windows\\System32",
    else => unreachable,
};
const DefaultDllNames = .{ "opengl32.dll", "vulkan-1.dll" };
var yes = false;

pub fn main() !u8 {
    try common.init();
    const args = try std.process.argsAlloc(common.allocator);
    var next_arg: usize = 1;
    defer std.process.argsFree(common.allocator, args);
    if (args.len <= 1) {
        RunLogger.info("Program not specified", .{});
        return 1;
    }
    if (std.ascii.eqlIgnoreCase(args[next_arg], "-y")) {
        next_arg += 1;
        yes = true;
    }

    const cwd = std.fs.cwd();
    var this_path_from_args = false;
    const this_path = std.fs.selfExePathAlloc(common.allocator) catch blk: {
        this_path_from_args = true;
        break :blk args[0]; //To workaround wine realpath() bug
    };
    defer if (!this_path_from_args) common.allocator.free(this_path);
    const this_dirname = path.dirname(this_path);

    //Exclude runner process from deshader interception
    {
        const old_ignore_processes = common.env.get(common.env_prefix ++ "IGNORE_PROCESS");
        if (old_ignore_processes != null) {
            const merged = try std.fmt.allocPrint(common.allocator, "{s},{s}", .{ old_ignore_processes.?, this_path });
            defer common.allocator.free(merged);
            common.setenv(common.env_prefix ++ "IGNORE_PROCESS", merged);
            RunLogger.debug("Setting DESHADER_IGNORE_PROCESS to {s}", .{merged});
        } else {
            common.setenv(common.env_prefix ++ "IGNORE_PROCESS", this_path);
            RunLogger.debug("Setting DESHADER_IGNORE_PROCESS to {s}", .{this_path});
        }
    }

    //
    // Find Deshader
    //
    specified_libs_dir = common.env.get(common.env_prefix ++ "LIB_ROOT");
    if (specified_libs_dir == null) {
        specified_libs_dir = OriginalLibDir;
    } else {
        specified_libs_dir = try cwd.realpathAlloc(common.allocator, specified_libs_dir.?);
    }
    const deshader_lib_name = common.env.get(common.env_prefix ++ "LIB") orelse try std.fs.path.join(common.allocator, &.{ this_dirname orelse ".", options.deshaderRelativeRoot, options.deshaderLibName });

    const previous_env_path = common.env.get("PATH") orelse "";
    if (builtin.os.tag == .windows) {
        const deshader_env_path = path.dirname(deshader_lib_name) orelse ".";
        const new_env_path = try std.mem.concat(common.allocator, u8, &.{ previous_env_path, ";", deshader_env_path });
        common.setenv("PATH", new_env_path);
        common.allocator.free(new_env_path);
    }

    var deshader_lib: std.DynLib = dlopenAbsolute(deshader_lib_name) catch fallback: {
        const lib_name_in_dir = try path.join(common.allocator, &.{ common.env.get(common.env_prefix ++ "LIB") orelse options.deshaderRelativeRoot, options.deshaderLibName });
        defer common.allocator.free(lib_name_in_dir);
        break :fallback dlopenAbsolute(lib_name_in_dir);
    } catch
        fallback: {
        RunLogger.debug("Failed to open global deshader: {s}", .{dlerror()});
        const at_cwd = cwd.realpathAlloc(common.allocator, deshader_lib_name) catch {
            RunLogger.debug("Failed to find deshader at CWD: {s}", .{deshader_lib_name});

            const new_env_path = try std.mem.concat(common.allocator, u8, &.{ previous_env_path, ";", specified_libs_dir.? });
            defer common.allocator.free(new_env_path);
            common.setenv("PATH", new_env_path);

            break :fallback dlopenAbsolute(try path.join(common.allocator, &[_]String{ specified_libs_dir.?, deshader_lib_name })) catch {
                RunLogger.err("Failed to open deshader at {s} (DESHADER_LIB_ROOT): {s}", .{ specified_libs_dir.?, dlerror() });
                return error.DeshaderNotFound;
            };
        };

        break :fallback dlopenAbsolute(at_cwd) catch {
            RunLogger.err("Failed to load deshader at {s}: {s}", .{ at_cwd, dlerror() });
            return error.DeshaderNotFound;
        };
    };
    defer deshader_lib.close();
    var deshader_path_buffer = try common.allocator.alloc(if (builtin.os.tag == .windows) u16 else u8, std.fs.MAX_NAME_BYTES);
    var deshader_or_dir_name: String = undefined;
    defer common.allocator.free(deshader_path_buffer);

    if (builtin.os.tag == .windows) {
        deshader_or_dir_name = try std.unicode.utf16leToUtf8Alloc(common.allocator, try std.os.windows.GetModuleFileNameW(deshader_lib.dll, @ptrCast(deshader_path_buffer), std.fs.MAX_PATH_BYTES - 1));
    } else {
        if (c.dlinfo(deshader_lib.handle, c.RTLD_DI_ORIGIN, @ptrCast(deshader_path_buffer)) != 0) {
            const err = c.dlerror();
            RunLogger.err("Failed to get deshader library path: {s}", .{err});
            return error.DeshaderPathResolutionFailed;
        }
    }
    const deshader_path = if (builtin.target.os.tag == .windows) deshader_or_dir_name else try path.join(common.allocator, &[_]String{ deshader_path_buffer[0..std.mem.indexOfScalar(u8, deshader_path_buffer, 0).?], options.deshaderLibName });
    defer common.allocator.free(deshader_path);

    RunLogger.info("Using deshader at {s}", .{deshader_path});

    //
    // Start target
    //

    if (args.len >= 2) {
        // Run the specified program with deshader
        var realpath_not_working = false;
        const target_program = args[next_arg];
        const target_realpath = cwd.realpathAlloc(common.allocator, target_program) catch |err| blk: {
            switch (err) {
                error.OutOfMemory => return err,
                error.Unexpected => {
                    realpath_not_working = true;
                    break :blk target_program; //To workaround wine bug
                },
                else => {
                    RunLogger.err("Program {s} not accessible: {any}", .{ target_program, err });
                },
            }
            return err;
        };
        defer if (!realpath_not_working) common.allocator.free(target_realpath);
        var child = std.process.Child.init(args[next_arg..], common.allocator);
        var child_envs = try std.process.getEnvMap(common.allocator);
        defer child_envs.deinit();
        {
            try child_envs.put(common.env_prefix ++ "LIB_ROOT", specified_libs_dir.?);
            RunLogger.debug("Setting DESHADER_LIB_ROOT to {s}", .{specified_libs_dir.?});
        }
        if (builtin.os.tag == .windows) {
            const symlink_dir = path.dirname(target_realpath) orelse ".";
            // Symlink deshader to this directory
            try symlinkLibToLib(cwd, deshader_path, symlink_dir, options.deshaderLibName);
            const local_deshader = try path.join(common.allocator, &[_]String{ symlink_dir, options.deshaderLibName });
            defer common.allocator.free(local_deshader);

            // DLL replacement: symlink opengl32.dll and vulkan-1.dll to the symlinked Deshader
            inline for (DefaultDllNames) |lib| {
                try symlinkLibToLib(cwd, local_deshader, symlink_dir, lib);
            }
            const extra_lib_names = common.env.get(common.env_prefix ++ "HOOK_LIBS");
            if (extra_lib_names) |eln| {
                var extra_lib_it = std.mem.splitScalar(u8, eln, ',');
                while (extra_lib_it.next()) |lib| {
                    try symlinkLibToLib(cwd, local_deshader, symlink_dir, lib);
                }
            }
            const deshader_dir = path.dirname(deshader_path) orelse ".";
            inline for (options.dependencies) |lib| {
                const target_path = try path.join(common.allocator, &.{ deshader_dir, lib });
                defer common.allocator.free(target_path);
                try symlinkLibToLib(cwd, target_path, symlink_dir, lib);
            }
        } else {
            const insert_libraries_var = switch (builtin.os.tag) {
                .macos => "DYLD_INSERT_LIBRARIES",
                .linux => "LD_PRELOAD",
                else => unreachable,
            };
            const old_ld_preload = child_envs.get(insert_libraries_var);
            const ld_preload = if (old_ld_preload != null) try std.fmt.allocPrint(common.allocator, "{s} {s}", .{ old_ld_preload.?, deshader_path }) else deshader_path;
            defer if (old_ld_preload != null) common.allocator.free(ld_preload);

            try child_envs.put(insert_libraries_var, ld_preload);
        }
        child.env_map = &child_envs;
        child.stderr_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stdin_behavior = .Inherit;
        try child.spawn();
        RunLogger.info("Launched PID {d}", .{if (builtin.os.tag == .windows) c.GetProcessId(child.id) else child.id});

        switch (try child.wait()) {
            .Exited => |status| {
                if (status != 0) {
                    RunLogger.err("Target process exited with status {d}", .{status});
                }
            },
            .Signal => |signal| {
                RunLogger.err("Target process terminated with signal {d}", .{signal});
            },
            .Stopped => |signal| {
                RunLogger.err("Target process stopped with signal {d}", .{signal});
            },
            .Unknown => |result| {
                RunLogger.err("Target process terminated with unknown result {d}", .{result});
            },
        }

        // TODO cleanup
    }
    return 0;
}

fn symlinkLibToLib(cwd: std.fs.Dir, target_path: String, symlink_dir: String, dll_name: String) !void {
    var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const symlink_path = try path.join(common.allocator, &[_]String{ symlink_dir, dll_name });
    defer common.allocator.free(symlink_path);

    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    if (cwd.access(symlink_path, .{})) {
        RunLogger.debug("Symlink at {s} already exists", .{symlink_path});
        if (cwd.readLink(symlink_path, &buffer)) |previous_target| {
            if (std.mem.eql(u8, previous_target, target_path)) {
                try stdout.print("Symlink at {s} to {s} already exists\n", .{ symlink_path, previous_target });
            } else {
                while (!yes and blk: {
                    try stdout.print("Do you want to replace symlink at {s} to {s} by Deshader [y/N]?\n", .{ symlink_path, previous_target });
                    const input = try stdin.readUntilDelimiterOrEofAlloc(common.allocator, '\n', 10);
                    if (input == null) break :blk true; //repeat
                    defer common.allocator.free(input.?);
                    if (std.ascii.toLower(input.?[0]) == 'y') break :blk false;
                    if (std.ascii.toLower(input.?[0]) == 'n') return;
                    break :blk true; //repeat
                }) {}
            }
        } else |err| {
            err catch {};

            while (!yes and blk: {
                try stdout.print("Do you want to replace file {s} by a symlink to Deshader [y/N]?\n", .{symlink_path});
                const input = try stdin.readUntilDelimiterOrEofAlloc(common.allocator, '\n', 10);
                if (input == null) break :blk true; //repeat
                defer common.allocator.free(input.?);
                if (std.ascii.toLower(input.?[0]) == 'y') break :blk false;
                if (std.ascii.toLower(input.?[0]) == 'n') return;
                break :blk true; //repeat
            }) {}
        }
        try std.os.unlink(symlink_path);
    } else |err| {
        err catch {};
    }

    try common.symlinkOrCopy(cwd, target_path, symlink_path);
    RunLogger.info("Created symlink at {s} to {s}", .{ symlink_path, target_path });
}

fn dlerror() if (builtin.os.tag == .windows) String else [*:0]const u8 {
    if (builtin.os.tag == .linux and builtin.link_libc) {
        return c.dlerror();
    } else {
        const err = std.os.windows.kernel32.GetLastError();
        // 614 is the length of the longest windows error description
        var buf_wstr: [614]u16 = undefined;
        var buf_utf8: [614]u8 = undefined;
        const len = std.os.windows.kernel32.FormatMessageW(
            std.os.windows.FORMAT_MESSAGE_FROM_SYSTEM | std.os.windows.FORMAT_MESSAGE_IGNORE_INSERTS,
            null,
            err,
            (std.os.windows.LANG.NEUTRAL << 10) | std.os.windows.SUBLANG.DEFAULT,
            &buf_wstr,
            buf_wstr.len,
            null,
        );
        _ = std.unicode.utf16leToUtf8(&buf_utf8, buf_wstr[0..len]) catch unreachable;
        RunLogger.warn("{s}", .{buf_utf8[0..len]});
        return @tagName(err);
    }
}

fn dlopenAbsolute(p: String) !std.DynLib {
    if (builtin.os.tag == .windows) {
        const handle = try common.LoadLibraryEx(p, false);
        return std.DynLib{ .dll = @ptrCast(handle) };
    } else {
        return std.DynLib.open(p);
    }
}
