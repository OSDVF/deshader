// Copyright (C) 2024  Ondřej Sabela
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

//! This module provides the editor server and the editor window
//! Injects current Deshader settings into the editor extension

const std = @import("std");
const builtin = @import("builtin");
const positron = @import("positron");
const serve = @import("serve");
const common = @import("common");
const options = @import("options");
const ctregex = @import("ctregex");
const extended_wv = @import("extended_wv.zig");

const log = std.log.scoped(.GUI);

const C = @cImport(if (builtin.os.tag == .linux) {
    @cInclude("gtk/gtk.h");
});

const String = []const u8;
const ZString = [:0]const u8;

pub fn getProductJson(allocator: std.mem.Allocator, https: bool, srv_authority: String, comm_url: ?String) !String {
    const comm_uri: ?std.Uri = if (comm_url) |h| try std.Uri.parse(h) else null;
    // TODO probe the https://open-vsx.org and do not use it if not available (vscode would not even work without the gallery)
    const comm_authority = if (comm_uri) |u| try std.fmt.allocPrint(allocator, "{+}", .{u}) else null;
    defer if (comm_authority) |a| allocator.free(a);

    const name = if (comm_authority) |c| try std.fmt.allocPrint(allocator, "Deshader {s}", .{c}) else null;
    defer if (name) |n| allocator.free(n);

    return try std.json.stringifyAlloc(allocator, .{
        .productConfiguration = .{
            .nameShort = "Deshader Editor",
            .nameLong = "Deshader Integrated Editor",
            .applicationName = "deshader-editor",
            .dataFolderName = ".deshader-editor",
            .version = "1.91.1",
            .extensionsGallery = .{
                .serviceUrl = "https://open-vsx.org/vscode/gallery",
                .itemUrl = "https://open-vsx.org/vscode/item",
                .resourceUrlTemplate = "https://openvsxorg.blob.core.windows.net/resources/{publisher}/{name}/{version}/{path}",
            },
            .extensionEnabledApiProposals = .{
                .@"osdvf.deshader" = .{ "fileSearchProvider", "textSearchProvider", "resolvers", "contribViewsRemote" },
            },
        },
        .folderUri = if (comm_uri) |u|
            .{
                .scheme = if (std.ascii.eqlIgnoreCase(u.scheme, "ws"))
                    "deshaderws"
                else if (std.ascii.eqlIgnoreCase(u.scheme, "wss"))
                    "deshaderwss"
                else if (std.ascii.eqlIgnoreCase(u.scheme, "http"))
                    "deshader"
                else if (std.ascii.eqlIgnoreCase(u.scheme, "https"))
                    "deshaders"
                else
                    u.scheme,
                .authority = comm_authority.?,
                .path = "/",
                .name = name.?,
            }
        else
            null,
        .additionalBuiltinExtensions = .{ .{
            .scheme = if (https) "https" else "http",
            .authority = srv_authority,
            .path = "/deshader-vscode",
        }, .{
            .scheme = if (https) "https" else "http",
            .authority = srv_authority,
            .path = "/glsl-language-support",
        } },
    }, .{ .whitespace = .minified, .emit_null_optional_fields = false });
}

