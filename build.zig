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
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const builtin = @import("builtin");
const PositronSdk = @import("libs/positron/Sdk.zig");
const ZigServe = @import("libs/positron/vendor/serve/build.zig");
const ctregex = @import("libs/ctregex/ctregex.zig");
const CompressStep = @import("bootstrap/compress.zig").CompressStep;
const DependenciesStep = @import("bootstrap/dependencies.zig").DependenciesStep;
const ListGlProcsStep = @import("bootstrap/list_gl_procs.zig").ListGlProcsStep;
const arch = @import("src/common/arch.zig");

const String = []const u8;

const log = std.log.scoped(.DeshaderBuild);
const hasDylibCache = builtin.os.isAtLeast(.macos, .{ .major = 11, .minor = 0, .patch = 1 }) orelse false; // https://developer.apple.com/documentation/macos-release-notes/macos-big-sur-11_0_1-release-notes#Kernel
var dependencies_step: DependenciesStep = undefined;

// Shims for compatibility between Zig versions
const exec = std.process.Child.run;
fn openIterableDir(path: String) std.fs.File.OpenError!if (@hasDecl(std.fs, "openIterableDirAbsolute")) std.fs.IterableDir else std.fs.Dir {
    return if (@hasDecl(std.fs, "openIterableDirAbsolute")) std.fs.openIterableDirAbsolute(path, .{}) else std.fs.openDirAbsolute(path, .{ .iterate = true });
}

