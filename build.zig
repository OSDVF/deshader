const std = @import("std");
const builtin = @import("builtin");
const PositronSdk = @import("libs/positron/Sdk.zig");
const ZigServe = @import("libs/positron/vendor/serve/build.zig");
const ctregex = @import("libs/ctregex/ctregex.zig");
const CompressStep = @import("bootstrap/compress.zig").CompressStep;
const DependenciesStep = @import("bootstrap/dependencies.zig").DependenciesStep;
const ListGlProcsStep = @import("bootstrap/list_gl_procs.zig").ListGlProcsStep;

const Linkage = enum {
    Static,
    Dynamic,
};
const String = []const u8;

// Shims for compatibility between Zig versions
const exec = if (@hasDecl(std.ChildProcess, "exec")) std.ChildProcess.exec else std.ChildProcess.run;
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
        else => &[_]String{ "libGLX.so.0", "libEGL.so" },
    };
    const system32 = "C:/Windows/System32/";
    const host_libs_location = switch (targetTarget) {
        .windows => if (builtin.os.tag == .windows) system32 else try winepath(b.allocator, system32, false),
        else => "/usr/lib/",
    };
    const native_libs_location = if (targetTarget == .windows) system32 else host_libs_location;
    const GlSymbolPrefixes: []const String = switch (targetTarget) {
        .windows => &[_]String{ "wgl", "gl" },
        .linux => &[_]String{ "glX", "egl", "gl" },
        else => &[_]String{"gl"},
    };
    const VulkanLibName = switch (targetTarget) {
        .windows => "vulkan-1.dll",
        .macos => "libvulkan.dylib",
        else => "libvulkan.so",
    };
    const ObjectFormat = enum { Default, c, IR, BC };
    const optionOfmt = b.option(ObjectFormat, "ofmt", "Compile into object format") orelse .Default;
    if (optionOfmt == .c) {
        target.result.ofmt = .c;
    }

    // Deshader library
    const deshaderCompileOptions = .{
        .name = "deshader",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    };

    // Compile options
    const option_custom_library = b.option([]const String, "customLibrary", "Names of additional libraries to intercept");
    const option_dependencies = b.option(bool, "deps", "Build dependencies first: VCPKG managed libs, GL definitions, VSCode, extension") orelse false;
    const option_docs = b.option(bool, "docs", "Generate API documentation") orelse false;
    const option_embed_gui = b.option(bool, "embedGUI", "Embed Runner GUI and VSCode editor into the library (default yes)") orelse true;
    const option_ignore_missing = b.option(bool, "ignoreMissing", "Ignore missing VK and GL libraries. GLX, EGL and VK will be required by default") orelse false;
    const option_include = b.option(String, "include", "Path to directory with additional headers to include");
    const option_lib_dir = b.option(String, "lib", "Path to directory with additional libraries to link");
    const option_linkage = b.option(Linkage, "linkage", "Select linkage type for deshader library. Cannot be combined with -Dofmt.") orelse Linkage.Dynamic;
    const option_log_intercept = b.option(bool, "logIntercept", "Log intercepted GL and VK procedure list to stdout") orelse false;
    const option_memory_frames = b.option(u32, "memoryFrames", "Number of frames in memory leak backtrace") orelse 7;
    const option_wolf_system = b.option(bool, "wolfSSL", "Link dynamically WolfSSL available on this system instead of from vcpkg") orelse false;

    const deshader_lib: *std.Build.Step.Compile = if (option_linkage == .Static) b.addStaticLibrary(deshaderCompileOptions) else b.addSharedLibrary(deshaderCompileOptions);
    deshader_lib.defineCMacro("_GNU_SOURCE", null); // To access dl_iterate_phdr
    const deshader_lib_name = try std.mem.concat(b.allocator, u8, &.{ if (targetTarget == .windows) "" else "lib", deshader_lib.name, targetTarget.dynamicLibSuffix() });
    const deshader_lib_cmd = b.step("deshader", "Install deshader library");
    switch (optionOfmt) {
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
    try addVcpkgInstalledPaths(deshader_lib);
    // WolfSSL
    if (try linkWolfSSL(deshader_lib, deshader_lib_install, !option_wolf_system)) |lib_name| {
        const with_ext = try std.mem.concat(b.allocator, u8, &.{ lib_name, targetTarget.dynamicLibSuffix() });
        try deshader_dependent_dlls.append(with_ext);
    }
    // Native file dialogs library
    deshader_lib.linkSystemLibrary(if (optimize == .Debug) "nfd_d" else "nfd"); //Native file dialog library from VCPKG

    const noSystemGLSLang = blk: {
        const libname = try std.mem.concat(b.allocator, u8, &.{ target.result.libPrefix(), "glslang" });
        defer b.allocator.free(libname);
        if (try fileWithPrefixExists(b.allocator, host_libs_location, libname)) |_| {
            break :blk true;
        } else break :blk false;
    };

    // GLSLang
    inline for (.{ "glslang", "glslang-default-resource-limits" }) |glslang| {
        try installVcpkgLibrary(deshader_lib_install, glslang);
        deshader_lib.linkSystemLibrary(glslang);
    }
    if (noSystemGLSLang) {
        // vcpkg will link these statically
        deshader_lib.linkSystemLibrary("MachineIndependent");
        deshader_lib.linkSystemLibrary("GenericCodeGen");
    }

    // Websocket
    const websocket = b.addModule("websocket", .{
        .root_source_file = b.path("libs/websocket/src/websocket.zig"),
    });
    deshader_lib.root_module.addImport("websocket", websocket);

    // OpenGL
    // Choose the OpenGL API, version, profile and extensions you want to generate bindings for.
    const zigglgen = @import("zigglgen");
    const string_exts = b.option([]const []const u8, "glExtensions", "OpenGL extensions included in the bindings") orelse &.{};
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
    const compressed_spec = b.addModule("glsl_spec.json.zlib", .{ .root_source_file = .{ .generated = &compresss_spec.generatedFile } });
    const glsl_analyzer_options = b.addOptions();
    glsl_analyzer_options.addOption(bool, "has_websocket", true);
    const glsl_analyzer = b.addModule("glsl_analyzer", .{
        .root_source_file = b.path("libs/glsl_analyzer.zig"),
        .imports = &[_]std.Build.Module.Import{ .{
            .name = "glsl_spec.json.zlib",
            .module = compressed_spec,
        }, .{
            .name = "websocket",
            .module = websocket,
        }, .{
            .name = "build_options",
            .module = glsl_analyzer_options.createModule(),
        } },
    });
    deshader_lib.root_module.addImport("glsl_analyzer", glsl_analyzer);

    // Deshader internal library options
    const options = b.addOptions();
    const optionGLAdditionalLoader = b.option(String, "glAddLoader", "Name of additional exposed function which will call GL function loader");
    const optionvkAddInstanceLoader = b.option(String, "vkAddInstanceLoader", "Name of additional exposed function which will call Vulkan instance function loader");
    const optionvkAddDeviceLoader = b.option(String, "vkAddDeviceLoader", "Name of additional exposed function which will call Vulkan device function loader");
    options.addOption(?String, "glAddLoader", optionGLAdditionalLoader);
    options.addOption(?String, "vkAddDeviceLoader", optionvkAddDeviceLoader);
    options.addOption(?String, "vkAddInstanceLoader", optionvkAddInstanceLoader);
    options.addOption(bool, "logIntercept", option_log_intercept);
    options.addOption(String, "deshaderLibName", deshader_lib_name);
    options.addOption(ObjectFormat, "ofmt", optionOfmt);
    options.addOption(u32, "memoryFrames", option_memory_frames);
    const version_result = try exec(.{ .allocator = b.allocator, .argv = &.{ "git", "describe", "--tags", "--always" } });
    options.addOption([:0]const u8, "version", try b.allocator.dupeZ(u8, std.mem.trim(u8, version_result.stdout, " \n\t")));
    if (targetTarget == .windows) {
        options.addOption([]const String, "dependencies", deshader_dependent_dlls.items);
    }

    // Symbol Enumeration
    const run_symbol_enum = b.addSystemCommand(if (targetTarget == .windows) &.{
        "bootstrap/tools/dumpbin.exe",
        "/exports",
    } else &.{ "nm", "--format=posix", "--defined-only", "-DAp" });
    if (b.enable_wine) {
        run_symbol_enum.setEnvironmentVariable("WINEDEBUG", "-all"); //otherwise expectStdErrEqual("") will not ignore fixme messages
    }
    for (GlLibNames) |libName| {
        if (try fileWithPrefixExists(b.allocator, host_libs_location, libName)) |real_name| {
            run_symbol_enum.addArg(std.fmt.allocPrint(b.allocator, "{s}{s}", .{ native_libs_location, real_name }) catch unreachable);
        } else {
            if (option_ignore_missing) {
                std.log.warn("Missing library {s}", .{libName});
            } else {
                return deshader_lib.step.fail("Missing library {s}", .{libName});
            }
        }
    }
    if (try fileWithPrefixExists(b.allocator, host_libs_location, VulkanLibName)) |real_name| {
        run_symbol_enum.addArg(std.fmt.allocPrint(b.allocator, "{s}{s}", .{ native_libs_location, real_name }) catch unreachable);
    } else {
        if (option_ignore_missing) {
            std.log.warn("Missing library {s}", .{VulkanLibName});
        } else {
            return deshader_lib.step.fail("Missing library {s}", .{VulkanLibName});
        }
    }

    run_symbol_enum.addArg(std.fmt.allocPrint(b.allocator, "{s}{s}", .{ native_libs_location, VulkanLibName }) catch unreachable);
    run_symbol_enum.expectExitCode(0);
    run_symbol_enum.expectStdErrEqual("");
    var allLibraries = std.ArrayList(String).init(b.allocator);
    allLibraries.appendSlice(GlLibNames) catch unreachable;
    allLibraries.append(VulkanLibName) catch unreachable;
    if (option_custom_library != null) {
        run_symbol_enum.addArgs(option_custom_library.?);
        allLibraries.appendSlice(option_custom_library.?) catch unreachable;
    }
    // Parse symbol enumerator output
    var addGlProcsStep = ListGlProcsStep.init(b, targetTarget, "add_gl_procs", allLibraries.items, GlSymbolPrefixes, run_symbol_enum.captureStdOut());
    addGlProcsStep.step.dependOn(&run_symbol_enum.step);
    deshader_lib.step.dependOn(&addGlProcsStep.step);
    const transitive_exports = b.createModule(.{ .root_source_file = .{ .generated = &addGlProcsStep.generated_file } });
    deshader_lib.root_module.addImport("transitive_exports", transitive_exports);

    // Positron
    const positron = PositronSdk.getPackage(b, "positron");
    deshader_lib.root_module.addImport("positron", positron);
    deshader_lib.root_module.addImport("serve", b.modules.get("serve").?);
    if (option_embed_gui) {
        PositronSdk.linkPositron(deshader_lib, null, option_linkage == .Static);
        if (targetTarget == .windows) {
            try deshader_dependent_dlls.append("WebView2Loader.dll");
        }
    }
    //
    // Steps for building generated and embedded files
    //
    const stubs_path = try std.fs.path.join(b.allocator, &.{ b.h_dir, "deshader.zig" });
    var stub_gen_cmd = b.step("generate_stubs", "Generate .zig file with function stubs for deshader library");
    const header_gen_cmd = b.step("generate_headers", "Generate C header file for deshader library");

    const deshader_stubs = b.addModule("deshader", .{
        .root_source_file = .{ .path = stubs_path }, //future file, may not exist
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
            var stat: std.posix.Stat = undefined;
            var result = std.os.linux.stat(full_path, &stat);
            if (result == 0) {
                result = std.os.linux.chmod(full_path, stat.mode | 0o111);
                if (result != 0) { //add execute permission
                    std.log.err("could not chmod {s}: {}", .{ ar_name, std.posix.errno(result) });
                }
            } else {
                std.log.err("could not stat {s}: {}", .{ ar_name, std.posix.errno(result) });
            }
        }

        // Build dependencies
        b.top_level_steps.get("install").?.description = "Download dependencies managed by Zig";

        const dependencies_cmd = b.step("dependencies", "Bootstrap building internal Deshader components and dependencies");
        var dependencies_step: *DependenciesStep = try b.allocator.create(DependenciesStep);
        dependencies_step.* = DependenciesStep.init(b, target.result, !option_wolf_system or targetTarget == .windows or noSystemGLSLang); // If wolfSSL is meant to be linked dynamically, it must be built first
        dependencies_cmd.dependOn(&dependencies_step.step);
        if (option_dependencies) {
            deshader_lib.step.dependOn(&dependencies_step.step);
        }

        //
        // Embed the created dependencies
        //
        var files = std.ArrayList(String).init(b.allocator);
        defer files.deinit();

        // Add all file names in the editor dist folder to `files`
        const editor_directory = "editor";
        if (option_embed_gui) {
            const editor_files = try b.build_root.handle.readFileAlloc(b.allocator, editor_directory ++ "/required.txt", 1024 * 1024);
            var editor_files_lines = std.mem.splitScalar(u8, editor_files, '\n');
            editor_files_lines.reset();
            while (editor_files_lines.next()) |line| {
                const path = try std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ editor_directory, line });
                try files.append(path);
                if (optimize != .Debug) { // In debug mode files are served from physical filesystem so one does not need to recompile Deshader each time
                    try embedCompressedFile(deshader_lib, if (option_dependencies) &dependencies_step.step else null, path);
                }
            }
        }

        // Add the file names as an option to the exe, making it available
        // as a string array at comptime in main.zig
        options.addOption([]const String, "files", files.items);
        options.addOption(String, "editorDir", editor_directory);
        options.addOption(String, "editorDirRelative", try std.fs.path.relative(b.allocator, b.lib_dir, b.pathFromRoot(editor_directory)));
        options.addOption(bool, "embedGUI", option_embed_gui);
        deshader_lib.root_module.addOptions("options", options);

        //
        // Emit .zig file with function stubs
        //
        // Or generate them right here in the build process
        const stubGenSrc = @import("src/tools/generate_stubs.zig");
        var stub_gen: *stubGenSrc.GenerateStubsStep = try b.allocator.create(stubGenSrc.GenerateStubsStep);
        {
            try b.build_root.handle.makePath(std.fs.path.dirname(stubs_path).?);
            std.fs.accessAbsolute(stubs_path, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    _ = try b.build_root.handle.createFile(stubs_path, .{});
                }
            };
            stub_gen.* = stubGenSrc.GenerateStubsStep.init(b, try std.fs.openFileAbsolute(stubs_path, .{ .mode = .write_only }), true);
        }
        stub_gen_cmd.dependOn(&stub_gen.step);
        deshader_lib_cmd.dependOn(&stub_gen.step);

        //
        // Emit H File
        //
        var target_query = target.query;
        target_query.ofmt = null;
        var header_gen = b.addExecutable(.{
            .name = "generate_headers",
            .root_source_file = b.path("src/tools/generate_headers.zig"),
            .target = b.resolveTargetQuery(target_query),
            .optimize = optimize,
        });
        const heade_gen_opts = b.addOptions();
        heade_gen_opts.addOption(String, "emitHDir", b.h_dir);
        header_gen.root_module.addOptions("options", heade_gen_opts);
        header_gen.root_module.addAnonymousImport("header_gen", .{
            .root_source_file = b.path("libs/zig-header-gen/src/header_gen.zig"),
        });
        // no-short stubs for the C header
        {
            const log_name = "deshader_long.zig";
            const long_stub_file = (if (b.cache_root.handle.access(log_name, .{ .mode = .write_only })) //
                try b.cache_root.handle.openFile(log_name, .{ .mode = .write_only })
            else |_|
                try b.cache_root.handle.createFile(log_name, .{}));
            var stub_gen_long = try b.allocator.create(stubGenSrc.GenerateStubsStep);
            stub_gen_long.* = stubGenSrc.GenerateStubsStep.init(b, long_stub_file, false);
            header_gen.step.dependOn(&stub_gen_long.step);
            header_gen.root_module.addAnonymousImport("deshader", .{ .root_source_file = .{ .cwd_relative = "zig-cache/deshader_long.zig" } });
        }

        {
            const header_gen_install = b.addInstallArtifact(header_gen, .{});
            header_gen_cmd.dependOn(&header_gen_install.step);
            const header_run = b.addRunArtifact(header_gen_install.artifact);
            header_run.step.dependOn(&b.addInstallHeaderFile(b.path("src/declarations/macros.h"), "deshader/macros.h").step);
            header_run.step.dependOn(&b.addInstallHeaderFile(b.path("src/declarations/commands.h"), "deshader/commands.h").step);
            // automatically create header when building the library
            deshader_lib_cmd.dependOn(&header_run.step);
        }
    }

    //
    // DLL interception generation
    //
    //if (targetTarget == .windows) {
    //    for (GlLibNames) |lib_name| {
    //        const renamed = b.addSharedLibrary(.{
    //            .name = lib_name,
    //            .root_source_file = b.path("src/tools/forward.zig" ,
    //            .target = target,
    //            .optimize = optimize,
    //        });
    //        renamed.addOptions("options", options);
    //        renamed.addModule("transitive_exports", transitive_exports);
    //        renamed.linkLibrary(deshader_lib);
    //
    //        desahder_lib_cmd.dependOn(&b.addInstallArtifact(renamed, .{}).step);
    //    }
    //}

    //
    // Docs
    //
    if (option_docs) b.installDirectory(.{
        .source_dir = deshader_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    //
    // Runner utility
    //
    const runner_exe = b.addExecutable(.{
        .name = "deshader-run",
        .root_source_file = b.path("src/tools/run.zig"),
        .link_libc = true,
        .optimize = optimize,
        .target = target,
    });
    runner_exe.root_module.addAnonymousImport("common", .{
        .root_source_file = b.path("src/common.zig"),
        .imports = &.{
            .{ .name = "options", .module = options.createModule() },
        },
    });
    const runner_install = b.addInstallArtifact(runner_exe, .{});
    _ = b.step("runner", "Build Deshader Runner - a utility to run any application with Deshader").dependOn(&runner_install.step);

    const runner_options = b.addOptions();
    runner_options.addOption(String, "deshaderLibName", deshader_lib_name);
    runner_options.addOption(u32, "memoryFrames", option_memory_frames);
    runner_options.addOption([]const String, "dependencies", deshader_dependent_dlls.items);
    runner_options.addOption(String, "deshaderRelativeRoot", try std.fs.path.relative(b.allocator, b.exe_dir, b.lib_dir));
    runner_exe.root_module.addOptions("options", runner_options);
    runner_exe.defineCMacro("_GNU_SOURCE", null); // To access dlinfo

    //
    // Example usages demonstration applications
    //
    {
        const examplesStep = b.step("examples", "Example OpenGL apps");
        examplesStep.dependOn(deshader_lib_cmd);

        const example_bootstraper = b.addExecutable(.{
            .name = "deshader-examples-all",
            .root_source_file = b.path("examples/examples.zig"),
            .target = target,
            .optimize = optimize,
        });
        const sub_examples = struct {
            const glfw = "glfw";
            const editor = "editor";
            const glfw_cpp = "glfw_cpp";
            const debug_commands = "debug_commands";
            const editor_linked_cpp = "editor_linked_cpp";
        };
        const example_options = b.addOptions();
        example_options.addOption([]const String, "exampleNames", &.{ sub_examples.glfw, sub_examples.editor, sub_examples.debug_commands, sub_examples.glfw_cpp });
        example_bootstraper.root_module.addOptions("options", example_options);
        example_bootstraper.step.dependOn(header_gen_cmd);

        // Various example applications
        {
            const exampleModules = .{
                .{ .name = "gl", .module = gl_bindings },
                .{ .name = "deshader", .module = deshader_stubs },
            };

            // Use mach-glfw
            const mach_glfw_dep = b.dependency("mach_glfw", .{
                .target = target,
                .optimize = optimize,
            });

            // GLFW
            const example_glfw = try SubExampleStep.create(example_bootstraper, sub_examples.glfw, "examples/" ++ sub_examples.glfw ++ ".zig", exampleModules ++ .{.{ .name = "mach-glfw", .module = mach_glfw_dep.module("mach-glfw") }});
            try addVcpkgInstalledPaths(example_glfw.compile);

            // Editor
            const example_editor = try SubExampleStep.create(example_bootstraper, sub_examples.editor, "examples/" ++ sub_examples.editor ++ ".zig", exampleModules);
            example_editor.compile.linkLibrary(deshader_lib);

            // GLFW in C++
            const glfw_dep = mach_glfw_dep.builder.dependency("glfw", .{
                .target = target,
                .optimize = optimize,
            });
            const glfw_lib = glfw_dep.artifact("glfw");
            const example_glfw_cpp = try SubExampleStep.create(example_bootstraper, sub_examples.glfw_cpp, "examples/" ++ sub_examples.glfw ++ ".cpp", .{});
            example_glfw_cpp.compile.addIncludePath(.{ .path = b.h_dir });
            example_glfw_cpp.compile.linkLibCpp();
            example_glfw_cpp.compile.linkLibrary(glfw_lib);

            //example_glfw_cpp.linkLibrary(deshader_lib);
            try linkGlew(example_glfw_cpp.install, targetTarget);

            if (targetTarget == .windows) {
                example_glfw_cpp.compile.addWin32ResourceFile(.{ .file = b.path(try std.fs.path.join(b.allocator, &.{
                    b.build_root.path.?,
                    "examples",
                    "shaders.rc",
                })) });
            } else {
                // Embed shaders into the executable
                inline for (.{ "fragment.frag", "vertex.vert" }) |shader| {
                    const output = try std.fs.path.join(b.allocator, &.{ b.cache_root.path.?, "shaders", shader ++ ".o" });
                    b.cache_root.handle.access("shaders", .{}) catch try std.fs.makeDirAbsolute(std.fs.path.dirname(output).?);
                    var dir = try b.build_root.handle.openDir("examples", .{});
                    defer dir.close();
                    const result = try exec(.{
                        .allocator = b.allocator,
                        .argv = &.{ "ld", "--relocatable", "--format", "binary", "--output", output, shader },
                        .cwd_dir = dir,
                    });
                    if (result.term.Exited == 0) {
                        example_glfw_cpp.compile.addObjectFile(.{ .path = output });
                    } else {
                        std.log.err("Failed to compile shader {s}: {s}", .{ shader, result.stderr });
                    }
                }
            }

            // Editor in C++
            const example_editor_linked_cpp = try SubExampleStep.create(example_bootstraper, sub_examples.editor_linked_cpp, "examples/editor_linked.cpp", .{});
            example_editor_linked_cpp.compile.addIncludePath(.{ .path = b.h_dir });
            example_editor_linked_cpp.compile.linkLibrary(deshader_lib);

            const example_debug_commands = try SubExampleStep.create(example_bootstraper, sub_examples.debug_commands, "examples/debug_commands.cpp", .{});
            example_debug_commands.compile.addIncludePath(.{ .path = b.h_dir });
            example_debug_commands.compile.linkLibCpp();
            example_debug_commands.compile.linkLibrary(glfw_lib);
            try linkGlew(example_debug_commands.install, targetTarget);
        }
        examplesStep.dependOn(stub_gen_cmd);
        const exampleInstall = b.addInstallArtifact(example_bootstraper, .{});
        examplesStep.dependOn(&exampleInstall.step);

        // Run examples by `deshader-run`
        const exampleRun = b.addRunArtifact(runner_install.artifact);
        const exampleRunCmd = b.step("examples-run", "Run example with injected Deshader debugging");
        exampleRun.setEnvironmentVariable("DESHADER_LIB", try std.fs.path.join(b.allocator, &.{ b.lib_dir, deshader_lib_name }));
        exampleRun.addArg(try std.fs.path.join(b.allocator, &.{ b.exe_dir, "examples" }));
        exampleRunCmd.dependOn(&exampleInstall.step);
        exampleRunCmd.dependOn(&exampleRun.step);
        exampleRunCmd.dependOn(&runner_install.step);
        exampleRunCmd.dependOn(stub_gen_cmd);
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
        .windows => &[_]String{ "del", "/s", "/q" },
        .linux, .macos => &[_]String{ "rm", "-rf" },
        else => unreachable,
    } ++ &[_]String{ "zig-out", "zig-cache" });
    clean_run.step.dependOn(b.getUninstallStep());
    clean_step.dependOn(&clean_run.step);
}

