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
const shaders = @import("services/shaders.zig");
const shader_decls = @import("declarations/shaders.zig");

const loaders = @import("interceptors/loaders.zig");
const transitive = @import("interceptors/transitive.zig");
const editor = if (options.embedEditor) @import("tools/editor.zig") else null;

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
    if (options.embedEditor) {
        editor.serverStart(command_listener) catch |err| {
            DeshaderLog.err(err_format, .{ @src().fn_name, err });
            return @intFromError(err);
        };
    }
    return 0;
}

pub export fn deshaderEditorServerStop() usize {
    if (options.embedEditor) {
        editor.serverStop() catch |err| {
            DeshaderLog.err(err_format, .{ @src().fn_name, err });
            return @intFromError(err);
        };
    }
    return 0;
}

pub export fn deshaderEditorWindowShow() usize {
    if (options.embedEditor) {
        editor.windowShow(command_listener) catch |err| {
            DeshaderLog.err(err_format, .{ @src().fn_name, err });
            return @intFromError(err);
        };
        return 0;
    }
    return 1;
}

pub export fn deshaderEditorWindowWait() usize {
    if (options.embedEditor) {
        editor.windowWait() catch |err| {
            DeshaderLog.err(err_format, .{ @src().fn_name, err });
            return @intFromError(err);
        };
        return 0;
    }
    return 1;
}

pub export fn deshaderEditorWindowTerminate() usize {
    if (options.embedEditor) {
        editor.windowTerminate() catch |err| {
            DeshaderLog.err(err_format, .{ @src().fn_name, err });
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

pub export fn deshaderListPrograms(include_untagged: bool, path: [*:0]const u8, count: *usize) ?[*]const [*:0]const u8 {
    const result = shaders.Programs.list(include_untagged, std.mem.span(path)) catch return null;
    count.* = result.len;
    return @ptrCast(result);
}

pub export fn deshaderListSources(include_untagged: bool, path: [*:0]const u8, count: *usize) ?[*]const [*:0]const u8 {
    const result = shaders.Shaders.list(include_untagged, std.mem.span(path)) catch return null;
    count.* = result.len;
    return @ptrCast(result);
}

pub export fn deshaderRemovePath(path: [*:0]const u8, dir: bool) usize {
    shaders.Shaders.removePath(std.mem.span(path), dir) catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        return @intFromError(err);
    };
    return 0;
}

pub export fn deshaderRemoveSource(ref: usize) usize {
    shaders.Shaders.remove(ref) catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        return @intFromError(err);
    };
    return 0;
}

pub export fn deshaderTagSource(ref: usize, part_index: usize, path: [*:0]const u8, if_exists: ExistsBehavior) usize {
    shaders.Shaders.assignTag(ref, part_index, std.mem.span(path), if_exists) catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        return @intFromError(err);
    };
    return 0;
}

/// Link shader source code to a file in physical workspace
pub export fn deshaderLinkSource(ref: usize, part_index: usize, path: [*:0]const u8) usize {
    _ = path;
    _ = part_index;
    _ = ref;
    //TODO
    return 0;
}

/// Set a physical folder as a workspace for shader sources
/// ALl calls to deshaderSourceLink will expect paths relative to this folder
pub export fn deshaderPhysicalWorkspace(path: [*:0]const u8) usize {
    _ = path;
    //TODO
    return 0;
}

pub export fn deshaderTaggedProgram(payload: ProgramPayload, behavior: ExistsBehavior) usize {
    shaders.programCreateUntagged(payload) catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        return @intFromError(err);
    };
    shaders.Programs.assignTag(payload.ref, 0, std.mem.span(payload.path.?), behavior) catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        return @intFromError(err);
    };
    return 0;
}

pub export fn deshaderTaggedSource(payload: SourcesPayload, if_exists: ExistsBehavior) usize {
    std.debug.assert(payload.count == 1);
    std.debug.assert(payload.paths != null);
    shaders.sourcesCreateUntagged(payload) catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        return @intFromError(err);
    };
    for (0..payload.count) |i| {
        shaders.Programs.assignTag(payload.ref, i, std.mem.span(payload.paths.?[i]), if_exists) catch |err| {
            DeshaderLog.err(err_format, .{ @src().fn_name, err });
            return @intFromError(err);
        };
    }
    return 0;
}

