//! This module provides the editor server and the editor window
//! Injects current Deshader settings into the editor extension

const std = @import("std");
const builtin = @import("builtin");
const positron = @import("positron");
const common = @import("../common.zig");
const commands = @import("../commands.zig");
const options = @import("options");
const ctregex = @import("ctregex");
const extended_wv = @import("./extended_wv.zig");

const DeshaderLog = @import("../log.zig").DeshaderLog;

const String = []const u8;
const ZString = [:0]const u8;

pub fn getProductJson(allocator: std.mem.Allocator, https: bool, port: u16) !String {
    const authority = try std.fmt.allocPrint(allocator, "127.0.0.1:{}", .{port});
    // TODO probe the https://open-vsx.org and do not use it if not available (vscode would not even work without the gallery)
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
                .@"osdvf.deshader-vscode" = .{ "fileSearchProvider", "textSearchProvider", "debugFocus" },
            },
        },
        .folderUri = .{
            .scheme = "deshader",
            .path = "/",
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
    const dll_path = if (builtin.mode == .Debug) try common.selfDllPathAlloc(provider.allocator, "");
    defer if (builtin.mode == .Debug) provider.allocator.free(dll_path);
    var dll_dir: ?std.fs.Dir = if (builtin.mode == .Debug) if (std.fs.path.dirname(dll_path)) |d| try std.fs.cwd().openDir(d, .{}) else null else null;
    defer if (dll_dir) |*d| d.close();
    if (builtin.mode == .Debug) {
        // Let the provider read the files at runtime in debug mode
        const editor_dir_path = try std.fs.path.join(provider.allocator, if (std.fs.path.dirname(dll_path)) |d| &.{ d, options.editorDirRelative } else &.{options.editorDir});
        try provider.embedded.append(positron.Provider.EmbedDir{ .address = "/", .path = editor_dir_path, .resolveMime = &resolveMime });
    }
    inline for (options.files) |file| {
        const lastDot = std.mem.lastIndexOf(u8, file, &[_]u8{@as(u8, '.')});
        const fileExt = if (lastDot != null) file[lastDot.? + 1 ..] else "";
        const mime_type = resolveMime(file);

        if (builtin.mode != .Debug and try ctregex.search("map|ts", .{}, fileExt) != null) {
            comptime continue; // Do not include sourcemaps in release builds
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
                    if (builtin.mode == .Debug) {
                        const handle = try if (dll_dir) |d| d.openFile(options.editorDirRelative ++ f_address, .{}) else std.fs.cwd().openFile(file, .{});
                        defer handle.close();
                        decompressed_data = try handle.readToEndAlloc(provider.allocator, 10 * 1024 * 1024);
                    } else {
                        var stream = std.io.fixedBufferStream(compressed_or_content);
                        const reader = stream.reader();
                        var decompressor = std.compress.zlib.decompressor(reader);
                        var decompressed = decompressor.reader();
                        decompressed_data = try decompressed.readAllAlloc(provider.allocator, 10 * 1024 * 1024);
                    }
                    defer provider.allocator.free(decompressed_data);
                    if (cl.ws_config) |wsc| {
                        editor_config = try std.fmt.allocPrint(provider.allocator, editor_config_fmt ++ "{s}\",port:{d}}}}}\n", .{ decompressed_data, commands.setting_vars.languageServerPort, if (cl.secure) "wss" else "ws", wsc.address, wsc.port });
                    } else {
                        if (cl.http) |http| {
                            if (http.server.bindings.getLastOrNull()) |bind| {
                                editor_config = try std.fmt.allocPrint(provider.allocator, editor_config_fmt ++ "{}\",port:{d}}}}}\n", .{ decompressed_data, commands.setting_vars.languageServerPort, if (cl.secure) "https" else "http", bind.address, bind.port });
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
    try provide_thread.?.setName("GUIServer");
    return provider;
}

pub const EditorProviderError = error{ AlreadyRunning, NotRunning };

pub var global_provider: ?*positron.Provider = null;
pub fn serverStart(command_listener: ?*const commands.CommandListener) !void {
    if (global_provider != null) {
        for (global_provider.?.server.bindings.items) |binding| {
            DeshaderLog.err("GUI server already running on port {d}", .{binding.port});
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
    if (global_provider) |p| {
        if (builtin.mode == .Debug) p.allocator.free(p.embedded.items[0].path);
        p.destroy();
        provide_thread.?.join();
        common.allocator.destroy(p);
        global_provider = null;
    } else {
        DeshaderLog.err("GUI server not running", .{});
        return error.NotRunning;
    }
}

// GUI Window runs in a separate process on unices, or in a thread on Windows
pub var gui_process: if (builtin.os.tag == .windows) ?std.Thread else ?std.process.Child = null;
var gui_mutex = std.Thread.Mutex{};
var gui_shutdown = std.Thread.Condition{};
pub var state = extended_wv.State{
    .view = undefined,
    .run = &dummyRun,
};
const GuiErrors = error{GuiNotEmbedded};
pub const DESHADER_GUI_URL = common.env_prefix ++ "GUI_URL";

/// Spawns a new thread that runs the editor
/// This function will block until the editor is ready to be used
pub fn editorShow(command_listener: ?*const commands.CommandListener) !void {
    if (!options.editor) {
        DeshaderLog.err("GUI not embedded in this Deshader distribution. Cannot show it.", .{});
        return error.GuiNotEmbedded;
    }

    if (global_provider == null) {
        try serverStart(command_listener);
    }
    if (gui_process != null or common.env.get(DESHADER_GUI_URL) != null) {
        DeshaderLog.err("GUI already running", .{});
        return error.AlreadyRunning;
    }

    const base = (try global_provider.?.getUriAlloc("/index.html")).?;
    defer global_provider.?.allocator.free(base);
    DeshaderLog.info("GUI URL: {s}", .{base});

    if (builtin.os.tag == .windows) {
        gui_process = try std.Thread.spawn(.{ .allocator = common.allocator }, guiProcess, .{ base, "Deshader Editor" });
        try gui_process.?.setName("GUI");
        gui_process.?.detach();
    } else {
        const exe_or_dll_path = try common.selfExePathAlloc(global_provider.?.allocator);
        defer global_provider.?.allocator.free(exe_or_dll_path);
        // Duplicate the current process and set env vars to indicate that the child should act as the Editor Window
        gui_process = std.process.Child.init(&.{ exe_or_dll_path, "editor" }, common.allocator); // the "editor" parameter is really ignored but it is here for reference to be found easily

        try common.env.put(DESHADER_GUI_URL, base);

        gui_process.?.env_map = &common.env;
        gui_process.?.stdout_behavior = .Inherit;
        gui_process.?.stderr_behavior = .Inherit;
        gui_process.?.stdin_behavior = .Close;
        try gui_process.?.spawn();
        common.env.remove(DESHADER_GUI_URL);

        // Watch the child process and inform about its end
        const watcher = try std.Thread.spawn(.{ .allocator = common.allocator }, struct {
            fn watch() !void {
                if (builtin.os.tag == .windows) {
                    _ = try gui_process.?.wait();
                } else { //Must be called separately because Zig std library contains extra security check which would crash
                    var status: u32 = undefined;
                    while (blk: {
                        const result = std.posix.system.waitpid(gui_process.?.id, @ptrCast(&status), std.posix.W.UNTRACED);
                        DeshaderLog.debug("Editor PID {d} watcher result {}", .{ gui_process.?.id, std.posix.errno(result) });
                        break :blk !(std.posix.W.IFEXITED(status) or std.posix.W.IFSTOPPED(status) or std.posix.W.IFSIGNALED(status));
                    }) {}
                }
                gui_process = null;
            }
        }.watch, .{});
        try watcher.setName("EditorWatch");
        watcher.detach();
    }
}

pub fn runnerGUI(run: *const fn (target_argv: []const String, working_dir: ?String, env: ?std.StringHashMapUnmanaged(String)) anyerror!void) !void {
    state.run = run;
    const content = @embedFile("../tools/run.html");
    const result_len = std.base64.standard.Encoder.calcSize(content.len);
    const preamble = "data:text/html;base64,";
    const result = try common.allocator.allocSentinel(u8, result_len + preamble.len, 0);
    defer common.allocator.free(result);

    @memcpy(result[0..preamble.len], preamble);
    _ = std.base64.standard.Encoder.encode(result[preamble.len..], content);

    // ignore zenity processes (file dialogs)
    const old_ignore_processes = common.env.get(common.env_prefix ++ "IGNORE_PROCESS");
    if (old_ignore_processes != null) {
        const merged = try std.fmt.allocPrint(common.allocator, "{s},zenity", .{old_ignore_processes.?});
        defer common.allocator.free(merged);
        common.setenv(common.env_prefix ++ "IGNORE_PROCESS", merged);
    } else {
        common.setenv(common.env_prefix ++ "IGNORE_PROCESS", "zenity");
    }
    try guiProcess(result, "Deshader Runner Tool");
}

pub fn editorTerminate() !void {
    if (gui_process) |*p| {
        if (builtin.os.tag == .windows) {
            state.view.terminate();
        } else {
            try std.posix.kill(p.id, std.posix.SIG.TERM);
        }
        DeshaderLog.debug("Editor terminated", .{});
    } else {
        DeshaderLog.err("Editor not running", .{});
        return error.NotRunning;
    }
}

pub fn editorWait() !void {
    if (gui_process) |*p| {
        if (builtin.os.tag == .windows) {
            gui_mutex.lock();
            gui_shutdown.wait(&gui_mutex);
            gui_mutex.unlock();
        } else {
            _ = std.posix.waitpid(p.id, 0);
        }
    } else {
        DeshaderLog.err("Editor not running", .{});
        return error.NotRunning;
    }
}

fn dummyRun(_: []const String, _: ?String, _: ?std.StringHashMapUnmanaged(String)) anyerror!void {}

//
// The following code should exist only in the GUI subprocess
//
pub fn guiProcess(url: ZString, title: ZString) !void {
    state.view = try positron.View.create((@import("builtin").mode == .Debug), null);
    defer state.view.destroy();

    const titleZ = try common.allocator.dupeZ(u8, title);
    defer common.allocator.free(titleZ);
    state.view.setTitle(titleZ);
    state.view.setSize(600, 400, .none);
    state.injectFunctions();

    // Inform the deshader-editor VSCode extension that it is running inside embdedded editor
    const urlZ = try common.allocator.dupeZ(u8, url);
    defer common.allocator.free(urlZ);
    state.view.navigate(urlZ);
    state.view.run();
    gui_mutex.lock();
    gui_shutdown.signal();
    if (builtin.os.tag == .windows) {
        gui_process = null;
    }
    gui_mutex.unlock();
}
