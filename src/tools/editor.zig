//! This module provides the editor server and the editor window
//! Injects current Deshader settings into the editor extension

const std = @import("std");
const builtin = @import("builtin");
const positron = @import("positron");
const common = @import("../common.zig");
const commands = @import("../commands.zig");
const options = @import("options");
const ctregex = @import("ctregex");

const DeshaderLog = @import("../log.zig").DeshaderLog;

const String = []const u8;

pub fn getProductJson(allocator: std.mem.Allocator, https: bool, port: u16) !String {
    const authority = try std.fmt.allocPrint(allocator, "127.0.0.1:{}", .{port});
    defer allocator.free(authority);
    return try std.json.stringifyAlloc(allocator, .{
        .productConfiguration = .{
            .nameShort = "Deshader Editor",
            .nameLong = "Deshader Integrated Editor",
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
            .path = "/connected.code-workspace",
        },
        .additionalBuiltinExtensions = .{ .{
            .scheme = if (https) "https" else "http",
            .authority = authority,
            .path = "/deshader-vscode",
        }, .{
            .scheme = if (https) "https" else "http",
            .authority = authority,
            .path = "/glsl-language-support",
        } },
    }, .{ .whitespace = .minified });
}

var provide_thread: ?std.Thread = null;

fn resolveMime(path: String) String {
    const lastDot = std.mem.lastIndexOf(u8, path, &[_]u8{@as(u8, '.')});
    const fileExt = if (lastDot != null) path[lastDot.? + 1 ..] else "";
    const case = std.meta.stringToEnum(enum { html, htm, js, map, ts, css, json, other }, fileExt) orelse .other;
    return switch (case) {
        .html, .htm => "text/html",
        .js, .ts => "text/javascript",
        .map => "application/json",
        .css => "text/css",
        .other => "text/plain",
        .json => "application/json",
    };
}