fn embedCompressedFile(compile: *std.Build.Step.Compile, dependOn: ?*std.Build.Step, path: String) !void {
    const compress = try CompressStep.init(compile.step.owner, compile.step.owner.path(path));
    if (dependOn) |d| {
        compress.step.dependOn(d);
    }
    compile.root_module.addAnonymousImport(path, .{
        .root_source_file = .{ .generated = &compress.generatedFile },
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
            .name = "deshader-" ++ name,
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
            subExe.addLibraryPath(.{ .path = lib_dir });
        }
        for (n_paths.include_dirs.items) |include_dir| {
            subExe.addSystemIncludePath(.{ .path = include_dir });
        }
        inline for (modules) |mod| {
            subExe.root_module.addImport(mod.name, mod.module);
        }
        const target = compile.rootModuleTarget().os.tag;

        if (target == .windows) {
            subExe.linkSystemLibrary("opengl32");
        }
        const sep = std.fs.path.sep_str;
        const install = step.owner.addInstallArtifact(
            subExe,
            .{ .dest_sub_path = try std.mem.concat(step.owner.allocator, u8, &.{ "deshader-examples", sep, name, if (target == .windows) ".exe" else "" }) },
        );
        step.dependOn(&install.step);
        return @This(){
            .compile = subExe,
            .install = install,
        };
    }
};

