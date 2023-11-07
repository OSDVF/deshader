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
            _ = editorWindowShow();
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

pub export fn editorWindowTerminate() u8 {
    editor.windowTerminate() catch |err| return @intFromError(err);
    return 0;
}

pub export fn editorWindowShow() u32 {
    editor.windowShow() catch |err| return @intFromError(err);
    return 0;
}

pub export fn editorServerStart() u32 {
    editor.serverStart() catch |err| return @intFromError(err);
    return 0;
}

pub export fn editorServerStop() u32 {
    editor.serverStop() catch |err| return @intFromError(err);
    return 0;
}

pub export fn listShaders() ?[*]const [*:0]const u8 {
    return null;
}

const SourcePayload = shader_decls.SourcePayload;
const ProgramPayload = shader_decls.ProgramPayload;
pub export fn deshaderAddTaggedSource(payload: SourcePayload, move: bool, overwrite_other: bool) u32 {
    shaders.Sources.addTagged(payload, move, overwrite_other) catch |err| return @intFromError(err);
    return 0;
}

pub export fn deshaderRemoveSourceTag(path: [*:0]const u8, dir: bool) u32 {
    shaders.Sources.remove(std.mem.span(path), dir) catch |err| return @intFromError(err);
    return 0;
}

pub export fn deshaderAddTaggedProgram(payload: ProgramPayload, move: bool, overwrite_other: bool) u32 {
    shaders.Programs.addTagged(payload, move, overwrite_other) catch |err| return @intFromError(err);
    return 0;
}
