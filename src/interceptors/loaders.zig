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
const shaders = @import("../interceptors/shaders.zig");

const GetProcAddressSignature = fn (name: [*:0]const u8) gl.FunctionPointer;
const String = []const u8;

// TODO multi-context
// TODO wasm
pub const APIs = struct {
    const vk = struct {
        const names = [_]String{"libvulkan.so"};
        var lib: ?std.DynLib = null;
        var device_loader: ?*const GetProcAddressSignature = null;
        var instance_loader: ?*const GetProcAddressSignature = null;
        const device_loaders = [_]?String{ "vkGetDeviceProcAddr", options.vkAddDeviceLoader };
        const instance_loaders = [_]?String{ "vkGetInstanceProcAddr", options.vkAddInstanceLoader };
    };
    pub const gl = if (builtin.os.tag == .windows) struct {
        pub const wgl = struct {
            const names = [_]String{"C:\\Windows\\System32\\opengl32.dll"};
            pub var lib: ?std.DynLib = null;
            var loader: ?*const GetProcAddressSignature = null;
            const default_loaders = [_]String{"wglGetProcAddress"};
            var possible_loaders: []const String = &@This().default_loaders;
            var late_loaded = false;
        };
        pub const custom = struct {
            var names: []const String = &[_]String{};
            pub var lib: ?std.DynLib = null;
            var loader: ?*const GetProcAddressSignature = null;
            var possible_loaders: []const String = &[_]String{};
            var late_loaded = false;
        };
    } else struct {
        pub const glX = struct {
            const names = [_]String{"libGLX.so"};
            pub var lib: ?std.DynLib = null;
            var loader: ?*const GetProcAddressSignature = null;
            const default_loaders = [_]String{ "glXGetProcAddress", "glXGetProcAddressARB" };
            var possible_loaders: []const String = &@This().default_loaders;
            var late_loaded = false;
        };
        pub const egl = struct {
            const names = [_]String{"libEGL.so"};
            pub var lib: ?std.DynLib = null;
            var loader: ?*const GetProcAddressSignature = null;
            const default_loaders = [_]String{"eglGetProcAddress"};
            var possible_loaders: []const String = &@This().default_loaders;
            var late_loaded = false;
        };
        pub const custom = struct {
            var names: []const String = &[_]String{};
            pub var lib: ?std.DynLib = null;
            var loader: ?*const GetProcAddressSignature = null;
            var possible_loaders: []const String = &[_]String{};
            var late_loaded = false;
        };
    };
    pub var originalDlopen: ?*const fn (name: ?[*:0]const u8, mode: c_int) callconv(.C) ?*const anyopaque = null;
};

var renamed_libs: std.ArrayList(String) = undefined;
var already_intercepted = false;
pub var ignored = false;
pub fn checkIgnoredProcess() void {
    var ignored_this = false;
    if (common.selfExePathAlloc(common.allocator)) |self_path| {
        defer common.allocator.free(self_path);
        DeshaderLog.debug("From process {s}", .{self_path});

        const only_process_env = common.env.get(common.env_prefix ++ "PROCESS");
        if (only_process_env) |only| {
            ignored_this = true;
            var it = std.mem.splitScalar(u8, only, ',');
            while (it.next()) |p_name| {
                if (std.mem.endsWith(u8, self_path, p_name)) {
                    DeshaderLog.debug("Whitelisting processes {s}", .{p_name});
                    ignored_this = false;
                    break;
                }
            }
            if (ignored_this) {
                DeshaderLog.debug("{s} not on whitelist: {s}", .{ self_path, only });
            }
        }

        const ignore_process_env = common.env.get(common.env_prefix ++ "IGNORE_PROCESS");
        if (ignore_process_env != null) {
            var it = std.mem.splitScalar(u8, ignore_process_env.?, ',');
            while (it.next()) |p_name| {
                if (std.mem.endsWith(u8, self_path, p_name)) {
                    DeshaderLog.debug("Ignoring processes {s}", .{ignore_process_env.?});
                    ignored_this = true;
                    break;
                }
            }
        }
    } else |e| {
        DeshaderLog.err("Failed to get self path: {any}", .{e});
    }
    ignored = ignored_this or common.env.get(common.env_prefix ++ "HOOKED") != null;
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
                    checkIgnoredProcess();
                }
                if (name != null and !ignored) {
                    var name_span = std.mem.span(name.?);
                    // Ignore libraries marked with '?' and pass them to the original dlopen
                    if (name_span[name_span.len - 1] == '?') {
                        name_span[name_span.len - 1] = 0;
                        return APIs.originalDlopen.?(@ptrCast(name_span), mode);
                    }
                    inline for (_platform_gl_libs ++ .{APIs.vk}) |lib| {
                        inline for (lib.names) |possible_name| {
                            if (std.mem.startsWith(u8, name_span, possible_name)) {
                                DeshaderLog.debug("Intercepting dlopen for API {s}", .{name_span});
                                if (!already_intercepted) {
                                    already_intercepted = true;
                                    common.env.put(common.env_prefix ++ "HOOKED", "1") catch unreachable;
                                }
                                return APIs.originalDlopen.?(@ptrCast(options.deshaderLibName ++ &[_]u8{0}), mode);
                            }
                        }
                    }
                }
                const result = APIs.originalDlopen.?(name, mode);
                if (result == null) {
                    DeshaderLog.debug("Failed dlopen {?s}: {?s}", .{ name, @as(?[*:0]const u8, c.dlerror()) });
                }
                return result;
            }
        }.dlopen, .{ .name = "dlopen" });
    }
}