/// Inserts correct authorities into product.json
fn productJsonHandler(_: *positron.Provider, r: *positron.Provider.Route, c: *serve.http.Context) positron.Provider.Route.Error!void {
    const commands_url: [*:0]u8 = @alignCast(@ptrCast(r.context));
    // Generate product.json according to current settings
    const srv_authority = c.request.headers.get("Host") orelse "127.0.0.1:" ++ common.default_editor_port;
    const product_config = getProductJson(common.allocator, c.ssl != null, srv_authority, if (commands_url[0] != 0) std.mem.span(commands_url) else null) catch |e| {
        log.err("Failed to generate product.json: {}", .{e});
        return positron.Provider.Route.Error.Unknown;
    };
    defer common.allocator.free(product_config);
    try c.response.setHeader("Content-Type", "application/json");
    try c.response.setHeader("Cache-Control", "max-age=1800, public");
    const w = try c.response.writer();
    try w.writeAll(product_config);
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

fn decompress(provider: *positron.Provider, comptime file: String, dll_path: String, compressed_or_content: anytype) ![]u8 {
    const f_address = file[options.editor_dir.len..];
    if (builtin.mode == .Debug) {
        var dll_dir: ?std.fs.Dir = if (builtin.mode == .Debug) if (std.fs.path.dirname(dll_path)) |d| try std.fs.cwd().openDir(d, .{}) else null else null;
        defer if (dll_dir) |*d| d.close();
        const handle = try if (dll_dir) |d| d.openFile(options.editor_dir_relative ++ f_address, .{}) else std.fs.cwd().openFile(file, .{});
        defer handle.close();
        return try handle.readToEndAlloc(provider.allocator, provider.max_file_size);
    } else {
        var stream = std.io.fixedBufferStream(compressed_or_content);
        const reader = stream.reader();
        var decompressor = std.compress.zlib.decompressor(reader);
        var decompressed = decompressor.reader();
        return try decompressed.readAllAlloc(provider.allocator, provider.max_file_size);
    }
}

fn addCacheHeaders(_: *positron.Provider, _: ?*positron.Provider.Route, c: *serve.http.Context) positron.Provider.Route.Error!void {
    if (builtin.mode == .Debug and std.ascii.indexOfIgnoreCase(c.request.url, "deshader-vscode/dist") != null) {
        try c.response.setHeader("Cache-Control", "max-age=0, public");
    } else try c.response.setHeader("Cache-Control", "max-age=1800, public");
}

fn addDeflateHeaders(p: *positron.Provider, r: ?*positron.Provider.Route, c: *serve.http.Context) positron.Provider.Route.Error!void {
    try c.response.setHeader("Content-Encoding", "deflate");
    try addCacheHeaders(p, r, c);
}
const ext_js_address = "/deshader-vscode/dist/extension.js";
// basicaly a HTTP server
pub fn createEditorProvider(port: u16, commands_uri: ?String, lsp_host: ?String) !*positron.Provider {
    var provider = try positron.Provider.create(common.allocator, port);
    provider.allowed_origins = std.BufSet.init(provider.allocator);
    provider.additional_handler = &addCacheHeaders;

    inline for (.{ "localhost", "127.0.0.1" }) |origin| {
        const concatOrigin = try std.fmt.allocPrint(provider.allocator, "{s}://{s}:{d}", .{ if (provider.server.bindings.getLast().tls == null) "http" else "https", origin, port });
        defer provider.allocator.free(concatOrigin);
        try provider.allowed_origins.?.insert(concatOrigin);
    }
    const dll_path = if (builtin.mode == .Debug) try resolveSelfDllTarget(provider.allocator);

    defer if (builtin.mode == .Debug) provider.allocator.free(dll_path);
    if (builtin.mode == .Debug) {
        // Let the provider read the files at runtime in debug mode
        const editor_dir_path = try std.fs.path.join(provider.allocator, if (std.fs.path.dirname(dll_path)) |d| &.{ d, options.editor_dir_relative } else &.{options.editor_dir});
        try provider.embedded.append(positron.Provider.EmbedDir{ .address = "/", .path = editor_dir_path, .resolveMime = &resolveMime });
    }
    inline for (options.files) |file| {
        const lastDot = std.mem.lastIndexOf(u8, file, &[_]u8{@as(u8, '.')});
        const fileExt = if (lastDot != null) file[lastDot.? + 1 ..] else "";
        const mime_type = resolveMime(file);

        if (builtin.mode != .Debug and try ctregex.search("map|ts", .{}, fileExt) != null) {
            comptime continue; // Do not include sourcemaps in release builds
        }
        const f_address = file[options.editor_dir.len..];
        // assume all paths start with `options.editor_dir`
        const compressed_or_content = if (builtin.mode != .Debug) @embedFile(file);
        if (comptime std.ascii.eqlIgnoreCase(f_address, ext_js_address)) {
            const decompressed_data = try decompress(provider, file, dll_path, compressed_or_content);
            defer provider.allocator.free(decompressed_data);
            // Inject editor config into Deshader extension
            // Construct editor base url and config JSON
            if (lsp_host != null or commands_uri != null) {
                const json = try std.json.stringifyAlloc(provider.allocator, .{
                    .commands = commands_uri,
                    .lsp = lsp_host,
                }, .{});

                defer provider.allocator.free(json);
                const editor_config = try std.fmt.allocPrint(provider.allocator,
                    \\{s}
                    \\globalThis.deshader={s}
                ++ "", .{ decompressed_data, json });
                _ = try provider.addContentNoAlloc(f_address, mime_type, editor_config);
            } else if (builtin.mode != .Debug) {
                const handler = try provider.addContentNoAlloc(f_address, mime_type, compressed_or_content);
                handler.additional_handler = &addDeflateHeaders;
            }
        } else if (builtin.mode != .Debug) {
            const handler = try provider.addContentNoAlloc(f_address, mime_type, compressed_or_content);
            handler.additional_handler = &addDeflateHeaders;
        }
    }

    const product_route = try provider.addRoute("/product.json");
    const comm: [*:0]u8 = (try provider.allocator.dupeZ(u8, commands_uri orelse "")).ptr;
    product_route.context = @constCast(@ptrCast(comm));
    product_route.handler = &productJsonHandler;

    inline for (.{ "/run", "/browseFile", "/browseDirectory", "/isRunning", "/terminate" }) |command| {
        var route = try provider.addRoute(command);
        route.handler = &rpcHandler;
    }

    provide_thread = try std.Thread.spawn(.{}, positron.Provider.run, .{provider});
    provide_thread.?.setName("GUIServer") catch {};
    return provider;
}

pub const EditorProviderError = error{ AlreadyRunning, NotRunning };

pub var global_provider: ?*positron.Provider = null;
var base_url: ZString = undefined;
pub fn serverStart(port: u16, commands_url: ?String, lsp_host: ?String) !void {
    if (global_provider != null) {
        for (global_provider.?.server.bindings.items) |binding| {
            log.err("GUI server already running on port {d}", .{binding.port});
        }
        return error.AlreadyRunning;
    }
    global_provider = try createEditorProvider(port, commands_url, lsp_host);
    errdefer {
        global_provider.?.destroy();
        global_provider = null;
    }
}

pub fn serverStop() EditorProviderError!void {
    if (global_provider) |p| {
        if (builtin.mode == .Debug) p.allocator.free(p.embedded.items[0].path);
        for (p.routes.items) |r| {
            if (std.mem.endsWith(u8, r.prefix, "/product.json")) {
                p.allocator.free(std.mem.span(@as([*:0]u8, @ptrCast(r.context))));
            } else if (std.mem.endsWith(u8, r.prefix, ext_js_address)) {
                const handler: *positron.Provider.ContentHandler = r.getContext(positron.Provider.ContentHandler);
                p.allocator.free(handler.contents);
            }
        }
        p.destroy();
        provide_thread.?.join();
        common.allocator.destroy(p);
        global_provider = null;
    } else {
        log.err("GUI server not running", .{});
        return error.NotRunning;
    }
}

pub fn serverJoin() EditorProviderError!void {
    if (provide_thread) |p| {
        p.join();
    } else {
        log.err("GUI server not running", .{});
        return error.NotRunning;
    }
}

// GUI Window runs in a separate process on unices, or in a thread on Windows
pub var gui_process: if (builtin.os.tag == .windows) ?std.Thread else ?std.process.Child = null;
var gui_mutex = std.Thread.Mutex{};
var gui_shutdown = std.Thread.Condition{};
var state: extended_wv.State = .{};

const GuiErrors = error{GuiNotEmbedded};
pub const DESHADER_GUI_URL = common.env_prefix ++ "GUI_URL";

/// Spawns a new thread that runs the editor
/// This function will block until the editor is ready to be used
pub fn editorShow(port: u16, commands_host: ?String, lsp_host: ?String) !void {
    if (!options.editor) {
        log.err("GUI not embedded in this Deshader Launcher distribution. Cannot show it.", .{});
        return error.GuiNotEmbedded;
    }

    if (global_provider == null) {
        try serverStart(port, commands_host, lsp_host);
    }
    if (gui_process != null or common.env.get(DESHADER_GUI_URL) != null) {
        log.err("GUI already running", .{});
        return error.AlreadyRunning;
    }

    base_url = (try global_provider.?.getUriAlloc("/index.html")).?;
    log.info("GUI URL: {s}", .{base_url});

    if (builtin.os.tag == .windows) {
        // On Windows, the GUI runs in a separate thread
        gui_process = try std.Thread.spawn(.{ .allocator = common.allocator }, guiProcess, .{ base_url, "Deshader Editor" });
        gui_process.?.setName("GUI") catch {};
        gui_process.?.detach();
    } else {
        // On Unix, the GUI runs in a separate process
        const exe_or_dll_path = try common.selfExePath();
        // Duplicate the current process and set env vars to indicate that the child should act as the Editor Window
        gui_process = std.process.Child.init(&.{ exe_or_dll_path, "editor" }, common.allocator); // the "editor" parameter is really ignored but it is here for reference to be found easily

        common.env.set(DESHADER_GUI_URL, base_url);

        gui_process.?.env_map = common.env.getMap();
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
                } else {
                    if (common.process.wailNoFailReport(&gui_process.?)) |term| {
                        if (term == .Exited and term.Exited == 0) {
                            if (global_provider) |gp| {
                                gp.allocator.free(base_url);
                            }
                        }
                    }
                }
                gui_process = null;
            }
        }.watch, .{});
        watcher.setName("EditorWatch") catch {};
        watcher.detach();
    }
}

