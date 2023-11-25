const std = @import("std");
const positron = @import("positron");
const common = @import("../common.zig");
const options = @import("options");

const DeshaderLog = @import("../log.zig").DeshaderLog;

const String = []const u8;

pub fn getProductJson(allocator: std.mem.Allocator, https: bool, port: u16) !String {
    const authority = try std.fmt.allocPrint(allocator, "127.0.0.1:{}", .{port});
    defer allocator.free(authority);
    return try std.json.stringifyAlloc(allocator, .{
        .productConfiguration = .{
            .nameShort = "Deshader Editor",
            .nameLong = "Deshader Editor",
            .applicationName = "deshader-editor",
            .dataFolderName = ".deshader-editor",
            .version = "1.82.0",
            .extensionsGallery = .{
                .serviceUrl = "https://open-vsx.org/vscode/gallery",
                .itemUrl = "https://open-vsx.org/vscode/item",
                .resourceUrlTemplate = "https://openvsxorg.blob.core.windows.net/resources/{publisher}/{name}/{version}/{path}",
            },
            .extensionEnabledApiProposals = .{
                .@"vscode.vscode-web-playground" = .{ "fileSearchProvider", "textSearchProvider" },
            },
        },
        .workspaceUri = .{
            .scheme = "deshader",
            .path = "/live-app.code-workspace",
        },
        .additionalBuiltinExtensions = .{.{
            .scheme = if (https) "https" else "http",
            .authority = authority,
            .path = "/deshader-vscode",
        }},
    }, .{ .whitespace = .minified });
}

var provide_thread: ?std.Thread = null;

// basicaly a HTTP server
pub fn createEditorProvider() !*positron.Provider {
    var port: u16 = undefined;
    if (common.env.get("DESHADER_PORT")) |portString| {
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

    var provider = try positron.Provider.create(common.allocator, port);
    inline for (options.files) |file| {
        const lastDot = std.mem.lastIndexOf(u8, file, &[_]u8{@as(u8, '.')});
        const fileExt = if (lastDot != null) file[lastDot.? + 1 ..] else "";
        const Case = enum { html, htm, js, ts, css, json, other };
        const case = std.meta.stringToEnum(Case, fileExt) orelse .other;
        const mimeType = switch (case) {
            .html, .htm => "text/html",
            .js, .ts => "text/javascript",
            .css => "text/css",
            .other => "text/plain",
            .json => "application/json",
        };
        // assume all paths start with `options.editorDir`

        try provider.addContentDeflated(file[options.editorDir.len..], mimeType, @embedFile(file));
    }

    // Generate product.json according to current settings
    const product_config = try getProductJson(common.allocator, false, port);
    defer common.allocator.free(product_config);
    try provider.addContent("/product.json", "application/json", product_config);

    provide_thread = try std.Thread.spawn(.{}, positron.Provider.run, .{provider});
    try provide_thread.?.setName("EditorServer");
    return provider;
}

pub const EditorProviderError = error{ AlreadyRunning, NotRunning };

pub var global_provider: ?*positron.Provider = null;
pub fn serverStart() !void {
    if (global_provider != null) {
        for (global_provider.?.server.bindings.items) |binding| {
            DeshaderLog.err("Editor server already running on port {d}", .{binding.port});
        }
        return error.AlreadyRunning;
    }
    global_provider = try createEditorProvider();
    errdefer {
        global_provider.?.destroy();
        global_provider = null;
    }
}

pub fn serverStop() EditorProviderError!void {
    if (global_provider == null) {
        DeshaderLog.err("Editor server not running", .{});
        return error.NotRunning;
    }
    global_provider.?.destroy();
    provide_thread.?.join();
    common.allocator.destroy(global_provider.?);
    global_provider = null;
}

const AppState = struct {
    provider: *positron.Provider,
    view: *positron.View,

    shutdown_lock: std.Thread.Mutex,

    pub fn getWebView(app: *AppState) *positron.View {
        _ = app;
        return global_app.?.view;
    }
};
pub var global_app: ?AppState = null;

const EditorErrors = error{EditorNotEmbedded};

pub fn windowShow() !void {
    if (!options.embedEditor) {
        DeshaderLog.err("Editor not embedded in this Deshader distribution. Cannot show it.", .{});
        return error.EditorNotEmbedded;
    }

    if (global_provider == null) {
        try serverStart();
    }
    if (global_app != null) {
        DeshaderLog.err("Editor already running", .{});
        return error.AlreadyRunning;
    }

    const view = try positron.View.create((@import("builtin").mode == .Debug), null);
    defer {
        view.destroy();
        global_app.?.shutdown_lock.unlock();
        global_app = null;
    }
    global_app = AppState{
        .provider = global_provider.?,
        .view = view,
        .shutdown_lock = std.Thread.Mutex{},
    };
    global_app.?.shutdown_lock.lock();
    DeshaderLog.info("Editor URL: {s}", .{global_app.?.provider.base_url});
    global_app.?.view.setTitle("Deshader Editor");
    global_app.?.view.setSize(500, 300, .none);

    global_app.?.view.navigate(global_app.?.provider.getUri("/index.html").?);

    const injected_code = try std.mem.concatWithSentinel(global_app.?.provider.allocator, u8, &.{ "globalThis.deshader = ", global_app.?.provider.base_url }, 0);
    defer global_app.?.provider.allocator.free(injected_code);
    global_app.?.view.eval(injected_code);

    global_app.?.view.run();
    DeshaderLog.debug("Editor terminated", .{});
}

pub fn windowTerminate() !void {
    if (global_app != null) {
        global_app.?.view.terminate();
        global_app.?.shutdown_lock.lock();
        DeshaderLog.debug("Terminating editor", .{});
    } else {
        DeshaderLog.err("Editor not running", .{});
        return error.NotRunning;
    }
}
