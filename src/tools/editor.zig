const std = @import("std");
const builtin = @import("builtin");
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

pub var editor_process: ?std.process.Child = null;
const EditorErrors = error{EditorNotEmbedded};
pub const DESHADER_EDITOR_PROCESS = "DESHADER_EDITOR_PROCESS";

/// Spawns a new thread that runs the editor
/// This function will block until the editor is ready to be used
pub fn windowShow() !void {
    if (!options.embedEditor) {
        DeshaderLog.err("Editor not embedded in this Deshader distribution. Cannot show it.", .{});
        return error.EditorNotEmbedded;
    }

    if (global_provider == null) {
        try serverStart();
    }
    if (editor_process != null or common.env.get(DESHADER_EDITOR_PROCESS) != null) {
        DeshaderLog.err("Editor already running", .{});
        return error.AlreadyRunning;
    }

    const base = global_provider.?.getUri("/index.html").?;
    DeshaderLog.info("Editor URL: {s}", .{base});

    const exe_path = try std.fs.selfExePathAlloc(global_provider.?.allocator);
    defer global_provider.?.allocator.free(exe_path);
    // Duplicate self but set env vars to indicate that the child should be the editor
    editor_process = std.process.Child.init(&.{ exe_path, "editor" }, common.allocator); // the "editor" parameter is really ignored but it is here for reference to be found easily
    try common.env.put(DESHADER_EDITOR_PROCESS, base);
    editor_process.?.env_map = &common.env;
    editor_process.?.stdout_behavior = .Inherit;
    editor_process.?.stderr_behavior = .Inherit;
    editor_process.?.stdin_behavior = .Close;
    try editor_process.?.spawn();

    // Watch the child process and inform about its end
    const watcher = try std.Thread.spawn(.{ .allocator = common.allocator }, struct {
        fn watch() !void {
            if (builtin.os.tag == .windows) {
                _ = try editor_process.?.wait();
            } else { //Must be called separately because Zig std library contains extra security check which would crash
                var status: u32 = undefined;
                while (blk: {
                    const result = std.os.system.waitpid(editor_process.?.id, @ptrCast(&status), std.os.W.UNTRACED);
                    DeshaderLog.debug("Editor PID {d} watcher result {}", .{ editor_process.?.id, std.os.system.getErrno(result) });
                    break :blk !(std.os.W.IFEXITED(status) or std.os.W.IFSTOPPED(status) or std.os.W.IFSIGNALED(status));
                }) {}
            }
            editor_process = null;
            common.env.remove(DESHADER_EDITOR_PROCESS);
        }
    }.watch, .{});
    try watcher.setName("EditorWatch");
    watcher.detach();
}

pub fn windowTerminate() !void {
    if (editor_process) |*p| {
        if (builtin.os.tag == .windows) {
            _ = try p.kill();
        } else {
            try std.os.kill(p.id, std.os.SIG.TERM);
        }
        DeshaderLog.debug("Editor terminated", .{});
    } else {
        DeshaderLog.err("Editor not running", .{});
        return error.NotRunning;
    }
}

pub fn windowWait() !void {
    if (editor_process) |*p| {
        if (builtin.os.tag == .windows) {
            _ = try p.wait();
        } else {
            _ = std.os.system.waitpid(p.id, null, 0);
        }
    } else {
        DeshaderLog.err("Editor not running", .{});
        return error.NotRunning;
    }
}

//
// The following code should exist only in the editor subprocess
//
pub fn editorProcess(url: String) !void {
    const view = try positron.View.create((@import("builtin").mode == .Debug), null);
    defer view.destroy();
    view.setTitle("Deshader Editor");
    view.setSize(500, 300, .none);

    // Inform the deshader-editor VSCode extension that it is running inside embdedded editor
    const urlZ = try common.allocator.dupeZ(u8, url);
    defer common.allocator.free(urlZ);
    view.navigate(urlZ);

    const injected_code = try std.mem.concatWithSentinel(common.allocator, u8, &.{ "globalThis.deshader = \"", url, "\"" }, 0);
    defer common.allocator.free(injected_code);

    // Inform the deshader-editor VSCode extension that it is running inside embdedded editor
    view.init(injected_code);
    view.run();
}