pub fn editorTerminate() !void {
    if (gui_process) |*p| {
        if (builtin.os.tag == .windows) {
            state.view.terminate();
        } else {
            try std.posix.kill(p.id, std.posix.SIG.TERM);
        }
        if (global_provider) |pr| {
            pr.allocator.free(base_url);
        }
        log.debug("Editor terminated", .{});
    } else {
        log.err("Editor not running", .{});
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
            _ = common.process.wailNoFailReport(p);
        }
    } else {
        log.err("Editor not running", .{});
        return error.NotRunning;
    }
}

//
// The following code should exist only in the GUI subprocess
//
pub fn guiProcess(url: String, title: ZString) !void {
    if (builtin.os.tag == .linux) {
        try common.env.appendList(common.env_prefix ++ "IGNORE_PROCESS", "zenity:WebKitWebProcess");
    }

    state = .{};
    const deshader = "deshader";
    const window = if (builtin.os.tag == .linux) create: {
        _ = C.gtk_init_check(null, null);
        C.g_set_prgname(deshader);
        C.g_set_application_name(title); // Application name must be set before the window is created to be accepted by the window manager (and to assign the icon)
        C.gtk_window_set_default_icon_name(deshader);
        const w = C.gtk_window_new(C.GTK_WINDOW_TOPLEVEL);
        C.gtk_window_set_icon_name(@ptrCast(w), deshader);
        C.gtk_window_set_wmclass(@ptrCast(w), deshader, title);
        break :create w;
    } else null;

    state.view = try positron.View.create((@import("builtin").mode == .Debug), window);
    defer state.view.destroy();

    const titleZ = try common.allocator.dupeZ(u8, title);
    defer common.allocator.free(titleZ);
    state.view.setTitle(titleZ);
    state.view.setSize(800, 600, .none);
    const exe = try resolveSelfDllTarget(common.allocator);
    defer common.allocator.free(exe);

    if (builtin.os.tag != .linux) {
        const icon = try std.fs.path.joinZ(common.allocator, &.{ std.fs.path.dirname(exe) orelse ".", deshader ++ ".ico" });
        defer common.allocator.free(icon);
        if (std.fs.cwd().access(icon, .{})) {
            state.view.setIcon(icon);
        } else |_| {}
    }

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

fn resolveSelfDllTarget(allocator: std.mem.Allocator) !String {
    const self = try common.selfDllPathAlloc(allocator, "");
    if (builtin.os.tag == .windows) { // On windows, deshader may be symlinked
        defer common.allocator.free(self);
        const f = try std.fs.cwd().openFile(self, .{});
        defer f.close();
        return common.readLinkAbsolute(common.allocator, self) catch try common.allocator.dupe(u8, self);
    }
    return self;
}

/// Used to reply to request from the extension inside Deshader Editor
fn rpcHandler(p: *positron.Provider, r: *positron.Provider.Route, c: *serve.http.Context) positron.Provider.Route.Error!void {
    const Reject = struct {
        http: *serve.http.Context,

        fn reject(self: *const @This(), err: anytype) !void {
            if (!self.http.response.is_writing_body) {
                try self.http.response.setHeader("Content-Type", "text/plain");
                try self.http.response.setStatusCode(.bad_request);
            }
            var w = try self.http.response.writer();
            if (@typeInfo(@TypeOf(err)) == .error_set) {
                try w.print("Error: {}", .{err});
            } else {
                try w.writeAll(err);
            }
        }
    };
    const reject = Reject{ .http = c };

    var args = try common.argsFromFullCommand(p.allocator, c.request.url);
    defer if (args) |*a| a.deinit(p.allocator);
    if (std.mem.endsWith(u8, r.prefix, "run")) {
        if (state.running) {
            return reject.reject("Multiple subprocesses are not supported");
        }
        if (args) |a| {
            const argv = std.json.parseFromSlice([]String, p.allocator, a.get("argv").?, .{}) catch |e| return reject.reject(e);
            defer argv.deinit();
            const env = if (a.get("env")) |e| std.json.parseFromSlice(std.json.ArrayHashMap(String), p.allocator, e, .{}) catch |er| return reject.reject(er) else null;
            defer if (env) |e| e.deinit();
            var sanitized_env = if (env) |e| e.value else std.json.ArrayHashMap(String){};
            try sanitized_env.map.put(p.allocator, common.env_prefix ++ "GUI", "false"); // To not run multiple GUIs
            if (!common.nullOrEmpty(common.env.get(common.env_prefix ++ "LSP"))) {
                try sanitized_env.map.put(p.allocator, common.env_prefix ++ "LSP", ""); // To not run multiple LSPs
            }

            state.run(argv.value, a.get("directory") orelse "", sanitized_env) catch |er| return reject.reject(er);
            var w = try c.response.writer();
            try w.print("{}", .{state.target.id});
            // Because the subprocess inherited the socket, we need to close it here
            std.posix.shutdown(c.socket.internal, .both) catch |err| {
                log.err("Failed to shutdown socket: {}", .{err});
                return reject.reject(err);
            };
        }
    } else if (std.mem.endsWith(u8, r.prefix, "browseFile")) {
        const result = extended_wv.browseFile(&state, "");
        if (result) |res| {
            defer std.heap.raw_c_allocator.free(res);
            const j = try std.json.stringifyAlloc(p.allocator, res, .{});
            defer p.allocator.free(j);
            var w = try c.response.writer();
            try w.writeAll(j);
        }
    } else if (std.mem.endsWith(u8, r.prefix, "browseDirectory")) {
        const result = extended_wv.browseDirectory(&state, "");
        if (result) |res| {
            defer std.heap.raw_c_allocator.free(res);
            const j = try std.json.stringifyAlloc(p.allocator, res, .{});
            defer p.allocator.free(j);
            var w = try c.response.writer();
            try w.writeAll(j);
        }
    } else if (std.mem.endsWith(u8, r.prefix, "terminate")) {
        state.terminateTarget();
    } else if (std.mem.endsWith(u8, r.prefix, "isRunning")) {
        var w = try c.response.writer();
        try w.writeAll(if (state.running) "true" else "false");
    }
}
