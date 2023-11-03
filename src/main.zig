const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const wv = @import("positron");
const shrink = @import("tools/shrink.zig");
const gl = @import("gl");
const vulkan = @import("vulkan");
const DeshaderLog = @import("log.zig").DeshaderLog;
const common = @import("common.zig");
const commands = @import("commands.zig");

const loaders = @import("interceptors/loaders.zig");
const transitive = @import("interceptors/transitive.zig");
const editor = @import("tools/editor.zig");

// Run these functions at Deshader shared library load
export const init_array linksection(".init_array") = &wrapErrorRunOnLoad;

fn runOnLoad() !void {
    try common.init(); // init allocator and env
    const commands_port_string = common.env.get("DESHADER_COMMANDS_HTTP") orelse "8081";
    const commands_port_string_ws = common.env.get("DESHADER_COMMANDS_WS");
    const commands_port_http = try std.fmt.parseInt(u16, commands_port_string, 10);
    const commands_port_ws = if (commands_port_string_ws == null) null else try std.fmt.parseInt(u16, commands_port_string_ws.?, 10);
    _ = try commands.CommandListener.start(common.allocator, commands_port_http, commands_port_ws);
    DeshaderLog.debug("Commands HTTP port {d}", .{commands_port_http});
    if (commands_port_ws != null) {
        DeshaderLog.debug("Commands WS port {d}", .{commands_port_ws.?});
    }

    try loaders.loadGlLib();
    try loaders.loadVkLib();
    try transitive.TransitiveSymbols.loadOriginal();

    const editor_at_startup = common.env.get("DESHADER_SHOW") orelse "0";
    const l = try std.ascii.allocLowerString(common.allocator, editor_at_startup);
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
fn wrapErrorRunOnLoad() callconv(.C) void {
    runOnLoad() catch |err| {
        DeshaderLog.err("Initialization error: {any}", .{err});
    };
}

pub const std_options = @import("log.zig").std_options;

const AppState = struct {
    arena: std.heap.ArenaAllocator,
    provider: *wv.Provider,
    view: *wv.View,

    shutdown_thread: u32,

    pub fn getWebView(app: *AppState) *wv.View {
        _ = app;
        return global_app.?.view;
    }
};
var global_app: ?AppState = null;

pub export fn editorWindowTerminate() u8 {
    if (global_app != null) {
        global_app.?.view.terminate();
        return 0;
    } else {
        DeshaderLog.err("Editor not running", .{});
        return 1;
    }
}

pub export fn editorWindowShow() u8 {
    if (!options.embedEditor) {
        DeshaderLog.err("Editor not embedded in this Deshader distribution. Cannot show it.", .{});
        return 1;
    }

    var editor_provider: ?*wv.Provider = null;
    if (editor.global_provider == null) {
        editor.editorServerStart() catch |err| {
            DeshaderLog.err("Failed to launch editor server: {any}", .{err});
            return 3;
        };
        editor_provider = editor.global_provider;
    }
    defer {
        if (editor_provider != null) {
            editor.editorServerStop() catch |err| {
                DeshaderLog.err("Failed to stop editor server: {any}", .{err});
            };
        }
    }
    if (global_app != null) {
        DeshaderLog.err("Editor already running", .{});
        return 4;
    }

    const view = wv.View.create((@import("builtin").mode == .Debug), null) catch return 2;
    defer view.destroy();
    var arena = std.heap.ArenaAllocator.init(common.allocator);
    defer arena.deinit();
    global_app = AppState{
        .arena = arena,
        .provider = editor_provider.?,
        .view = view,
        .shutdown_thread = 0,
    };
    defer global_app = null;

    DeshaderLog.info("Editor URL: {s}", .{global_app.?.provider.base_url});

    global_app.?.view.setTitle("Deshader Editor");
    global_app.?.view.setSize(500, 300, .none);

    global_app.?.view.navigate(global_app.?.provider.getUri("/index.html") orelse unreachable);

    global_app.?.view.run();

    @atomicStore(u32, &global_app.?.shutdown_thread, 1, .SeqCst);

    return 0;
}

pub export fn editorServerStart() u8 {
    editor.editorServerStart() catch return 1;
    return 0;
}

pub export fn editorServerStop() u8 {
    editor.editorServerStop() catch return 1;
    return 0;
}