pub fn build(b: *std.Build) !void {
    var target = b.standardTargetOptions(.{});
    const optimize: std.builtin.OptimizeMode = switch (b.release_mode) {
        .any => .ReleaseSafe,
        .fast => .ReleaseFast,
        .safe => .ReleaseSafe,
        .small => .ReleaseSmall,
        .off => .Debug,
    };

    const targetTarget = target.result.os.tag;
    const GlLibNames: []const String = switch (targetTarget) {
        .windows => &[_]String{"opengl32.dll"},
        .macos => &.{ "System/Library/Frameworks/OpenGL.framework/OpenGL", "System/Library/Frameworks/OpenGL.framework/Libraries/libGL.dylib" },
        else => &[_]String{ "libGLX.so.0", "libEGL.so" },
    };
    const system32 = "C:/Windows/System32/";

    // do not deinit env, because it will be used in DependeciesStep in make phase
    const host_libs_location = switch (targetTarget) {
        .windows => if (builtin.os.tag == .windows) system32 else try winepath(b.allocator, system32, false),
        .macos => if (builtin.os.tag == .macos) "/" else pathExists("/usr/libexec/darling/") orelse pathExists("/usr/local/libexec/darling/") orelse return error.NoDarling,
        else => getLdConfigPath(b),
    };

    const GlSymbolPrefixes: []const String = switch (targetTarget) {
        .windows => &.{ "wgl", "gl" },
        .linux => &.{ "glX", "egl", "gl" },
        .macos => &.{ "CGL", "gl" },
        else => &.{"gl"},
    };
    const VulkanLibName = switch (targetTarget) {
        .windows => "vulkan-1.dll",
        .macos => "libvulkan.dylib",
        else => "libvulkan.so",
    };
    const ObjectFormat = enum { Default, c, IR, BC };
    const Level = enum { err, warn, info, debug, default }; //cannot use std.log.Level because it gets corrupted in options generated file
    const option_ofmt = b.option(ObjectFormat, "ofmt", "Compile into object format") orelse .Default;
    if (option_ofmt == .c) {
        target.result.ofmt = .c;
        target.query.ofmt = .c;
    }

    // Deshader library
    const deshaderCompileOptions = .{
        .name = "deshader",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    };

    // Compilation options
    const default_traces = (targetTarget != .windows or builtin.os.tag == .windows) and (optimize == .Debug or optimize == .ReleaseSafe);

    const option_custom_library = b.option([]const String, "customLibrary", "Names of additional libraries to intercept");
    const option_editor = b.option(bool, "editor", "Include VSCode editor in Deshader Launcher (default yes)") orelse true;
    const option_ignore_missing = b.option(bool, "ignoreMissing", "Ignore missing VK and GL libraries. GLX, EGL and VK will be required by default") orelse false;
    const option_include = b.option(String, "include", "Path to directory with additional headers to include");
    const option_lib_assert = b.option(bool, "libAssert", "Include assertions in VCPKG libraries (implicit for debug and release safe)") orelse (optimize == .Debug or optimize == .ReleaseSafe);
    const option_lib_debug = b.option(bool, "libDebug", "Include debug information in VCPKG libraries") orelse (optimize == .Debug);
    const option_lib_dir = b.option(String, "lib", "Path to directory with additional libraries to link");
    const option_lib_linkage = b.option(std.builtin.LinkMode, "libLinkage", "Select linkage type for VCPKG libraries. (default dynamic for OSX and Windows, static for Linux)") orelse if (targetTarget == .windows) std.builtin.LinkMode.dynamic else std.builtin.LinkMode.static;
    const option_linkage = b.option(std.builtin.LinkMode, "linkage", "Select linkage type for deshader library. Cannot be combined with -Dofmt.") orelse .dynamic;
    const option_log_intercept = b.option(bool, "logInterception", "Log intercepted GL and VK procedure list and loader errors to stdout (adds several MB to library size)") orelse false;
    const option_log_level = b.option(Level, "logLevel", "Set log level for the build") orelse .default;
    const option_memory_frames = b.option(u32, "memoryFrames", "Number of frames in memory leak backtrace (default 7)") orelse 7;
    const options_sanitize = b.option(bool, "sanitize", "Enable sanitizers (implicit for debug mode)") orelse default_traces;
    const option_sdk = b.option(String, "sdk", "SDK path (macOS only, defaults to the one selected by xcode-select)");
    const option_stack_check = (b.option(bool, "stackCheck", "Enable stack checking (implicit for debug mode, not supported for Windows, ARM)") orelse (optimize == .Debug)) and (targetTarget != .windows and target.result.cpu.arch != .arm);
    const option_stack_protector = b.option(bool, "stackProtector", "Enable stack protector (implicit for debug mode)") orelse option_stack_check;
    const option_strip = b.option(bool, "strip", "Strip debug symbols from the library (implicit for release fast and minimal mode)") orelse (optimize != .Debug and optimize != .ReleaseSafe);
    const option_system_glew = b.option(bool, "sGLEW", "Force usage of system-supplied GLEW library (VCPKG has priority otherwise)") orelse false;
    var option_system_glfw = b.option(bool, "sGLFW3", "Force usage of system-supplied GLFW3 library (VCPKG has priority otherwise)") orelse false;
    var option_system_glslang = b.option(bool, "sGLSLang", "Force usage of system-supplied GLSLang library (VCPKG has priority otherwise)") orelse false;
    var option_system_nfd = b.option(bool, "sNFD", "Force usage of system-supplied NFD library (VCPKG has priority otherwise)") orelse false;
    var option_system_wolfssl = b.option(bool, "sWolfSSL", "Force usage of system-supplied WolfSSL library (VCPKG has priority otherwise)") orelse false;
    const options_traces = b.option(bool, "traces", "Enable error traces (implicit for debug mode)") // important! keep tracing support synced for Deshader Library and Launcher, because there are casts from error aware functions to anyopaque
    orelse default_traces;
    const option_triplet = b.option(String, "triplet", "VCPKG triplet to use for dependencies");
    const option_valgrind = b.option(bool, "valgrind", "Enable valgrind support (implicit for debug mode, not supported for macos, ARM, and msvc target)") orelse (options_traces and target.result.abi != .msvc and targetTarget != .macos and target.result.cpu.arch != .arm);
    const options_unwind = b.option(bool, "unwind", "Enable unwind tables (implicit for debug mode)") orelse options_traces;

    const deshader_lib: *std.Build.Step.Compile = if (option_linkage == .static) b.addStaticLibrary(deshaderCompileOptions) else b.addSharedLibrary(deshaderCompileOptions);
    deshader_lib.root_module.error_tracing = options_traces;
    deshader_lib.root_module.strip = option_strip;
    deshader_lib.root_module.unwind_tables = options_unwind;
    deshader_lib.root_module.sanitize_c = options_sanitize;
    deshader_lib.root_module.stack_check = option_stack_check;
    deshader_lib.root_module.stack_protector = option_stack_protector;
    deshader_lib.root_module.valgrind = option_valgrind;
    deshader_lib.each_lib_rpath = false;
    deshader_lib.addLibraryPath(.{ .cwd_relative = host_libs_location });

    const system_framwork_path = std.Build.LazyPath{ .cwd_relative = "/System/Library/Frameworks/" };
    const framework_path = std.Build.LazyPath{ .cwd_relative = if (targetTarget == .macos) option_sdk orelse b.pathJoin(&.{ std.mem.trim(u8, b.run(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }), "\n \t"), system_framwork_path.cwd_relative }) else "" };

    if (target.result.abi == .msvc) {
        deshader_lib.linkSystemLibrary("shell32");
        deshader_lib.linkSystemLibrary("libvcruntimed");
        deshader_lib.linkSystemLibrary("libcmtd");
        deshader_lib.linkSystemLibrary("libcpmtd");
    } else {
        if (targetTarget == .macos) {
            deshader_lib.linkFramework("CoreFoundation");
            deshader_lib.linkFramework("Cocoa");
            deshader_lib.linkFramework("Security");
            deshader_lib.linkFramework("OpenGL");
        }
    }

    if (!option_lib_assert) {
        deshader_lib.defineCMacro("NDEBUG", null);
    }
    // translate zig flags to cflags and cxxflags (will be used when building VCPKG dependencies)
    var env = try std.process.getEnvMap(std.heap.page_allocator); // uses heap alloctor, because if b.allocator was used, the env would be deallocated after the config phase
    defer env.deinit();

    inline for (.{ "CFLAGS", "CXXFLAGS" }) |flags| {
        const old = env.get(flags);
        const new_flags = try std.mem.concat(b.allocator, u8, &.{
            if (old) |o| o else "",
            if (option_lib_assert) "" else " -DNDEBUG",
            if (option_strip) "" else " -g",
            if (options_unwind) " -funwind-tables" else " -fno-unwind-tables",
            if (option_stack_check) " -fstack-check" else " -fno-stack-check",
            if (option_stack_protector) " -fstack-protector" else " -fno-stack-protector",
        });
        defer b.allocator.free(new_flags);
        try env.put(flags, new_flags);
    }
    if (option_sdk) |sdk| {
        try env.put("MACOSSDK", sdk);
    }
    const targetTriplet = try std.mem.join(b.allocator, "-", &.{ @tagName(target.result.cpu.arch), @tagName(targetTarget), @tagName(target.result.abi) });
    try env.put("ZIG_LIB_LINKAGE", @tagName(option_lib_linkage));
    try env.put("ZIG_PATH", b.graph.zig_exe);
    try env.put("ZIG_OPTIMIZE", if (option_lib_debug) "debug" else "release");
    try env.put("ZIG_TARGET", targetTriplet);
    try env.put("ZIG_ARCH", arch.archToVcpkg(target.result.cpu.arch));
    try env.put("ZIG_OSX_ARCH", arch.archToOSXArch(target.result.cpu.arch));
    try env.put("ZIG_OS", switch (targetTarget) {
        .windows => "Windows",
        .macos => "Darwin",
        .linux => "Linux",
        else => try uppercaseFirstLetter(b.allocator, @tagName(targetTarget)),
    });

    dependencies_step = try DependenciesStep.init(b, "dependencies", target.result, env);
    try dependencies_step.vcpkg(option_triplet);

    const deshader_lib_name = try std.mem.concat(b.allocator, u8, &.{ if (targetTarget == .windows) "" else "lib", deshader_lib.name, targetTarget.dynamicLibSuffix() });
    const deshader_lib_cmd = b.step("deshader", "Install deshader library");
    switch (option_ofmt) {
        .BC => {
            deshader_lib.generated_llvm_ir = try b.allocator.create(std.Build.GeneratedFile);
            deshader_lib.generated_llvm_ir.?.* = .{ .step = &deshader_lib.step, .path = try b.cache_root.join(b.allocator, &.{ "llvm", "deshader.ll" }) };
            deshader_lib_cmd.dependOn(&b.addInstallFileWithDir(deshader_lib.getEmittedLlvmBc(), .lib, "deshader.bc").step);
            deshader_lib.root_module.stack_check = false;
        },
        .IR => {
            deshader_lib.generated_llvm_bc = try b.allocator.create(std.Build.GeneratedFile);
            deshader_lib.generated_llvm_bc.?.* = .{ .step = &deshader_lib.step, .path = try b.cache_root.join(b.allocator, &.{ "llvm", "deshader.bc" }) };
            deshader_lib_cmd.dependOn(&b.addInstallFileWithDir(deshader_lib.getEmittedLlvmIr(), .lib, "deshader.ll").step);
            deshader_lib.root_module.stack_check = false;
        },
        else => {},
    }
    const deshader_lib_install = b.addInstallArtifact(deshader_lib, .{});
    deshader_lib_cmd.dependOn(&deshader_lib_install.step);
    deshader_lib.addIncludePath(b.path("src/declarations"));
    if (option_include) |includeDir| {
        deshader_lib.addIncludePath(b.path(includeDir));
    }
    if (option_lib_dir) |libDir| {
        deshader_lib.addLibraryPath(b.path(libDir));
    }

    if (targetTarget == .windows) {
        const icon = b.addInstallBinFile(b.path("src/deshader.ico"), "deshader.ico");
        deshader_lib_install.step.dependOn(&icon.step);
        deshader_lib.addWin32ResourceFile(.{ .file = b.path(b.pathJoin(&.{ "src", "resources.rc" })) });
    }

    // CTRegex
    const ctregex_mod = b.addModule("ctregex", .{
        .root_source_file = b.path("libs/ctregex/ctregex.zig"),
    });
    deshader_lib.root_module.addImport("ctregex", ctregex_mod);

    // Args parser
    const args_mod = b.addModule("args", .{
        .root_source_file = b.path("libs/positron/vendor/args/args.zig"),
    });
    deshader_lib.root_module.addImport("args", args_mod);

    var deshader_dependent_dlls = std.ArrayList(String).init(b.allocator);

    // Websocket
    const websocket = b.dependency("websocket", .{});
    deshader_lib.root_module.addImport("websocket", websocket.module("websocket"));

    // OpenGL
    const zigglgen = @import("zigglgen");
    const string_exts = b.option([]const String, "glExtensions", "OpenGL extensions included in the bindings") orelse &[_]String{
        "ARB_shading_language_include",
    };
    const exts = try b.allocator.alloc(zigglgen.GeneratorOptions.Extension, string_exts.len);
    for (string_exts, exts) |s, *e| {
        e.* = std.meta.stringToEnum(zigglgen.GeneratorOptions.Extension, s) orelse @panic("Invalid extension");
    }
    defer b.allocator.free(exts);
    const gl_bindings = zigglgen.generateBindingsModule(b, .{
        .api = .gl,
        .version = b.option(zigglgen.GeneratorOptions.Version, "glVersion", "OpenGL version to generate bindings for") orelse .@"4.6",
        .profile = b.option(zigglgen.GeneratorOptions.Profile, "glProfile", "OpenGL profile to generate bindings for") orelse .core,
        .extensions = exts,
    });
    deshader_lib.root_module.addImport("gl", gl_bindings);

    // Vulkan
    const vulkanXmlInput = try b.build_root.join(b.allocator, &[_]String{"libs/Vulkan-Docs/xml/vk.xml"});
    const vkzig_dep = b.dependency("vulkan_zig", .{
        .registry = @as(String, vulkanXmlInput),
    });
    const vkzigBindings = vkzig_dep.module("vulkan-zig");
    deshader_lib.root_module.addImport("vulkan-zig", vkzigBindings);

    // GLSL Analyzer
    const compresss_spec = try CompressStep.init(b, b.path("libs/glsl_analyzer/spec/spec.json"));
    const compressed_spec = b.addModule("glsl_spec.json.zlib", .{ .root_source_file = .{ .generated = .{ .file = &compresss_spec.generatedFile } } });
    const glsl_analyzer_options = b.addOptions();
    glsl_analyzer_options.addOption(bool, "has_websocket", true);
    const glsl_analyzer = b.addModule("glsl_analyzer", .{
        .root_source_file = b.path("libs/glsl_analyzer.zig"),
        .imports = &[_]std.Build.Module.Import{ .{
            .name = "glsl_spec.json.zlib",
            .module = compressed_spec,
        }, .{
            .name = "websocket",
            .module = websocket.module("websocket"),
        }, .{
            .name = "build_options",
            .module = glsl_analyzer_options.createModule(),
        } },
    });
    deshader_lib.root_module.addImport("glsl_analyzer", glsl_analyzer); // TODO externalize glsl_analyzer

    // Deshader internal library options
    const options = b.addOptions();
    const optionGLAdditionalLoader = b.option(String, "glAddLoader", "Name of additional exposed function which will call GL function loader");
    const optionvkAddInstanceLoader = b.option(String, "vkAddInstanceLoader", "Name of additional exposed function which will call Vulkan instance function loader");
    const optionvkAddDeviceLoader = b.option(String, "vkAddDeviceLoader", "Name of additional exposed function which will call Vulkan device function loader");
    options.addOption(?String, "glAddLoader", optionGLAdditionalLoader);
    options.addOption(?String, "vkAddDeviceLoader", optionvkAddDeviceLoader);
    options.addOption(?String, "vkAddInstanceLoader", optionvkAddInstanceLoader);
    options.addOption(bool, "logInterception", option_log_intercept);
    options.addOption(String, "deshaderLibName", deshader_lib_name);
    options.addOption(Level, "log_level", option_log_level);
    options.addOption(ObjectFormat, "ofmt", option_ofmt);
    options.addOption(u32, "memoryFrames", option_memory_frames);
    const version = resolve: {
        const version_result = try exec(.{ .allocator = b.allocator, .argv = &.{ "git", "describe", "--tags", "--always", "--abbrev=0", "--exact-match" } });
        if (version_result.term == .Exited and version_result.term.Exited == 0 and std.ascii.isDigit(version_result.stdout[0])) {
            break :resolve version_result.stdout; // tag with a digit => version number
        } else {
            const rev_result = try exec(.{ .allocator = b.allocator, .argv = &.{ "git", "rev-parse", "--short", "HEAD" } });
            if (rev_result.term == .Exited and rev_result.term.Exited == 0) {
                break :resolve rev_result.stdout; // else use commit hash
            } else {
                break :resolve "unknown";
            }
        }
    };
    options.addOption([:0]const u8, "version", try b.allocator.dupeZ(u8, std.mem.trim(u8, version, " \n\t")));
    const options_module = options.createModule();
    deshader_lib.root_module.addImport("options", options_module);

    // Common
    const common = b.addModule("common", .{
        .optimize = optimize,
        .target = target,
        .root_source_file = b.path("src/common.zig"),
        .imports = &.{
            .{ .name = "options", .module = options_module },
            .{ .name = "glsl_analyzer", .module = glsl_analyzer },
        },
    });
    common.addCMacro("_GNU_SOURCE", ""); // To access dl_iterate_phdr
    deshader_lib.root_module.addImport("common", common);

    // Symbol Enumeration
    const run_symbol_enum_cmd = if (!hasDylibCache) configure: { // OpenGL is not directly available in the form of dynamic library on macOS >= 11.x
        const run_symbol_enum = b.addSystemCommand(switch (targetTarget) {
            .windows => &.{
                "bootstrap/tools/dumpbin.exe",
                "/exports",
            },
            .macos => if (b.enable_darling) &.{ "darling", "shell", "nm", "--format=posix", "--defined-only", "-ap" } else &.{ "nm", "--format=posix", "--defined-only", "-ap" },
            else => &.{ "nm", "--format=posix", "--defined-only", "-DAp" },
        });
        if (b.enable_wine) {
            _ = try exec(.{ .allocator = b.allocator, .argv = &.{ "wineserver", "-k" } }); // To apply the new WINEDEBUG settings
            run_symbol_enum.setEnvironmentVariable("WINEDEBUG", "-all"); //otherwise expectStdErrEqual("") will not ignore fixme messages
        }
        for (GlLibNames) |libName| {
            if (try fileWithPrefixExists(b.allocator, host_libs_location, libName)) |real_name| {
                run_symbol_enum.addArg(try hostToTargetPath(b.allocator, targetTarget, real_name, host_libs_location));
            } else {
                if (option_ignore_missing) {
                    log.warn("Missing library {s}", .{libName});
                } else {
                    log.err("Missing library {s}", .{libName});
                    return deshader_lib.step.fail("Missing library {s}", .{libName});
                }
            }
        }
        if (!b.enable_darling) {
            if (try fileWithPrefixExists(b.allocator, host_libs_location, VulkanLibName)) |real_name| {
                run_symbol_enum.addArg(try hostToTargetPath(b.allocator, targetTarget, real_name, host_libs_location));
            } else {
                if (option_ignore_missing) {
                    log.warn("Missing library {s}", .{VulkanLibName});
                } else {
                    log.err("Missing library {s}", .{VulkanLibName});
                    return deshader_lib.step.fail("Missing library {s}", .{VulkanLibName});
                }
            }
        }

        run_symbol_enum.expectExitCode(0);
        if (!b.enable_wine) { // wine can add weird fixme messages, or "fsync: up and running" to the stderr
            run_symbol_enum.expectStdErrEqual("");
        }
        break :configure run_symbol_enum;
    };
    var allLibraries = std.ArrayList(String).init(b.allocator);
    try allLibraries.appendSlice(GlLibNames);
    try allLibraries.append(VulkanLibName);
    if (option_custom_library != null) {
        if (builtin.os.tag != .macos) {
            run_symbol_enum_cmd.addArgs(option_custom_library.?);
        }
        try allLibraries.appendSlice(option_custom_library.?);
    }
    // Parse symbol enumerator output
    var addGlProcsStep = ListGlProcsStep.init(b, targetTarget, "add_gl_procs", allLibraries.items, GlSymbolPrefixes, if (builtin.os.tag == .macos)
        b.path("libs/mac-fallback.txt")
    else
        run_symbol_enum_cmd.captureStdOut());
    if (builtin.os.tag != .macos) {
        addGlProcsStep.step.dependOn(&run_symbol_enum_cmd.step);
    }
    deshader_lib.step.dependOn(&addGlProcsStep.step);
    const transitive_exports = b.createModule(.{ .root_source_file = .{ .generated = .{ .file = &addGlProcsStep.generated_file } } });
    deshader_lib.root_module.addImport("transitive_exports", transitive_exports);

    //
    // Steps for building generated and embedded files
    //
    const stubs_path = b.getInstallPath(.header, "deshader/deshader.zig");
    var stub_gen_cmd = b.step("generate_stubs", "Generate .zig file with function stubs for deshader library");
    const header_gen_cmd = b.step("generate_headers", "Generate C header file for deshader library");

    const deshader_stubs = b.addModule("deshader", .{
        .root_source_file = .{ .cwd_relative = stubs_path }, //future file, may not exist
    });
    {
        //
        // Other components / dependencies
        // NOTE: must be run manually with `zig build dependencies` before `zig  build`
        //

        // Prepare the toolchain
        // Create a script that acts as `ar` script. Redirects commands to `zig ar``
        const ar_name = if (builtin.os.tag == .windows) "build/ar.bat" else "build/ar";
        b.build_root.handle.access(ar_name, .{ .mode = .write_only }) catch {
            if (std.fs.path.dirname(ar_name)) |dir| try b.build_root.handle.makePath(dir);
            const file = try b.build_root.handle.createFile(ar_name, .{});
            defer file.close();
            try file.writeAll(
                if (builtin.os.tag == .windows)
                    try std.mem.concat(b.allocator, u8, &.{ b.graph.zig_exe, " ar %*" })
                else
                    try std.mem.concat(b.allocator, u8, &.{ "#!/bin/sh\n", b.graph.zig_exe, " ar $@" }),
            );
        };
        // Set execution permissions
        if (builtin.os.tag != .windows) {
            const full_path = try std.fs.path.joinZ(b.allocator, &.{ b.build_root.path.?, ar_name });
            const f = try std.fs.cwd().openFile(full_path, .{});
            defer f.close();
            const stat = try f.stat();
            try f.chmod(stat.mode | 0o111);
        }

        // Build dependencies
        b.top_level_steps.get("install").?.description = "Download dependencies managed by Zig";

        const editor_cmd = b.step("editor", "Bootstrap building internal Deshader components and dependencies");
        editor_cmd.dependOn(&dependencies_step.step);
        const vcpkg_cmd = b.step("vcpkg", "Download and build dependencies managed by vcpkg");
        vcpkg_cmd.dependOn(&dependencies_step.step);

        //
        // Emit .zig file with function stubs
        //
        // Or generate them right here in the build process
        const stubGenSrc = @import("bootstrap/generate_stubs.zig");
        var stub_gen: *stubGenSrc.GenerateStubsStep = try b.allocator.create(stubGenSrc.GenerateStubsStep);
        {
            try b.build_root.handle.makePath(std.fs.path.dirname(stubs_path).?);
            stub_gen.* = stubGenSrc.GenerateStubsStep.init(b, stubs_path, true);
        }
        stub_gen_cmd.dependOn(&stub_gen.step);
        // automatically create zig stubs when building the library
        deshader_lib_cmd.dependOn(&stub_gen.step);

        //
        // Emit H File
        //
        var header_gen = b.addExecutable(.{
            .name = "generate_headers",
            .root_source_file = b.path("bootstrap/generate_headers.zig"),
            .target = b.resolveTargetQuery(std.Target.Query{}),
            .optimize = optimize,
        });
        const heade_gen_opts = b.addOptions();
        heade_gen_opts.addOption(String, "h_dir", b.pathJoin(&.{ b.h_dir, "deshader" }));
        header_gen.root_module.addOptions("options", heade_gen_opts);
        header_gen.root_module.addAnonymousImport("header_gen", .{
            .root_source_file = b.path("libs/zig-header-gen/src/header_gen.zig"),
        });
        // no-short stubs for the C header
        {
            const long_name = b.getInstallPath(.header, "deshader/deshader_prefixed.zig");
            var stub_gen_long = try b.allocator.create(stubGenSrc.GenerateStubsStep);
            stub_gen_long.* = stubGenSrc.GenerateStubsStep.init(b, long_name, false);
            header_gen.step.dependOn(&stub_gen_long.step);
            header_gen.root_module.addAnonymousImport("deshader", .{ .root_source_file = .{ .cwd_relative = long_name } });
        }

        {
            header_gen_cmd.dependOn(&header_gen.step);
            const header_run = b.addRunArtifact(header_gen);
            header_run.step.dependOn(&b.addInstallHeaderFile(b.path("src/declarations/macros.h"), "deshader/macros.h").step);
            header_run.step.dependOn(&b.addInstallHeaderFile(b.path("src/declarations/commands.h"), "deshader/commands.h").step);
            // automatically create header when building the library
            deshader_lib_cmd.dependOn(&header_run.step);
        }
    }

    //
    // Docs
    //
    var docs = b.addInstallDirectory(.{
        .source_dir = deshader_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const deshader_docs = b.step("docs", "Generate API documentation");
    deshader_docs.dependOn(&docs.step);

    //
    // Launcher utility
    //
    const launcher_exe = b.addExecutable(.{
        .name = "deshader-run",
        .root_source_file = b.path("src/launcher/launcher.zig"),
        .link_libc = true,
        .optimize = optimize,
        .target = target,
    });
    launcher_exe.root_module.error_tracing = options_traces;
    launcher_exe.root_module.strip = option_strip;
    launcher_exe.root_module.unwind_tables = options_unwind;
    launcher_exe.root_module.sanitize_c = options_sanitize;
    launcher_exe.root_module.stack_check = option_stack_check;
    launcher_exe.root_module.stack_protector = option_stack_protector;
    launcher_exe.root_module.valgrind = option_valgrind;
    launcher_exe.each_lib_rpath = false;
    launcher_exe.root_module.addImport("common", common);

    launcher_exe.root_module.addImport("args", args_mod);
    launcher_exe.root_module.addImport("glsl_analyzer", glsl_analyzer); // TODO externalize glsl_analyzer

    const launcher_install = b.addInstallArtifact(launcher_exe, .{});
    _ = b.step("launcher", "Build Deshader Launcher - a utility to run any application with Deshader").dependOn(&launcher_install.step);

    const launcher_options = b.addOptions();
    launcher_options.addOption(String, "deshaderLibName", deshader_lib_name);
    launcher_options.addOption(u32, "memoryFrames", option_memory_frames);
    launcher_options.addOption(String, "deshaderRelativeRoot", if (targetTarget == .windows) "." else try std.fs.path.relative(b.allocator, b.exe_dir, b.lib_dir));

    // Editor
    {
        const editor_directory = "editor";
        const editor_dir_relative = try std.fs.path.relative(b.allocator, if (targetTarget == .windows) b.exe_dir else b.lib_dir, b.pathFromRoot(editor_directory));
        if (option_editor) {
            launcher_exe.step.dependOn(&dependencies_step.step);
        }

        //
        // Embed the created dependencies
        //
        var files = std.ArrayList(String).init(b.allocator);
        defer files.deinit();

        // Add all file names in the editor dist folder to `files`
        if (option_editor) {
            const editor_files = try b.build_root.handle.readFileAlloc(b.allocator, editor_directory ++ "/required.txt", 1024 * 1024);
            var editor_files_lines = std.mem.splitScalar(u8, editor_files, '\n');
            editor_files_lines.reset();
            while (editor_files_lines.next()) |line| {
                const path = try std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ editor_directory, std.mem.trim(u8, line, "\n\r\t ") });
                try files.append(path);
                if (optimize != .Debug) { // In debug mode files are served from physical filesystem so one does not need to recompile Deshader each time
                    try embedCompressedFile(deshader_lib, if (option_editor) &dependencies_step.step else null, path);
                }
            }
        }

        // Add the file names as an option to the exe, making it available
        // as a string array at comptime in main.zig
        launcher_options.addOption([]const String, "files", files.items);
        launcher_options.addOption(String, "editor_dir", editor_directory);
        launcher_options.addOption(String, "editor_dir_relative", editor_dir_relative);
        launcher_options.addOption(bool, "editor", option_editor);
    }
    launcher_exe.root_module.addOptions("options", launcher_options);
    launcher_exe.defineCMacro("_GNU_SOURCE", null); // To access dlinfo
    if (targetTarget == .windows) {
        launcher_exe.addWin32ResourceFile(.{ .file = b.path(b.pathJoin(&.{ "src", "resources.rc" })) });
    }

    // Positron SDK
    const positron = PositronSdk.getPackage(b, "positron", target);
    const serve = b.modules.get("serve").?;

    //
    // VCPKG libraries - must be at the end of configure phase, for the DependenciesStep to be correctly populated
    //
    {
        // WolfSSL - a serve's dependency
        option_system_wolfssl = option_system_wolfssl and try systemHasLib(deshader_lib, host_libs_location, "wolfssl");
        if (try linkWolfSSL(serve, deshader_lib_install, !option_system_wolfssl, option_triplet, option_lib_debug)) |lib_name| {
            try deshader_dependent_dlls.append(lib_name);
        }

        // Dependent DLLLs must be added to options after the list is populated
        launcher_options.addOption([]const String, "dependencies", deshader_dependent_dlls.items);
        if (targetTarget == .windows) {
            options.addOption([]const String, "dependencies", deshader_dependent_dlls.items);
        }

        // Native file dialogs library
        option_system_nfd = option_system_nfd and try systemHasLib(deshader_lib, host_libs_location, "nfd");
        try nfd(launcher_exe, option_system_nfd, option_triplet, option_lib_debug);

        switch (targetTarget) {
            .linux => launcher_exe.linkSystemLibrary("gtk+-3.0"),
            .windows => {
                launcher_exe.linkSystemLibrary("ole32");
            },
            else => {},
        }

        // GLSLang
        inline for (.{ "glslang", "glslang-default-resource-limits", "MachineIndependent", "GenericCodeGen" }) |l| {
            const lib_name = if (targetTarget == .windows) if (b.release_mode == .off) l ++ "d" else l else l;
            option_system_glslang = option_system_glslang and try systemHasLib(deshader_lib, host_libs_location, lib_name);

            if (option_system_glslang) {
                deshader_lib.linkSystemLibrary2(lib_name, .{ .preferred_link_mode = .dynamic });
            } else {
                try linkVcpkgLibrary(deshader_lib, lib_name, option_triplet, option_lib_debug);
                _ = try installVcpkgLibrary(deshader_lib_install, lib_name, option_triplet, option_lib_debug);
            }
        }

        // GLFW
        option_system_glfw = option_system_glfw and try systemHasLib(deshader_lib, host_libs_location, "glfw3");
    }

    if (option_editor) {
        try dependencies_step.editor(); //TODO do not always do everything
        PositronSdk.linkPositron(launcher_exe, null, option_linkage == .static);
        launcher_exe.linkLibCpp();
        _ = try linkWolfSSL(serve, launcher_install, !option_system_wolfssl, option_triplet, option_lib_debug);
        switch (targetTarget) {
            .linux => {
                if (try systemHasLib(launcher_exe, host_libs_location, "webkit2gtk-4.1")) {
                    launcher_exe.linkSystemLibrary("webkit2gtk-4.1");
                } else {
                    launcher_exe.linkSystemLibrary("webkit2gtk-4.0");
                }
            },
            else => {},
        }
    }

    deshader_lib.root_module.addImport("positron", positron);
    deshader_lib.root_module.addImport("serve", serve);
    launcher_exe.root_module.addImport("positron", positron);
    launcher_exe.root_module.addImport("serve", serve);

    const system_libs_available = option_system_glslang and option_system_wolfssl and option_system_nfd and option_system_glfw;
    if (system_libs_available) {
        log.info("All required libraries are supplied by system, skipping installing vcpkg dependencies", .{});
        deshader_lib.linkLibCpp();
    } else {
        try addVcpkgInstalledPaths(b, deshader_lib, option_triplet, option_lib_debug);
        try addVcpkgInstalledPaths(b, launcher_exe, option_triplet, option_lib_debug);
        try addVcpkgInstalledPaths(b, serve, option_triplet, option_lib_debug); // add WolfSSL from VCPKG to serve
        deshader_lib.step.dependOn(&dependencies_step.step);
        launcher_exe.step.dependOn(&dependencies_step.step);
        if (target.result.isGnuLibC()) { // VCPKG links to libstdc++ dynamically
            deshader_lib.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ host_libs_location, "libstdc++.so" }) });
        } else {
            deshader_lib.linkLibCpp();
        }
    }

    //
    // Example usages demonstration applications
    //
    {
        const examples_cmd = b.step("examples", "Example OpenGL apps");
        examples_cmd.dependOn(deshader_lib_cmd);

        const example_bootstraper = b.addExecutable(.{
            .name = "deshader-examples-all",
            .root_source_file = b.path("examples/examples.zig"),
            .target = target,
            .optimize = optimize,
        });
        const sub_examples = struct {
            const glfw = "glfw";
            const sdf = "sdf";
            const linked = "linked";
            const glfw_cpp = "glfw_cpp";
            const debug_commands = "debug_commands";
            const linked_cpp = "linked_cpp";
        };
        const example_options = b.addOptions();
        example_options.addOption([]const String, "exampleNames", &.{ sub_examples.glfw, sub_examples.linked, sub_examples.linked_cpp, sub_examples.debug_commands, sub_examples.glfw_cpp });
        example_bootstraper.root_module.addOptions("options", example_options);
        example_bootstraper.step.dependOn(header_gen_cmd);

        // Various example applications
        {
            const exampleModules = .{
                .{ .name = "gl", .module = gl_bindings },
                .{ .name = "deshader", .module = deshader_stubs },
            };

            // Use zig-glfw
            const zig_glfw_dep = b.dependency("zig_glfw", .{
                .target = target,
                .optimize = optimize,
            });

            // GLFW
            const example_glfw = try SubExampleStep.create(example_bootstraper, sub_examples.glfw, "examples/" ++ sub_examples.glfw ++ ".zig", exampleModules ++ .{.{ .name = "zig_glfw", .module = zig_glfw_dep.module("zig-glfw") }});
            try addVcpkgInstalledPaths(b, zig_glfw_dep.module("zig-glfw"), option_triplet, option_lib_debug);
            example_glfw.compile.linkLibC();

            const example_sdf = try SubExampleStep.create(example_bootstraper, sub_examples.sdf, "examples/" ++ sub_examples.sdf ++ ".zig", exampleModules ++ .{.{ .name = "zig_glfw", .module = zig_glfw_dep.module("zig-glfw") }});
            example_sdf.compile.linkLibC();

            // Editor Linked
            const example_editor = try SubExampleStep.create(example_bootstraper, sub_examples.linked, "examples/" ++ sub_examples.linked ++ ".zig", exampleModules);
            example_editor.compile.linkLibrary(deshader_lib);

            // GLFW in C++
            const example_glfw_cpp = try SubExampleStep.create(example_bootstraper, sub_examples.glfw_cpp, "examples/" ++ sub_examples.glfw ++ ".cpp", .{});
            example_glfw_cpp.compile.addIncludePath(.{ .cwd_relative = b.h_dir });
            example_glfw_cpp.compile.defineCMacro("_LIBCPP_HAS_NO_WIDE_CHARACTERS", null);
            example_glfw_cpp.compile.linkLibCpp();
            try linkGlew(example_glfw_cpp.install, option_system_glew, option_triplet, option_lib_debug);

            // Embed shaders into the executable
            if (targetTarget == .windows) {
                example_glfw_cpp.compile.addWin32ResourceFile(.{ .file = b.path(b.pathJoin(&.{ "examples", "shaders.rc" })) });
                example_glfw_cpp.compile.defineCMacro("WIN32", null);
            } else {
                inline for (.{ "fragment.frag", "vertex.vert" }) |shader| {
                    const output = try std.fs.path.join(b.allocator, &.{ b.cache_root.path.?, "shaders", shader ++ ".o" });
                    b.cache_root.handle.access("shaders", .{}) catch try std.fs.makeDirAbsolute(std.fs.path.dirname(output).?);
                    var dir = try b.build_root.handle.openDir("examples", .{});
                    defer dir.close();
                    const result = if (builtin.os.tag == .macos) embed: { // TODO do not run on every configure
                        // https://stackoverflow.com/questions/8923097/compile-a-binary-file-for-linking-osx
                        const stub = try std.fs.path.join(b.allocator, &.{ b.cache_root.path.?, "shaders", "stub.o" });
                        _ = try exec(.{
                            .allocator = b.allocator,
                            .cwd_dir = dir,
                            .argv = &.{ "gcc", "-o", stub, "-c", "../bootstrap/stub.c" },
                        });
                        break :embed try exec(.{
                            .allocator = b.allocator,
                            .cwd_dir = dir,
                            .argv = &.{ "ld", "-r", "-o", output, "-sectcreate", "binary", shader, shader, stub },
                        });
                    } else try exec(.{
                        .allocator = b.allocator,
                        .argv = &.{ "ld", "--relocatable", "--format", "binary", "--output", output, shader },
                        .cwd_dir = dir,
                    });
                    if (result.term.Exited == 0) {
                        example_glfw_cpp.compile.addObjectFile(.{ .cwd_relative = output });
                    } else {
                        log.err("Failed to compile shader {s}: {s}", .{ shader, result.stderr });
                    }
                }
            }

            // Linking Deshader with C++ code
            const example_linked_cpp = try SubExampleStep.create(example_bootstraper, sub_examples.linked_cpp, "examples/linked.cpp", .{});
            example_linked_cpp.compile.addIncludePath(.{ .cwd_relative = b.h_dir });
            example_linked_cpp.compile.linkSystemLibrary("deshader");
            example_linked_cpp.compile.addLibraryPath(.{ .cwd_relative = b.lib_dir }); //implib or .so
            if (targetTarget == .windows) {
                example_linked_cpp.compile.addLibraryPath(.{ .cwd_relative = b.exe_dir }); // .dll
            }
            example_linked_cpp.compile.each_lib_rpath = false;
            example_linked_cpp.compile.step.dependOn(&deshader_lib_install.step);
            example_linked_cpp.compile.linkLibCpp();
            example_linked_cpp.compile.defineCMacro("_LIBCPP_HAS_NO_WIDE_CHARACTERS", null);

            // Using unobtrusive Deshader Library commands
            const example_debug_commands = try SubExampleStep.create(example_bootstraper, sub_examples.debug_commands, "examples/debug_commands.cpp", .{});
            example_debug_commands.compile.addIncludePath(.{ .cwd_relative = b.h_dir });
            example_debug_commands.compile.defineCMacro("_LIBCPP_HAS_NO_WIDE_CHARACTERS", null);
            example_debug_commands.compile.linkLibCpp();
            example_debug_commands.compile.addFrameworkPath(framework_path);
            example_debug_commands.compile.addFrameworkPath(system_framwork_path);
            try linkGlew(example_debug_commands.install, option_system_glew, option_triplet, option_lib_debug);

            inline for (.{ example_glfw, example_sdf, example_glfw_cpp, example_debug_commands }) |example| {
                if (option_system_glfw)
                    example.compile.linkSystemLibrary("glfw3")
                else {
                    example.compile.step.dependOn(&dependencies_step.step);
                    try linkVcpkgLibrary(example.compile, "glfw3", option_triplet, option_lib_debug);
                    _ = try installVcpkgLibrary(example.install, "glfw3", option_triplet, option_lib_debug);
                }

                if (!system_libs_available) {
                    try addVcpkgInstalledPaths(b, example.compile, option_triplet, option_lib_debug);
                }

                switch (targetTarget) {
                    .linux => example.compile.linkSystemLibrary("x11"),
                    .macos => {
                        example.compile.linkFramework("Cocoa");
                        example.compile.linkFramework("OpenGL");
                        example.compile.linkFramework("IOKit");
                        example.compile.linkFramework("QuartzCore");
                        example.compile.addFrameworkPath(framework_path);
                        example.compile.addFrameworkPath(system_framwork_path);
                    },
                    else => {},
                }
            }
        }
        examples_cmd.dependOn(stub_gen_cmd);
        const example_bootstraper_install = b.addInstallArtifact(example_bootstraper, .{});
        examples_cmd.dependOn(&example_bootstraper_install.step);

        // Run examples by `deshader-run`
        const examples_run = b.addRunArtifact(launcher_install.artifact);
        const examples_run_cmd = b.step("examples-run", "Run example with injected Deshader debugging");
        examples_run.setEnvironmentVariable("DESHADER_LIB", try std.fs.path.join(b.allocator, &.{ if (targetTarget == .windows) b.exe_dir else b.lib_dir, deshader_lib_name }));
        examples_run.setCwd(.{ .cwd_relative = b.pathJoin(&.{ b.exe_dir, "deshader-examples" }) });
        examples_run.setEnvironmentVariable("DESHADER_PROCESS", "glfw:glfw_cpp:editor:debug_commands");
        examples_run.setEnvironmentVariable((if (targetTarget == .macos) "DYLD_LIBRARY_PATH" else "LD_LIBRARY_PATH"), b.lib_dir);
        examples_run.addArg("-no-whitelist");
        examples_run.addArg(b.pathJoin(&.{ b.exe_dir, try std.mem.concat(b.allocator, u8, &.{ example_bootstraper.name, target.result.exeFileExt() }) }));
        examples_run.step.dependOn(&example_bootstraper_install.step);
        examples_run_cmd.dependOn(&examples_run.step);
    }

    //
    // Tests
    //
    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build test`
    // This will evaluate the `test` step rather than the default, which is "install".
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    // Clean step
    const clean_step = b.step("clean", "Remove zig-out and zig-cache folders");
    const clean_run = b.addSystemCommand(switch (builtin.os.tag) {
        .windows => &[_]String{ "cmd", "/c", "del", "/s", "/q" },
        .linux, .macos => &[_]String{ "rm", "-rf" },
        else => unreachable,
    } ++ &[_]String{ "zig-out", ".zig-cache" });
    clean_run.step.dependOn(b.getUninstallStep());
    clean_step.dependOn(&clean_run.step);
}

fn embedCompressedFile(compile: *std.Build.Step.Compile, dependOn: ?*std.Build.Step, path: String) !void {
    const compress = try CompressStep.init(compile.step.owner, compile.step.owner.path(path));
    if (dependOn) |d| {
        compress.step.dependOn(d);
    }
    compile.root_module.addAnonymousImport(path, .{
        .root_source_file = .{ .generated = .{ .file = &compress.generatedFile } },
    });
    compile.step.dependOn(&compress.step);
}

const SubExampleStep = struct {
    compile: *std.Build.Step.Compile,
    install: *std.Build.Step.InstallArtifact,

    pub fn create(compile: *std.Build.Step.Compile, comptime name: String, path: String, modules: anytype) !@This() {
        var step = &compile.step;
        const b = compile.step.owner;
        const is_zig = std.mem.endsWith(u8, path, "zig");
        const subExe = step.owner.addExecutable(.{
            .name = name,
            .root_source_file = if (is_zig) b.path(path) else null,
            .target = step.owner.resolveTargetQuery(std.Target.Query.fromTarget(compile.rootModuleTarget())),
            .optimize = compile.root_module.optimize orelse .ReleaseSafe,
        });
        if (!is_zig) {
            subExe.addCSourceFile(.{
                .file = b.path(path),
            });
        }
        var arena = std.heap.ArenaAllocator.init(b.allocator);
        defer arena.deinit();
        const n_paths = try std.zig.system.NativePaths.detect(arena.allocator(), compile.rootModuleTarget());
        for (n_paths.lib_dirs.items) |lib_dir| {
            subExe.addLibraryPath(.{ .cwd_relative = lib_dir });
        }
        for (n_paths.include_dirs.items) |include_dir| {
            subExe.addSystemIncludePath(.{ .cwd_relative = include_dir });
        }
        inline for (modules) |mod| {
            subExe.root_module.addImport(mod.name, mod.module);
        }
        const target = compile.rootModuleTarget().os.tag;

        if (target == .windows) {
            subExe.linkSystemLibrary("opengl32");
        }
        const examples_dirname = "deshader-examples";
        const sep = std.fs.path.sep_str;
        const install = step.owner.addInstallArtifact(
            subExe,
            .{
                .dest_sub_path = try std.mem.concat(step.owner.allocator, u8, &.{ examples_dirname, sep, name, if (target == .windows) ".exe" else "" }),
                .pdb_dir = if (target == .windows) .{ .override = .{ .custom = b.pathJoin(&.{ "bin", examples_dirname }) } } else .default,
            },
        );
        step.dependOn(&install.step);
        return @This(){
            .compile = subExe,
            .install = install,
        };
    }
};

fn fileWithPrefixExists(allocator: std.mem.Allocator, dirname: String, basename: String) !?String {
    const full_dirname = try std.fs.path.join(allocator, &.{ dirname, std.fs.path.dirname(basename) orelse "" });
    defer allocator.free(full_dirname);
    var dir = openIterableDir(full_dirname) catch return null;
    defer dir.close();
    var it = dir.iterate();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    while (try it.next()) |current| {
        if (current.kind == .file or (current.kind == .sym_link and resolve: {
            const target = try dir.readLink(current.name, &buffer);
            break :resolve (dir.statFile(target) catch break :resolve false).kind == .file;
        })) {
            if (std.mem.startsWith(u8, current.name, std.fs.path.basename(basename))) {
                return try std.fs.path.join(allocator, &.{ full_dirname, current.name });
            }
        }
    }
    return null;
}

fn addVcpkgInstalledPaths(b: *std.Build, c: anytype, triplet: ?String, debug_lib: bool) !void {
    const module = if (@hasField(@TypeOf(c.*), "root_module")) c.root_module else c;
    const debug = if (debug_lib) "debug" else "";
    const target = if (module.resolved_target) |t| t.result else builtin.target;
    c.addIncludePath(b.path(b.pathJoin(&.{ "build", "vcpkg_installed", triplet orelse try arch.targetToVcpkgTriplet(b.allocator, target), "debug", "include" })));
    c.addIncludePath(b.path(b.pathJoin(&.{ "build", "vcpkg_installed", triplet orelse try arch.targetToVcpkgTriplet(b.allocator, target), "include" })));
    c.addLibraryPath(b.path(b.pathJoin(&.{ "build", "vcpkg_installed", triplet orelse try arch.targetToVcpkgTriplet(b.allocator, target), debug, "bin" })));
    c.addLibraryPath(b.path(b.pathJoin(&.{ "build", "vcpkg_installed", triplet orelse try arch.targetToVcpkgTriplet(b.allocator, target), debug, "lib" })));
}

/// Must be called at the end of configure phase, because it could dispatch vcpkg installation
fn linkVcpkgLibrary(compile: anytype, name: String, triplet: ?String, debug: bool) !void {
    const b = if (@hasField(@TypeOf(compile.*), "step")) compile.step.owner else compile.owner;
    const target = if (@hasDecl(@TypeOf(compile.*), "rootModuleTarget")) compile.rootModuleTarget() else if (compile.resolved_target) |r| r.result else builtin.target;

    const vcpkg_dir = b.pathJoin(&.{ "build", "vcpkg_installed", triplet orelse try arch.targetToVcpkgTriplet(b.allocator, target), if (debug) "debug" else "" });
    b.build_root.handle.access(vcpkg_dir, .{}) catch {
        // VCPKG libraries were not installed previously so all our check would fail. We must wait for VCPKG to install them.
        log.debug("Starting VCPKG installation in configuration phase", .{});
        try DependenciesStep.doAll(&dependencies_step.step, std.Progress.Node{ .index = .none });
    };

    const vcpkg_dir_real = try b.build_root.handle.realpathAlloc(b.allocator, vcpkg_dir);
    defer b.allocator.free(vcpkg_dir_real);

    inline for (.{ "lib", "" }) |prefix| {
        if (try fileWithPrefixExists(b.allocator, vcpkg_dir_real, try std.mem.concat(b.allocator, u8, &.{ "lib", std.fs.path.sep_str, prefix, name, target.staticLibSuffix() }))) |full_name| {
            compile.addObjectFile(.{ .cwd_relative = full_name });
            log.info("Linked {s} from VCPKG", .{full_name});
            return;
        } else if (try fileWithPrefixExists(b.allocator, vcpkg_dir_real, try std.mem.concat(b.allocator, u8, &.{ "bin", std.fs.path.sep_str, prefix, name, target.staticLibSuffix() }))) |full_name| {
            compile.addObjectFile(.{ .cwd_relative = full_name });
            log.info("Linked {s} from VCPKG", .{full_name});
            return;
        }
    }

    if (@hasField(@TypeOf(compile.*), "root_module")) compile.root_module.linkSystemLibrary(name, .{}) else compile.linkSystemLibrary(name, .{});
    log.warn("Could not link {s} from VCPKG but maybe it is in system.", .{name});
}

fn installVcpkgLibrary(i: *std.Build.Step.InstallArtifact, name: String, triplet: ?String, debug_lib: bool) !String {
    const b = i.step.owner;
    const target = i.artifact.rootModuleTarget();
    const os = target.os.tag;
    var name_parts = std.mem.splitScalar(u8, name, '.');
    const basename = name_parts.first();
    inline for (.{ "", "lib" }) |p| {
        const name_with_ext = try std.mem.concat(b.allocator, u8, &.{ p, basename, os.dynamicLibSuffix() });
        const dll_path = b.pathJoin(&.{
            "build",
            "vcpkg_installed",
            triplet orelse try arch.targetToVcpkgTriplet(b.allocator, target),
            if (debug_lib) "debug" else "",
            "bin",
            name_with_ext,
        });
        if (b.build_root.handle.access(dll_path, .{})) {
            const dest_path = if (std.fs.path.dirname(i.dest_sub_path)) |sub_dir|
                try std.fs.path.join(b.allocator, &.{ sub_dir, name_with_ext })
            else
                name_with_ext;

            // Copy the library to the install directory
            i.step.dependOn(&(if (i.artifact.kind == .lib and os != .windows) // on windows, DLLS are inside bin
                b.addInstallLibFile(b.path(dll_path), dest_path)
            else
                b.addInstallBinFile(b.path(dll_path), dest_path)).step);

            log.info("Installed dynamic {s} from VCPKG", .{dest_path});
            return name_with_ext;
        } else |_| {}
    } else {
        log.warn("Could not install dynamic {s} from VCPKG but maybe it is static or in system.", .{name});
    }
    return name;
}

fn linkGlew(i: *std.Build.Step.InstallArtifact, prefer_system: bool, triplet: ?String, debug_lib: bool) !void {
    if (i.artifact.rootModuleTarget().os.tag == .windows) {
        try addVcpkgInstalledPaths(i.step.owner, i.artifact, triplet, debug_lib);
        const glew = if (i.artifact.root_module.optimize orelse .Debug == .Debug) "glew32d" else "glew32";
        try linkVcpkgLibrary(i.artifact, glew, triplet, debug_lib); // VCPKG on x64-windows-cross generates bin/glew32.dll but lib/libglew32.dll.a
        _ = try installVcpkgLibrary(i, glew, triplet, debug_lib);
        i.artifact.linkSystemLibrary2("opengl32", .{ .needed = true });
    } else if (prefer_system) {
        i.artifact.linkSystemLibrary2("glew", .{ .preferred_link_mode = .dynamic });
    } else {
        try linkVcpkgLibrary(i.artifact, "glew", triplet, debug_lib);
    }
}

fn winepath(alloc: std.mem.Allocator, path: String, toWindows: bool) !String {
    const result = try exec(.{ .allocator = alloc, .argv = &.{ "winepath", if (toWindows) "-w" else "-u", path } });
    if (result.term.Exited == 0) {
        return std.mem.trim(u8, result.stdout, " \n\t");
    } else if (result.term == .Exited) {
        log.err("Failed to run winepath with code {d}: {s}", .{ result.term.Exited, result.stderr });
        return error.Winepath;
    } else {
        log.err("Failed to run winepath: {}", .{result.term});
        return error.Winepath;
    }
}

fn linkWolfSSL(module: *std.Build.Module, install: ?*std.Build.Step.InstallArtifact, prefer_vcpkg: bool, triplet: ?String, debug: bool) !?String {
    const target = if (module.resolved_target) |t| t.result else builtin.target;
    const wolfssl_lib_name = "wolfssl";
    if (prefer_vcpkg) {
        try linkVcpkgLibrary(module, wolfssl_lib_name, triplet, debug);
        return if (install) |i|
            try installVcpkgLibrary(i, wolfssl_lib_name, triplet, debug)
        else
            null;
    } else {
        module.linkSystemLibrary(wolfssl_lib_name, .{ .preferred_link_mode = .dynamic });
    }
    if (target.os.tag == .windows) {
        module.addCMacro("SINGLE_THREADED", ""); // To workaround missing pthread.h
    }
    const with_ext = try std.mem.concat(module.owner.allocator, u8, &.{ wolfssl_lib_name, target.dynamicLibSuffix() });
    return with_ext;
}

/// Search for all lib directories
/// TODO: different architectures than system-native
fn systemHasLib(c: *std.Build.Step.Compile, native_libs_location: String, lib: String) !bool {
    const b: *std.Build = c.step.owner;
    const target: std.Target = c.rootModuleTarget();

    const libname = try std.mem.concat(b.allocator, u8, &.{ target.libPrefix(), lib });
    defer b.allocator.free(libname);
    if (builtin.os.tag == target.os.tag and builtin.cpu.arch == target.cpu.arch) { // native
        for (c.root_module.lib_paths.items) |lib_dir| {
            const path = lib_dir.getPath(b);
            if (try fileWithPrefixExists(b.allocator, path, libname)) |full_name| {
                log.info("Found library {s}", .{full_name});
                b.allocator.free(full_name);
                return true;
            }
        }
    }

    if (try fileWithPrefixExists(b.allocator, native_libs_location, libname)) |full_name| {
        log.info("Found system library {s}", .{full_name});
        b.allocator.free(full_name);
        return true;
    } else return false;
}

fn nfd(c: *std.Build.Step.Compile, prefer_system: bool, triplet: ?String, debug: bool) !void {
    if (c.rootModuleTarget().os.tag == .linux) {
        // sometimes located here on Linux
        c.addLibraryPath(.{ .cwd_relative = "/usr/lib/nfd/" });
        c.addIncludePath(.{ .cwd_relative = "/usr/include/nfd/" });
        c.addLibraryPath(.{ .cwd_relative = "/usr/local/lib/nfd/" });
        c.addIncludePath(.{ .cwd_relative = "/usr/local/include/nfd/" });
    }
    if (prefer_system) {
        c.linkSystemLibrary("nfd");
    } else {
        try linkVcpkgLibrary(c, if (debug) "nfd_d" else "nfd", triplet, debug); //Native file dialog library from VCPKG
    }
}

// TODO use zig.system.NativePaths
fn getLdConfigPath(b: *std.Build) String { // searches for libGL
    const output = b.run(&.{ "ldconfig", "-p" });
    defer b.allocator.free(output);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "libGL") != null) {
            if (std.mem.indexOf(u8, line, "=>")) |arrow| {
                const gl_path = std.mem.trim(u8, line[arrow + 2 ..], " \n\t ");
                std.log.info("Found libGL at {s}", .{gl_path});
                return b.pathJoin(&.{ std.fs.path.dirname(gl_path) orelse "", "/" });
            }
        }
    }
    std.log.warn("Could not find libGL path", .{});
    return "/usr/lib/";
}

fn pathExists(path: String) ?String {
    if (std.fs.accessAbsolute(path, .{})) {
        return path;
    } else |_| {
        return null;
    }
}

fn hostToTargetPath(alloc: std.mem.Allocator, target: std.Target.Os.Tag, path: String, target_sysroot_in_host: String) !String {
    if (target == builtin.os.tag) {
        return path;
    } else switch (target) {
        .windows => return winepath(alloc, path, true),
        .macos => if (std.mem.startsWith(u8, path, target_sysroot_in_host)) {
            return path[target_sysroot_in_host.len - 1 ..];
        } else if (try ctregex.search("/home/.*/.darling", .{}, path)) |found| {
            return path[found.slice.len..];
        } else return std.fs.path.join(alloc, &.{ "/Volumes/SystemRoot/", path }), // Darling
        else => return path,
    }
}

fn uppercaseFirstLetter(a: std.mem.Allocator, s: String) !String {
    if (s.len == 0) {
        return s;
    }
    return try std.mem.concat(a, u8, &.{ &.{std.ascii.toUpper(s[0])}, s[1..] });
}