// basicaly a HTTP server
pub fn createEditorProvider(command_listener: ?*const commands.CommandListener) !*positron.Provider {
    var port: u16 = undefined;
    if (common.env.get(common.env_prefix ++ "PORT")) |portString| {
        if (std.fmt.parseInt(u16, portString, 10)) |parsedPort| {
            port = parsedPort;
        } else |err| {
            DeshaderLog.err("Invalid port: {any}. Using default 8080", .{err});
            port = 8080;
        }
    } else {
        DeshaderLog.warn(common.env_prefix ++ "PORT not set, using default port 8080", .{});
        port = 8080;
    }

    var provider = try positron.Provider.create(common.allocator, port);
    provider.allowed_origins = std.BufSet.init(provider.allocator);
    inline for (.{ "localhost", "127.0.0.1" }) |origin| {
        const concatOrigin = try std.fmt.allocPrint(provider.allocator, "{s}://{s}:{d}", .{ if (provider.server.bindings.getLast().tls == null) "http" else "https", origin, port });
        defer provider.allocator.free(concatOrigin);
        try provider.allowed_origins.?.insert(concatOrigin);
    }
    if (builtin.mode == .Debug) {
        // Let the provider read the files at runtime in debug mode
        try provider.embedded.append(positron.Provider.EmbedDir{ .address = "/", .path = "editor", .resolveMime = &resolveMime });
    }
    inline for (options.files) |file| {
        const lastDot = std.mem.lastIndexOf(u8, file, &[_]u8{@as(u8, '.')});
        const fileExt = if (lastDot != null) file[lastDot.? + 1 ..] else "";
        const mime_type = resolveMime(file);

        if (builtin.mode != .Debug and try ctregex.search("map|ts", .{}, fileExt) != null) {
            continue; // Do not include sourcemaps in release builds
        }

        const f_address = file[options.editorDir.len..];
        // assume all paths start with `options.editorDir`
        const compressed_or_content = if (builtin.mode != .Debug) @embedFile(file);
        if (comptime std.mem.eql(u8, f_address, "/deshader-vscode/dist/web/extension.js")) {
            // Inject editor config into Deshader extension
            // Construct editor base url and config JSON
            var editor_config: ?String = null;
            const editor_config_fmt = "{s}\nglobalThis.deshader={{lsp:{{port:{d}}},{s}:{{host:\"";
            if (command_listener) |cl| {
                var decompressed_data: String = undefined;
                if (cl.ws_config != null or cl.http != null) {
                    var decompressor: std.compress.zlib.DecompressStream(std.io.FixedBufferStream(String).Reader) = undefined;
                    if (builtin.mode == .Debug) {
                        const handle = try std.fs.cwd().openFile(file, .{});
                        defer handle.close();
                        decompressed_data = try handle.readToEndAlloc(provider.allocator, 10 * 1024 * 1024);
                    } else {
                        var stream = std.io.fixedBufferStream(compressed_or_content);
                        decompressor = try std.compress.zlib.decompressStream(provider.allocator, stream.reader());
                        var decompressed = decompressor.reader();
                        decompressed_data = try decompressed.readAllAlloc(provider.allocator, 10 * 1024 * 1024);
                    }
                    defer if (builtin.mode != .Debug) {
                        decompressor.deinit();
                    };
                    defer provider.allocator.free(decompressed_data);
                    if (cl.ws_config) |wsc| {
                        editor_config = try std.fmt.allocPrint(provider.allocator, editor_config_fmt ++ "{s}\",port:{d}}}}}\n", .{ decompressed_data, commands.CommandListener.setting_vars.languageServerPort, if (cl.secure) "wss" else "ws", wsc.address, wsc.port });
                    } else {
                        if (cl.http) |http| {
                            if (http.server.bindings.getLastOrNull()) |bind| {
                                editor_config = try std.fmt.allocPrint(provider.allocator, editor_config_fmt ++ "{}\",port:{d}}}}}\n", .{ decompressed_data, commands.CommandListener.setting_vars.languageServerPort, if (cl.secure) "https" else "http", bind.address, bind.port });
                            }
                        }
                    }
                }
            }
            if (editor_config) |c| {
                defer provider.allocator.free(c);
                try provider.addContent(f_address, mime_type, c);
            } else if (builtin.mode != .Debug) {
                try provider.addContentDeflatedNoAlloc(f_address, mime_type, compressed_or_content);
            }
        } else if (builtin.mode != .Debug) {
            try provider.addContentDeflatedNoAlloc(f_address, mime_type, compressed_or_content);
        }
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
pub fn serverStart(command_listener: ?*const commands.CommandListener) !void {
    if (global_provider != null) {
        for (global_provider.?.server.bindings.items) |binding| {
            DeshaderLog.err("Editor server already running on port {d}", .{binding.port});
        }
        return error.AlreadyRunning;
    }
    global_provider = try createEditorProvider(command_listener);
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

pub var editor_process: if (builtin.os.tag == .windows) ?std.Thread else ?std.process.Child = null;
var editor_mutex = std.Thread.Mutex{};
var editor_shutdown = std.Thread.Condition{};
var editor_view: if (builtin.os.tag == .windows) *positron.View else undefined = undefined;
const EditorErrors = error{EditorNotEmbedded};
pub const DESHADER_EDITOR_URL = common.env_prefix ++ "EDITOR_URL";

/// Spawns a new thread that runs the editor
/// This function will block until the editor is ready to be used
pub fn windowShow(command_listener: ?*const commands.CommandListener) !void {
    if (!options.embedEditor) {
        DeshaderLog.err("Editor not embedded in this Deshader distribution. Cannot show it.", .{});
        return error.EditorNotEmbedded;
    }

    if (global_provider == null) {
        try serverStart(command_listener);
    }
    if (editor_process != null or common.env.get(DESHADER_EDITOR_URL) != null) {
        DeshaderLog.err("Editor already running", .{});
        return error.AlreadyRunning;
    }

    const base = (try global_provider.?.getUriAlloc("/index.html")).?;
    defer global_provider.?.allocator.free(base);
    DeshaderLog.info("Editor URL: {s}", .{base});

    if (builtin.os.tag == .windows) {
        editor_process = try std.Thread.spawn(.{ .allocator = common.allocator }, editorProcess, .{base});
        try editor_process.?.setName("Editor");
        editor_process.?.detach();
    } else {
        const exe_or_dll_path = try common.selfExePathAlloc(global_provider.?.allocator);
        defer global_provider.?.allocator.free(exe_or_dll_path);
        // Duplicate the current process and set env vars to indicate that the child should act as the Editor Window
        editor_process = std.process.Child.init(&.{ exe_or_dll_path, "editor" }, common.allocator); // the "editor" parameter is really ignored but it is here for reference to be found easily

        try common.env.put(DESHADER_EDITOR_URL, base);

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
                common.env.remove(DESHADER_EDITOR_URL);
            }
        }.watch, .{});
        try watcher.setName("EditorWatch");
        watcher.detach();
    }
}

pub fn windowTerminate() !void {
    if (editor_process) |*p| {
        if (builtin.os.tag == .windows) {
            editor_view.terminate();
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
            editor_mutex.lock();
            editor_shutdown.wait(&editor_mutex);
            editor_mutex.unlock();
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
    if (builtin.os.tag == .windows) {
        editor_view = view;
    }
    view.setTitle("Deshader Editor");
    view.setSize(600, 400, .none);

    // Inform the deshader-editor VSCode extension that it is running inside embdedded editor
    const urlZ = try common.allocator.dupeZ(u8, url);
    defer common.allocator.free(urlZ);
    view.navigate(urlZ);

    view.run();
    editor_mutex.lock();
    editor_shutdown.signal();
    if (builtin.os.tag == .windows) {
        editor_process = null;
    }
    editor_mutex.unlock();
}
