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
    const optionOfmt = b.option(enum { Default, c, IR, BC }, "ofmt", "Compile into object format") orelse .Default;
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
    const optionLinkage = b.option(Linkage, "linkage", "Select linkage type for deshader library") orelse Linkage.Dynamic;
    const optionIgnoreMissingLibs = b.option(bool, "ignoreMissingLibs", "Ignore missing VK and GL libraries. Defaultly GLX, EGL and VK will be required") orelse false;
    const optionWolfSSL = b.option(bool, "wolfSSL", "Link against WolfSSL available on this system (produces smaller binaries)") orelse false;
    const option_embed_editor = b.option(bool, "embedEditor", "Embed VSCode editor into the library (default yes)") orelse true;
    const optionAdditionalLibraries = b.option([]const String, "customLibrary", "Names of additional libraroes to intercept");
    const optionInterceptionLog = b.option(bool, "logIntercept", "Log intercepted GL and VK procedure list to stdout") orelse false;

    const deshader_lib: *std.build.Step.Compile = if (optionLinkage == .Static) b.addStaticLibrary(deshaderCompileOptions) else b.addSharedLibrary(deshaderCompileOptions);
    const deshader_lib_name = try std.mem.concat(b.allocator, u8, &.{ "libdeshader", targetTarget.dynamicLibSuffix() });
    const desahder_lib_cmd = b.step("deshader", "Install deshader library");
    switch (optionOfmt) {
        .BC => {
            deshader_lib.generated_llvm_ir = try b.allocator.create(std.build.GeneratedFile);
            deshader_lib.generated_llvm_ir.?.* = .{ .step = &deshader_lib.step, .path = try b.cache_root.join(b.allocator, &.{ "llvm", "deshader.ll" }) };
            desahder_lib_cmd.dependOn(&b.addInstallFileWithDir(deshader_lib.getEmittedLlvmBc(), .lib, "deshader.bc").step);
        },
        .IR => {
            deshader_lib.generated_llvm_bc = try b.allocator.create(std.build.GeneratedFile);
            deshader_lib.generated_llvm_bc.?.* = .{ .step = &deshader_lib.step, .path = try b.cache_root.join(b.allocator, &.{ "llvm", "deshader.bc" }) };
            desahder_lib_cmd.dependOn(&b.addInstallFileWithDir(deshader_lib.getEmittedLlvmIr(), .lib, "deshader.ll").step);
        },
        else => {},
    }
    const deshaderLibInstall = b.addInstallArtifact(deshader_lib, .{});
    desahder_lib_cmd.dependOn(&deshaderLibInstall.step);

    // WolfSSL
    var wolfssl: *std.build.Step.Compile = undefined;
    if (optionWolfSSL) {
        deshader_lib.linkSystemLibrary("wolfssl");
        deshader_lib.addIncludePath(.{ .path = ZigServe.sdkPath("/vendor/wolfssl/") });
    } else {
        wolfssl = ZigServe.createWolfSSL(b, target);
        deshader_lib.linkLibrary(wolfssl);
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
    const version_result = try exec(.{ .allocator = b.allocator, .argv = &.{ "git", "describe", "--tags", "--always" } });
    options.addOption(String, "version", std.mem.trim(u8, version_result.stdout, " \n\t"));

    // Symbol Enumerator
    const buildSymbolEnum = b.addExecutable(.{
        .name = "symbol_enumerator",
        .link_libc = true,
        .root_source_file = .{ .path = "src/tools/symbol_enumerator.cc" },
        .target = target,
        .optimize = optimize,
    });
    if (targetTarget == .windows) {
        buildSymbolEnum.linkSystemLibrary("dbghelp");
    }
    var runSymbolEnum: *std.build.Step.Run = undefined;
    if (targetTarget == .windows) {
        runSymbolEnum = b.addRunArtifact(buildSymbolEnum);
        runSymbolEnum.addArgs(GlLibNames);
        runSymbolEnum.addArg(VulkanLibName);
    } else {
        runSymbolEnum = b.addSystemCommand(&[_]String{ "nm", "--format=posix", "--defined-only", "-DAp" }); // BUGFIX: symbol enumerator does not return all the symbols
        for (GlLibNames) |libName| {
            if (try fileWithPrefixExists(b.allocator, "/usr/lib/", libName)) |real_name| {
                runSymbolEnum.addArg(std.fmt.allocPrint(b.allocator, "/usr/lib/{s}", .{real_name}) catch unreachable);
            } else {
                if (optionIgnoreMissingLibs) {
                    std.log.warn("Missing library {s}", .{libName});
                } else {
                    return deshader_lib.step.fail("Missing library {s}", .{libName});
                }
            }
        }
        if (try fileWithPrefixExists(b.allocator, "/usr/lib/", VulkanLibName)) |real_name| {
            runSymbolEnum.addArg(std.fmt.allocPrint(b.allocator, "/usr/lib/{s}", .{real_name}) catch unreachable);
        } else {
            if (optionIgnoreMissingLibs) {
                std.log.warn("Missing library {s}", .{VulkanLibName});
            } else {
                return deshader_lib.step.fail("Missing library {s}", .{VulkanLibName});
            }
        }

        runSymbolEnum.addArg(std.fmt.allocPrint(b.allocator, "/usr/lib/{s}", .{VulkanLibName}) catch unreachable);
    }
    runSymbolEnum.expectExitCode(0);
    runSymbolEnum.expectStdErrEqual("");
    var allLibraries = std.ArrayList(String).init(b.allocator);
    allLibraries.appendSlice(GlLibNames) catch unreachable;
    allLibraries.append(VulkanLibName) catch unreachable;
    if (optionAdditionalLibraries != null) {
        runSymbolEnum.addArgs(optionAdditionalLibraries.?);
        allLibraries.appendSlice(optionAdditionalLibraries.?) catch unreachable;
    }
    var addGlProcsStep = ListGlProcsStep.init(b, "add_gl_procs", allLibraries.items, GlSymbolPrefixes, runSymbolEnum.captureStdOut());
    addGlProcsStep.step.dependOn(&runSymbolEnum.step);
    deshader_lib.step.dependOn(&addGlProcsStep.step);
    const transitive_exports = b.createModule(.{ .source_file = .{ .generated = &addGlProcsStep.generated_file } });
    deshader_lib.addModule("transitive_exports", transitive_exports);
    const header_dir = try std.fs.path.join(b.allocator, &.{ b.install_path, "include" });

    // Positron
    const positron = PositronSdk.getPackage(b, "positron");
    deshader_lib.addModule("positron", positron);
    deshader_lib.addModule("serve", b.modules.get("serve").?);
    if (option_embed_editor) {
        PositronSdk.linkPositron(deshader_lib, null);
    }
    //
    // Steps for building generated and embedded files
    //
    const stubs_path = try std.fs.path.join(b.allocator, &.{ header_dir, "deshader.zig" });
    var stub_gen_cmd = b.step("generate_stubs", "Generate .zig file with function stubs for deshader library");
    const deshader_stubs = b.addModule("deshader", .{
        .source_file = .{ .path = stubs_path }, //future file, may not exist
    });
    {
        //
        // Other components / dependencies
        // NOTE: must be run manually with `zig build dependencies` before `zig  build`
        //
        const dependenciesCmd = b.step("dependencies", "Bootstrap building nested deshader components and dependencies");
        var dependenciesStep: *DependenciesStep = try b.allocator.create(DependenciesStep);
        dependenciesStep.* = DependenciesStep.init(b);
        dependenciesCmd.dependOn(&dependenciesStep.step);

        //
        // Embed the created dependencies
        //
        var files = std.ArrayList(String).init(b.allocator);
        defer files.deinit();

        // Add all files names in the editor dist folder to `files`
        const editor_directory = "editor";
        if (option_embed_editor) {
            const editor_files = try std.fs.cwd().readFileAlloc(b.allocator, editor_directory ++ "/required.txt", 1024 * 1024);
            var editor_files_lines = std.mem.splitScalar(u8, editor_files, '\n');
            editor_files_lines.reset();
            while (editor_files_lines.next()) |line| {
                try appendFiles(deshader_lib, &files, .{
                    try std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ editor_directory, line }),
                });
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
            try std.fs.cwd().makePath(std.fs.path.dirname(stubs_path).?);
            std.fs.accessAbsolute(stubs_path, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    _ = try std.fs.cwd().createFile(stubs_path, .{});
                }
            };
            stub_gen.* = stubGenSrc.GenerateStubsStep.init(b, try std.fs.openFileAbsolute(stubs_path, .{ .mode = .write_only }), true);
        }
        stub_gen_cmd.dependOn(&stub_gen.step);
        desahder_lib_cmd.dependOn(&stub_gen.step);

        //
        // Emit H File
        //
        const header_gen_cmd = b.step("generate_header", "Generate C header file for deshader library");
        var header_gen_target = target;
        header_gen_target.ofmt = null;
        var header_gen = b.addExecutable(.{
            .name = "generate_header",
            .root_source_file = .{ .path = "src/tools/generate_header.zig" },
            .main_mod_path = .{ .path = "src" },
            .target = header_gen_target,
            .optimize = optimize,
        });
        const heade_gen_opts = b.addOptions();
        heade_gen_opts.addOption(String, "emitHDir", header_dir);
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
        const header_gen_install = b.addInstallArtifact(header_gen, .{});
        header_gen_cmd.dependOn(&header_gen_install.step);
        // automatically create header when building the library
        desahder_lib_cmd.dependOn(&b.addRunArtifact(header_gen_install.artifact).step);
    }

    //
    // Runner utility
    //
    const runnerExe = b.addExecutable(.{
        .name = "deshader-run",
        .root_source_file = .{ .path = "src/tools/run.zig" },
        .link_libc = true,
        .optimize = optimize,
        .target = target,
        .main_mod_path = .{ .path = "src" },
    });
    const runnerOptions = b.addOptions();
    runnerOptions.addOption(String, "deshaderLibName", deshader_lib_name);
    runnerExe.addOptions("options", runnerOptions);
    runnerExe.defineCMacro("_GNU_SOURCE", null); // To access dlinfo

    const runnerInstall = b.addInstallArtifact(runnerExe, .{});
    _ = b.step("runner", "Build a utility to run any application with Deshader").dependOn(&runnerInstall.step);

    //
    // Example usages demonstration applications
    //
    {
        const examplesStep = b.step("example", "Build example OpenGL app");
        examplesStep.dependOn(desahder_lib_cmd);

        const example_bootstraper = b.addExecutable(.{
            .name = "examples",
            .root_source_file = .{ .path = "examples/examples.zig" },
            .main_mod_path = .{ .path = "examples" },
            .target = target,
            .optimize = optimize,
        });
        const sub_examples = struct {
            const glfw = "glfw";
            const editor = "editor";
            const glfw_cpp = "glfw_cpp";
            const editor_cpp = "editor_cpp";
        };
        const example_options = b.addOptions();
        example_options.addOption([]const String, "exampleNames", &.{ sub_examples.glfw, sub_examples.editor, sub_examples.editor_cpp, sub_examples.glfw_cpp });
        example_bootstraper.addOptions("options", example_options);

        // Various example applications
        {
            const exampleModules = .{
                .{ .name = "gl", .module = glModule },
                .{ .name = "deshader", .module = deshader_stubs },
            };
            // GLFW
            const example_glfw = try exampleSubProgram(example_bootstraper, sub_examples.glfw, "examples/" ++ sub_examples.glfw ++ ".zig", exampleModules);

            // Use mach-glfw
            const glfw_dep = b.dependency("mach_glfw", .{
                .target = target,
                .optimize = optimize,
            });
            example_glfw.addModule("mach-glfw", glfw_dep.module("mach-glfw"));
            @import("mach_glfw").link(glfw_dep.builder, example_glfw);

            // Editor
            const example_editor = try exampleSubProgram(example_bootstraper, sub_examples.editor, "examples/" ++ sub_examples.editor ++ ".zig", exampleModules);
            example_editor.linkLibrary(deshader_lib);

            // GLFW in C++
            const example_glfw_cpp = try exampleSubProgram(example_bootstraper, sub_examples.glfw_cpp, "examples/glfw.cpp", .{});
            example_glfw_cpp.addIncludePath(.{ .path = header_dir });
            example_glfw_cpp.linkLibCpp();
            //example_glfw_cpp.linkLibrary(deshader_lib);
            example_glfw_cpp.linkSystemLibrary("glew");
            @import("mach_glfw").link(glfw_dep.builder, example_glfw_cpp);
            inline for (.{ "fragment.frag", "vertex.vert" }) |shader| {
                const output = try std.fs.path.join(b.allocator, &.{ b.cache_root.path.?, "shaders", shader ++ ".o" });
                b.cache_root.handle.access("shaders", .{}) catch try std.fs.makeDirAbsolute(std.fs.path.dirname(output).?);
                const result = try exec(.{
                    .allocator = b.allocator,
                    .argv = &.{ "ld", "--relocatable", "--format", "binary", "--output", output, shader },
                    .cwd_dir = try std.fs.cwd().openDir("examples", .{}),
                });
                if (result.term.Exited == 0) {
                    example_glfw_cpp.addObjectFile(.{ .path = output });
                } else {
                    std.log.err("Failed to compile shader {s}: {s}", .{ shader, result.stderr });
                }
            }

            // Editor in C++
            const example_editor_cpp = try exampleSubProgram(example_bootstraper, sub_examples.editor_cpp, "examples/editor.cpp", .{});
            example_editor_cpp.addIncludePath(.{ .path = header_dir });
            example_editor_cpp.linkLibrary(deshader_lib);
        }
        examplesStep.dependOn(stub_gen_cmd);
        const exampleInstall = b.addInstallArtifact(example_bootstraper, .{});
        examplesStep.dependOn(&exampleInstall.step);

        // Run examples by `deshader-run`
        const exampleRun = b.addRunArtifact(runnerInstall.artifact);
        const exampleRunCmd = b.step("examples-run", "Run example with injected Deshader debugging");
        exampleRun.setEnvironmentVariable("DESHADER_LIB", try std.fs.path.join(b.allocator, &.{ b.install_path, "lib", deshader_lib_name }));
        exampleRun.addArg(try std.fs.path.join(b.allocator, &.{ b.install_path, "bin", "examples" }));
        exampleRunCmd.dependOn(&exampleInstall.step);
        exampleRunCmd.dependOn(&exampleRun.step);
        exampleRunCmd.dependOn(&runnerInstall.step);
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

fn appendFiles(step: *std.build.Step.Compile, files: *std.ArrayList(String), toAdd: anytype) !void {
    inline for (toAdd) |addThis| {
        const compress = try CompressStep.init(step.step.owner, std.build.FileSource.relative(addThis));
        step.addAnonymousModule(addThis, .{
            .source_file = .{ .generated = &compress.generatedFile },
        });
        step.step.dependOn(&compress.step);
        try files.append(addThis);
    }
}

fn appendFilesRecursive(
    b: *std.Build,
    step: *std.build.Step.Compile,
    files: *std.ArrayList(String),
    absolutePasePath: String,
    it: *std.fs.IterableDir.Iterator,
    exclude: anytype,
) !void {
    eachFile: while (try it.next()) |file| {
        switch (file.kind) {
            .directory => {
                const innerDir = try openIterableDir(try it.dir.realpathAlloc(b.allocator, file.name));
                var innerIt = innerDir.iterateAssumeFirstIteration();
                try appendFilesRecursive(b, step, files, absolutePasePath, &innerIt, exclude);
                continue;
            },
            .file => {
                inline for (exclude) |excl| {
                    if (file.name.len == 0) {
                        continue :eachFile;
                    }
                    if (try ctregex.search(excl, .{ .encoding = .utf8 }, file.name) != null) {
                        continue :eachFile;
                    }
                }
                const relPath = try std.fs.path.relative(
                    b.allocator,
                    absolutePasePath,
                    try it.dir.realpathAlloc(b.allocator, file.name),
                );
                try appendFiles(step, files, .{relPath});
            },
            else => continue,
        }
    }
}

fn exampleSubProgram(bootstraper: *std.build.Step.Compile, name: String, path: String, modules: anytype) !*std.build.Step.Compile {
    var step = &bootstraper.step;
    const subExe = step.owner.addExecutable(.{
        .name = name,
        .root_source_file = .{ .path = path },
        .main_mod_path = .{ .path = "examples" },
        .target = bootstraper.target,
        .optimize = bootstraper.optimize,
    });
    inline for (modules) |mod| {
        subExe.addModule(mod.name, mod.module);
    }

    const install = step.owner.addInstallArtifact(
        subExe,
        .{ .dest_sub_path = try std.fs.path.join(step.owner.allocator, &.{ "example", name }) },
    );
    step.dependOn(&install.step);
    return subExe;
}

fn fileWithPrefixExists(allocator: std.mem.Allocator, dirname: String, basename: String) !?String {
    var dir = try openIterableDir(dirname);
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