fn fileWithPrefixExists(allocator: std.mem.Allocator, dirname: String, basename: String) !?String {
    var dir = try openIterableDir(dirname);
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |current| {
        if (current.kind == .file) {
            if (std.mem.startsWith(u8, current.name, basename)) {
                return try allocator.dupe(u8, current.name);
            }
        }
    }
    return null;
}

fn vcpkgTriplet(t: std.Target.Os.Tag) String {
    return if (builtin.os.tag == .windows) "x64-windows" else switch (t) {
        .linux => "x64-linux",
        .macos => "x64-osx",
        .windows => "x64-windows-cross",
        else => @panic("Unsupported target"),
    };
}

/// assuming vcpkg is called as by Visual Studio or `vcpkg install --triplet x64-windows-cross --x-install-root=build/vcpkg_installed` or inside DependenciesStep
fn addVcpkgInstalledPaths(c: *std.Build.Step.Compile) !void {
    const debug = if (c.root_module.optimize == .Debug) "debug" else "";
    const b = c.step.owner;
    c.addIncludePath(b.path(b.pathJoin(&.{ "build", "vcpkg_installed", vcpkgTriplet(c.rootModuleTarget().os.tag), "include" })));
    c.addLibraryPath(b.path(b.pathJoin(&.{ "build", "vcpkg_installed", vcpkgTriplet(c.rootModuleTarget().os.tag), debug, "bin" })));
    c.addLibraryPath(b.path(b.pathJoin(&.{ "build", "vcpkg_installed", vcpkgTriplet(c.rootModuleTarget().os.tag), debug, "lib" })));
}

