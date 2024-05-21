const std = @import("std");
const gl = @import("gl");
const options = @import("options");
const builtin = @import("builtin");
const DeshaderLog = @import("../log.zig").DeshaderLog;
const common = @import("../common.zig");
const transitive = @import("transitive.zig");
const c = @cImport({
    if (builtin.os.tag == .windows) {
        @cInclude("windows.h");
        @cInclude("GL/gl.h"); // Letter case is important (when cross-compiling from Linux)
    } else {
        @cInclude("dlfcn.h");
    }
});
const gl_shaders = @import("../interceptors/gl_shaders.zig");

const String = []const u8;
const ZString = [:0]const u8;
const CString = [*:0]const u8;
const GetProcAddressSignature = fn (name: CString) gl.FunctionPointer;

// TODO multi-context
// TODO wasm
pub const APIs = struct {
    pub const gl = if (builtin.os.tag == .windows) struct {
        pub const wgl = struct {
            const names = [_]String{"C:\\Windows\\System32\\opengl32.dll"};
            pub var lib: ?std.DynLib = null;
            pub var loader: ?*const GetProcAddressSignature = null;
            const default_loaders = [_]String{"wglGetProcAddress"};
            var possible_loaders: []const String = &@This().default_loaders;
            const make_current_names: []const String = &.{ "wglMakeCurrent", "wglMakeContextCurrentARB" };
            pub var make_current: struct {
                *const fn (hdc: *const anyopaque, hglrc: *const anyopaque) c_int,
                *const fn (draw: *const anyopaque, read: *const anyopaque, context: ?*const anyopaque) c_int,
            } = .{ undefined, undefined };
            const create_names: []const String = &.{ "wglCreateContext", "wglCreateContextAttribsARB" };
            pub var create: struct {
                *const fn (hdc: *const anyopaque) ?*const anyopaque,
                *const fn (hdc: *const anyopaque, attribs: *const c_int) ?*const anyopaque,
            } = .{ undefined, undefined };
            pub var late_loaded = false;
        };
        pub const custom = struct {
            var names: []const String = &[_]String{};
            pub var lib: ?std.DynLib = null;
            pub var loader: ?*const GetProcAddressSignature = null;
            var possible_loaders: []const String = &.{};
            var make_current_names: []const ZString = &.{""};
            pub var make_current: struct { *const fn (hdc: *const anyopaque, hglrc: *const anyopaque) c_int } = .{undefined};
            pub var create_names = []const ZString{""};
            pub var create: struct { *const fn (hdc: *const anyopaque) ?*const anyopaque } = .{undefined};
            pub var late_loaded = false;
        };
    } else struct {
        pub const glX = struct {
            const names = [_]String{ "libGLX.so", "libGL.so" }; //TODO also "libOpenGL.so" ?
            pub var lib: ?std.DynLib = null;
            pub var loader: ?*const GetProcAddressSignature = null;
            const default_loaders = [_]String{ "glXGetProcAddress", "glXGetProcAddressARB" };
            var possible_loaders: []const String = &@This().default_loaders;
            const make_current_names: []const ZString = &.{ "glXMakeCurrent", "glXMakeContextCurrent" };
            pub var make_current: struct {
                *const fn (display: *const anyopaque, drawable: c_ulong, context: ?*const anyopaque) c_int,
                *const fn (display: *const anyopaque, draw: c_ulong, read: c_ulong, context: ?*const anyopaque) c_int,
            } = .{ undefined, undefined };
            const create_names: []const ZString = &.{ "glXCreateContext", "glXCreateNewContext", "glXCreateContextAttribsARB" };
            pub var create: struct {
                *const fn (display: *const anyopaque, vis: *const anyopaque, share: *const anyopaque, direct: c_int) ?*const anyopaque,
                *const fn (display: *const anyopaque, render_type: c_int, share: *const anyopaque, direct: c_int) ?*const anyopaque,
                *const fn (display: *const anyopaque, vis: *const anyopaque, share: *const anyopaque, direct: c_int, attribs: ?[*]const c_int) ?*const anyopaque,
            } = .{ undefined, undefined, undefined };
            pub var late_loaded = false;
        };
        pub const egl = struct {
            const names = [_]String{"libEGL.so"};
            pub var lib: ?std.DynLib = null;
            pub var loader: ?*const GetProcAddressSignature = null;
            const default_loaders = [_]String{"eglGetProcAddress"};
            var possible_loaders: []const String = &@This().default_loaders;
            const make_current_names: []const ZString = &.{"eglMakeCurrent"};
            pub var make_current: struct { *const fn (display: *const anyopaque, draw: *const anyopaque, read: *const anyopaque, context: ?*const anyopaque) c_uint } = .{undefined};
            const create_names: []const ZString = &.{"eglCreateContext"};
            pub var create: struct {
                *const fn (display: *const anyopaque, config: *const anyopaque, share: *const anyopaque, attribs: ?[*]const c_int) ?*const anyopaque,
            } = .{undefined};
            pub var late_loaded = false;
        };
        pub const custom = struct {
            var names: []const String = &[_]String{};
            pub var lib: ?std.DynLib = null;
            pub var loader: ?*const GetProcAddressSignature = null;
            var make_current_names: []const ZString = &.{""};
            var make_current: struct { *const fn (display: *const anyopaque, draw: c_ulong, context: ?*const anyopaque) c_int } = .{undefined};
            var possible_loaders: []const String = &.{};
            var create_names: []const ZString = &.{""};
            var create: struct { *const fn (display: *const anyopaque, vis: *const anyopaque, share: *const anyopaque, direct: c_int) ?*const anyopaque } = .{undefined};
            pub var late_loaded = false;
        };
    };
    pub var originalDlopen: ?*const fn (name: ?CString, mode: c_int) callconv(.C) ?*const anyopaque = null;
};

