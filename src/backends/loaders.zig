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

const std = @import("std");
const gl = @import("gl");
const options = @import("options");
const builtin = @import("builtin");
const common = @import("common");
const log = common.log;
const transitive = @import("transitive.zig");
const c = @cImport({
    if (builtin.os.tag == .windows) {
        @cInclude("windows.h");
        @cInclude("GL/gl.h"); // Letter case is important (when cross-compiling from Linux)
    } else {
        @cInclude("dlfcn.h");
    }
});
const gl_shaders = @import("../backends/gl.zig");

const String = []const u8;
const ZString = [:0]const u8;
const CString = [*:0]const u8;
const GetProcAddressSignature = fn (name: CString) ?gl.PROC;

// TODO multi-context
// TODO wasm
pub const APIs = struct {
    pub const gl = if (builtin.os.tag == .windows) struct {
        pub const wgl = struct {
            pub const name = "wgl";
            const names = [_]String{"C:\\Windows\\System32\\opengl32.dll"};
            pub var lib: ?std.DynLib = null;
            pub var loader: ?*const GetProcAddressSignature = null;
            const default_loaders = [_]String{"wglGetProcAddress"};
            var possible_loaders: []const String = &@This().default_loaders;
            const make_current_names: []const ZString = &.{ "wglMakeCurrent", "wglMakeContextCurrentARB", "wglMakeContextCurrentEXT" };
            pub var make_current: struct {
                *const fn (hdc: *const anyopaque, hglrc: ?*const anyopaque) c_int,
                *const fn (hDrawDC: *const anyopaque, hReadDC: *const anyopaque, hglrc: ?*const anyopaque) c_int,
                *const fn (hDrawDC: *const anyopaque, hReadDC: *const anyopaque, hglrc: ?*const anyopaque) c_int,
            } = .{ undefined, undefined, undefined };
            const create_names: []const ZString = &.{ "wglCreateContext", "wglCreateContextAttribsARB" };
            pub var create: struct {
                *const fn (hdc: *const anyopaque) ?*const anyopaque,
                *const fn (hdc: *const anyopaque, share: *const anyopaque, attribs: ?[*]c_int) ?*const anyopaque,
            } = .{ undefined, undefined };
            const destroy_name = "wglDeleteContext";
            pub var destroy: ?*const fn (hdc: *const anyopaque) bool = null;
            const get_current_name = "wglGetCurrentContext";
            pub var get_current: ?*const fn () ?*const anyopaque = null;
            pub var late_loaded = false;
            pub const MakeCurrentParams = struct { *const anyopaque };
        };
        pub const custom = struct {
            pub const name = "custom";
            var names: []const String = &[_]String{};
            pub var lib: ?std.DynLib = null;
            pub var loader: ?*const GetProcAddressSignature = null;
            var possible_loaders: []const String = &.{};
            var make_current_names: []const ZString = &.{""};
            pub var make_current: struct { *const fn (hdc: *const anyopaque, hglrc: ?*const anyopaque) c_int } = .{undefined};
            pub var create_names = [_]ZString{""};
            pub var create: struct { *const fn (hdc: *const anyopaque) ?*const anyopaque } = .{undefined};
            var destroy_name = "";
            pub var destroy: ?*const fn (hdc: *const anyopaque) bool = null;
            var get_current_name: ZString = "";
            pub var get_current: ?*const fn () ?*const anyopaque = null;
            pub const MakeCurrentParams = struct { *const anyopaque };
            pub var late_loaded = false;
        };
    } else struct {
        pub const glX = struct {
            pub const name = "glX";
            const names: []const String = &.{ "libGL" ++ builtin.target.dynamicLibSuffix(), "libGLX" ++ builtin.target.dynamicLibSuffix() }; //TODO also "libOpenGL.so" ?
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
            const destroy_name = "glXDestroyContext";
            pub var destroy: ?*const fn (display: *const anyopaque, context: *const anyopaque) bool = null;
            const get_current_name = "glXGetCurrentContext";
            pub var get_current: ?*const fn () ?*const anyopaque = null;
            pub const MakeCurrentParams = struct { *const anyopaque, c_ulong };
            pub var late_loaded = false;
        };
        pub const egl = struct {
            pub const name = "egl";
            const names: []const String = &.{"libEGL" ++ builtin.target.dynamicLibSuffix()};
            pub var lib: ?std.DynLib = null;
            pub var loader: ?*const GetProcAddressSignature = null;
            const default_loaders = [_]String{"eglGetProcAddress"};
            var possible_loaders: []const String = &@This().default_loaders;
            const make_current_names: []const ZString = &.{"eglMakeCurrent"};
            pub var make_current: struct { *const fn (display: *const anyopaque, draw: ?*const anyopaque, read: ?*const anyopaque, context: ?*const anyopaque) c_uint } = .{undefined};
            const create_names: []const ZString = &.{"eglCreateContext"};
            pub var create: struct {
                *const fn (display: *const anyopaque, config: *const anyopaque, share: *const anyopaque, attribs: ?[*]const c_int) ?*const anyopaque,
            } = .{undefined};
            const destroy_name = "eglDestroyContext";
            pub var destroy: ?*const fn (display: *const anyopaque, context: *const anyopaque) bool = null;
            const get_current_name = "eglGetCurrentContext";
            pub var get_current: ?*const fn () ?*const anyopaque = null;
            pub var late_loaded = false;
            pub const MakeCurrentParams = struct { *const anyopaque, *const anyopaque, *const anyopaque };
        };
        pub const cgl = struct {
            pub const name = "cgl";
            const names = &[_]String{ "/System/Library/Frameworks/OpenGL.framework/OpenGL", "/System/Library/Frameworks/OpenGL.framework/Libraries/libGL.dylib" };
            pub var lib: ?std.DynLib = null;
            pub var loader: ?*const GetProcAddressSignature = null;
            const default_loaders = [_]String{"CGLGetProcAddress"};
            var possible_loaders: []const String = &@This().default_loaders;
            const make_current_names: []const ZString = &.{"CGLSetCurrentContext"};
            pub var make_current: struct { *const fn (context: ?*const anyopaque) c_int } = .{undefined};
            const create_names: []const ZString = &.{"CGLCreateContext"};
            pub var create: struct { *const fn (pix: *const anyopaque, share: *const anyopaque, ctx: *const anyopaque) c_int } = .{undefined};
            const destroy_name = "CGLDestroyContext";
            pub var destroy: ?*const fn (context: *const anyopaque) bool = null;
            const get_current_name = "CGLGetCurrentContext";
            pub var get_current: ?*const fn () ?*const anyopaque = null;
            pub var late_loaded = false;
            pub const MakeCurrentParams = struct {};
        };
        pub const custom = struct {
            pub const name = "custom";
            var names: []String = &.{};
            pub var lib: ?std.DynLib = null;
            pub var loader: ?*const GetProcAddressSignature = null;
            var make_current_names: []const ZString = &.{""};
            pub var make_current: struct { *const fn (display: *const anyopaque, draw: c_ulong, context: ?*const anyopaque) c_int } = .{undefined};
            var possible_loaders: []const String = &.{};
            var create_names: []const ZString = &.{""};
            var create: struct { *const fn (display: *const anyopaque, vis: *const anyopaque, share: *const anyopaque, direct: c_int) ?*const anyopaque } = .{undefined};
            var destroy_name = "";
            pub var destroy: ?*const fn (display: *const anyopaque, context: *const anyopaque) bool = null;
            var get_current_name: ZString = "";
            pub var get_current: ?*const fn () ?*const anyopaque = null;
            pub var late_loaded = false;
            pub const MakeCurrentParams = struct { *const anyopaque, c_ulong };
        };
    };
    pub var originalDlopen: ?*const fn (name: ?CString, mode: c_int) callconv(.C) ?*const anyopaque = null;
};

