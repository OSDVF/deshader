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
    const optimize = b.standardOptimizeOption(.{});
    const targetTarget = target.os_tag orelse builtin.os.tag;
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
        target.ofmt = .c;
    }

    // Deshader library
    const deshaderCompileOptions = .{
        .name = "deshader",
        .root_source_file = .{ .path = "src/main.zig" },
        .main_mod_path = .{ .path = "src" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    };

    // Compile options
    const optionLinkage = b.option(Linkage, "linkage", "Select linkage type for deshader library. Cannot be combined with -Dofmt.") orelse Linkage.Dynamic;
    const optionIgnoreMissingLibs = b.option(bool, "ignoreMissingLibs", "Ignore missing VK and GL libraries. GLX, EGL and VK will be required by default") orelse false;
    const optionWolfSSL = b.option(bool, "wolfSSL", "Link dynamically WolfSSL available on this system or vcpkg_installed (produces smaller binaries)") orelse false;
    const option_embed_editor = b.option(bool, "embedEditor", "Embed VSCode editor into the library (default yes)") orelse true;
    const optionAdditionalLibraries = b.option([]const String, "customLibrary", "Names of additional libraroes to intercept");
    const optionInterceptionLog = b.option(bool, "logIntercept", "Log intercepted GL and VK procedure list to stdout") orelse false;
    const optionMemoryTraceFrames = b.option(u32, "memoryFrames", "Number of frames in memory leak backtrace") orelse 7;
    const optionIncludeDir = b.option(String, "include", "Path to directory with additional headers to include");
    const optionDependencies = b.option(bool, "deps", "Also build dependencies before Deshader") orelse false;
    const optionLibDir = b.option(String, "lib", "Path to directory with additional libraries to link");

    const deshader_lib: *std.build.Step.Compile = if (optionLinkage == .Static) b.addStaticLibrary(deshaderCompileOptions) else b.addSharedLibrary(deshaderCompileOptions);
    deshader_lib.disable_stack_probing = true;
    deshader_lib.stack_protector = false;
    const deshader_lib_name = try std.mem.concat(b.allocator, u8, &.{ if (targetTarget == .windows) "" else "lib", deshader_lib.name, targetTarget.dynamicLibSuffix() });
    const deshader_lib_cmd = b.step("deshader", "Install deshader library");
    switch (optionOfmt) {
        .BC => {
            deshader_lib.generated_llvm_ir = try b.allocator.create(std.build.GeneratedFile);
            deshader_lib.generated_llvm_ir.?.* = .{ .step = &deshader_lib.step, .path = try b.cache_root.join(b.allocator, &.{ "llvm", "deshader.ll" }) };
            deshader_lib_cmd.dependOn(&b.addInstallFileWithDir(deshader_lib.getEmittedLlvmBc(), .lib, "deshader.bc").step);
            deshader_lib.disable_stack_probing = true;
        },
        .IR => {
            deshader_lib.generated_llvm_bc = try b.allocator.create(std.build.GeneratedFile);
            deshader_lib.generated_llvm_bc.?.* = .{ .step = &deshader_lib.step, .path = try b.cache_root.join(b.allocator, &.{ "llvm", "deshader.bc" }) };
            deshader_lib_cmd.dependOn(&b.addInstallFileWithDir(deshader_lib.getEmittedLlvmIr(), .lib, "deshader.ll").step);
            deshader_lib.disable_stack_probing = true;
        },
        else => {},
    }
    const deshader_lib_install = b.addInstallArtifact(deshader_lib, .{});
    deshader_lib_cmd.dependOn(&deshader_lib_install.step);
    deshader_lib.addIncludePath(.{ .path = try b.build_root.join(b.allocator, &.{ "src", "declarations" }) });
    if (optionIncludeDir) |includeDir| {
        deshader_lib.addIncludePath(.{ .path = includeDir });
    }
    if (optionLibDir) |libDir| {
        deshader_lib.addLibraryPath(.{ .path = libDir });
    }

    // CTRegex
    const ctregex_mod = b.addModule("ctregex", .{
        .source_file = .{ .path = "libs/ctregex/ctregex.zig" },
    });
    deshader_lib.addModule("ctregex", ctregex_mod);
    // Args parser
    const args_mod = b.addModule("args", .{
        .source_file = .{ .path = "libs/positron/vendor/args/args.zig" },
    });
    deshader_lib.addModule("args", args_mod);

    var deshader_dependent_dlls = std.ArrayList(String).init(b.allocator);
    // WolfSSL
    var wolfssl: *std.build.Step.Compile = undefined;
    if (optionWolfSSL) {
        const wolfssl_lib_name = if (targetTarget == .windows and builtin.os.tag != .windows) "libwolfssl" else "wolfssl";
        deshader_lib.linkSystemLibrary(wolfssl_lib_name);
        try addVcpkgInstalledPaths(deshader_lib);
        try installVcpkgLibrary(deshader_lib_install, wolfssl_lib_name); // This really depends on host build system
        const with_ext = try std.mem.concat(b.allocator, u8, &.{ wolfssl_lib_name, targetTarget.dynamicLibSuffix() });
        try deshader_dependent_dlls.append(with_ext);
        if (targetTarget == .windows) {
            deshader_lib.defineCMacro("SINGLE_THREADED", null); // To workaround missing pthread.h
        }
    } else {
        wolfssl = ZigServe.createWolfSSL(b, target, optimize);
        deshader_lib.linkLibrary(wolfssl);
        deshader_lib.addIncludePath(.{ .path = ZigServe.sdkPath("/vendor/wolfssl/") });
    }

    // Websocket
    const websocket = b.addModule("websocket", .{
        .source_file = .{ .path = "libs/websocket/src/websocket.zig" },
        .dependencies = &.{
            .{
                .name = "zigtrait",
                .module = b.addModule("zigtrait", .{
                    .source_file = .{
                        .path = "libs/websocket/vendor/zigtrait/src/zigtrait.zig",
                    },
                }),
            },
        },
    });
    deshader_lib.addModule("websocket", websocket);

    // OpenGL
    const glModule = try openGlModule(b);
    deshader_lib.addModule("gl", glModule);

    // Vulkan
    const vulkanXmlInput = try b.build_root.join(b.allocator, &[_]String{"libs/Vulkan-Docs/xml/vk.xml"});
    const vkzig_dep = b.dependency("vulkan_zig", .{
        .registry = @as(String, vulkanXmlInput),
    });
    const vkzigBindings = vkzig_dep.module("vulkan-zig");
    deshader_lib.addModule("vulkan-zig", vkzigBindings);

    // Deshader internal library options
    const options = b.addOptions();
    const optionGLAdditionalLoader = b.option(String, "glAddLoader", "Name of additional exposed function which will call GL function loader");
    const optionvkAddInstanceLoader = b.option(String, "vkAddInstanceLoader", "Name of additional exposed function which will call Vulkan instance function loader");
    const optionvkAddDeviceLoader = b.option(String, "vkAddDeviceLoader", "Name of additional exposed function which will call Vulkan device function loader");
    options.addOption(?String, "glAddLoader", optionGLAdditionalLoader);
    options.addOption(?String, "vkAddDeviceLoader", optionvkAddDeviceLoader);
    options.addOption(?String, "vkAddInstanceLoader", optionvkAddInstanceLoader);
    options.addOption(bool, "logIntercept", optionInterceptionLog);
    options.addOption(String, "deshaderLibName", deshader_lib_name);
    options.addOption(ObjectFormat, "ofmt", optionOfmt);
    options.addOption(u32, "memoryFrames", optionMemoryTraceFrames);
    const version_result = try exec(.{ .allocator = b.allocator, .argv = &.{ "git", "describe", "--tags", "--always" } });
    options.addOption(String, "version", std.mem.trim(u8, version_result.stdout, " \n\t"));
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
            if (optionIgnoreMissingLibs) {
                std.log.warn("Missing library {s}", .{libName});
            } else {
                return deshader_lib.step.fail("Missing library {s}", .{libName});
            }
        }
    }
    if (try fileWithPrefixExists(b.allocator, host_libs_location, VulkanLibName)) |real_name| {
        run_symbol_enum.addArg(std.fmt.allocPrint(b.allocator, "{s}{s}", .{ native_libs_location, real_name }) catch unreachable);
    } else {
        if (optionIgnoreMissingLibs) {
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
    if (optionAdditionalLibraries != null) {
        run_symbol_enum.addArgs(optionAdditionalLibraries.?);
        allLibraries.appendSlice(optionAdditionalLibraries.?) catch unreachable;
    }
    // Parse symbol enumerator output
    var addGlProcsStep = ListGlProcsStep.init(b, targetTarget, "add_gl_procs", allLibraries.items, GlSymbolPrefixes, run_symbol_enum.captureStdOut());
    addGlProcsStep.step.dependOn(&run_symbol_enum.step);
    deshader_lib.step.dependOn(&addGlProcsStep.step);
    const transitive_exports = b.createModule(.{ .source_file = .{ .generated = &addGlProcsStep.generated_file } });
    deshader_lib.addModule("transitive_exports", transitive_exports);

    // Positron
    const positron = PositronSdk.getPackage(b, "positron");
    deshader_lib.addModule("positron", positron);
    deshader_lib.addModule("serve", b.modules.get("serve").?);
    if (option_embed_editor) {
        PositronSdk.linkPositron(deshader_lib, null, optionLinkage == .Static);
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
        .source_file = .{ .path = stubs_path }, //future file, may not exist
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
                    try std.mem.concat(b.allocator, u8, &.{ b.zig_exe, " ar %*" })
                else
                    try std.mem.concat(b.allocator, u8, &.{ "#!/bin/sh\n", b.zig_exe, " ar $@" }),
            );
        };
        // Set execution permissions
        if (builtin.os.tag != .windows) {
            const full_path = try std.fs.path.joinZ(b.allocator, &.{ b.build_root.path.?, ar_name });
            var stat: std.os.system.Stat = undefined;
            var result = std.os.system.stat(full_path, &stat);
            if (result == 0) {
                result = std.os.system.chmod(full_path, stat.mode | 0o111);
                if (result != 0) { //add execute permission
                    std.log.err("could not chmod {s}: {}", .{ ar_name, std.os.errno(result) });
                }
            } else {
                std.log.err("could not stat {s}: {}", .{ ar_name, std.os.errno(result) });
            }
        }

        // Build dependencies
        const dependencies_cmd = b.step("dependencies", "Bootstrap building nested deshader components and dependencies");
        var dependencies_step: *DependenciesStep = try b.allocator.create(DependenciesStep);
        dependencies_step.* = DependenciesStep.init(b, target, optionWolfSSL or targetTarget == .windows); // If wolfSSL is meant to be linked dynamically, it must be built first
        dependencies_cmd.dependOn(&dependencies_step.step);
        if (optionDependencies) {
            deshader_lib.step.dependOn(&dependencies_step.step);
        }

        //
        // Embed the created dependencies
        //
        var files = std.ArrayList(String).init(b.allocator);
        defer files.deinit();

        // Add all file names in the editor dist folder to `files`
        const editor_directory = "editor";
        if (option_embed_editor) {
            const editor_files = try b.build_root.handle.readFileAlloc(b.allocator, editor_directory ++ "/required.txt", 1024 * 1024);
            var editor_files_lines = std.mem.splitScalar(u8, editor_files, '\n');
            editor_files_lines.reset();
            while (editor_files_lines.next()) |line| {
                const path = try std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ editor_directory, line });
                try files.append(path);
                if (optimize != .Debug) { // In debug mode files are served from physical filesystem so one does not need to recompile Deshader each time
                    try embedCompressedFile(deshader_lib, if (optionDependencies) &dependencies_step.step else null, path);
                }
            }
        }

        // Add the file names as an option to the exe, making it available
        // as a string array at comptime in main.zig
        options.addOption([]const String, "files", files.items);
        options.addOption(String, "editorDir", editor_directory);
        options.addOption(bool, "embedEditor", option_embed_editor);
        deshader_lib.addOptions("options", options);

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
        var header_gen_target = target;
        header_gen_target.ofmt = null;
        var header_gen = b.addExecutable(.{
            .name = "generate_headers",
            .root_source_file = .{ .path = "src/tools/generate_headers.zig" },
            .main_mod_path = .{ .path = "src" },
            .target = header_gen_target,
            .optimize = optimize,
        });
        const heade_gen_opts = b.addOptions();
        heade_gen_opts.addOption(String, "emitHDir", b.h_dir);
        header_gen.addOptions("options", heade_gen_opts);
        header_gen.addAnonymousModule("header_gen", .{
            .source_file = .{ .path = "libs/zig-header-gen/src/header_gen.zig" },
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
            header_gen.addAnonymousModule("deshader", .{ .source_file = .{ .cwd_relative = "zig-cache/deshader_long.zig" } });
        }

        {
            const header_gen_install = b.addInstallArtifact(header_gen, .{});
            header_gen_cmd.dependOn(&header_gen_install.step);
            const header_run = b.addRunArtifact(header_gen_install.artifact);
            header_run.step.dependOn(&b.addInstallHeaderFile("src/declarations/macros.h", "deshader/macros.h").step);
            header_run.step.dependOn(&b.addInstallHeaderFile("src/declarations/commands.h", "deshader/commands.h").step);
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
    //            .root_source_file = .{ .path = "src/tools/forward.zig" },
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
    // Runner utility
    //
    const runner_exe = b.addExecutable(.{
        .name = "deshader-run",
        .root_source_file = .{ .path = "src/tools/run.zig" },
        .link_libc = true,
        .optimize = optimize,
        .target = target,
        .main_mod_path = .{ .path = "src" },
    });
    const runner_install = b.addInstallArtifact(runner_exe, .{});
    _ = b.step("runner", "Utility to run any application with Deshader").dependOn(&runner_install.step);

    const runner_options = b.addOptions();
    runner_options.addOption(String, "deshaderLibName", deshader_lib_name);
    runner_options.addOption(u32, "memoryFrames", optionMemoryTraceFrames);
    runner_options.addOption([]const String, "dependencies", deshader_dependent_dlls.items);
    runner_options.addOption(String, "deshaderRelativeRoot", try std.fs.path.relative(b.allocator, b.exe_dir, b.lib_dir));
    runner_exe.addOptions("options", runner_options);
    runner_exe.defineCMacro("_GNU_SOURCE", null); // To access dlinfo

    //
    // Example usages demonstration applications
    //
    {
        const examplesStep = b.step("examples", "Example OpenGL apps");
        examplesStep.dependOn(deshader_lib_cmd);

        const example_bootstraper = b.addExecutable(.{
            .name = "deshader-examples-all",
            .root_source_file = .{ .path = "examples/examples.zig" },
            .main_mod_path = .{ .path = "examples" },
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
        example_bootstraper.addOptions("options", example_options);
        example_bootstraper.step.dependOn(header_gen_cmd);

        // Various example applications
        {
            const exampleModules = .{
                .{ .name = "gl", .module = glModule },
                .{ .name = "deshader", .module = deshader_stubs },
            };
            // GLFW
            const example_glfw = try SubExampleStep.create(example_bootstraper, sub_examples.glfw, "examples/" ++ sub_examples.glfw ++ ".zig", exampleModules);
            try example_glfw.compile.addVcpkgPaths(.dynamic);

            // Use mach-glfw
            const glfw_dep = b.dependency("mach_glfw", .{
                .target = target,
                .optimize = optimize,
            });
            example_glfw.compile.addModule("mach-glfw", glfw_dep.module("mach-glfw"));
            @import("mach_glfw").link(glfw_dep.builder, example_glfw.compile);

            // Editor
            const example_editor = try SubExampleStep.create(example_bootstraper, sub_examples.editor, "examples/" ++ sub_examples.editor ++ ".zig", exampleModules);
            example_editor.compile.linkLibrary(deshader_lib);

            // GLFW in C++
            const example_glfw_cpp = try SubExampleStep.create(example_bootstraper, sub_examples.glfw_cpp, "examples/" ++ sub_examples.glfw ++ ".cpp", .{});
            example_glfw_cpp.compile.addIncludePath(.{ .path = b.h_dir });
            example_glfw_cpp.compile.linkLibCpp();

            //example_glfw_cpp.linkLibrary(deshader_lib);
            try linkGlew(example_glfw_cpp.install, targetTarget);
            @import("mach_glfw").link(glfw_dep.builder, example_glfw_cpp.compile);

            if (targetTarget == .windows) {
                example_glfw_cpp.compile.addWin32ResourceFile(.{ .file = .{ .path = try std.fs.path.join(b.allocator, &.{
                    b.build_root.path.?,
                    "examples",
                    "shaders.rc",
                }) } });
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
            try linkGlew(example_debug_commands.install, targetTarget);
            @import("mach_glfw").link(glfw_dep.builder, example_debug_commands.compile);
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
        .root_source_file = .{ .path = "src/main.zig" },
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
    clean_step.dependOn(&clean_run.step);
}

// This scans the environment for the `DESHADER_GL_VERSION` variable and
// returns a module that exports the OpenGL bindings for that version.
fn openGlModule(b: *std.build.Builder) !*std.build.Module {
    const glVersion = b.option(String, "glSuffix", "Suffix to libs/zig-opengl/exports/gl_X.zig that will be imported") orelse "4v6";
    const glFormat = "libs/zig-opengl/exports/gl_{s}.zig";

    return b.addModule("gl", .{
        .source_file = .{ .path = try std.fmt.allocPrint(b.allocator, glFormat, .{glVersion}) },
    });
}

fn embedCompressedFile(compile: *std.build.Step.Compile, dependOn: ?*std.build.Step, path: String) !void {
    const compress = try CompressStep.init(compile.step.owner, std.build.FileSource.relative(path));
    if (dependOn) |d| {
        compress.step.dependOn(d);
    }
    compile.addAnonymousModule(path, .{
        .source_file = .{ .generated = &compress.generatedFile },
    });
    compile.step.dependOn(&compress.step);
}

const SubExampleStep = struct {
    compile: *std.build.Step.Compile,
    install: *std.build.Step.InstallArtifact,

    pub fn create(bootstraper: *std.build.Step.Compile, comptime name: String, path: String, modules: anytype) !@This() {
        var step = &bootstraper.step;
        const subExe = step.owner.addExecutable(.{
            .name = "deshader-" ++ name,
            .root_source_file = .{ .path = path },
            .main_mod_path = .{ .path = "examples" },
            .target = bootstraper.target,
            .optimize = bootstraper.optimize,
        });
        inline for (modules) |mod| {
            subExe.addModule(mod.name, mod.module);
        }
        const target = bootstraper.target.os_tag orelse builtin.os.tag;

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
fn addVcpkgInstalledPaths(c: *std.build.Step.Compile) !void {
    c.addIncludePath(.{ .path = try c.step.owner.build_root.join(c.step.owner.allocator, &.{ "build", "vcpkg_installed", vcpkgTriplet(c.target.getOsTag()), "include" }) });
    c.addLibraryPath(.{ .path = try c.step.owner.build_root.join(c.step.owner.allocator, &.{ "build", "vcpkg_installed", vcpkgTriplet(c.target.getOsTag()), "bin" }) });
    c.addLibraryPath(.{ .path = try c.step.owner.build_root.join(c.step.owner.allocator, &.{ "build", "vcpkg_installed", vcpkgTriplet(c.target.getOsTag()), "lib" }) });
}

fn installVcpkgLibrary(i: *std.build.Step.InstallArtifact, name: String) !void {
    const b = i.step.owner;
    const os = i.artifact.target.getOsTag();
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
            b.addInstallLibFile(.{ .path = lib_path }, dest_path)
        else
            b.addInstallBinFile(.{ .path = lib_path }, dest_path)).step);
        std.log.info("Installed {s} from VCPKG", .{dest_path});
    } else |err| {
        std.log.warn("Could not find {s} from VCPKG but maybe system library will work too. {}", .{ name, err });
    }
}

fn linkGlew(i: *std.build.Step.InstallArtifact, target: std.Target.Os.Tag) !void {
    if (target == .windows) {
        try i.artifact.addVcpkgPaths(.dynamic);
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
