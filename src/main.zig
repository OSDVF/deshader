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

//! Contains:
//! Code that will be executed upon library load
//! Public symbols for interaction with Deshader library (shader tagging etc.)

const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const positron = @import("positron");
const gl = @import("gl");
const vulkan = @import("vulkan");
const DeshaderLog = @import("log.zig").DeshaderLog;
const common = @import("common.zig");
const commands = @import("commands.zig");
const gl_shaders = @import("interceptors/gl_shaders.zig");
const shaders = @import("services/shaders.zig");
const shader_decls = @import("declarations/shaders.zig");

const loaders = @import("interceptors/loaders.zig");
const transitive = @import("interceptors/transitive.zig");
const gui = if (options.editor) @import("tools/gui.zig") else null;

const String = []const u8;

//
// Public API
//

/// Defines logging options for the whole library
pub const std_options = @import("log.zig").std_options;
const err_format = "{s}: {any}";

const SourcesPayload = shader_decls.SourcesPayload;
const ProgramPayload = shader_decls.ProgramPayload;
const ExistsBehavior = shader_decls.ExistsBehavior;

pub export fn deshaderEditorServerStart() usize {
    if (options.editor) {
        gui.serverStart(common.command_listener) catch |err| {
            DeshaderLog.err(err_format, .{ @src().fn_name, err });
            if (@errorReturnTrace()) |trace|
                std.debug.dumpStackTrace(trace.*);
            return @intFromError(err);
        };
    }
    return 0;
}

pub export fn deshaderEditorServerStop() usize {
    if (options.editor) {
        gui.serverStop() catch |err| {
            DeshaderLog.err(err_format, .{ @src().fn_name, err });
            if (@errorReturnTrace()) |trace|
                std.debug.dumpStackTrace(trace.*);
            return @intFromError(err);
        };
    }
    return 0;
}

pub export fn deshaderEditorWindowShow() usize {
    DeshaderLog.debug("Show editor window", .{});

    if (common.selfExePathAlloc(common.allocator)) |exe_path| {
        const exe_basename = std.fs.path.basename(exe_path);
        const whitelist_env = common.env_prefix ++ "PROCESS";
        // add to whitelist
        if (common.env.get(whitelist_env)) |whitelist| {
            if (std.mem.indexOf(u8, whitelist, exe_basename) == null) {
                DeshaderLog.debug("Adding {s} to process whitelist", .{exe_basename});
                common.env.appendList(whitelist_env, exe_basename) catch {};
            }
        }

        // remove from blacklist
        const blacklist_env = common.env_prefix ++ "PROCESS_IGNORE";
        if (common.env.get(blacklist_env)) |blacklist| {
            if (std.mem.indexOf(u8, blacklist, exe_basename) != null) {
                DeshaderLog.debug("Removing {s} from process blacklist", .{exe_basename});
                common.env.removeList(blacklist_env, exe_basename) catch {};
            }
        }
    } else |err| {
        DeshaderLog.err("Failed to get exe path: {any}", .{err});
    }

    if (options.editor) {
        gui.editorShow(common.command_listener) catch |err| {
            DeshaderLog.err(err_format, .{ @src().fn_name, err });
            if (@errorReturnTrace()) |trace|
                std.debug.dumpStackTrace(trace.*);
            return @intFromError(err);
        };
        return 0;
    }
    return 1;
}

pub export fn deshaderEditorWindowWait() usize {
    if (options.editor) {
        gui.editorWait() catch |err| {
            DeshaderLog.err(err_format, .{ @src().fn_name, err });
            if (@errorReturnTrace()) |trace|
                std.debug.dumpStackTrace(trace.*);
            return @intFromError(err);
        };
        return 0;
    }
    return 1;
}

pub export fn deshaderEditorWindowTerminate() usize {
    if (options.editor) {
        gui.editorTerminate() catch |err| {
            DeshaderLog.err(err_format, .{ @src().fn_name, err });
            if (@errorReturnTrace()) |trace|
                std.debug.dumpStackTrace(trace.*);
            return @intFromError(err);
        };
        return 0;
    }
    return 1;
}

pub export fn deshaderFreeList(list: [*]const [*:0]const u8, count: usize) void {
    for (list[0..count]) |item| {
        common.allocator.free(std.mem.span(item));
    }
    common.allocator.free(list[0..count]);
}