fn GlBackendUnion() type {
    const fieldInfos = std.meta.declarations(APIs.gl);
    var enumDecls: [fieldInfos.len]std.builtin.Type.EnumField = undefined;
    var unionDecls: [fieldInfos.len]std.builtin.Type.UnionField = undefined;
    var empty = [_]std.builtin.Type.Declaration{};
    for (fieldInfos, 0..) |field, i| {
        enumDecls[i] = .{ .name = field.name, .value = i };
        unionDecls[i] = .{
            .name = field.name,
            .type = @field(APIs.gl, field.name).MakeCurrentParams,
            .alignment = 0,
        };
    }
    return @Type(std.builtin.Type{
        .Union = .{
            .tag_type = @Type(std.builtin.Type{
                .Enum = .{
                    .tag_type = std.math.IntFittingRange(0, fieldInfos.len - 1),
                    .fields = &enumDecls,
                    .decls = &empty,
                    .is_exhaustive = true,
                },
            }),
            .decls = &empty,
            .fields = &unionDecls,
            .layout = .auto,
        },
    });
}

pub const GlBackend = GlBackendUnion();

var reported_process_name = false;
/// used for renaming libraries on Windows
var renamed_libs: std.ArrayList(String) = undefined;
pub var ignored = false;
pub fn checkIgnoredProcess() void {
    var ignored_this = false;
    if (common.selfExePath()) |self_path| {
        var set_reported_process_name = reported_process_name;
        defer reported_process_name = set_reported_process_name;
        if (!reported_process_name) {
            log.debug("From process {s}", .{self_path});
            set_reported_process_name = true;
        }

        const whitelist_process_env = common.env.get(common.env_prefix ++ "PROCESS");
        if (whitelist_process_env) |whitelist| {
            ignored_this = true;
            var it = std.mem.splitScalar(u8, whitelist, ':');
            while (it.next()) |p_name| {
                if (std.mem.endsWith(u8, self_path, p_name)) {
                    if (!reported_process_name) {
                        log.debug("Whitelisting processes {s}", .{p_name});
                    }
                    ignored_this = false;
                    break;
                }
            }
            if (ignored_this and !reported_process_name) {
                log.debug("{s} not on whitelist: {s}", .{ self_path, whitelist });
            }
        }
        // balcklist
        const ignore_process_env = common.env.get(common.env_prefix ++ "IGNORE_PROCESS");
        if (ignore_process_env) |blacklist| {
            var it = std.mem.splitScalar(u8, blacklist, ':');
            while (it.next()) |p_name| {
                if (std.mem.endsWith(u8, self_path, p_name)) {
                    if (!reported_process_name) {
                        log.debug("Ignoring processes {s}", .{blacklist});
                    }
                    ignored_this = true;
                    break;
                }
            }
        }
    } else |e| {
        log.err("Failed to get self path: {any}", .{e});
    }
    ignored = ignored or ignored_this;
}

