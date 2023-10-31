const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const wv = @import("positron");
const shrink = @import("tools/shrink.zig");
const gl = @import("gl");
const vulkan = @import("vulkan");
const DeshaderLog = @import("log.zig").DeshaderLog;
const common = @import("common.zig");

const loaders = @import("interceptors/loaders.zig");
const transitive = @import("interceptors/transitive.zig");

// Run these functions at Deshader shared library load
export const init_array linksection(".init_array") = &wrapErrorRunOnLoad;

fn runOnLoad() !void {
    try common.init();
    const showAtStartup = std.os.getenv("DESHADER_SHOW") orelse "0";
    const l = try std.ascii.allocLowerString(common.allocator, showAtStartup);
    const showOpts = enum { yes, no, @"1", @"0", true, false, unknown };
    switch (std.meta.stringToEnum(showOpts, l) orelse .unknown) {
        .yes, .@"1", .true => {
            _ = showEditorWindow();
        },
        .no, .@"0", .false => {},
        .unknown => {
            DeshaderLog.warn("Invalid value for DESHADER_SHOW: {s}", .{showAtStartup});
        },
    }
    try loaders.loadGlLib();
    try loaders.loadVkLib();
    try transitive.TransitiveSymbols.loadOriginal();
}
fn wrapErrorRunOnLoad() callconv(.C) void {
    runOnLoad() catch |err| {
        DeshaderLog.err("Initialization error: {any}", .{err});
    };
}

const AppState = struct {
    arena: std.heap.ArenaAllocator,
    provider: *wv.Provider,
    view: *wv.View,

    shutdown_thread: u32,

    pub fn getWebView(app: *AppState) *wv.View {
        return app.view;
    }
};

pub export fn showEditorWindow() u8 {
    var port: u16 = undefined;
    if (std.os.getenv("DESHADER_PORT")) |portString| {
        if (std.fmt.parseInt(u16, portString, 10)) |parsedPort| {
            port = parsedPort;
        } else |err| {
            DeshaderLog.err("Invalid port: {any}. Using default 8080", .{err});
            port = 8080;
        }
    } else {
        DeshaderLog.warn("DESHADER_PORT not set, using default port 8080", .{});
        port = 8080;
    }
    const provider = wv.Provider.create(common.allocator, port) catch return 1;
    defer provider.destroy();
    const view = wv.View.create((@import("builtin").mode == .Debug), null) catch return 2;
    defer view.destroy();
    const arena = std.heap.ArenaAllocator.init(common.allocator);
    var app = AppState{
        .arena = arena,
        .provider = provider,
        .view = view,
        .shutdown_thread = 0,
    };

    DeshaderLog.info("Editor URL: {s}", .{app.provider.base_url});

    inline for (options.files) |file| {
        const lastDot = std.mem.lastIndexOf(u8, file, &[_]u8{@as(u8, '.')});
        const fileExt = if (lastDot != null) file[lastDot.? + 1 ..] else "";
        const Case = enum { html, htm, js, ts, css, other };
        const case = std.meta.stringToEnum(Case, fileExt) orelse .other;
        const mimeType = switch (case) {
            .html, .htm => "text/html",
            .js, .ts => "text/javascript",
            .css => "text/css",
            .other => "text/plain",
        };
        // assume all paths start with `options.editorDir`
        app.provider.addContent(file[options.editorDir.len..], mimeType, @embedFile(file)) catch return 4;
    }

    const provide_thread = std.Thread.spawn(.{}, wv.Provider.run, .{app.provider}) catch return 5;
    provide_thread.detach();

    app.view.setTitle("Deshader Editor");
    app.view.setSize(500, 300, .none);

    app.view.navigate(app.provider.getUri("/index.html") orelse unreachable);

    app.view.run();

    @atomicStore(u32, &app.shutdown_thread, 1, .SeqCst);

    return 0;
}
