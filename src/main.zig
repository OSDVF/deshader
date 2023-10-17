const std = @import("std");
const options = @import("options");
const wv = @import("positron");
const shrink = @import("tools/shrink.zig");

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
    const provider = wv.Provider.create(std.heap.c_allocator) catch return 1;
    defer provider.destroy();
    const view = wv.View.create((@import("builtin").mode == .Debug), null) catch return 2;
    defer view.destroy();
    const arena = comptime std.heap.ArenaAllocator.init(std.heap.c_allocator);
    var app = AppState{
        .arena = arena,
        .provider = provider,
        .view = view,
        .shutdown_thread = 0,
    };

    std.log.info("base uri: {s}", .{app.provider.base_url});

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

    std.log.info("provider ready.", .{});

    app.view.setTitle("Deshader Editor");

    app.view.navigate(app.provider.getUri("/index.html") orelse unreachable);

    std.log.info("webview ready.", .{});

    std.log.info("start.", .{});

    app.view.run();

    @atomicStore(u32, &app.shutdown_thread, 1, .SeqCst);

    return 0;
}
