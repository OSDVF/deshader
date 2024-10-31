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

const log = std.log.scoped(.DeshaderBuild);

// Shims for compatibility between Zig versions
const exec = std.process.Child.run;
fn openIterableDir(path: String) std.fs.File.OpenError!if (@hasDecl(std.fs, "openIterableDirAbsolute")) std.fs.IterableDir else std.fs.Dir {
    return if (@hasDecl(std.fs, "openIterableDirAbsolute")) std.fs.openIterableDirAbsolute(path, .{}) else std.fs.openDirAbsolute(path, .{ .iterate = true });
}

pub fn build(b: *std.Build) !void {
    var target = b.standardTargetOptions(.{ //.default_target = .{ .abi = if (builtin.os.tag == .windows) .msvc else null }
    });
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
    const option_editor = b.option(bool, "editor", "Build editor (VSCode and extension) along Deshader (default true)") orelse true;
    const option_ignore_missing = b.option(bool, "ignoreMissing", "Ignore missing VK and GL libraries. GLX, EGL and VK will be required by default") orelse false;
    const option_include = b.option(String, "include", "Path to directory with additional headers to include");
    const option_lib_dir = b.option(String, "lib", "Path to directory with additional libraries to link");
    const option_linkage = b.option(Linkage, "linkage", "Select linkage type for deshader library. Cannot be combined with -Dofmt.") orelse Linkage.Dynamic;
    const option_log_intercept = b.option(bool, "logIntercept", "Log intercepted GL and VK procedure list to stdout") orelse false;
    const option_memory_frames = b.option(u32, "memoryFrames", "Number of frames in memory leak backtrace") orelse 7;
    const options_traces = b.option(bool, "traces", "Enable traces for debugging (even in release mode)") // important! keep tracing support synced for Deshader Library and Runner, because there are casts from error aware functions to anyopaque
    orelse if ((targetTarget != .windows or builtin.os.tag == .windows) and (optimize == .Debug or optimize == .ReleaseSafe)) true else false;
    const options_unwind = b.option(bool, "unwind", "Enable unwind tables for debugging (even in release mode)") orelse options_traces;
    const options_sanitize = b.option(bool, "sanitize", "Enable sanitizers for debugging (even in release mode)") orelse options_traces;
    const option_stack_check = b.option(bool, "stackCheck", "Enable stack check for debugging (even in release mode)") orelse options_traces;
    const option_stack_protector = b.option(bool, "stackProtector", "Enable stack protector for debugging (even in release mode)") orelse options_traces;
    const option_valgrind = b.option(bool, "valgrind", "Enable valgrind support for debugging (even in release mode)") orelse options_traces;

    const deshader_lib: *std.Build.Step.Compile = if (option_linkage == .Static) b.addStaticLibrary(deshaderCompileOptions) else b.addSharedLibrary(deshaderCompileOptions);
    deshader_lib.defineCMacro("_GNU_SOURCE", null); // To access dl_iterate_phdr
    deshader_lib.root_module.error_tracing = options_traces;
    deshader_lib.root_module.unwind_tables = options_unwind;
    deshader_lib.root_module.sanitize_c = options_sanitize;
    deshader_lib.root_module.stack_check = option_stack_check;
    deshader_lib.root_module.stack_protector = option_stack_protector;
    deshader_lib.root_module.valgrind = option_valgrind;

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

    const extension = if (targetTarget == .windows) "ico" else "png";
    const icon = b.addInstallFile(b.path("src/deshader." ++ extension), "lib/deshader." ++ extension);
    deshader_lib_install.step.dependOn(&icon.step);
    if (targetTarget == .windows) {
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

    // Native file dialogs library
    const system_nfd = try systemHasLib(deshader_lib, host_libs_location, "nfd");
    nfd(deshader_lib, system_nfd);

    // GLSLang
    var system_glslang = true;
    inline for (.{ "glslang", "glslang-default-resource-limits", "MachineIndependent", "GenericCodeGen" }) |l| {
        const lib_name = if (targetTarget == .windows) if (b.release_mode == .off) l ++ "d" else l else l;
        system_glslang = system_glslang and try systemHasLib(deshader_lib, host_libs_location, lib_name);

        deshader_lib.linkSystemLibrary2(lib_name, .{ .needed = true });
        if (!system_glslang) {
            _ = try installVcpkgLibrary(deshader_lib_install, lib_name);
        }
    }

    // Websocket
    const websocket = b.addModule("websocket", .{
        .root_source_file = b.path("libs/websocket/src/websocket.zig"),
    });
    deshader_lib.root_module.addImport("websocket", websocket);

    // OpenGL
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
            run_symbol_enum.addArg(std.fmt.allocPrint(b.allocator, "{s}{s}", .{ host_libs_location, real_name }) catch unreachable);
        } else {
            if (option_ignore_missing) {
                log.warn("Missing library {s}", .{libName});
            } else {
                return deshader_lib.step.fail("Missing library {s}", .{libName});
            }
        }
    }
    if (try fileWithPrefixExists(b.allocator, host_libs_location, VulkanLibName)) |real_name| {
        run_symbol_enum.addArg(std.fmt.allocPrint(b.allocator, "{s}{s}", .{ host_libs_location, real_name }) catch unreachable);
    } else {
        if (option_ignore_missing) {
            log.warn("Missing library {s}", .{VulkanLibName});
        } else {
            return deshader_lib.step.fail("Missing library {s}", .{VulkanLibName});
        }
    }

    run_symbol_enum.addArg(std.fmt.allocPrint(b.allocator, "{s}{s}", .{ host_libs_location, VulkanLibName }) catch unreachable);
    run_symbol_enum.expectExitCode(0);
    if (!b.enable_wine) { // wine can add weird fixme messages, or "fsync: up and running" to the stderr
        run_symbol_enum.expectStdErrEqual("");
    }
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
    const transitive_exports = b.createModule(.{ .root_source_file = .{ .generated = .{ .file = &addGlProcsStep.generated_file } } });
    deshader_lib.root_module.addImport("transitive_exports", transitive_exports);

    // Positron
    const positron = PositronSdk.getPackage(b, "positron", target);
    const serve = b.modules.get("serve").?;
    deshader_lib.root_module.addImport("positron", positron);
    deshader_lib.root_module.addImport("serve", serve);
    if (option_editor) {
        PositronSdk.linkPositron(deshader_lib, null, option_linkage == .Static);
        if (targetTarget == .windows) {
            try deshader_dependent_dlls.append("WebView2Loader.dll");
        }
    }

    // WolfSSL - a serve's dependency
    const system_wolf = try systemHasLib(deshader_lib, host_libs_location, "wolfssl");
    if (try linkWolfSSL(deshader_lib, deshader_lib_install, !system_wolf)) |lib_name| {
        try deshader_dependent_dlls.append(lib_name);
    }

    serve.linkSystemLibrary("wolfssl", .{ .needed = true });

    //
    // Steps for building generated and embedded files
    //
    const stubs_path = b.getInstallPath(.header, "deshader.zig");
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
            var stat: std.posix.Stat = undefined;
            var result = std.os.linux.stat(full_path, &stat);
            if (result == 0) {
                result = std.os.linux.chmod(full_path, stat.mode | 0o111);
                if (result != 0) { //add execute permission
                    log.err("could not chmod {s}: {}", .{ ar_name, std.posix.errno(result) });
                }
            } else {
                log.err("could not stat {s}: {}", .{ ar_name, std.posix.errno(result) });
            }
        }

        // Build dependencies
        b.top_level_steps.get("install").?.description = "Download dependencies managed by Zig";

        const editor_cmd = b.step("editor", "Bootstrap building internal Deshader components and dependencies");
        var editor_step = try b.allocator.create(DependenciesStep);
        editor_step.* = DependenciesStep.init(b, "editor", target.result);
        try editor_step.editor();

        editor_cmd.dependOn(&editor_step.step);
        if (option_editor) {
            if (optimize == .Debug) {
                // permit parallel building of editor and deshader, because editor is then not embedded
                deshader_lib_cmd.dependOn(&editor_step.step);
            } else {
                deshader_lib.step.dependOn(&editor_step.step);
            }
        }

        //
        // Embed the created dependencies
        //
        var files = std.ArrayList(String).init(b.allocator);
        defer files.deinit();

        // Add all file names in the editor dist folder to `files`
        const editor_directory = "editor";
        if (option_editor) {
            const editor_files = try b.build_root.handle.readFileAlloc(b.allocator, editor_directory ++ "/required.txt", 1024 * 1024);
            var editor_files_lines = std.mem.splitScalar(u8, editor_files, '\n');
            editor_files_lines.reset();
            while (editor_files_lines.next()) |line| {
                const path = try std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ editor_directory, std.mem.trim(u8, line, "\n\r\t ") });
                try files.append(path);
                if (optimize != .Debug) { // In debug mode files are served from physical filesystem so one does not need to recompile Deshader each time
                    try embedCompressedFile(deshader_lib, if (option_editor) &editor_step.step else null, path);
                }
            }
        }

        // Add the file names as an option to the exe, making it available
        // as a string array at comptime in main.zig
        options.addOption([]const String, "files", files.items);
        options.addOption(String, "editorDir", editor_directory);
        options.addOption(String, "editorDirRelative", try std.fs.path.relative(b.allocator, b.lib_dir, b.pathFromRoot(editor_directory)));
        options.addOption(bool, "editor", option_editor);
        deshader_lib.root_module.addOptions("options", options);

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
        deshader_lib_cmd.dependOn(&stub_gen.step);

        //
        // Emit H File
        //
        var target_query = target.query;
        target_query.ofmt = null;
        var header_gen = b.addExecutable(.{
            .name = "generate_headers",
            .root_source_file = b.path("bootstrap/generate_headers.zig"),
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
            const long_name = b.getInstallPath(.header, "deshader_long.zig");
            var stub_gen_long = try b.allocator.create(stubGenSrc.GenerateStubsStep);
            stub_gen_long.* = stubGenSrc.GenerateStubsStep.init(b, long_name, false);
            header_gen.step.dependOn(&stub_gen_long.step);
            header_gen.root_module.addAnonymousImport("deshader", .{ .root_source_file = .{ .cwd_relative = long_name } });
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
    // Runner utility
    //
    const runner_exe = b.addExecutable(.{
        .name = "deshader-run",
        .root_source_file = b.path("src/tools/run.zig"),
        .link_libc = true,
        .optimize = optimize,
        .target = target,
    });
    runner_exe.root_module.error_tracing = options_traces;
    runner_exe.root_module.unwind_tables = options_unwind;
    runner_exe.root_module.addAnonymousImport("common", .{
        .root_source_file = b.path("src/common.zig"),
        .imports = &.{
            .{ .name = "options", .module = options.createModule() },
        },
    });
    if (targetTarget == .linux) {
        runner_exe.linkSystemLibrary("gtk+-3.0");
    } else {
        runner_exe.linkSystemLibrary("ole32");
        nfd(runner_exe, system_nfd);
    }
    const runner_install = b.addInstallArtifact(runner_exe, .{});
    _ = b.step("runner", "Build Deshader Runner - a utility to run any application with Deshader").dependOn(&runner_install.step);

    const runner_options = b.addOptions();
    runner_options.addOption(String, "deshaderLibName", deshader_lib_name);
    runner_options.addOption(u32, "memoryFrames", option_memory_frames);
    runner_options.addOption([]const String, "dependencies", deshader_dependent_dlls.items);
    runner_options.addOption(String, "deshaderRelativeRoot", try std.fs.path.relative(b.allocator, b.exe_dir, b.lib_dir));
    runner_exe.root_module.addOptions("options", runner_options);
    runner_exe.defineCMacro("_GNU_SOURCE", null); // To access dlinfo
    if (targetTarget == .windows) {
        runner_exe.addWin32ResourceFile(.{ .file = b.path(b.pathJoin(&.{ "src", "resources.rc" })) });
    }

    const vcpkg_cmd = b.step("vcpkg", "Download and build dependencies managed by vcpkg");
    var vcpkg_step = try b.allocator.create(DependenciesStep);
    vcpkg_step.* = DependenciesStep.init(b, "vcpkg", target.result);
    try vcpkg_step.vcpkg();
    vcpkg_cmd.dependOn(&vcpkg_step.step);

    const system_libs_available = system_glslang and system_wolf and system_nfd;
    if (!system_libs_available) {
        try addVcpkgInstalledPaths(b, deshader_lib);
        try addVcpkgInstalledPaths(b, runner_exe);
        try addVcpkgInstalledPaths(b, serve); // add WolfSSL from VCPKG to serve
        deshader_lib.step.dependOn(&vcpkg_step.step);
        runner_exe.step.dependOn(&vcpkg_step.step);
    } else {
        log.info("All required libraries are available on system, skipping installing vcpkg dependencies", .{});
    }

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
            const sdf = "sdf";
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

            // Use zig-glfw
            const zig_glfw_dep = b.dependency("zig_glfw", .{
                .target = target,
                .optimize = optimize,
            });

            // GLFW
            const example_glfw = try SubExampleStep.create(example_bootstraper, sub_examples.glfw, "examples/" ++ sub_examples.glfw ++ ".zig", exampleModules ++ .{.{ .name = "zig_glfw", .module = zig_glfw_dep.module("zig-glfw") }});
            try addVcpkgInstalledPaths(b, example_glfw.compile);

            const example_sdf = try SubExampleStep.create(example_bootstraper, sub_examples.sdf, "examples/" ++ sub_examples.sdf ++ ".zig", exampleModules ++ .{.{ .name = "zig_glfw", .module = zig_glfw_dep.module("zig-glfw") }});
            try addVcpkgInstalledPaths(b, example_sdf.compile);

            // Editor
            const example_editor = try SubExampleStep.create(example_bootstraper, sub_examples.editor, "examples/" ++ sub_examples.editor ++ ".zig", exampleModules);
            example_editor.compile.linkLibrary(deshader_lib);

            // GLFW in C++
            const glfw_dep = zig_glfw_dep.builder.dependency("glfw", .{
                .target = target,
                .optimize = optimize,
            });
            const glfw_lib = glfw_dep.artifact("glfw");
            const example_glfw_cpp = try SubExampleStep.create(example_bootstraper, sub_examples.glfw_cpp, "examples/" ++ sub_examples.glfw ++ ".cpp", .{});
            example_glfw_cpp.compile.addIncludePath(.{ .cwd_relative = b.h_dir });
            example_glfw_cpp.compile.linkLibCpp();
            example_glfw_cpp.compile.linkLibrary(glfw_lib);

            //example_glfw_cpp.linkLibrary(deshader_lib);
            try linkGlew(example_glfw_cpp.install, targetTarget);

            // Embed shaders into the executable
            if (targetTarget == .windows) {
                example_glfw_cpp.compile.addWin32ResourceFile(.{ .file = b.path(b.pathJoin(&.{ "examples", "shaders.rc" })) });
            } else {
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
                        example_glfw_cpp.compile.addObjectFile(.{ .cwd_relative = output });
                    } else {
                        log.err("Failed to compile shader {s}: {s}", .{ shader, result.stderr });
                    }
                }
            }

            // Editor in C++
            const example_editor_linked_cpp = try SubExampleStep.create(example_bootstraper, sub_examples.editor_linked_cpp, "examples/editor_linked.cpp", .{});
            example_editor_linked_cpp.compile.addIncludePath(.{ .cwd_relative = b.h_dir });
            example_editor_linked_cpp.compile.linkLibrary(deshader_lib);

            const example_debug_commands = try SubExampleStep.create(example_bootstraper, sub_examples.debug_commands, "examples/debug_commands.cpp", .{});
            example_debug_commands.compile.addIncludePath(.{ .cwd_relative = b.h_dir });
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
    var dir = openIterableDir(dirname) catch return null;
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