fn installVcpkgLibrary(i: *std.Build.Step.InstallArtifact, name: String) !void {
    const b = i.step.owner;
    const os = i.artifact.rootModuleTarget().os.tag;
    var name_parts = std.mem.splitScalar(u8, name, '.');
    const name_with_ext = try std.mem.concat(b.allocator, u8, &.{ name_parts.first(), os.dynamicLibSuffix() });
    const lib_path = try b.build_root.join(b.allocator, &.{
        "build",
        "vcpkg_installed",
        vcpkgTriplet(os),
        "bin",
        name_with_ext,
    });
    if (std.fs.accessAbsolute(lib_path, .{})) {
        const dest_path = if (std.fs.path.dirname(i.dest_sub_path)) |sub_dir|
            try std.fs.path.join(b.allocator, &.{ sub_dir, name_with_ext })
        else
            name_with_ext;

        // Copy the library to the install directory
        i.step.dependOn(&(if (i.artifact.kind == .lib)
            b.addInstallLibFile(b.path(lib_path), dest_path)
        else
            b.addInstallBinFile(b.path(lib_path), dest_path)).step);

        std.log.info("Installed dynamic {s} from VCPKG", .{dest_path});
    } else |err| {
        std.log.warn("Could not find dynamic {s} from VCPKG but maybe system library will work too. {}", .{ name, err });
    }
}