// Intercept dlopen on POSIX systems
comptime {
    if (builtin.os.tag != .windows) {
        const INTERPOSE = extern struct {
            replacement: ?*const anyopaque,
            replacee: ?*const anyopaque,

            fn dlopen(name: ?[*:0]u8, mode: c_int) callconv(.C) ?*const anyopaque {
                // Check for initialization
                if (APIs.originalDlopen == null) {
                    APIs.originalDlopen = @alignCast(@ptrCast(std.c.dlsym(c.RTLD_NEXT, "dlopen")));
                    if (APIs.originalDlopen == null) {
                        log.err("Failed to find original dlopen: {s}", .{c.dlerror()});
                    }

                    if (!common.initialized) {
                        common.init() catch |err|
                            log.err("Failed to initialize: {any}", .{err});
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
                            log.debug("Failed original dlopen {?s}: {?s}", .{ name, @as(?CString, c.dlerror()) });
                        }
                        return result;
                    }
                    if (!ignored) inline for (_platform_gl_libs) |lib| {
                        for (lib.names) |lib_name| {
                            if (std.mem.startsWith(u8, name_span, std.fs.path.basename(lib_name))) {
                                log.debug("Intercepting dlopen for API {s}", .{name_span});
                                return APIs.originalDlopen.?(@ptrCast(options.deshaderLibName ++ &[_]u8{0}), mode);
                            }
                        }
                    };
                }
                const result = APIs.originalDlopen.?(name, mode);
                if (result == null) {
                    log.debug("Failed ignored dlopen {?s}: {?s}", .{ name, @as(?CString, c.dlerror()) });
                }
                return result;
            }
        };

        const interpose = INTERPOSE{
            .replacement = &INTERPOSE.dlopen,
            .replacee = &c.dlopen,
        };
        if (builtin.os.tag == .macos) {
            @export(interpose, .{
                .name = "_interpose_dlopen",
                .section = "__DATA,__interpose",
            });
        }
        @export(INTERPOSE.dlopen, .{ .name = "dlopen" });
    }
}