fn vcpkgTriplet(b: *const std.Build, t: std.Target.Os.Tag) String {
    return switch (t) {
        .linux => "x64-linux",
        .macos => "x64-osx",
        .windows => if (b.release_mode == .off) "x64-windows-cross-dbg" else "x64-windows-cross-rel",
        else => @panic("Unsupported target"),
    };
}

/// assuming vcpkg is called as by Visual Studio or `vcpkg install --triplet x64-windows-cross --x-install-root=build/vcpkg_installed` or inside DependenciesStep
fn addVcpkgInstalledPaths(b: *std.Build, c: anytype) !void {
    const module = if (@hasField(@TypeOf(c.*), "root_module")) c.root_module else c;
    const debug = if (b.release_mode == .off) "debug" else "";
    const target = if (module.resolved_target) |t| t.result else builtin.target;
    c.addIncludePath(b.path(b.pathJoin(&.{ "build", "vcpkg_installed", vcpkgTriplet(b, target.os.tag), debug, "include" })));
    c.addLibraryPath(b.path(b.pathJoin(&.{ "build", "vcpkg_installed", vcpkgTriplet(b, target.os.tag), debug, "bin" })));
    c.addLibraryPath(b.path(b.pathJoin(&.{ "build", "vcpkg_installed", vcpkgTriplet(b, target.os.tag), debug, "lib" })));
}