pub export fn deshaderListPrograms(path: [*:0]const u8, recursive: bool, count: *usize, physical: bool, postfix: ?[*:0]const u8) ?[*]const [*:0]const u8 {
    const result = gl_shaders.current.Programs.listTagged(common.allocator, std.mem.span(path), recursive, physical, if (postfix) |n| std.mem.span(n) else null) catch return null;
    count.* = result.len;
    return result.ptr;
}

pub export fn deshaderListSources(path: [*:0]const u8, recursive: bool, count: *usize, physical: bool, postfix: ?[*:0]const u8) ?[*]const [*:0]const u8 {
    const result = gl_shaders.current.Shaders.listTagged(common.allocator, std.mem.span(path), recursive, physical, if (postfix) |n| std.mem.span(n) else null) catch return null;
    count.* = result.len;
    return result.ptr;
}

/// If `program` == 0, then list all programs. Else list shader stages of a particular program
pub export fn deshaderListProgramsUntagged(count: *usize, ref_or_root: usize, nested_postfix: ?[*:0]const u8) ?[*]const [*:0]const u8 {
    const result = gl_shaders.current.Programs.listUntagged(common.allocator, ref_or_root, if (nested_postfix) |n| std.mem.span(n) else null) catch return null;
    count.* = result.len;
    return @ptrCast(result);
}

pub export fn deshaderListSourcesUntagged(count: *usize, ref_or_root: usize, nested_postfix: ?[*:0]const u8) ?[*]const [*:0]const u8 {
    const result = gl_shaders.current.Shaders.listUntagged(common.allocator, ref_or_root, if (nested_postfix) |n| std.mem.span(n) else null) catch return null;
    count.* = result.len;
    return @ptrCast(result);
}

pub export fn deshaderRemovePath(path: [*:0]const u8, dir: bool) usize {
    gl_shaders.current.Shaders.untag(std.mem.span(path), dir) catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        if (@errorReturnTrace()) |trace|
            std.debug.dumpStackTrace(trace.*);
        return @intFromError(err);
    };
    return 0;
}

pub export fn deshaderRemoveSource(ref: usize) usize {
    gl_shaders.current.Shaders.remove(ref) catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        if (@errorReturnTrace()) |trace|
            std.debug.dumpStackTrace(trace.*);
        return @intFromError(err);
    };
    return 0;
}

// # Shader tagging
// Deshader creates a virtual file system for better management of you shaders. Use these functions to assign filesystem locations to your shaders and specify dependencies between them. Call them just before you call `glShaderSource` or similar functions.

/// path cannot contain '>'
pub export fn deshaderTagSource(ref: usize, part_index: usize, path: [*:0]const u8, if_exists: ExistsBehavior) usize {
    gl_shaders.current.Shaders.assignTag(ref, part_index, std.mem.span(path), if_exists) catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        if (@errorReturnTrace()) |trace|
            std.debug.dumpStackTrace(trace.*);
        return @intFromError(err);
    };
    return 0;
}

/// Set a physical folder as a workspace for shader sources
pub export fn deshaderPhysicalWorkspace(virtual: [*:0]const u8, physical: [*:0]const u8) usize {
    _ = _try: {
        gl_shaders.current.mapPhysicalToVirtual(std.mem.span(physical), shaders.GenericLocator.parse(std.mem.span(virtual)) catch |err| break :_try err) catch |err| break :_try err;
    } catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        if (@errorReturnTrace()) |trace|
            std.debug.dumpStackTrace(trace.*);
        return @intFromError(err);
    };
    return 0;
}

pub export fn deshaderTaggedProgram(payload: ProgramPayload, behavior: ExistsBehavior) usize {
    gl_shaders.current.programCreateUntagged(payload) catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        if (@errorReturnTrace()) |trace|
            std.debug.dumpStackTrace(trace.*);
        return @intFromError(err);
    };
    gl_shaders.current.Programs.assignTag(payload.ref, 0, std.mem.span(payload.path.?), behavior) catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        if (@errorReturnTrace()) |trace|
            std.debug.dumpStackTrace(trace.*);
        return @intFromError(err);
    };
    return 0;
}