var reported_process_name = false;
var renamed_libs: std.ArrayList(String) = undefined;
pub var ignored = false;
pub fn checkIgnoredProcess() void {
    var ignored_this = false;
    if (common.selfExePathAlloc(common.allocator)) |self_path| {
        defer common.allocator.free(self_path);
        var set_reported_process_name = reported_process_name;
        defer reported_process_name = set_reported_process_name;
        if (!reported_process_name) {
            DeshaderLog.debug("From process {s}", .{self_path});
            set_reported_process_name = true;
        }

        const only_process_env = common.env.get(common.env_prefix ++ "PROCESS");
        if (only_process_env) |only| {
            ignored_this = true;
            var it = std.mem.splitScalar(u8, only, ',');
            while (it.next()) |p_name| {
                if (std.mem.endsWith(u8, self_path, p_name)) {
                    if (!reported_process_name) {
                        DeshaderLog.debug("Whitelisting processes {s}", .{p_name});
                    }
                    ignored_this = false;
                    break;
                }
            }
            if (ignored_this and !reported_process_name) {
                DeshaderLog.debug("{s} not on whitelist: {s}", .{ self_path, only });
            }
        }
        // balcklist
        const ignore_process_env = common.env.get(common.env_prefix ++ "IGNORE_PROCESS");
        if (ignore_process_env != null) {
            var it = std.mem.splitScalar(u8, ignore_process_env.?, ',');
            while (it.next()) |p_name| {
                if (std.mem.endsWith(u8, self_path, p_name)) {
                    if (!reported_process_name) {
                        DeshaderLog.debug("Ignoring processes {s}", .{ignore_process_env.?});
                    }
                    ignored_this = true;
                    break;
                }
            }
        }
    } else |e| {
        DeshaderLog.err("Failed to get self path: {any}", .{e});
    }
    ignored = ignored or ignored_this;
}

