const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const wv = @import("positron");
const shrink = @import("tools/shrink.zig");
const gl = @import("gl");

const AppState = struct {
    arena: std.heap.ArenaAllocator,
    provider: *wv.Provider,
    view: *wv.View,

    shutdown_thread: u32,

    pub fn getWebView(app: *AppState) *wv.View {
        return app.view;
    }
};
const DeshaderLog = std.log.scoped(.Deshader);

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

    const provider = wv.Provider.create(std.heap.c_allocator, port) catch return 1;
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

    app.view.setTitle("Deshader Editor");

    app.view.navigate(app.provider.getUri("/index.html") orelse unreachable);

    app.view.run();

    @atomicStore(u32, &app.shutdown_thread, 1, .SeqCst);

    return 0;
}

var originalGlLib: ?std.DynLib = null;

pub export fn loadGlLib() callconv(.C) void {
    const libName = std.os.getenv("DESHADER_GL_LIBRARY") orelse switch (builtin.os.tag) {
        .windows => "openGL32.dll",
        .linux => "libGL.so",
        .macos => "libGL.dylib",
        else => {
            DeshaderLog.err("Unsupported OS: {s}", .{builtin.os.name});
        },
    };
    if (std.DynLib.open(libName)) |openedLib| {
        originalGlLib = openedLib;
    } else |err| {
        DeshaderLog.err("Failed to open {s}: {any}", .{ libName, err });
    }
}

// Run function at Deshader shared library load
export const init_array linksection(".init_array") = &loadGlLib;

/// Interceptors for OpenGL functions
pub fn deshaderGetProcAddress(procedure: [*:0]const u8) callconv(.C) *align(@alignOf(fn (u32) callconv(.C) u32)) const anyopaque {
    if (originalGlLib == null) {
        return undefined;
    }
    return originalGlLib.?.lookup(gl.FunctionPointer, std.mem.span(procedure)) orelse undefined;
}

comptime {
    var trampolineNames = [_][]const u8{ "wglGetProcAddress", "glXGetProcAddressARB", "glXGetProcAddress", "eglGetProcAddress" };
    if (options.GlAdditionalLoader) |name| {
        trampolineNames = trampolineNames ++ [_][]const u8{name};
    }
    inline for (trampolineNames) |trampolineName| {
        @export(deshaderGetProcAddress, .{ .name = trampolineName, .linkage = .Strong });
    }
}

test "declarations" {
    std.testing.expect(@TypeOf(deshaderGetProcAddress).ReturnType == gl.FunctionPointer);
}
