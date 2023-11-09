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
const editor = @import("tools/editor.zig");

const String = []const u8;

export const init_array linksection(".init_array") = &wrapErrorRunOnLoad;
export const fini_array linksection(".fini_array") = &wrapErrorUnload;
var command_listener: ?*commands.CommandListener = null;

/// Run this functions at Deshader shared library load
fn runOnLoad() !void {
    try common.init(); // init allocator and env
    if (!loaders.ignored) {
        // maybe it was not checked yet
        loaders.checkIgnoredProcess();
    }
    if (loaders.ignored) {
        DeshaderLog.warn("This process is ignored", .{});
        return;
    }
    shaders.Programs = try @TypeOf(shaders.Programs).init(common.allocator);
    shaders.Sources = try @TypeOf(shaders.Sources).init(common.allocator);

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

fn finalize() !void {
    defer common.deinit();
    if (command_listener != null) {
        command_listener.?.stop();
        common.allocator.destroy(command_listener.?);
    }
    transitive.TransitiveSymbols.deinit();
    shaders.Programs.deinit();
    shaders.Sources.deinit();
}

fn wrapErrorRunOnLoad() callconv(.C) void {
    runOnLoad() catch |err| {
        DeshaderLog.err("Initialization error: {any}", .{err});
    };
}

fn wrapErrorUnload() callconv(.C) void {
    finalize() catch |err| {
        DeshaderLog.err("Finalization error: {any}", .{err});
    };
}
/// Defines logging options for the whole library
pub const std_options = @import("log.zig").std_options;

const err_format = "{s}: {any}";
pub export fn deshaderEditorWindowTerminate() usize {
    editor.windowTerminate() catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        return @intFromError(err);
    };
    return 0;
}

pub export fn deshaderEditorWindowShow() usize {
    editor.windowShow() catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        return @intFromError(err);
    };
    return 0;
}

pub export fn deshaderEditorServerStart() usize {
    editor.serverStart() catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        return @intFromError(err);
    };
    return 0;
}

pub export fn deshaderEditorServerStop() usize {
    editor.serverStop() catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        return @intFromError(err);
    };
    return 0;
}

/// [out] count - will be set to number of sources
pub export fn deshaderListSources(include_untagged: bool, path: [*:0]const u8, count: *usize) ?[*]const [*:0]const u8 {
    const result = shaders.Sources.list(include_untagged, std.mem.span(path)) catch return null;
    count.* = result.len;
    return @ptrCast(result);
}

/// [out] count - will be set to number of programs
pub export fn deshaderListPrograms(include_untagged: bool, path: [*:0]const u8, count: *usize) ?[*]const [*:0]const u8 {
    const result = shaders.Programs.list(include_untagged, std.mem.span(path)) catch return null;
    count.* = result.len;
    return @ptrCast(result);
}

/// Free list returned by deshaderListSources or deshaderListPrograms
pub export fn deshaderFreeList(list: [*]const [*:0]const u8, count: usize) void {
    for (list[0..count]) |item| {
        common.allocator.free(std.mem.span(item));
    }
    common.allocator.free(list[0..count]);
}

pub export fn deshaderSourceTag(ref: usize, part_index: usize, path: [*:0]const u8, move: bool, overwrite_other: bool) usize {
    shaders.sourceTag(ref, part_index, path, move, overwrite_other) catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        return @intFromError(err);
    };
    return 0;
}

const SourcesPayload = shader_decls.SourcesPayload;
const ProgramPayload = shader_decls.ProgramPayload;
/// SourcesPayload should contain only a single source
pub export fn deshaderTaggedSource(payload: SourcesPayload, move: bool, overwrite_other: bool) usize {
    std.debug.assert(payload.count == 1);
    shaders.Sources.putTagged(payload, move, overwrite_other) catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        return @intFromError(err);
    };
    return 0;
}

pub export fn deshaderRemoveSourceByTag(path: [*:0]const u8, dir: bool) usize {
    shaders.Sources.removeByTag(std.mem.span(path), dir) catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        return @intFromError(err);
    };
    return 0;
}

pub export fn deshaderRemoveSource(ref: usize) usize {
    shaders.Sources.remove(ref) catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        return @intFromError(err);
    };
    return 0;
}

pub export fn deshaderAddTaggedProgram(payload: ProgramPayload, move: bool, overwrite_other: bool) usize {
    shaders.Programs.putTagged(payload, move, overwrite_other) catch |err| {
        DeshaderLog.err(err_format, .{ @src().fn_name, err });
        return @intFromError(err);
    };
    return 0;
}