// Intercept dlopen on POSIX systems
comptime {
    if (builtin.os.tag != .windows) {
        @export(struct {
            fn dlopen(name: ?[*:0]u8, mode: c_int) callconv(.C) ?*const anyopaque {
                // Check for initialization
                if (APIs.originalDlopen == null) {
                    APIs.originalDlopen = @ptrCast(std.c.dlsym(c.RTLD_NEXT, "dlopen"));
                    if (APIs.originalDlopen == null) {
                        DeshaderLog.err("Failed to find original dlopen: {s}", .{c.dlerror()});
                    }

                    if (!common.initialized) {
                        common.init() catch |err|
                            DeshaderLog.err("Failed to initialize: {any}", .{err});
                    }
                }
                checkIgnoredProcess();
                if (name != null) {
                    var name_span = std.mem.span(name.?);

                    // Ignore libraries marked with '?' and pass them to the original dlopen
                    if (name_span[name_span.len - 1] == '?') {
                        name_span[name_span.len - 1] = 0; // kindly replace with sentinel
                        const result = APIs.originalDlopen.?(name, mode);
                        if (result == null) {
                            DeshaderLog.debug("Failed original dlopen {?s}: {?s}", .{ name, @as(?CString, c.dlerror()) });
                        }
                        return result;
                    }
                    if (!ignored) inline for (_platform_gl_libs) |lib| {
                        inline for (lib.names) |possible_name| {
                            if (std.mem.startsWith(u8, name_span, possible_name)) {
                                DeshaderLog.debug("Intercepting dlopen for API {s}", .{name_span});
                                return APIs.originalDlopen.?(@ptrCast(options.deshaderLibName ++ &[_]u8{0}), mode);
                            }
                        }
                    };
                }
                const result = APIs.originalDlopen.?(name, mode);
                if (result == null) {
                    DeshaderLog.debug("Failed ignored dlopen {?s}: {?s}", .{ name, @as(?CString, c.dlerror()) });
                }
                return result;
            }
        }.dlopen, .{ .name = "dlopen" });
    }
}

const _known_gl_loaders =
    (if (builtin.os.tag == .windows) APIs.gl.wgl.default_loaders ++ APIs.gl.wgl.make_current_names ++ APIs.gl.wgl.create_names else APIs.gl.glX.default_loaders ++ APIs.gl.glX.make_current_names ++ APIs.gl.glX.create_names ++ APIs.gl.egl.default_loaders ++ APIs.gl.egl.make_current_names ++ APIs.gl.egl.create_names) ++ [_]?String{options.glAddLoader};
const _platform_gl_libs = if (builtin.os.tag == .windows) .{APIs.gl.wgl} else .{ APIs.gl.glX, APIs.gl.egl };
const _gl_libs = _platform_gl_libs ++ .{APIs.gl.custom};

/// Lists all exported declarations inside interceptors/shaders.zig and creates a map from procedure name to procedure pointer
pub const intercepted = blk: {
    const decls = @typeInfo(gl_shaders).Struct.decls ++ @typeInfo(gl_shaders.context_procs).Struct.decls;

    var count = 0;
    for (decls) |decl| {
        if (std.mem.startsWith(u8, decl.name, "gl") or std.mem.startsWith(u8, decl.name, "egl")) {
            count += 1;
        }
    }
    var i = 0;
    comptime var procs: [count]struct { String, gl.FunctionPointer } = undefined;
    comptime var names2: [count]?String = undefined;
    for (decls) |proc| {
        if (std.mem.startsWith(u8, proc.name, "gl") or std.mem.startsWith(u8, proc.name, "egl")) {
            defer i += 1;
            names2[i] = proc.name;
            procs[i] = .{
                proc.name,
                // depends on every declaration in gl_shaders.zig to be a function or a private struct (so not listed here). It cannot be pub struct
                if (@hasDecl(gl_shaders, proc.name)) @field(gl_shaders, proc.name) else @field(gl_shaders.context_procs, proc.name),
            };
        }
    }
    break :blk struct {
        const names = names2;
        const map = std.ComptimeStringMap(gl.FunctionPointer, procs);
    };
};
pub const all_exported_names = _known_gl_loaders ++ intercepted.names;