pub export fn deshaderTaggedSource(payload: SourcesPayload, if_exists: ExistsBehavior) usize {
    std.debug.assert(payload.count == 1);
    std.debug.assert(payload.paths != null);
    gl_shaders.current.sourcesCreateUntagged(payload) catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        if (@errorReturnTrace()) |trace|
            std.debug.dumpStackTrace(trace.*);
        return @intFromError(err);
    };
    for (0..payload.count) |i| {
        if (payload.paths.?[i]) |path| {
            gl_shaders.current.Programs.assignTag(payload.ref, i, std.mem.span(path), if_exists) catch |err| {
                DeshaderLog.err(err_format, .{ @src().fn_name, err });
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpStackTrace(trace.*);
                return @intFromError(err);
            };
        }
    }
    return 0;
}

/// Not meant to be called externally by any other program than Deshader Launcher Tool. The launcher callback parameters are zig objects which cannot be handled in C
pub export fn deshaderLauncherGUI(run: *const anyopaque) void {
    gui.launcherGUI(@alignCast(@ptrCast(run))) catch |err| {
        DeshaderLog.err("Launcher GUI Error {}", .{err});
    };
}

pub export fn deshaderVersion() [*:0]const u8 {
    return options.version;
}

//
// Startup logic
//
pub fn DllMain(instance: std.os.windows.HINSTANCE, reason: std.os.windows.DWORD, reserved: std.os.windows.LPVOID) callconv(std.os.windows.WINAPI) std.os.windows.BOOL {
    _ = instance;
    _ = reserved;

    if (builtin.os.tag == .windows) {
        const windows = @cImport(if (builtin.os.tag == .windows) @cInclude("windows.h"));
        switch (reason) {
            windows.DLL_PROCESS_ATTACH => wrapErrorRunOnLoad(),
            windows.DLL_PROCESS_DETACH => finalize(),
            else => {},
        }
    }
    return std.os.windows.TRUE;
}
comptime {
    switch (builtin.os.tag) {
        .windows => @export(DllMain, .{
            .name = "DllMain",
        }),
        .macos => {
            const i = &wrapErrorRunOnLoad;
            const f = &finalize;
            @export(i, .{ .name = "__init", .section = "__DATA,__mod_init_func" });
            @export(f, .{ .name = "__term", .section = "__DATA,__mod_term_func" });
        },
        else => {
            const i = &wrapErrorRunOnLoad;
            const f = &finalize;
            @export(i, .{ .name = "init_array", .section = ".init_array" });
            @export(f, .{ .name = "fini_array", .section = ".fini_array" });
        },
    }
}

