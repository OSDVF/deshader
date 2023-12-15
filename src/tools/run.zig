const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const path = std.fs.path;
const String = []const u8;
const c = @cImport({
    if (builtin.target.os.tag != .windows) @cInclude("dlfcn.h");
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

pub fn main() !u8 {
    try common.init();
    const args = try std.process.argsAlloc(common.allocator);
    defer std.process.argsFree(common.allocator, args);
    var errors: u8 = 0;
    if (args.len <= 1) {
        RunLogger.info("Program not specified", .{});
        return errors;
    }

    const cwd = std.fs.cwd();

    specified_libs_dir = common.env.get("DESHADER_LIB_ROOT");
    if (specified_libs_dir == null) {
        specified_libs_dir = OriginalLibDir;
    } else {
        specified_libs_dir = try cwd.realpathAlloc(common.allocator, specified_libs_dir.?);
    }

    //Exclude runner process from deshader interception
    {
        const old_ignore_processes = common.env.get("DESHADER_IGNORE_PROCESS");
        const this_path = try std.fs.selfExePathAlloc(common.allocator);
        defer common.allocator.free(this_path);
        if (old_ignore_processes != null) {
            const merged = try std.fmt.allocPrint(common.allocator, "{s},{s}", .{ old_ignore_processes.?, this_path });
            defer common.allocator.free(merged);
            common.setenv("DESHADER_IGNORE_PROCESS", merged);
        } else {
            common.setenv("DESHADER_IGNORE_PROCESS", this_path);
        }
    }

    const deshader_lib_name = common.env.get("DESHADER_LIB") orelse options.deshaderLibRoot ++ std.fs.path.sep_str ++ options.deshaderLibName;
    var deshader_lib: std.DynLib = std.DynLib.open(deshader_lib_name) catch fallback: {
        const lib_name_in_dir = try std.fs.path.join(common.allocator, &.{ common.env.get("DESHADER_LIB") orelse options.deshaderLibRoot, options.deshaderLibName });
        defer common.allocator.free(lib_name_in_dir);
        break :fallback std.DynLib.open(lib_name_in_dir);
    } catch
        fallback: {
        if (builtin.os.tag == .linux and builtin.link_libc) {
            RunLogger.debug("Failed to open global deshader: {s}", .{c.dlerror()});
        }
        const at_cwd = cwd.realpathAlloc(common.allocator, deshader_lib_name) catch {
            if (builtin.os.tag == .linux and builtin.link_libc) {
                RunLogger.debug("Failed to open deshader at CWD: {s}", .{deshader_lib_name});
            }

            break :fallback std.DynLib.open(try path.join(common.allocator, &[_]String{ specified_libs_dir.?, deshader_lib_name })) catch {
                if (builtin.os.tag == .linux and builtin.link_libc) {
                    RunLogger.err("Failed to open deshader at DESHADER_LIB_ROOT: {s}", .{c.dlerror()});
                }
                errors += 1;
                return errors;
            };
        };
        break :fallback try std.DynLib.open(at_cwd);
    };
    defer deshader_lib.close();
    var deshader_path_buffer = try common.allocator.alloc(if (builtin.os.tag == .windows) u16 else u8, std.fs.MAX_NAME_BYTES);
    var deshader_dir_name: String = undefined;
    defer common.allocator.free(deshader_path_buffer);

    if (builtin.os.tag == .windows) {
        deshader_dir_name = try std.unicode.utf16leToUtf8Alloc(common.allocator, try std.os.windows.GetModuleFileNameW(deshader_lib.dll, @ptrCast(deshader_path_buffer), std.fs.MAX_PATH_BYTES - 1));
    } else {
        if (c.dlinfo(deshader_lib.handle, c.RTLD_DI_ORIGIN, @ptrCast(deshader_path_buffer)) != 0) {
            const err = c.dlerror();
            RunLogger.err("Failed to get deshader library path: {s}", .{err});
            errors += 1;
            return errors;
        }
    }
    const deshader_path = if (builtin.target.os.tag == .windows) deshader_dir_name else try path.join(common.allocator, &[_]String{ deshader_path_buffer[0..std.mem.indexOfScalar(u8, deshader_path_buffer, 0).?], options.deshaderLibName });
    defer common.allocator.free(deshader_path);

    RunLogger.info("Using deshader at {s}", .{deshader_path});

    if (args.len >= 2) {
        // Run the specified program with deshader
        const target_program = args[1];
        cwd.access(target_program, .{}) catch |err| {
            RunLogger.err("Program {s} not accessible {any}", .{ target_program, err });
            errors += 1;
            return errors;
        };
        var child = std.ChildProcess.init(args[1..], common.allocator);
        var child_envs = try std.process.getEnvMap(common.allocator);
        defer child_envs.deinit();
        {
            try child_envs.put("DESHADER_LIB_ROOT", specified_libs_dir.?);
            RunLogger.debug("Setting DESHADER_LIB_ROOT to {s}", .{specified_libs_dir.?});
        }
        if (builtin.os.tag != .windows) {
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
