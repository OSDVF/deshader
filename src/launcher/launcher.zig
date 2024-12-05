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
const args = @import("args");
const analysis = @import("analysis.zig");
const gui = @import("gui.zig");
const common = @import("common");

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

const log = std.log.scoped(.Launcher);
const OriginalLibDir: ?String = switch (builtin.os.tag) {
    .macos => null,
    .linux => "/usr/lib",
    .windows => "C:\\Windows\\System32",
    else => @compileError("Unsupported OS"),
};
const DefaultDllNames = .{ "opengl32.dll", "vulkan-1.dll" };
var deshader_lib: std.DynLib = undefined;
var this_dir: String = undefined;
var will_show_gui = false;
var yes_to_replace = false;
var specified_libs_dir: ?String = null;
var specified_deshader_path: ?String = null;

pub fn main() !u8 {
    try common.init();
    defer common.deinit();
    if (common.env.get(gui.DESHADER_GUI_URL)) |url| {
        try gui.guiProcess(url, "Deshader Editor");
        return 0;
    }

    var cli_args = try args.parseForCurrentProcess(struct {
        commands: ?String = "",
        directory: ?String = null,
        deshader: ?String = null,
        editor: bool = true,
        gui: bool = false,
        help: bool = false,
        libs: ?String = null,
        lsp: ?String = "",
        port: ?u16 = 0,
        replace: bool = false,
        version: bool = false,
        whitelist: bool = true,

        pub const shorthands = .{
            .c = "commands",
            .D = "directory",
            .d = "deshader",
            .e = "editor",
            .g = "gui",
            .h = "help",
            .L = "libs",
            .l = "lsp",
            .p = "port",
            .y = "replace",
            .v = "version",
            .w = "whitelist",
        };
    }, common.allocator, .print);
    defer cli_args.deinit();

    if (cli_args.options.commands) |cm| if (cm.len == 0) {
        cli_args.options.commands = common.env.get(common.env_prefix ++ "COMMANDS") orelse common.default_ws_url;
    };
    if (cli_args.options.lsp) |l| if (l.len == 0) {
        cli_args.options.lsp = common.env.get(common.env_prefix ++ "LSP") orelse common.default_lsp_url;
    };
    if (cli_args.options.port) |p| if (p == 0) {
        cli_args.options.port = get_port: {
            if (common.env.get(common.env_prefix ++ "PORT")) |portString| {
                if (std.fmt.parseInt(u16, portString, 10)) |parsedPort| {
                    break :get_port parsedPort;
                } else |err| {
                    log.err("Invalid port: {any}. Using default 8080", .{err});
                }
            }
            break :get_port 8080;
        };
    };

    const cwd = std.fs.cwd();
    var this_path_from_args = false;
    const this_path = std.fs.selfExePathAlloc(common.allocator) catch blk: {
        this_path_from_args = true;
        break :blk cli_args.executable_name.?; //To workaround wine realpath() bug
    };
    defer if (!this_path_from_args) common.allocator.free(this_path);
    this_dir = path.dirname(this_path) orelse ".";

    yes_to_replace = cli_args.options.replace;
    specified_deshader_path = cli_args.options.deshader orelse common.env.get(common.env_prefix ++ "LIB");

    // Show gui when no arguments are provided
    cli_args.options.editor = isYes(common.env.get(common.env_prefix ++ "GUI")) or cli_args.options.editor or (cli_args.positionals.len == 0 and cli_args.raw_start_index == null);
    will_show_gui = cli_args.options.gui or cli_args.options.editor;

    if (cli_args.options.gui) {
        return runWithGUI();
    } else {
        if (cli_args.options.help or (!will_show_gui and cli_args.positionals.len == 0)) {
            try std.io.getStdErr().writer().print(
                \\Usage: deshader-run [options] <program> [args...]
                \\Options:
                \\  -c, --commands <uri>    Set the URI for the commands protocol (default {s}) (fallback to env DESHADER_WS)
                \\  -D, --directory <dir>   Set the working directory for the target program
                \\  -d, --deshader <path>   Set the path to the Deshader library (fallback to env DESHADER_LIB)
                \\  -e, --editor            Show Editor GUI (default when run without arguments)
                \\  -g, --gui               Show configuration GUI
                \\  -h, --help              Show this help
                \\  -L, --libs <dir>        Set the directory for the libraries (fallback to env DESHADER_LIB_ROOT)
                \\  -l, --lsp <uri>         GLSL Language Server URI (protocol, IP and port) (default {s}) (fallback to env DESHADER_LSP)
                \\  -p, --port <port>       Port for Editor GUI (default 8080) (fallback to env DESHADER_PORT)
                \\  -v, --version           Print the version of the Deshader library and exit
                \\  -w, --whitelist <y/n>   Whitelist the target process for Deshader operation (default)
                \\  -y, --replace           Answer yes to all library replacement questions
                \\
            , .{ common.default_lsp_url, common.default_ws_url });
            return 0;
        }

        specified_libs_dir = cli_args.options.libs orelse common.env.get(common.env_prefix ++ "LIB_ROOT");
        if (specified_libs_dir) |s| { //convert to realpath
            specified_libs_dir = try cwd.realpathAlloc(common.allocator, s);
        }

        //Exclude launcher process from deshader interception
        try common.env.appendList(common.env_prefix ++ "IGNORE_PROCESS", this_path);

        var search = SearchPaths{};
        const deshader_lib_path = while (try search.nextAlloc()) |lib_path| {
            log.debug("Trying {s}", .{lib_path});
            deshader_lib = dlopenAbsolute(lib_path) catch {
                log.info("Deshader not found at {s}: {s}", .{ lib_path, dlerror() });
                common.allocator.free(lib_path);
                continue;
            };
            break lib_path;
        } else {
            log.err("Failed to find deshader library", .{});
            return error.DeshaderNotFound;
        };
        defer common.allocator.free(deshader_lib_path);

        defer deshader_lib.close();

        if (builtin.os.tag == .windows) {
            try common.env.appendListWith("PATH", path.dirname(deshader_lib_path) orelse ".", ";");
        }

        if (cli_args.options.version) {
            const deshaderVersion = deshader_lib.lookup(*const fn () [*:0]const u8, "deshaderVersion") orelse {
                log.err("Could not find deshaderVersion symbol in the Deshader Library.", .{});
                return 2;
            };
            try std.io.getStdOut().writer().print("{s}\n", .{deshaderVersion()});
            return 0;
        }

        //
        // Start background services
        //

        // Language Server
        if (cli_args.options.lsp) |lsp| {
            const uri = std.Uri.parse(lsp) catch |e| fallback: {
                log.err("Could not parse LSP URL: {}, using default {s}", .{ e, common.default_lsp_url });
                break :fallback std.Uri{ .port = common.default_lsp_port_n, .scheme = "ws" };
            };
            const h = if (uri.host) |ho| try std.fmt.allocPrint(common.allocator, "{raw}", .{ho}) else null;
            defer if (h) |ho| common.allocator.free(ho);
            const p = uri.port orelse common.default_lsp_port_n;
            if (try common.isPortFree(h, p)) {
                try analysis.serverStart(p); // TODO obey host specification
            } else {
                log.err("Could not start LSP on port {d}", .{lsp});
            }
        }

        // Editor GUI
        if (cli_args.options.editor) {
            try gui.editorShow(cli_args.options.port.?, cli_args.options.commands, cli_args.options.lsp);
        }

        if (cli_args.positionals.len > 0) {
            if (cli_args.options.whitelist) {
                // Whitelist only the target process
                const process_name = std.fs.path.basename(cli_args.positionals[0]);
                try common.env.appendList(common.env_prefix ++ "PROCESS", process_name);
                log.debug("Setting DESHADER_PROCESS to {?s}", .{common.env.get(common.env_prefix ++ "PROCESS")});
            }

            if (cli_args.options.commands) |uri| {
                common.env.set(common.env_prefix ++ "COMMANDS", uri);
            }

            //
            // Start the target process
            //

            var deshader_path_buffer = try common.allocator.alloc(if (builtin.os.tag == .windows) u16 else u8, std.fs.MAX_NAME_BYTES);
            defer common.allocator.free(deshader_path_buffer);
            const deshader_path = switch (builtin.os.tag) {
                .windows => try std.unicode.utf16leToUtf8Alloc(common.allocator, try std.os.windows.GetModuleFileNameW(deshader_lib.inner.dll, @ptrCast(deshader_path_buffer), std.fs.max_path_bytes - 1)),
                .linux => resolve: {
                    if (c.dlinfo(deshader_lib.inner.handle, c.RTLD_DI_ORIGIN, @ptrCast(deshader_path_buffer)) != 0) {
                        const err = c.dlerror();
                        log.err("Failed to get deshader library path: {s}", .{err});
                        return error.DeshaderPathResolutionFailed;
                    }
                    break :resolve try path.join(common.allocator, &[_]String{ deshader_path_buffer[0..std.mem.indexOfScalar(u8, deshader_path_buffer, 0).?], options.deshaderLibName });
                },
                .macos => resolve: {
                    const version_symbol = deshader_lib.lookup(*const anyopaque, "deshaderVersion") orelse {
                        log.err("Could not find deshaderVersion symbol in the Deshader Library.", .{});
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

            log.info("Using deshader at {s}", .{deshader_path});

            //
            // Start target
            //

            // Run the specified program with deshader
            var realpath_not_working = false;
            const target_realpath = cwd.realpathAlloc(common.allocator, cli_args.positionals[0]) catch |err| blk: {
                switch (err) {
                    error.OutOfMemory => return err,
                    error.Unexpected => {
                        realpath_not_working = true;
                        break :blk cli_args.positionals[0]; //To workaround wine bug
                    },
                    else => {
                        log.err("Program {s} not accessible: {any}", .{ cli_args.positionals[0], err });
                    },
                }
                return err;
            };
            defer if (!realpath_not_working) common.allocator.free(target_realpath);
            var target = std.process.Child.init(cli_args.positionals, common.allocator);
            target.cwd_dir = if (cli_args.options.directory) |w| if (std.fs.path.isAbsolute(w)) if (std.fs.openDirAbsolute(w, .{ .access_sub_paths = false }) catch null) |dir| dir else null else null else null;
            defer if (target.cwd_dir) |*d| d.close();

            if (specified_libs_dir orelse OriginalLibDir) |dir| {
                common.env.set(common.env_prefix ++ "LIB_ROOT", dir);
                log.debug("Setting DESHADER_LIB_ROOT to {s}", .{dir});
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
            log.info("Launched PID {d}", .{if (builtin.os.tag == .windows) c.GetProcessId(target.id) else target.id});

            var running = true;
            var terminate = std.Thread.Condition{};
            var terminate_mutex = std.Thread.Mutex{};
            var target_watcher = try std.Thread.spawn(.{}, struct {
                fn spawn(ch: *std.process.Child, co: *std.Thread.Condition, m: *std.Thread.Mutex, r: *bool) !void {
                    common.process.wailNoFailReport(ch);
                    r.* = false;
                    m.lock();
                    defer m.unlock();
                    co.broadcast();
                }
            }.spawn, .{ &target, &terminate, &terminate_mutex, &running });

            defer target_watcher.detach();

            // Controller thread
            var controller_thread = try std.Thread.spawn(.{}, struct {
                fn controller(
                    co: *std.Thread.Condition,
                    m: *std.Thread.Mutex,
                    run: *bool,
                    cli: @TypeOf(cli_args),
                ) !void {
                    var stdin = std.io.getStdIn().reader();
                    var buffer: [1024]u8 = undefined;
                    while (run.*) {
                        if (try stdin.readUntilDelimiterOrEof(&buffer, '\n')) |n| {
                            if (std.ascii.eqlIgnoreCase(n, "q")) {
                                m.lock();
                                defer m.unlock();
                                co.broadcast();
                                gui.editorTerminate() catch {};
                            } else if (std.ascii.eqlIgnoreCase(n, "e")) {
                                gui.editorShow(cli.options.port.?, cli.options.commands, cli.options.lsp) catch {};
                            }
                        }
                    }
                }
            }.controller, .{ &terminate, &terminate_mutex, &running, cli_args });
            controller_thread.detach();

            // Wait for the target to finish or for the user to request termination
            terminate_mutex.lock();
            defer terminate_mutex.unlock();
            terminate.wait(&terminate_mutex);

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
        if (cli_args.options.editor) {
            gui.editorWait() catch {};
            gui.serverStop() catch {};
        }
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
        log.debug("Symlink at {s} already exists", .{symlink_path});
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
    log.info("Created symlink at {s} to {s}", .{ symlink_path, target_path });
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
        log.warn("{s}", .{buf_utf8[0..len]});
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
fn browseFile() ?String {
    var out_path: [*:0]c.nfdchar_t = undefined;
    const result: c.nfdresult_t = c.NFD_OpenDialog(null, null, @ptrCast(&out_path));
    switch (result) {
        c.NFD_OKAY => return std.mem.span(out_path),
        c.NFD_CANCEL => return null,
        else => {
            log.err("NFD error: {s}", .{std.mem.span(c.NFD_GetError())});
            return null;
        },
    }
}

fn runWithGUI() !u8 {
    if (builtin.os.tag == .windows) {
        _ = c.FreeConsole();
    }
    // Run the GUI
    try launcherGUI();
    return 0;
}

const SearchPaths = struct {
    i: usize = 0,

    pub fn nextAlloc(self: *@This()) !?String {
        self.i += 1;
        switch (self.i - 1) {
            0 => return try common.allocator.dupe(u8, specified_deshader_path orelse return self.nextAlloc()), // DESHADER_LIB as absolute path
            1 => return try std.fs.path.join(common.allocator, &.{ specified_deshader_path orelse return self.nextAlloc(), options.deshaderLibName }), // DESHADER_LIB as directory
            2 => { // libdeshader.so in cwd
                if (std.fs.cwd().access(options.deshaderLibName, .{})) {
                    return try common.getFullPath(common.allocator, options.deshaderLibName);
                } else |_| {
                    return self.nextAlloc();
                }
            },
            3 => return try std.fs.path.join(common.allocator, &.{ this_dir, options.deshaderRelativeRoot, options.deshaderLibName }), // RPATH-like relative path
            4 => return try common.allocator.dupe(u8, options.deshaderLibName), // Just the library name
            5 => { // Pick from system directories
                if (will_show_gui) {
                    const err = "Failed to load Deshader library. Specify its location in environment variable DESHADER_LIB. Would you like to find it now?";
                    switch (builtin.os.tag) {
                        .windows => {
                            const result = c.MessageBoxA(null, err, "Deshader Error", c.MB_OK | c.MB_ICONERROR);
                            if (result == c.IDOK) {
                                return browseFile() orelse self.nextAlloc();
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
                return self.nextAlloc();
            },
            else => return null,
        }
    }
};

fn isYes(s: ?String) bool {
    return if (s) |ys| std.ascii.eqlIgnoreCase(ys, "yes") or std.ascii.eqlIgnoreCase(ys, "y") or std.mem.eql(u8, ys, "1") else false;
}

pub fn launcherGUI() !void {
    const content = @embedFile("launcher.html");
    const result_len = std.base64.standard.Encoder.calcSize(content.len);
    const preamble = "data:text/html;base64,";
    const result = try common.allocator.alloc(u8, result_len + preamble.len);
    defer common.allocator.free(result);

    @memcpy(result[0..preamble.len], preamble);
    _ = std.base64.standard.Encoder.encode(result[preamble.len..], content);

    try gui.guiProcess(result, "Deshader Launcher");
}