const _known_gl_loaders =
    (if (builtin.os.tag == .windows)
    APIs.gl.wgl.default_loaders ++ APIs.gl.wgl.make_current_names ++ APIs.gl.wgl.create_names ++ .{APIs.gl.wgl.destroy_name}
else
    APIs.gl.glX.default_loaders ++ APIs.gl.glX.make_current_names ++ APIs.gl.glX.create_names ++ APIs.gl.egl.default_loaders ++ APIs.gl.egl.make_current_names ++ APIs.gl.egl.create_names ++ .{
        APIs.gl.egl.destroy_name,
        APIs.gl.glX.destroy_name,
        APIs.gl.egl.get_current_name,
        APIs.gl.glX.get_current_name,
    }) ++ [_]?String{options.glAddLoader};

const _platform_gl_libs = switch (builtin.os.tag) {
    .windows => .{APIs.gl.wgl},
    .macos => .{ APIs.gl.glX, APIs.gl.egl, APIs.gl.cgl },
    else => .{ APIs.gl.glX, APIs.gl.egl },
};
const _gl_libs = _platform_gl_libs ++ .{APIs.gl.custom};

/// Lists all exported declarations inside backends/shaders.zig and creates a map from procedure name to procedure pointer
pub const intercepted = blk: {
    const decls = @typeInfo(gl_shaders).Struct.decls ++ @typeInfo(gl_shaders.context_procs).Struct.decls;

    var count = 0;
    for (decls) |decl| {
        if (std.mem.startsWith(u8, decl.name, "gl") or std.mem.startsWith(u8, decl.name, "egl")) {
            count += 1;
        }
    }
    var i = 0;
    var procs: [count]struct { String, gl.PROC } = undefined;
    var names2: [count]?String = undefined;
    for (decls) |proc| {
        if (std.mem.startsWith(u8, proc.name, "gl") or std.mem.startsWith(u8, proc.name, "egl")) {
            defer i += 1;
            names2[i] = proc.name;
            procs[i] = .{
                proc.name,
                // depends on every declaration in backends/gl.zig to be a function or a private struct (so not listed here). It cannot be pub struct
                if (@hasDecl(gl_shaders, proc.name)) @field(gl_shaders, proc.name) else @field(gl_shaders.context_procs, proc.name),
            };
        }
    }
    break :blk struct {
        const names = names2;
        const map = std.StaticStringMap(gl.PROC).initComptime(procs);
    };
};
pub const all_exported_names = _known_gl_loaders ++ intercepted.names;