const _known_gl_loaders =
    (if (builtin.os.tag == .windows) APIs.gl.wgl.default_loaders else APIs.gl.glX.default_loaders ++ APIs.gl.egl.default_loaders) ++ [_]?String{options.glAddLoader};
const _platform_gl_libs = if (builtin.os.tag == .windows) .{APIs.gl.wgl} else .{ APIs.gl.glX, APIs.gl.egl };
const _gl_ibs = _platform_gl_libs ++ .{APIs.gl.custom};

/// Lists all declarations inside interceptors/shaders.zig and creates a map from procedure name to procedure pointer
pub const intercepted = blk: {
    const decls = @typeInfo(shaders).Struct.decls;
    comptime var procs: [decls.len]std.meta.Tuple(&.{ String, gl.FunctionPointer }) = undefined;
    comptime var names2: [decls.len]?String = undefined;

    for (decls, 0..) |proc, i| {
        names2[i] = proc.name;
        procs[i] = .{
            proc.name,
            @field(shaders, proc.name),
        };
    }
    break :blk struct {
        const names = names2;
        const map = std.ComptimeStringMap(gl.FunctionPointer, procs);
    };
};
pub const all_exported_names = _known_gl_loaders ++ APIs.vk.device_loaders ++ APIs.vk.instance_loaders ++ intercepted.names;

// Container for all OpenGL function symbols TODO
const GlFunctions = struct {
    fn load(self: *@This(), loader: GetProcAddressSignature) void {
        const fields = @typeInfo(@This()).Struct.fields;
        inline for (fields) |field| {
            @field(self, field.name) = loader(field.name);
        }
    }
};

