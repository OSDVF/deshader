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
const path = std.fs.path;
const String = []const u8;
const c = @cImport({
    if (builtin.target.os.tag == .windows) {
        @cInclude("processthreadsapi.h");
        @cInclude("libloaderapi.h");
        @cInclude("windows.h");
        @cInclude("winuser.h");
        @cInclude("nfd.h");
    } else {
        if (builtin.os.tag == .linux) {
            @cInclude("gtk/gtk.h");
        }
        @cInclude("dlfcn.h");
        @cInclude("unistd.h");
    }
});
const common = @import("common");

const LauncherLog = std.log.scoped(.Launcher);
var specified_libs_dir: ?String = null;
const OriginalLibDir: ?String = switch (builtin.os.tag) {
    .macos => null,
    .linux => "/usr/lib",
    .windows => "C:\\Windows\\System32",
    else => @compileError("Unsupported OS"),
};
const DefaultDllNames = .{ "opengl32.dll", "vulkan-1.dll" };
var deshader_lib: std.DynLib = undefined;
var this_dir: String = undefined;
var gui = false;
var yes_to_replace = false;

pub fn main() !u8 {
    try common.init();
    const args = try std.process.argsAlloc(common.allocator);
    var next_arg: usize = 1;
    defer std.process.argsFree(common.allocator, args);

    const cwd = std.fs.cwd();
    var this_path_from_args = false;
    const this_path = std.fs.selfExePathAlloc(common.allocator) catch blk: {
        this_path_from_args = true;
        break :blk args[0]; //To workaround wine realpath() bug
    };
    defer if (!this_path_from_args) common.allocator.free(this_path);
    this_dir = path.dirname(this_path) orelse ".";

    //
    // Find Deshader
    //
    specified_libs_dir = common.env.get(common.env_prefix ++ "LIB_ROOT");
    if (specified_libs_dir) |s| { //convert to realpath
        specified_libs_dir = try cwd.realpathAlloc(common.allocator, s);
    }

    //
    // Parse args
    //
    gui = args.len <= 1;
    var version = false;

    var target_cwd: ?String = null;
    var whitelist = true;
    while (args.len > next_arg) {
        if (std.ascii.endsWithIgnoreCase(args[next_arg], "-help")) {
            try std.io.getStdErr().writeAll(
                \\Usage: deshader-run [options] <program> [args...]
                \\Options:
                \\  -y             Answer yes to all library symlink questions
                \\  -cwd <dir>     Set the current working directory for the target program
                \\  -version       Print the version of the Deshader library
                \\  -gui           Run with a GUI
                \\  -no-whitelist  Do not whitelist the target process for OpenGL interception
                \\  -help          Show this help
            );
            return 0;
        } else if (std.ascii.eqlIgnoreCase(args[next_arg], "-y")) {
            next_arg += 1;
            yes_to_replace = true;
        } else if (std.ascii.eqlIgnoreCase(args[next_arg], "-gui")) {
            next_arg += 1;
            gui = true;
        } else if (std.ascii.eqlIgnoreCase(args[next_arg], "-cwd")) {
            target_cwd = args[next_arg + 1];
            next_arg += 2;
        } else if (std.ascii.eqlIgnoreCase(args[next_arg], "-no-whitelist")) {
            whitelist = false;
            next_arg += 1;
        } else if (std.ascii.eqlIgnoreCase(args[next_arg], "-version")) {
            version = true;
            next_arg += 1;
        } else {
            break;
        }
    }

    //Exclude launcher process from deshader interception
    {
        const old_ignore_processes = common.env.get(common.env_prefix ++ "IGNORE_PROCESS");
        if (old_ignore_processes != null) {
            const merged = try std.fmt.allocPrint(common.allocator, "{s},{s}", .{ old_ignore_processes.?, this_path });
            defer common.allocator.free(merged);
            common.env.set(common.env_prefix ++ "IGNORE_PROCESS", merged);
            LauncherLog.debug("Setting DESHADER_IGNORE_PROCESS to {s}", .{merged});
        } else {
            common.env.set(common.env_prefix ++ "IGNORE_PROCESS", this_path);
            LauncherLog.debug("Setting DESHADER_IGNORE_PROCESS to {s}", .{this_path});
        }
    }

    var search = SearchPaths{};
    const deshader_lib_path = while (try search.next()) |lib_path| {
        LauncherLog.debug("Trying {s}", .{lib_path});
        deshader_lib = dlopenAbsolute(lib_path) catch {
            LauncherLog.info("Deshader not found at {s}: {s}", .{ lib_path, dlerror() });
            continue;
        };
        break lib_path;
    } else {
        LauncherLog.err("Failed to find deshader library", .{});
        return error.DeshaderNotFound;
    };

    defer deshader_lib.close();

    const previous_env_path = common.env.get("PATH") orelse "";
    if (builtin.os.tag == .windows) {
        const deshader_env_path = path.dirname(deshader_lib_path) orelse ".";
        const new_env_path = try std.mem.concat(common.allocator, u8, &.{ previous_env_path, ";", deshader_env_path });
        common.env.set("PATH", new_env_path);
        common.allocator.free(new_env_path);
    }

    if (version) {
        const deshaderVersion = deshader_lib.lookup(*const fn () [*:0]const u8, "deshaderVersion") orelse {
            LauncherLog.err("Could not find deshaderVersion symbol in the Deshader Library.", .{});
            return 2;
        };
        try std.io.getStdOut().writer().print("{s}\n", .{deshaderVersion()});
        return 0;
    }

    if (gui) {
        return runWithGUI();
    } else {
        if (whitelist) {
            // Whitelist only the target process
            const process_name = std.fs.path.basename(args[next_arg]);
            try common.env.appendList(common.env_prefix ++ "PROCESS", process_name);
            LauncherLog.debug("Setting DESHADER_PROCESS to {?s}", .{common.env.get(common.env_prefix ++ "PROCESS")});
        }
        var cond = std.Thread.Condition{};
        var mutex = std.Thread.Mutex{};
        try run(args[next_arg..], target_cwd, null, &cond, &mutex);
    }
    return 0;
}