fn installVcpkgLibrary(i: *std.Build.Step.InstallArtifact, name: String) !String {
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
            vcpkgTriplet(i.step.owner, os),
            if (b.release_mode == .off) "debug" else "",
            "bin",
            name_with_ext,
        });
        if (b.build_root.handle.access(dll_path, .{})) {
            const dest_path = if (std.fs.path.dirname(i.dest_sub_path)) |sub_dir|
                try std.fs.path.join(b.allocator, &.{ sub_dir, name_with_ext })
            else
                name_with_ext;

            // Copy the library to the install directory
            i.step.dependOn(&(if (i.artifact.kind == .lib)
                b.addInstallLibFile(b.path(dll_path), dest_path)
            else
                b.addInstallBinFile(b.path(dll_path), dest_path)).step);

            log.info("Installed dynamic {s} from VCPKG", .{dest_path});
            return name_with_ext;
        } else |_| {}
    } else {
        log.warn("Could not find dynamic {s} from VCPKG but maybe it is static or in system.", .{name});
    }
    return name;
}

fn linkGlew(i: *std.Build.Step.InstallArtifact, target: std.Target.Os.Tag) !void {
    if (target == .windows) {
        try addVcpkgInstalledPaths(i.step.owner, i.artifact);
        const glew = if (builtin.os.tag == .windows) if (i.artifact.root_module.optimize orelse .Debug == .Debug) "glew32d" else "glew32" else "libglew32";
        i.artifact.linkSystemLibrary2(glew, .{ .needed = true }); // VCPKG on x64-wndows-cross generates bin/glew32.dll but lib/libglew32.dll.a
        _ = try installVcpkgLibrary(i, "glew32");
        i.artifact.linkSystemLibrary2("opengl32", .{ .needed = true });
    } else {
        i.artifact.linkSystemLibrary2("glew", .{ .needed = true });
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

fn linkWolfSSL(compile: *std.Build.Step.Compile, install: *std.Build.Step.InstallArtifact, from_vcpkg: bool) !?String {
    const os = compile.rootModuleTarget().os.tag;
    const wolfssl_lib_name = "wolfssl";
    compile.linkSystemLibrary2(wolfssl_lib_name, .{ .needed = true });
    if (from_vcpkg) {
        return try installVcpkgLibrary(install, wolfssl_lib_name);
    }
    if (os == .windows) {
        compile.defineCMacro("SINGLE_THREADED", null); // To workaround missing pthread.h
    }
    const with_ext = try std.mem.concat(compile.step.owner.allocator, u8, &.{ wolfssl_lib_name, compile.rootModuleTarget().dynamicLibSuffix() });
    return with_ext;
}

/// Search for all lib directories
fn systemHasLib(c: *std.Build.Step.Compile, native_libs_location: String, lib: String) !bool {
    const b: *std.Build = c.step.owner;
    const target: std.Target = c.rootModuleTarget();

    const libname = try std.mem.concat(b.allocator, u8, &.{ target.libPrefix(), lib });
    defer b.allocator.free(libname);
    if (builtin.os.tag == target.os.tag and builtin.cpu.arch == target.cpu.arch) { // native
        for (c.root_module.lib_paths.items) |lib_dir| {
            const path = lib_dir.getPath(b);
            if (try fileWithPrefixExists(b.allocator, path, libname)) |full_name| {
                log.info("Found library {s} in {s}", .{ full_name, path });
                b.allocator.free(full_name);
                return true;
            }
        }
    }

    if (try fileWithPrefixExists(b.allocator, native_libs_location, libname)) |full_name| {
        log.info("Found system library {s} in {s}", .{ full_name, native_libs_location });
        b.allocator.free(full_name);
        return true;
    } else return false;
}

fn nfd(c: *std.Build.Step.Compile, system_nfd: bool) void {
    if (c.rootModuleTarget().os.tag == .linux) {
        // sometimes located here on Linux
        c.addLibraryPath(.{ .cwd_relative = "/usr/lib/nfd/" });
        c.addIncludePath(.{ .cwd_relative = "/usr/include/nfd/" });
        c.addLibraryPath(.{ .cwd_relative = "/usr/local/lib/nfd/" });
        c.addIncludePath(.{ .cwd_relative = "/usr/local/include/nfd/" });
    }
    c.linkSystemLibrary2(if (c.root_module.optimize orelse .Debug == .Debug and !system_nfd) "nfd_d" else "nfd", .{ .needed = true }); //Native file dialog library from VCPKG
}