fn linkGlew(i: *std.Build.Step.InstallArtifact, target: std.Target.Os.Tag) !void {
    if (target == .windows) {
        try addVcpkgInstalledPaths(i.artifact);
        const glew = if (builtin.os.tag == .windows) "glew32" else "libglew32";
        i.artifact.linkSystemLibrary(glew); // VCPKG on x64-wndows-cross generates bin/glew32.dll but lib/libglew32.dll.a
        try installVcpkgLibrary(i, "glew32");
        i.artifact.linkSystemLibrary("opengl32");
    } else {
        i.artifact.linkSystemLibrary("glew");
    }
}

fn winepath(alloc: std.mem.Allocator, path: String, toWindows: bool) !String {
    const result = try exec(.{ .allocator = alloc, .argv = &.{ "winepath", if (toWindows) "-w" else "-u", path } });
    if (result.term.Exited == 0) {
        return std.mem.trim(u8, result.stdout, " \n\t");
    } else if (result.term == .Exited) {
        std.log.err("Failed to run winepath with code {d}: {s}", .{ result.term.Exited, result.stderr });
        return error.Winepath;
    } else {
        std.log.err("Failed to run winepath: {}", .{result.term});
        return error.Winepath;
    }
}

fn linkWolfSSL(compile: *std.Build.Step.Compile, install: *std.Build.Step.InstallArtifact, from_vcpkg: bool) !?String {
    const os = compile.rootModuleTarget().os.tag;
    const wolfssl_lib_name = if (os == .windows and builtin.os.tag != .windows) "libwolfssl" else "wolfssl";
    compile.linkSystemLibrary(wolfssl_lib_name);
    if (from_vcpkg) {
        try installVcpkgLibrary(install, wolfssl_lib_name); // This really depends on host build system
    }
    if (os == .windows) {
        compile.defineCMacro("SINGLE_THREADED", null); // To workaround missing pthread.h
    }
    return wolfssl_lib_name;
}