fn symlinkLibToLib(cwd: std.fs.Dir, target_path: String, symlink_dir: String, dll_name: String, yes: bool) !void {
    var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const symlink_path = try path.join(common.allocator, &[_]String{ symlink_dir, dll_name });
    defer common.allocator.free(symlink_path);

    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    if (cwd.access(symlink_path, .{})) {
        LauncherLog.debug("Symlink at {s} already exists", .{symlink_path});
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
                try stdout.print("Do you want to replace file {s} by a symlink to {s} [y/N]?\n", .{ symlink_path, target_path });
                const input = try stdin.readUntilDelimiterOrEofAlloc(common.allocator, '\n', 10);
                if (input == null) break :blk true; //repeat
                defer common.allocator.free(input.?);
                if (std.ascii.toLower(input.?[0]) == 'y') break :blk false;
                if (std.ascii.toLower(input.?[0]) == 'n') return;
                break :blk true; //repeat
            }) {}
        }
        try std.posix.unlink(symlink_path);
    } else |err| {
        err catch {};
    }

    try common.symlinkOrCopy(cwd, target_path, symlink_path);
    LauncherLog.info("Created symlink at {s} to {s}", .{ symlink_path, target_path });
}

fn dlerror() if (builtin.os.tag == .windows) String else [*:0]const u8 {
    if (builtin.os.tag != .windows and builtin.link_libc) {
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
        LauncherLog.warn("{s}", .{buf_utf8[0..len]});
        return @tagName(err);
    }
}

fn dlopenAbsolute(p: String) !std.DynLib {
    if (builtin.os.tag == .windows) {
        const handle = try common.LoadLibraryEx(p, false);
        return std.DynLib{ .inner = .{ .dll = @ptrCast(handle) } };
    } else {
        return std.DynLib.open(p);
    }
}

