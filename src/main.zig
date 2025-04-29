// Copyright (C) 2025  Ondřej Sabela
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
// along with this program. If not, see <https://www.gnu.org/licenses/>.

//! Contains:
//! Code that will be executed upon library load
//! Public symbols for interaction with Deshader library (shader tagging etc.)

const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const common = @import("common");
const log = common.log;
const commands = @import("commands.zig");
const backends = @import("backends.zig");
const shaders = @import("services/shaders.zig");
const declarations = @import("declarations.zig");

const loaders = @import("backends/loaders.zig");
const transitive = @import("backends/transitive.zig");

const String = []const u8;

//
// Public API
//

/// Defines logging options for the whole library
pub const std_options = common.logging.std_options;
const err_format = "{s}: {any}";

// Simplify declarations to allow generating stubs from this `main.zig` file without importing `declarations.zig`
const SourcesPayload = declarations.shaders.SourcesPayload;
const ProgramPayload = declarations.shaders.ProgramPayload;
const ExistsBehavior = declarations.shaders.ExistsBehavior;
const Service = declarations.instruments.Service;

pub export fn deshaderAcquireServiceGL() callconv(.c) ?*Service {
    return backends.gl.current.toOpaque(); // TODO locking
}

pub export fn deshaderFreeList(list: [*]const [*:0]const u8, count: usize) callconv(.c) void {
    for (list[0..count]) |item| {
        common.allocator.free(std.mem.span(item));
    }
    common.allocator.free(list[0..count]);
}

pub export fn deshaderListPrograms(path: [*:0]const u8, recursive: bool, count: *usize, physical: bool, meta: bool, postfix: ?[*:0]const u8) callconv(.c) ?[*]const [*:0]const u8 {
    var result = backends.gl.current.Programs.listDir(common.allocator, std.mem.span(path), recursive, physical, meta, if (postfix) |n| std.mem.span(n) else null) catch return null;
    count.* = result.items.len;
    return (result.toOwnedSlice(common.allocator) catch return null).ptr;
}

pub export fn deshaderListSources(path: [*:0]const u8, recursive: bool, count: *usize, physical: bool, meta: bool, postfix: ?[*:0]const u8) callconv(.c) ?[*]const [*:0]const u8 {
    var result = backends.gl.current.Shaders.listDir(common.allocator, std.mem.span(path), recursive, physical, meta, if (postfix) |n| std.mem.span(n) else null) catch return null;
    count.* = result.items.len;
    return (result.toOwnedSlice(common.allocator) catch return null).ptr;
}

/// If `program` == 0, then list all programs. Else list shader stages of a particular program
pub export fn deshaderListProgramsUntagged(count: *usize, ref_or_root: usize, meta: bool, nested_postfix: ?[*:0]const u8) callconv(.c) ?[*]const [*:0]const u8 {
    const result = backends.gl.current.Programs.listUntagged(common.allocator, @enumFromInt(ref_or_root), meta, if (nested_postfix) |n| std.mem.span(n) else null, null) catch return null;
    count.* = result.len;
    return @ptrCast(result);
}

pub export fn deshaderListSourcesUntagged(count: *usize, ref_or_root: usize, meta: bool, nested_postfix: ?[*:0]const u8) callconv(.c) ?[*]const [*:0]const u8 {
    const result = backends.gl.current.Shaders.listUntagged(common.allocator, @enumFromInt(ref_or_root), meta, if (nested_postfix) |n| std.mem.span(n) else null, null) catch return null;
    count.* = result.len;
    return @ptrCast(result);
}

pub export fn deshaderRemovePath(path: [*:0]const u8, dir: bool) callconv(.c) usize {
    backends.gl.current.Shaders.untag(std.mem.span(path), dir) catch |err| {
        log.err(err_format, .{ @src().fn_name, err });
        if (@errorReturnTrace()) |trace|
            std.debug.dumpStackTrace(trace.*);
        return @intFromError(err);
    };
    return 0;
}