pub fn loadGlLib() !void {
    if (builtin.os.tag == .windows) { // Assuming loadGlLib is called before loadVkLib
        renamed_libs = std.ArrayList(String).init(common.allocator);
    }

    const customLib = common.env.get(common.env_prefix ++ "GL_LIBS");
    {
        var names = std.ArrayList(String).init(common.allocator);
        if (customLib) |lib_name| {
            var split = std.mem.splitScalar(u8, lib_name, ':');
            while (split.next()) |name| {
                try names.append(name);
            }
        }
        APIs.gl.custom.names = try names.toOwnedSlice();
    }
    const customProcLoaders = common.env.get(common.env_prefix ++ "GL_PROC_LOADERS");
    var names = std.ArrayList(String).init(common.allocator);
    if (customProcLoaders != null) {
        var it = std.mem.splitScalar(u8, customProcLoaders.?, ':');
        while (it.next()) |name| {
            names.append(name) catch |err|
                log.err("Failed to allocate memory for custom GL procedure loader name: {any}", .{err});
        }
    }
    APIs.gl.custom.possible_loaders = try names.toOwnedSlice();

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
                log.err("Only valid positive values are 'yes', '1', 'true'", .{});
            },
        }
    }

    const specified_library_root = common.env.get(common.env_prefix ++ "LIB_ROOT");

    inline for (_gl_libs) |gl_lib| {
        for (gl_lib.names) |lib_name| {
            // add '?' to mark this as not intercepted on POSIX systems
            const full_lib_name = if (builtin.os.tag == .windows) lib_name else try std.mem.concat(common.allocator, u8, if (specified_library_root) |root|
                &.{ common.noTrailingSlash(root), std.fs.path.sep_str, std.fs.path.basename(lib_name), "?" }
            else
                &.{ lib_name, "?" });
            defer if (builtin.os.tag != .windows) common.allocator.free(full_lib_name);
            if (loadNotDeshaderLibrary(full_lib_name)) |lib| {
                gl_lib.lib = lib;
                if (options.logInterception) log.debug("Loaded library {s}", .{full_lib_name});
                for (gl_lib.possible_loaders) |loader| {
                    const loaderZ = try common.allocator.dupeZ(u8, loader);
                    defer common.allocator.free(loaderZ);
                    if (gl_lib.lib.?.lookup(*const GetProcAddressSignature, loaderZ)) |proc| {
                        gl_lib.loader = proc;
                        if (options.logInterception) log.debug("Found loader {s}", .{loader});
                    }
                }
                inline for (gl_lib.make_current, 0..) |func, i| {
                    if (gl_lib.lib.?.lookup(@TypeOf(func), gl_lib.make_current_names[i])) |target| {
                        gl_lib.make_current[i] = @ptrCast(target);
                        if (options.logInterception) log.debug("Found make current {s}", .{gl_lib.make_current_names[i]});
                    } else if (options.logInterception) {
                        log.debug("Failed to find make current {s}", .{gl_lib.make_current_names[i]});
                    }
                }
                inline for (gl_lib.create, 0..) |func, i| {
                    if (gl_lib.lib.?.lookup(@TypeOf(func), gl_lib.create_names[i])) |target| {
                        gl_lib.create[i] = @ptrCast(target);

                        if (options.logInterception) log.debug("Found create {s}", .{gl_lib.create_names[i]});
                    } else if (options.logInterception) {
                        log.debug("Failed to find create {s}", .{gl_lib.create_names[i]});
                    }
                }
                if (gl_lib.lib.?.lookup(@TypeOf(gl_lib.destroy), gl_lib.destroy_name)) |target| {
                    gl_lib.destroy = @ptrCast(target);

                    if (options.logInterception) log.debug("Found destroy {s}", .{gl_lib.destroy_name});
                }
                if (gl_lib.lib.?.lookup(@TypeOf(gl_lib.get_current), gl_lib.get_current_name)) |target| {
                    gl_lib.get_current = @ptrCast(target);

                    if (options.logInterception) log.debug("Found get current {s}", .{gl_lib.get_current_name});
                }
            } else |err| {
                if (builtin.os.tag == .linux and builtin.link_libc) {
                    const err_to_print = c.dlerror();
                    if (err_to_print != null) {
                        log.debug("Failed to open {s}: {s}", .{ full_lib_name, err_to_print });
                    } else {
                        log.debug("Failed to open {s}: {any}", .{ full_lib_name, err });
                    }
                } else {
                    log.debug("Failed to open {s}: {any}", .{ full_lib_name, err });
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
    defer common.allocator.free(APIs.gl.custom.names);
    defer common.allocator.free(APIs.gl.custom.possible_loaders);
    for (renamed_libs.items) |lib| {
        std.posix.unlinkat(cwd, lib, if (builtin.os.tag == .linux) std.posix.AT.SYMLINK_NOFOLLOW else 0) catch |err|
            log.err("Could not delete renamed lib {s}: {}", .{ lib, err });
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
        pub fn loaderReplacement(procedure: CString) callconv(.C) ?gl.PROC {
            if (interface.loader == null) {
                log.err("Loader " ++ loader ++ " is not available", .{});
                return null;
            }
            const span = std.mem.span(procedure);
            const target = intercepted.map.get(span);
            if (target != null) {
                if (options.logInterception) {
                    log.debug("Intercepting " ++ loader ++ " procedure {s}", .{procedure});
                }
                return target.?;
            }
            const original = interface.loader.?(procedure) orelse interface.lib.?.lookup(gl.PROC, span);
            if (options.logInterception) {
                if (original) |_| {
                    log.debug("Found original {s}", .{procedure});
                } else {
                    log.warn("Failed to find original {s}", .{procedure});
                }
            }
            return original;
        }
    };
}

/// Interceptor for custom library
pub fn deshaderGetProcAddress(procedure: CString) callconv(.C) *align(@alignOf(fn (u32) callconv(.C) u32)) const anyopaque {
    if (options.logInterception) {
        log.debug("Intercepting custom GL proc address {s}", .{procedure});
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