/// `target_argv` includes program name as the first element
fn run(target_argv: []const String, working_dir: ?String, env: ?*std.BufMap, terminate: *std.Thread.Condition, terminate_mutex: *std.Thread.Mutex) anyerror!void {
    var deshader_path_buffer = try common.allocator.alloc(if (builtin.os.tag == .windows) u16 else u8, std.fs.MAX_NAME_BYTES);
    defer common.allocator.free(deshader_path_buffer);
    const deshader_path = switch (builtin.os.tag) {
        .windows => try std.unicode.utf16leToUtf8Alloc(common.allocator, try std.os.windows.GetModuleFileNameW(deshader_lib.inner.dll, @ptrCast(deshader_path_buffer), std.fs.max_path_bytes - 1)),
        .linux => resolve: {
            if (c.dlinfo(deshader_lib.inner.handle, c.RTLD_DI_ORIGIN, @ptrCast(deshader_path_buffer)) != 0) {
                const err = c.dlerror();
                LauncherLog.err("Failed to get deshader library path: {s}", .{err});
                return error.DeshaderPathResolutionFailed;
            }
            break :resolve try path.join(common.allocator, &[_]String{ deshader_path_buffer[0..std.mem.indexOfScalar(u8, deshader_path_buffer, 0).?], options.deshaderLibName });
        },
        .macos => resolve: {
            const version_symbol = deshader_lib.lookup(*const anyopaque, "deshaderVersion") orelse {
                LauncherLog.err("Could not find deshaderVersion symbol in the Deshader Library.", .{});
                return error.DeshaderVersionNotFound;
            };
            var info: c.Dl_info = undefined;
            if (c.dladdr(version_symbol, &info) == 0) {
                return error.DlAddr;
            } else {
                break :resolve try common.allocator.dupe(u8, std.mem.span(info.dli_fname));
            }
        },
        else => @compileError("Unsupported OS"),
    };
    defer common.allocator.free(deshader_path);

    LauncherLog.info("Using deshader at {s}", .{deshader_path});

    //
    // Start target
    //

    // Run the specified program with deshader
    const cwd = std.fs.cwd();
    var realpath_not_working = false;
    const target_realpath = cwd.realpathAlloc(common.allocator, target_argv[0]) catch |err| blk: {
        switch (err) {
            error.OutOfMemory => return err,
            error.Unexpected => {
                realpath_not_working = true;
                break :blk target_argv[0]; //To workaround wine bug
            },
            else => {
                LauncherLog.err("Program {s} not accessible: {any}", .{ target_argv[0], err });
            },
        }
        return err;
    };
    defer if (!realpath_not_working) common.allocator.free(target_realpath);
    var target = std.process.Child.init(target_argv, common.allocator);
    target.cwd_dir = if (working_dir) |w| if (std.fs.path.isAbsolute(w)) if (std.fs.openDirAbsolute(w, .{ .access_sub_paths = false }) catch null) |dir| dir else null else null else null;
    defer if (target.cwd_dir) |*d| d.close();

    if (env) |wanted_env| {
        var it = wanted_env.iterator();
        while (it.next()) |entry| {
            common.env.set(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    if (specified_libs_dir orelse OriginalLibDir) |dir| {
        common.env.set(common.env_prefix ++ "LIB_ROOT", dir);
        LauncherLog.debug("Setting DESHADER_LIB_ROOT to {s}", .{dir});
    }
    if (builtin.os.tag == .windows) {
        const symlink_dir = path.dirname(target_realpath) orelse ".";
        // Symlink deshader to this directory
        const deshader_dir = path.dirname(deshader_path) orelse ".";
        {
            const full_dir = try common.getFullPath(common.allocator, deshader_dir);
            defer common.allocator.free(full_dir);
            const full_symlinkdir = try common.getFullPath(common.allocator, symlink_dir);
            defer common.allocator.free(full_symlinkdir);
            if (!std.ascii.eqlIgnoreCase(full_dir, full_symlinkdir)) {
                try symlinkLibToLib(cwd, deshader_path, symlink_dir, options.deshaderLibName, yes_to_replace);

                inline for (options.dependencies) |lib| {
                    const target_path = try path.join(common.allocator, &.{ deshader_dir, lib });
                    defer common.allocator.free(target_path);
                    try symlinkLibToLib(cwd, target_path, symlink_dir, lib, yes_to_replace);
                }
            }
        }
        const local_deshader = try path.join(common.allocator, &[_]String{ symlink_dir, options.deshaderLibName });
        defer common.allocator.free(local_deshader);

        // DLL replacement: symlink opengl32.dll and vulkan-1.dll to the symlinked Deshader
        inline for (DefaultDllNames) |lib| {
            try symlinkLibToLib(cwd, local_deshader, symlink_dir, lib, yes_to_replace);
        }
        const extra_lib_paths = common.env.get(common.env_prefix ++ "HOOK_LIBS");
        if (extra_lib_paths) |eln| {
            var extra_lib_it = std.mem.splitScalar(u8, eln, ':');
            while (extra_lib_it.next()) |lib| {
                try symlinkLibToLib(cwd, local_deshader, symlink_dir, lib, yes_to_replace);
            }
        }
    } else {
        try common.env.appendList(common.env.library_preload, deshader_path);
    }
    target.env_map = common.env.getMap();
    target.stderr_behavior = .Inherit;
    target.stdout_behavior = .Inherit;
    target.stdin_behavior = .Inherit;
    try target.spawn();
    if (builtin.os.tag != .windows) {
        _ = c.setpgid(target.id, 0); // Put the target in its own process group
    }
    LauncherLog.info("Launched PID {d}", .{if (builtin.os.tag == .windows) c.GetProcessId(target.id) else target.id});

    var running = true;
    var target_watcher = try std.Thread.spawn(.{}, struct {
        fn spawn(ch: *std.process.Child, co: *std.Thread.Condition, m: *std.Thread.Mutex, r: *bool) !void {
            common.process.wailNoFailReport(ch);
            r.* = false;
            m.lock();
            defer m.unlock();
            co.broadcast();
        }
    }.spawn, .{ &target, terminate, terminate_mutex, &running });

    defer target_watcher.detach();

    // TODO cleanup

    // Wait for the target to finish or for the user to request termination
    terminate_mutex.lock();
    defer terminate_mutex.unlock();
    terminate.wait(terminate_mutex);

    if (running) { // If the target is still running (termination was requested), kill it
        if (builtin.os.tag == .windows) {
            _ = try target.kill();
        } else {
            try std.posix.kill(-target.id, std.posix.SIG.TERM); // Kill the entire process group
            std.time.sleep(std.time.ns_per_ms * 200); // Wait for the target to exit
            std.posix.kill(-target.id, std.posix.SIG.KILL) catch {};
        }
    }
}

fn browseFile() ?String {
    var out_path: [*:0]c.nfdchar_t = undefined;
    const result: c.nfdresult_t = c.NFD_OpenDialog(null, null, @ptrCast(&out_path));
    switch (result) {
        c.NFD_OKAY => return std.mem.span(out_path),
        c.NFD_CANCEL => return null,
        else => {
            LauncherLog.err("NFD error: {s}", .{std.mem.span(c.NFD_GetError())});
            return null;
        },
    }
}

fn runWithGUI() !u8 {
    if (builtin.os.tag == .windows) {
        _ = c.FreeConsole();
    }
    // Run the GUI
    const deshaderLauncherGUI = deshader_lib.lookup(*const fn (*const anyopaque) void, "deshaderLauncherGUI") orelse {
        LauncherLog.err("Could not find Deshader GUI startup function", .{});
        return 1;
    };
    deshaderLauncherGUI(@ptrCast(&run));
    return 0;
}

const SearchPaths = struct {
    i: usize = 0,

    pub fn next(self: *@This()) !?String {
        self.i += 1;
        switch (self.i - 1) {
            0 => return common.env.get(common.env_prefix ++ "LIB") orelse return self.next(), // DESHADER_LIB as absolute path
            1 => return try std.fs.path.join(common.allocator, &.{ common.env.get(common.env_prefix ++ "LIB") orelse return self.next(), options.deshaderLibName }), // DESHADER_LIB as directory
            2 => { // libdeshader.so in cwd
                if (std.fs.cwd().access(options.deshaderLibName, .{})) {
                    return try common.getFullPath(common.allocator, options.deshaderLibName);
                } else |_| {
                    return self.next();
                }
            },
            3 => return try std.fs.path.join(common.allocator, &.{ this_dir, options.deshaderRelativeRoot, options.deshaderLibName }), // RPATH-like relative path
            4 => return options.deshaderLibName, // Just the library name
            5 => { // Pick from system directories
                if (gui) {
                    const err = "Failed to load Deshader library. Specify its location in environment variable DESHADER_LIB. Would you like to find it now?";
                    switch (builtin.os.tag) {
                        .windows => {
                            const result = c.MessageBoxA(null, err, "Deshader Error", c.MB_OK | c.MB_ICONERROR);
                            if (result == c.IDOK) {
                                return browseFile() orelse self.next();
                            }
                        },
                        .linux => {
                            // TODO show open file dialog
                            _ = c.gtk_init_check(null, null);
                            _ = c.gtk_message_dialog_new(null, c.GTK_DIALOG_MODAL, c.GTK_MESSAGE_ERROR, c.GTK_BUTTONS_OK, err);
                        },
                        else => {},
                    }
                }
                // orelse next
                return self.next();
            },
            else => return null,
        }
    }
};