pub export fn deshaderRemoveSource(ref: usize) callconv(.c) usize {
    backends.gl.current.Shaders.remove(@enumFromInt(ref)) catch |err| {
        log.err(err_format, .{ @src().fn_name, err });
        if (@errorReturnTrace()) |trace|
            std.debug.dumpStackTrace(trace.*);
        return @intFromError(err);
    };
    return 0;
}

pub export fn deshaderReturnServiceGL() callconv(.c) void {
    // TODO locking
}

/// # Shader tagging
/// Deshader creates a virtual file system for better management of your shaders. Use these functions to assign filesystem locations to your shaders and specify dependencies between them. Call them just before you call `glShaderSource` or similar functions.
/// `path` cannot contain '>'
///
/// Alternatively, glNamedStringARB or glObjectLabel can be used to tag shaders.
pub export fn deshaderTag(ref: usize, part_index: usize, path: [*:0]const u8, if_exists: ExistsBehavior) callconv(.c) usize {
    _ = backends.gl.current.Shaders.assignTag(@enumFromInt(ref), part_index, std.mem.span(path), if_exists) catch |err| {
        log.err(err_format, .{ @src().fn_name, err });
        if (@errorReturnTrace()) |trace|
            std.debug.dumpStackTrace(trace.*);
        return @intFromError(err);
    };
    return 0;
}

/// Set a physical folder as a workspace for shader sources
pub export fn deshaderPhysicalWorkspace(virt: [*:0]const u8, physical: [*:0]const u8) callconv(.c) usize {
    _ = _try: {
        backends.gl.current.mapPhysicalToVirtual(std.mem.span(physical), shaders.ResourceLocator.parse(std.mem.span(virt)) catch |err| break :_try err) catch |err| break :_try err;
    } catch |err| {
        log.err(err_format, .{ @src().fn_name, err });
        if (@errorReturnTrace()) |trace|
            std.debug.dumpStackTrace(trace.*);
        return @intFromError(err);
    };
    return 0;
}

pub export fn deshaderTaggedProgram(payload: ProgramPayload, behavior: ExistsBehavior) callconv(.c) usize {
    backends.gl.current.programCreateUntagged(payload) catch |err| {
        log.err(err_format, .{ @src().fn_name, err });
        if (@errorReturnTrace()) |trace|
            std.debug.dumpStackTrace(trace.*);
        return @intFromError(err);
    };
    _ = backends.gl.current.Programs.assignTag(@enumFromInt(payload.ref), 0, std.mem.span(payload.path.?), behavior) catch |err| {
        log.err(err_format, .{ @src().fn_name, err });
        if (@errorReturnTrace()) |trace|
            std.debug.dumpStackTrace(trace.*);
        return @intFromError(err);
    };
    return 0;
}

pub export fn deshaderTaggedSource(payload: SourcesPayload, if_exists: ExistsBehavior) callconv(.c) usize {
    std.debug.assert(payload.count == 1);
    std.debug.assert(payload.paths != null);
    backends.gl.current.sourcesCreateUntagged(payload) catch |err| {
        log.err(err_format, .{ @src().fn_name, err });
        if (@errorReturnTrace()) |trace|
            std.debug.dumpStackTrace(trace.*);
        return @intFromError(err);
    };
    for (0..payload.count) |i| {
        if (payload.paths.?[i]) |path| {
            _ = backends.gl.current.Programs.assignTag(@enumFromInt(payload.ref), i, std.mem.span(path), if_exists) catch |err| {
                log.err(err_format, .{ @src().fn_name, err });
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpStackTrace(trace.*);
                return @intFromError(err);
            };
        }
    }
    return 0;
}