/// Mean to be called at Deshader shared library load
fn runOnLoad() !void {
    if (!common.initialized) { // races with the intercepted dlopen but should be on the same thread
        try common.init(); // init allocator and env
    }

    try loaders.loadGlLib(); // at least load gl lib to forward calls. This must be done to ensure any host program has usable GL
    try transitive.TransitiveSymbols.loadOriginal();

    if (!loaders.ignored) {
        // maybe it was not checked yet
        loaders.checkIgnoredProcess();
    }

    // Should the library instance in this process serve as the GUI subprocess?
    const url = common.env.get(gui.DESHADER_GUI_URL);
    if (builtin.os.tag != .windows and url != null and common.env.get(common.env_prefix ++ "EDITOR_SHOWN") == null) {
        if (loaders.ignored) {
            DeshaderLog.warn("This GUI process is ignored", .{});
            return;
        }
        common.env.set(common.env_prefix ++ "EDITOR_SHOWN", "1");
        const preload = common.env.get("LD_PRELOAD") orelse "";
        var replaced = std.ArrayList(u8).init(common.allocator);
        var it = std.mem.splitAny(u8, preload, ": ");
        while (it.next()) |part| {
            if (std.mem.indexOf(u8, part, options.deshaderLibName) == null) {
                try replaced.appendSlice(part);
            }
        }
        common.env.set("LD_PRELOAD", replaced.items);

        try gui.guiProcess(url.?, "Deshader Editor");
        replaced.deinit();
        std.process.exit(0xde); // Do not continue to original program main()
    }

    if (loaders.ignored) {
        DeshaderLog.info("This process is ignored", .{});
        return;
    }
    if (common.env.get(common.env_prefix ++ "HOOKED") == null) {
        common.env.set(common.env_prefix ++ "HOOKED", "1");
    } else {
        return;
    }
    try shaders.initStatic(common.allocator);

    const commands_port_string_http = common.env.get(common.env_prefix ++ "COMMANDS_HTTP");
    const commands_port_string_ws: ?String = common.env.get(common.env_prefix ++ "COMMANDS_WS") orelse common.default_ws_port;
    const port_string_lsp = common.env.get(common.env_prefix ++ "LSP");
    const commands_port_http = if (commands_port_string_http) |s| std.fmt.parseInt(u16, s, 10) catch blk: {
        DeshaderLog.info("Specified HTTP commands port is not a number. Server won't start.", .{});
        break :blk null;
    } else null;
    const commands_port_ws = if (commands_port_string_ws) |s| std.fmt.parseInt(u16, s, 10) catch blk: {
        DeshaderLog.info("Specified WS commands port is not a number. Server won't start.", .{});
        break :blk null;
    } else null;
    const port_lsp = if (port_string_lsp) |p| std.fmt.parseInt(u16, p, 10) catch try std.fmt.parseInt(u16, common.default_lsp_port, 10) else null;
    // HTTP port is always open
    common.command_listener = try commands.CommandListener.start(common.allocator, commands_port_http, commands_port_ws, port_lsp);
    DeshaderLog.debug("Commands HTTP port {?d}", .{commands_port_http});
    DeshaderLog.debug("Commands WS port {?d}", .{commands_port_ws});
    if (port_lsp != null) {
        DeshaderLog.debug("Language server port {d}", .{port_lsp.?});
    }

    const server_at_startup = common.env.get(common.env_prefix ++ "START_SERVER") orelse "0";
    const ll = try std.ascii.allocLowerString(common.allocator, server_at_startup);
    defer common.allocator.free(ll);
    const opts = enum { yes, no, @"1", @"0", true, false, unknown };
    switch (std.meta.stringToEnum(opts, ll) orelse .unknown) {
        .yes, .@"1", .true => {
            _ = deshaderEditorServerStart();
        },
        .no, .@"0", .false => {},
        .unknown => {
            DeshaderLog.warn("Invalid value for DESHADER_START_SERVER: {s}", .{server_at_startup});
        },
    }

    const editor_at_startup = common.env.get(common.env_prefix ++ "GUI") orelse "0";
    const l = try std.ascii.allocLowerString(common.allocator, editor_at_startup);
    defer common.allocator.free(l);
    switch (std.meta.stringToEnum(opts, l) orelse .unknown) {
        .yes, .@"1", .true => {
            _ = deshaderEditorWindowShow();
        },
        .no, .@"0", .false => {},
        .unknown => {
            DeshaderLog.warn("Invalid value for DESHADER_GUI: {s}", .{editor_at_startup});
        },
    }
}

/// Will be called upon Deshader library unload
fn finalize() callconv(.C) void {
    // Inlining is disabled because Zig would otherwise optimize out all the conditions in release mode (compiler bug?)
    @call(.never_inline, DeshaderLog.debug, .{ "Unloading Deshader library", .{} });
    defer @call(.never_inline, common.deinit, .{});
    if (common.command_listener != null) {
        @call(.never_inline, commands.CommandListener.stop, .{common.command_listener.?});
        @call(.never_inline, std.mem.Allocator.destroy, .{ common.allocator, common.command_listener.? });
    }
    if (options.editor) {
        if (gui.gui_process != null) {
            @call(.never_inline, gui.editorTerminate, .{}) catch |err| {
                @call(.never_inline, DeshaderLog.err, .{ "{any}", .{err} });
            };
        }
        if (gui.global_provider != null) {
            @call(.never_inline, gui.serverStop, .{}) catch |err| {
                @call(.never_inline, DeshaderLog.err, .{ "{any}", .{err} });
            };
        }
    }
    if (!loaders.ignored) {
        @call(.never_inline, shaders.deinitStatic, .{});
    }
    @call(.never_inline, loaders.deinit, .{}); // also deinits gl_shaders

}

/// Will be called upon Deshader library load and BEFORE the host application's main()
fn wrapErrorRunOnLoad() callconv(.C) void {
    runOnLoad() catch |err| {
        DeshaderLog.err("Initialization error: {any}", .{err});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
    };
}