//
// Private logic
//

export const init_array linksection(".init_array") = &wrapErrorRunOnLoad;
export const fini_array linksection(".fini_array") = &finalize;
pub var command_listener: ?*commands.CommandListener = null;

/// Run this functions at Deshader shared library load
fn runOnLoad() !void {
    try common.init(); // init allocator and env
    if (!loaders.ignored) {
        // maybe it was not checked yet
        loaders.checkIgnoredProcess();
    }

    // Should this be the editor subprocess?
    const url = common.env.get(editor.DESHADER_EDITOR_URL);
    if (url != null and common.env.get("DESHADER_EDITOR_SHOWN") == null) {
        common.setenv("DESHADER_EDITOR_SHOWN", "1");
        // Prevent recursive hooking
        common.setenv("DESHADER_HOOKED", "1");
        const preload = common.env.get("LD_PRELOAD") orelse "";
        var replaced = std.ArrayList(u8).init(common.allocator);
        var it = std.mem.splitAny(u8, preload, ": ");
        while (it.next()) |part| {
            if (std.mem.indexOf(u8, part, options.deshaderLibName) == null) {
                try replaced.appendSlice(part);
            }
        }
        common.setenv("LD_PRELOAD", replaced.items);

        try editor.editorProcess(url.?);
        replaced.deinit();
        std.process.exit(0xde); // Do not continue to original program main()
    }

    if (loaders.ignored) {
        DeshaderLog.warn("This process is ignored", .{});
        return;
    }
    // Prevent recursive hooking
    common.setenv("DESHADER_HOOKED", "1");
    try shaders.init(common.allocator);

    const commands_port_string = common.env.get("DESHADER_COMMANDS_HTTP") orelse "8081";
    const commands_port_string_ws = common.env.get("DESHADER_COMMANDS_WS");
    const commands_port_http = try std.fmt.parseInt(u16, commands_port_string, 10);
    const commands_port_ws = if (commands_port_string_ws == null) null else try std.fmt.parseInt(u16, commands_port_string_ws.?, 10);
    command_listener = try commands.CommandListener.start(common.allocator, commands_port_http, commands_port_ws);
    DeshaderLog.debug("Commands HTTP port {d}", .{commands_port_http});
    if (commands_port_ws != null) {
        DeshaderLog.debug("Commands WS port {d}", .{commands_port_ws.?});
    }

    try loaders.loadGlLib();
    try loaders.loadVkLib();
    try transitive.TransitiveSymbols.loadOriginal();

    const editor_at_startup = common.env.get("DESHADER_SHOW") orelse "0";
    const l = try std.ascii.allocLowerString(common.allocator, editor_at_startup);
    defer common.allocator.free(l);
    const showOpts = enum { yes, no, @"1", @"0", true, false, unknown };
    switch (std.meta.stringToEnum(showOpts, l) orelse .unknown) {
        .yes, .@"1", .true => {
            _ = deshaderEditorWindowShow();
        },
        .no, .@"0", .false => {},
        .unknown => {
            DeshaderLog.warn("Invalid value for DESHADER_SHOW: {s}", .{editor_at_startup});
        },
    }
}

fn finalize() callconv(.C) void {
    defer common.deinit();
    if (command_listener != null) {
        command_listener.?.stop();
        common.allocator.destroy(command_listener.?);
    }
    if (options.embedEditor) {
        if (editor.editor_process != null) {
            editor.windowTerminate() catch |err| {
                DeshaderLog.err("{any}", .{err});
            };
        }
        if (editor.global_provider != null) {
            editor.serverStop() catch |err| {
                DeshaderLog.err("{any}", .{err});
            };
        }
    }
    shaders.Programs.deinit();
    shaders.Shaders.deinit();
}

fn wrapErrorRunOnLoad() callconv(.C) void {
    runOnLoad() catch |err| {
        DeshaderLog.err("Initialization error: {any}", .{err});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
    };
}