// Container for all OpenGL function symbols TODO
const GlFunctions = struct {
    fn load(self: *@This(), loader: GetProcAddressSignature) void {
        const fields = @typeInfo(@This()).Struct.fields;
        inline for (fields) |field| {
            @field(self, field.name) = loader(field.name);
        }
    }
};

pub fn useLoader(loader: *const GetProcAddressSignature, proc: ZString) gl.FunctionPointer {
    return loader(proc);
}

fn withoutTrailingSlash(path: String) String {
    return if (path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
}

pub fn loadGlLib() !void {
    if (builtin.os.tag == .windows) { // Assuming loadGlLib is called before loadVkLib
        renamed_libs = std.ArrayList(String).init(common.allocator);
    }

    const customLib = common.env.get(common.env_prefix ++ "GL_LIBS");
    if (customLib != null) {
        var names = std.ArrayList(String).init(common.allocator);
        var split = std.mem.splitScalar(u8, customLib.?, ',');
        while (split.next()) |name| {
            names.append(name) catch |err|
                DeshaderLog.err("Failed to allocate memory for custom GL library name: {any}", .{err});
        }
        APIs.gl.custom.names = names.items;
    }
    const customProcLoaders = common.env.get(common.env_prefix ++ "GL_PROC_LOADERS");
    if (customProcLoaders != null) {
        var names = std.ArrayList(String).init(common.allocator);
        var it = std.mem.splitScalar(u8, customProcLoaders.?, ',');
        while (it.next()) |name| {
            names.append(name) catch |err|
                DeshaderLog.err("Failed to allocate memory for custom GL procedure loader name: {any}", .{err});
        }
        APIs.gl.custom.possible_loaders = names.items;
    }

    const substitute_name = common.env.get(common.env_prefix ++ "SUBSTITUTE_LOADER");
    if (substitute_name != null) {
        const substitute_options = enum { yes, @"1", true, other };
        switch (std.meta.stringToEnum(substitute_options, substitute_name.?) orelse .other) {
            .yes, .@"1", .true => {
                inline for (_platform_gl_libs) |lib| {
                    lib.possible_loaders = APIs.gl.custom.possible_loaders;
                }
            },
            else => {
                DeshaderLog.err("Only valid positive values are 'yes', '1', 'true'", .{});
            },
        }
    }

    const specified_library_root = common.env.get(common.env_prefix ++ "LIB_ROOT");

    inline for (_gl_libs) |gl_lib| {
        for (gl_lib.names) |lib_name| {
            // add '?' to mark this as not intercepted on POSIX systems
            const full_lib_name = if (builtin.os.tag == .windows) lib_name else try std.mem.concat(common.allocator, u8, if (specified_library_root == null) &.{ lib_name, "?" } else &.{ withoutTrailingSlash(specified_library_root.?), std.fs.path.sep_str, lib_name, "?" });
            defer if (builtin.os.tag != .windows) common.allocator.free(full_lib_name);
            if (loadNotDeshaderLibrary(full_lib_name)) |lib| {
                gl_lib.lib = lib;
                DeshaderLog.debug("Loaded library {s}", .{full_lib_name});
                for (gl_lib.possible_loaders) |loader| {
                    const loaderZ = try common.allocator.dupeZ(u8, loader);
                    defer common.allocator.free(loaderZ);
                    if (gl_lib.lib.?.lookup(*const GetProcAddressSignature, loaderZ)) |proc| {
                        gl_lib.loader = proc;
                        DeshaderLog.debug("Found procedure loader {s}", .{loader});
                        // Early load all GL functions (late loading happens in gl_shaders.makeCurrent())
                        if (@as(?*const anyopaque, gl.function_pointers.glShaderSource) == null) {
                            gl.load(proc, useLoader) catch |err|
                                DeshaderLog.err("Failed to early load some GL functions: {}", .{err});
                        }

                        break;
                    }
                }
                inline for (gl_lib.make_current, 0..) |func, i| {
                    if (gl_lib.lib.?.lookup(@TypeOf(func), gl_lib.make_current_names[i])) |target| {
                        gl_lib.make_current[i] = @ptrCast(target);
                    }
                }
                inline for (gl_lib.create, 0..) |func, i| {
                    if (gl_lib.lib.?.lookup(@TypeOf(func), gl_lib.create_names[i])) |target| {
                        gl_lib.create[i] = @ptrCast(target);
                    }
                }
            } else |err| {
                if (builtin.os.tag == .linux and builtin.link_libc) {
                    const err_to_print = c.dlerror();
                    if (err_to_print != null) {
                        DeshaderLog.debug("Failed to open {s}: {s}", .{ full_lib_name, err_to_print });
                    } else {
                        DeshaderLog.debug("Failed to open {s}: {any}", .{ full_lib_name, err });
                    }
                } else {
                    DeshaderLog.debug("Failed to open {s}: {any}", .{ full_lib_name, err });
                }
            }
        }
    }
}

/// Mut be absolute path on Windows
fn loadNotDeshaderLibrary(original_name: []const u8) !std.DynLib {
    if (builtin.os.tag == .windows and common.env.get("WINELOADER") == null and blk: {
        const this_name = try common.selfDllPathAlloc(common.allocator, "");
        defer common.allocator.free(this_name);
        break :blk std.ascii.eqlIgnoreCase(std.fs.path.basename(this_name), std.fs.path.basename(original_name));
    }) {
        // The original dll must be firstly renamed to prevent recursive hooking
        const renamed_name = try std.mem.concat(common.allocator, u8, &.{ "original.", std.fs.path.basename(original_name) });
        try renamed_libs.append(renamed_name);
        try common.symlinkOrCopy(std.fs.cwd(), original_name, renamed_name);
        return std.DynLib.open(renamed_name);
    } else {
        // On Linux we use LD_PRELOAD so there is no conflict with original name
        return std.DynLib.open(original_name);
    }
}

pub fn deinit() void {
    const cwd = std.fs.cwd().fd;
    defer renamed_libs.deinit();
    for (renamed_libs.items) |lib| {
        std.os.unlinkat(cwd, lib, if (builtin.os.tag == .linux) std.os.AT.SYMLINK_NOFOLLOW else 0) catch |err|
            DeshaderLog.err("Could not delete renamed lib {s}: {}", .{ lib, err });
    }
    if (!ignored) {
        gl_shaders.deinit();
    }
}

//
// Gpahics API procedure loaders interception
//
pub fn LoaderInterceptor(comptime interface: type, comptime loader: String) type {
    return struct {
        /// Generic loader interception function
        pub fn loaderReplacement(procedure: CString) callconv(.C) ?gl.FunctionPointer {
            if (interface.loader == null) {
                DeshaderLog.err("Loader " ++ loader ++ " is not available", .{});
                return null;
            }
            const original = interface.loader.?(procedure);
            const target = intercepted.map.get(std.mem.span(procedure));
            if (target != null) {
                if (options.logIntercept) {
                    DeshaderLog.debug("Intercepting " ++ loader ++ " procedure {s}", .{procedure});
                }
                return target.?;
            }
            return original;
        }
    };
}

/// Interceptor for custom library
pub fn deshaderGetProcAddress(procedure: CString) callconv(.C) *align(@alignOf(fn (u32) callconv(.C) u32)) const anyopaque {
    if (options.logIntercept) {
        DeshaderLog.debug("Intercepting custom GL proc address {s}", .{procedure});
    }
    if (APIs.gl.custom.loader == null) {
        return undefined;
    }
    return APIs.gl.custom.loader.?(procedure);
}

// Export the interceptors
comptime {
    for (_platform_gl_libs) |lib| {
        for (lib.default_loaders) |gl_loader| {
            const r = LoaderInterceptor(lib, gl_loader);
            @export(r.loaderReplacement, .{ .name = gl_loader });
        }
    }
    if (options.glAddLoader) |name| {
        @export(deshaderGetProcAddress, .{ .name = name });
    }
} // end comptime