/// Writes a pointer to deshader version string to `output`. The string is null-terminated.
pub export fn deshaderVersion(output: ?*[*:0]const u8) callconv(.c) void {
    if (output) |o| {
        o.* = options.version.ptr;
    } else {
        log.info("Deshader version: {s}", .{options.version});
    }
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
    if (options.otype != .None) {
        switch (builtin.os.tag) {
            .windows => @export(&DllMain, .{
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
                @export(&i, .{ .name = "init_array", .section = ".init_array" });
                @export(&f, .{ .name = "fini_array", .section = ".fini_array" });
            },
        }
    }
}

/// Will be called on Deshader shared library load
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

    if (loaders.ignored) {
        log.info("This process is ignored", .{});
        return;
    }
    if (common.env.get(common.env_prefix ++ "HOOKED") == null) {
        common.env.set(common.env_prefix ++ "HOOKED", "1");
    } else {
        return;
    }
    try shaders.initStatic(common.allocator);

    var configs = std.ArrayListUnmanaged(commands.MutliListener.Config){};
    defer configs.deinit(common.allocator);
    const default = try parseConfigAlloc(common.env.get(common.env_prefix ++ "COMMANDS") orelse common.default_ws_url, common.default_ws_url, common.default_ws_port_n);
    try configs.append(common.allocator, default);
    if (common.env.get(common.env_prefix ++ "COMMANDS_WS")) |w| {
        const c = try parseConfigAlloc(w, common.default_ws_url, common.default_ws_port_n);
        if (configNotEqual(c, configs.getLastOrNull()))
            try configs.append(common.allocator, c)
        else
            common.allocator.free(c.host);
    }
    if (common.env.get(common.env_prefix ++ "COMMANDS_HTTP")) |h| {
        const c = try parseConfigAlloc(h, common.default_http_url, common.default_http_port_n);
        if (configNotEqual(c, default))
            try configs.append(common.allocator, c)
        else
            common.allocator.free(c.host);
    }

    commands.instance = try commands.MutliListener.start(common.allocator, configs.items);
    for (configs.items) |c| common.allocator.free(c.host);
}

/// Will be called upon Deshader library unload
fn finalize() callconv(.c) void {
    // Inlining is disabled because Zig would otherwise optimize out all the conditions in release mode (compiler bug?)
    const exe = @call(.never_inline, common.selfExePath, .{}) catch "?";
    @call(.never_inline, log.debug, .{ "Unloading Deshader library from {s}", .{exe} });
    defer @call(.never_inline, common.deinit, .{});

    @call(.never_inline, loaders.deinit, .{}); // also deinits gl_shaders
    if (commands.instance) |i| {
        @call(.never_inline, commands.MutliListener.stop, .{i});
        @call(.never_inline, std.mem.Allocator.destroy, .{ common.allocator, i });
    }
    if (!loaders.ignored) {
        @call(.never_inline, shaders.deinitStatic, .{});
    }
}

/// Will be called upon Deshader library load and BEFORE the host application's main()
fn wrapErrorRunOnLoad() callconv(.c) void {
    runOnLoad() catch |err| {
        log.err("Initialization error: {any}", .{err});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
    };
}

fn parseConfigAlloc(uri: ?String, default: String, default_port: u16) !commands.MutliListener.Config {
    const parsed = if (uri) |u|
        std.Uri.parse(u) catch std.Uri.parseAfterScheme(std.mem.sliceTo(default, ':'), u) catch fallback: {
            log.err("Invalid URI: {s}", .{u});
            break :fallback std.Uri.parse(default) catch unreachable;
        }
    else
        std.Uri.parse(default) catch unreachable;
    return .{
        .host = try std.fmt.allocPrint(common.allocator, "{raw}", .{(parsed.host orelse (std.Uri.parse(default) catch unreachable).host.?)}),
        .port = parsed.port orelse default_port,
        .protocol = if (std.ascii.eqlIgnoreCase(parsed.scheme, "ws")) .WS else .HTTP,
    };
}

fn configNotEqual(a: commands.MutliListener.Config, mb: ?commands.MutliListener.Config) bool {
    if (mb) |b| if (a.protocol != b.protocol or !std.ascii.eqlIgnoreCase(a.host, b.host) or a.port != b.port) {
        return true;
    };
    return false;
}
