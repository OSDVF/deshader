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
    gui.launcherGUI(@ptrCast(run)) catch |err| {
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
    if (builtin.os.tag == .windows) {
        @export(DllMain, .{
            .name = "DllMain",
        });
    } else {
        const i = &wrapErrorRunOnLoad;
        const f = &finalize;
        @export(i, .{ .name = "init_array", .section = ".init_array" });
        @export(f, .{ .name = "fini_array", .section = ".fini_array" });
    }
}

/// Mean to be called at Deshader shared library load
fn runOnLoad() !void {
    if (!common.initialized) { // races with the intercepted dlopen but should be on the same thread
        try common.init(); // init allocator and env
    }

    try loaders.loadGlLib(); // at least load gl lib to forward calls
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
        common.setenv(common.env_prefix ++ "EDITOR_SHOWN", "1");
        const preload = common.env.get("LD_PRELOAD") orelse "";
        var replaced = std.ArrayList(u8).init(common.allocator);
        var it = std.mem.splitAny(u8, preload, ": ");
        while (it.next()) |part| {
            if (std.mem.indexOf(u8, part, options.deshaderLibName) == null) {
                try replaced.appendSlice(part);
            }
        }
        common.setenv("LD_PRELOAD", replaced.items);
        const urlZ = try common.allocator.dupeZ(u8, url.?);
        defer common.allocator.free(urlZ);

        try gui.guiProcess(urlZ, "Deshader Editor");
        replaced.deinit();
        std.process.exit(0xde); // Do not continue to original program main()
    }

    if (loaders.ignored) {
        DeshaderLog.warn("This process is ignored", .{});
        return;
    }
    if (common.env.get(common.env_prefix ++ "HOOKED") == null) {
        common.setenv(common.env_prefix ++ "HOOKED", "1");
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

fn finalize() callconv(.C) void {
    DeshaderLog.info("Unloading Deshader library", .{});
    defer common.deinit();
    if (common.command_listener != null) {
        common.command_listener.?.stop();
        common.allocator.destroy(common.command_listener.?);
    }
    if (options.editor) {
        if (gui.gui_process != null) {
            gui.editorTerminate() catch |err| {
                DeshaderLog.err("{any}", .{err});
            };
        }
        if (gui.global_provider != null) {
            gui.serverStop() catch |err| {
                DeshaderLog.err("{any}", .{err});
            };
        }
    }
    if (!loaders.ignored and common.env.get(common.env_prefix ++ "HOOKED") == null) {
        shaders.deinitStatic();
    }
    loaders.deinit(); // also deinits gl_shaders
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