fn useLoader(loader: *const GetProcAddressSignature, proc: [:0]const u8) gl.FunctionPointer {
    return loader(proc);
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

    inline for (_gl_ibs) |gl_lib| {
        for (gl_lib.names) |lib_name| {
            // add '?' to mark this as not intercepted on POSIX systems
            const full_lib_name = if (builtin.os.tag == .windows) lib_name else try std.mem.concat(common.allocator, u8, if (specified_library_root == null) &.{ lib_name, "?" } else &.{ specified_library_root.?, std.fs.path.sep_str, lib_name, "?" });
            defer if (builtin.os.tag != .windows) common.allocator.free(full_lib_name);
            if (loadNotDeshaderLibrary(full_lib_name)) |lib| {
                gl_lib.lib = lib;
                DeshaderLog.debug("Loaded library {s}", .{full_lib_name});
                for (gl_lib.possible_loaders) |loader| {
                    if (gl_lib.lib.?.lookup(*const GetProcAddressSignature, @ptrCast(loader))) |proc| {
                        gl_lib.loader = proc;
                        DeshaderLog.debug("Found procedure loader {s}", .{loader});
                        // Early load all GL functions (late loading happens in makeCurrent())
                        if (@as(?*const anyopaque, gl.function_pointers.glShaderSource) == null) {
                            gl.load(proc, useLoader) catch |err|
                                DeshaderLog.err("Failed to early load some GL functions: {}", .{err});
                        }

                        break;
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

pub fn loadVkLib() !void {
    const lib_name = common.env.get(common.env_prefix ++ "VK_LIBRARY") orelse switch (builtin.os.tag) {
        .windows => "vulkan-1.dll",
        .linux => "libvulkan.so",
        .macos => "libvulkan.dylib",
        else => {
            DeshaderLog.err("Unsupported OS: {s}", .{builtin.os.name});
        },
    };
    // Mark this by '?' as not intercepted to prevent recursive hooking
    const with_mark = try std.mem.concat(common.allocator, u8, &.{ lib_name, "?" });
    defer common.allocator.free(with_mark);
    if (loadNotDeshaderLibrary(with_mark)) |openedLib| {
        APIs.vk.lib = openedLib;
        DeshaderLog.debug("Loaded {s}", .{lib_name});
        const vkGetDeviceProcAddrName = common.env.get(common.env_prefix ++ "VK_DEV_PROC_LOADER") orelse "vkGetDeviceProcAddr";
        if (APIs.vk.lib.?.lookup(gl.FunctionPointer, @ptrCast(vkGetDeviceProcAddrName))) |proc| {
            APIs.vk.device_loader = @ptrCast(proc);
            DeshaderLog.debug("Found device procedure loader {s}", .{vkGetDeviceProcAddrName});
        }
        const vkGetInstanceProcAddrName = common.env.get(common.env_prefix ++ "VK_INST_PROC_LOADER") orelse "vkGetInstanceProcAddr";
        if (APIs.vk.lib.?.lookup(gl.FunctionPointer, @ptrCast(vkGetInstanceProcAddrName))) |proc| {
            APIs.vk.instance_loader = @ptrCast(proc);
            DeshaderLog.debug("Found instance procedure loader {s}", .{vkGetInstanceProcAddrName});
        }
        if (options.vkAddDeviceLoader) |name| {
            DeshaderLog.debug("This Deshader build exports additional VK device function loader: {s}", .{name});
        }
        if (options.vkAddInstanceLoader) |name| {
            DeshaderLog.debug("This Deshader build exports additional VK instance function loader: {s}", .{name});
        }
    } else |err| {
        DeshaderLog.err("Failed to open {s}: {any}", .{ lib_name, err });
    }
}

pub fn deinit() void {
    const cwd = std.fs.cwd().fd;
    defer renamed_libs.deinit();
    for (renamed_libs.items) |lib| {
        std.os.unlinkat(cwd, lib, if (builtin.os.tag == .linux) std.os.AT.SYMLINK_NOFOLLOW else 0) catch |err|
            DeshaderLog.err("Could not delete renamed lib {s}: {}", .{ lib, err });
    }
}

/// Interceptors for Vulkan functions
pub fn deshaderGetVkInstanceProcAddr(procedure: [*:0]const u8) callconv(.C) ?*align(@alignOf(fn (u32) callconv(.C) u32)) const anyopaque {
    if (options.logIntercept) {
        DeshaderLog.debug("Intercepting VK instance proc address {s}", .{procedure});
    }
    if (APIs.vk.lib == null) {
        loadVkLib() catch |err|
            DeshaderLog.err("Failed to load Vulkan library from inst loader: {any}", .{err});
    }
    if (APIs.vk.lib == null or APIs.vk.instance_loader == null) {
        return null;
    }
    return APIs.vk.instance_loader.?(procedure);
}
pub fn deshaderGetVkDeviceProcAddr(procedure: [*:0]const u8) callconv(.C) ?*align(@alignOf(fn (u32) callconv(.C) u32)) const anyopaque {
    if (options.logIntercept) {
        DeshaderLog.debug("Intercepting VK device proc address {s}", .{procedure});
    }
    if (APIs.vk.lib == null) {
        loadVkLib() catch |err|
            DeshaderLog.err("Failed to load Vulkan library device loader: {any}", .{err});
    }
    if (APIs.vk.lib == null or APIs.vk.device_loader == null) {
        return null;
    }
    return APIs.vk.device_loader.?(procedure);
}

fn loadGlLibWrapError() void {
    loadGlLib() catch |err|
        DeshaderLog.err("Failed to load GL library: {any}", .{err});
}

//
// Gpahics API procedure loaders interception
//
pub fn LoaderInterceptor(comptime interface: type, comptime loader: String) type {
    return struct {
        /// Generic loader interception function
        pub fn loaderReplacement(procedure: [*:0]const u8) callconv(.C) ?gl.FunctionPointer {
            if (!interface.late_loaded) {
                loadGlLibWrapError();
                // Late load all GL funcitions
                gl.load(interface.loader.?, useLoader) catch |err|
                    DeshaderLog.err("Failed to load some GL functions: {any}", .{err});
                interface.late_loaded = true;
            }
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
pub fn deshaderGetProcAddress(procedure: [*:0]const u8) callconv(.C) *align(@alignOf(fn (u32) callconv(.C) u32)) const anyopaque {
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

    for (APIs.vk.device_loaders) |original_name_maybe| {
        if (original_name_maybe) |originalName| @export(deshaderGetVkDeviceProcAddr, .{ .name = originalName });
    }
    for (APIs.vk.instance_loaders) |original_name_maybe| {
        if (original_name_maybe) |originalName| @export(deshaderGetVkInstanceProcAddr, .{ .name = originalName });
    }
} // end comptime
