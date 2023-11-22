const std = @import("std");
const builtin = @import("builtin");
const PositronSdk = @import("libs/positron/Sdk.zig");
const ZigServe = @import("libs/positron/vendor/serve/build.zig");
const ctregex = @import("libs/ctregex/ctregex.zig");

const Linkage = enum {
    Static,
    Dynamic,
};
const String = []const u8;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const targetTarget = target.os_tag orelse builtin.os.tag;
    const GlLibNames: []const String = switch (targetTarget) {
        .windows => &[_]String{"opengl32.dll"},
        else => &[_]String{ "libGLX.so", "libEGL.so" },
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

    // Deshader library
    const deshaderCompileOptions = .{
        .name = "deshader",
        .root_source_file = .{ .path = "src/main.zig" },
        .main_mod_path = .{ .path = "src" },
        .target = target,
        .optimize = optimize,
    };
    // Compile options
    const optionLinkage = b.option(Linkage, "linkage", "Select linkage type for deshader library") orelse Linkage.Dynamic;
    const optionIgnoreMissingLibs = b.option(bool, "ignoreMissingLibs", "Ignore missing VK and GL libraries. Defaultly GLX, EGL and VK will be required") orelse false;
    const optionWolfSSL = b.option(bool, "wolfSSL", "Link against WolfSSL available on this system (produces smaller binaries)") orelse false;
    const option_embed_editor = b.option(bool, "embedEditor", "Embed VSCode editor into the library (default yes)") orelse true;
    const optionAdditionalLibraries = b.option([]const String, "customLibrary", "Names of additional libraroes to intercept");
    const optionInterceptionLog = b.option(bool, "logIntercept", "Log intercepted GL and VK procedure list to stdout") orelse false;

    const deshader_lib: *std.build.Step.Compile = if (optionLinkage == .Static) b.addStaticLibrary(deshaderCompileOptions) else b.addSharedLibrary(deshaderCompileOptions);
    const desahder_lib_cmd = b.step("deshader", "Install deshader library");
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

    // Websocket;
    const websocket = b.addModule("websocket", .{
        .source_file = .{ .path = "libs/websocket/src/websocket.zig" },
    });
    deshader_lib.addModule("websocket", websocket);

    // OpenGL
    const glModule = openGlModule(b);
    deshader_lib.addModule("gl", glModule);

    // Vulkan
    const vulkanXmlInput = b.build_root.join(b.allocator, &[_]String{"libs/Vulkan-Docs/xml/vk.xml"}) catch unreachable;
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
    const deshaderLibName = std.fs.path.basename(deshader_lib.out_filename);
    options.addOption(String, "deshaderLibName", deshaderLibName);

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
        runSymbolEnum = b.addSystemCommand(&[_]String{ "sh", "-c", "nm", "--format=posix", "--defined-only", "-DAp" }); // BUGFIX: symbol enumerator does not return all the symbols
        for (GlLibNames) |libName| {
            if (std.DynLib.open(libName)) |_| {
                runSymbolEnum.addArg(std.fmt.allocPrint(b.allocator, "/usr/lib/{s}*", .{libName}) catch unreachable);
            } else |_| {
                if (optionIgnoreMissingLibs) {
                    std.log.warn("Missing library {s}", .{libName});
                } else {
                    std.log.err("Missing library {s}", .{libName});
                    return;
                }
            }
        }
        if (std.DynLib.open(VulkanLibName)) |_| {
            runSymbolEnum.addArg(std.fmt.allocPrint(b.allocator, "/usr/lib/{s}*", .{VulkanLibName}) catch unreachable);
        } else |_| {
            if (optionIgnoreMissingLibs) {
                std.log.warn("Missing library {s}", .{VulkanLibName});
            } else {
                std.log.err("Missing library {s}", .{VulkanLibName});
                return;
            }
        }
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
    var addGlProcsStep = AddGlProcsStep.init(b, "add_gl_procs", allLibraries.items, GlSymbolPrefixes, runSymbolEnum.captureStdOut());
    addGlProcsStep.step.dependOn(&runSymbolEnum.step);
    deshader_lib.step.dependOn(&addGlProcsStep.step);
    const transitive_exports = b.createModule(.{ .source_file = .{ .generated = &addGlProcsStep.generated_file } });
    deshader_lib.addModule("transitive_exports", transitive_exports);
    deshader_lib.addAnonymousModule("transitive_exports_count", .{ .source_file = .{ .generated = &addGlProcsStep.generated_count_file } });
    const header_dir = std.fs.path.join(b.allocator, &.{ b.install_path, "include" }) catch unreachable;

    // Positron
    var positron: *std.build.Module = undefined;
    var serve: *std.build.Module = undefined;
    if (option_embed_editor) {
        positron = PositronSdk.getPackage(b, "positron");
        deshader_lib.addModule("positron", positron);
        PositronSdk.linkPositron(deshader_lib, null);
        deshader_lib.addModule("serve", b.modules.get("serve").?);
    } else {
        // The serve module itself is normally included in positron
        serve = PositronSdk.getServeModule(b);
        deshader_lib.addModule("serve", serve);
    }
    //
    // Steps for building generated and embedded files
    //
    const stubs_path = std.fs.path.join(b.allocator, &.{ header_dir, "deshader.zig" }) catch unreachable;
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
        var dependenciesStep: *DependenciesStep = b.allocator.create(DependenciesStep) catch unreachable;
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
            const editor_files = std.fs.cwd().readFileAlloc(b.allocator, editor_directory ++ "/required.txt", 1024 * 1024) catch undefined;
            var editor_files_lines = std.mem.splitScalar(u8, editor_files, '\n');
            editor_files_lines.reset();
            while (editor_files_lines.next()) |line| {
                appendFiles(deshader_lib, &files, .{
                    std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ editor_directory, line }) catch unreachable,
                }) catch unreachable;
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
        var stub_gen: *stubGenSrc.GenerateStubsStep = b.allocator.create(stubGenSrc.GenerateStubsStep) catch unreachable;
        {
            std.fs.cwd().makePath(std.fs.path.dirname(stubs_path).?) catch unreachable;
            std.fs.accessAbsolute(stubs_path, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    _ = std.fs.cwd().createFile(stubs_path, .{}) catch unreachable;
                }
            };
            stub_gen.* = stubGenSrc.GenerateStubsStep.init(b, std.fs.openFileAbsolute(stubs_path, .{ .mode = .write_only }) catch unreachable, true);
        }
        stub_gen_cmd.dependOn(&stub_gen.step);
        desahder_lib_cmd.dependOn(&stub_gen.step);

        //
        // Emit H File
        //
        const header_gen_cmd = b.step("generate_header", "Generate C header file for deshader library");
        var header_gen = b.addExecutable(.{
            .name = "generate_header",
            .root_source_file = .{ .path = "src/tools/generate_header.zig" },
            .main_mod_path = .{ .path = "src" },
            .target = target,
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
                b.cache_root.handle.openFile(log_name, .{ .mode = .write_only })
            else |_|
                b.cache_root.handle.createFile(log_name, .{})) catch unreachable;
            var stub_gen_long = b.allocator.create(stubGenSrc.GenerateStubsStep) catch unreachable;
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
    runnerOptions.addOption(String, "deshaderLibName", deshaderLibName);
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
            const abi = "abi";
        };
        const example_options = b.addOptions();
        example_options.addOption([]const String, "exampleNames", &.{ sub_examples.glfw, sub_examples.editor, sub_examples.abi });
        example_bootstraper.addOptions("options", example_options);

        // Various example applications
        {
            const exampleModules = .{
                .{ .name = "gl", .module = glModule },
                .{ .name = "deshader", .module = deshader_stubs },
            };
            // GLFW
            const example_glfw = exampleSubProgram(example_bootstraper, "glfw", "examples/" ++ sub_examples.glfw ++ ".zig", exampleModules);

            // Use mach-glfw
            const glfw_dep = b.dependency("mach_glfw", .{
                .target = target,
                .optimize = optimize,
            });
            example_glfw.addModule("mach-glfw", glfw_dep.module("mach-glfw"));
            @import("mach_glfw").link(glfw_dep.builder, example_glfw);

            // Editor
            const example_editor = exampleSubProgram(example_bootstraper, "editor", "examples/" ++ sub_examples.editor ++ ".zig", exampleModules);
            example_editor.linkLibrary(deshader_lib);

            // ABI
            const example_abi = exampleSubProgram(example_bootstraper, "abi", "examples/" ++ sub_examples.abi ++ ".cpp", .{});
            example_abi.addIncludePath(.{ .path = header_dir });
            example_abi.linkLibrary(deshader_lib);
        }
        examplesStep.dependOn(stub_gen_cmd);
        const exampleInstall = b.addInstallArtifact(example_bootstraper, .{});
        examplesStep.dependOn(&exampleInstall.step);

        // Run examples by `deshader-run`
        const exampleRun = b.addRunArtifact(runnerInstall.artifact);
        const exampleRunCmd = b.step("examples-run", "Run example with injected Deshader debugging");
        exampleRun.setEnvironmentVariable("DESHADER_LIB", std.fs.path.join(b.allocator, &.{ b.install_path, "lib", deshaderLibName }) catch unreachable);
        exampleRun.addArg(std.fs.path.join(b.allocator, &.{ b.install_path, "bin", "examples" }) catch unreachable);
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
fn openGlModule(b: *std.build.Builder) *std.build.Module {
    const glVersion = b.option(String, "glSuffix", "Suffix to libs/zig-opengl/exports/gl_X.zig that will be imported") orelse "4v6";
    const glFormat = "libs/zig-opengl/exports/gl_{s}.zig";

    return b.addModule("gl", .{
        .source_file = .{ .path = std.fmt.allocPrint(b.allocator, glFormat, .{glVersion}) catch unreachable },
    });
}

const DependenciesStep = struct {
    step: std.build.Step,

    pub fn init(b: *std.build.Builder) DependenciesStep {
        return @as(
            DependenciesStep,
            .{
                .step = std.build.Step.init(
                    .{
                        .name = "dependencies",
                        .makeFn = DependenciesStep.doStep,
                        .owner = b,
                        .id = .custom,
                    },
                ),
            },
        );
    }

    pub fn initSubprocess(self: *DependenciesStep, argv: []const String, cwd: String, env_map: ?*std.process.EnvMap) std.process.Child {
        return .{
            .id = undefined,
            .allocator = self.step.owner.allocator,
            .cwd = cwd,
            .env_map = env_map,
            .argv = argv,
            .thread_handle = undefined,
            .err_pipe = null,
            .term = null,
            .uid = if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {} else null,
            .gid = if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {} else null,
            .stdin = null,
            .stdout = null,
            .stderr = null,
            .stdin_behavior = .Ignore,
            .stdout_behavior = .Inherit,
            .stderr_behavior = .Inherit,
            .expand_arg0 = .no_expand,
        };
    }

    pub fn doStep(step: *std.build.Step, progressNode: *std.Progress.Node) anyerror!void {
        const self: *DependenciesStep = @fieldParentPtr(DependenciesStep, "step", step);

        const env_map: *std.process.EnvMap = self.step.owner.allocator.create(std.process.EnvMap) catch unreachable;
        env_map.* = std.process.getEnvMap(step.owner.allocator) catch unreachable;
        try env_map.put("NOTEST", "y");

        progressNode.activate();

        var oglProcess = self.initSubprocess(&.{ "make", "all" }, "./libs/zig-opengl", env_map);
        try oglProcess.spawn();

        const bunInstallCmd = [_]String{ "bun", "install", "--frozen-lockfile" };
        var bunProcess1 = self.initSubprocess((&bunInstallCmd ++ &[_]String{"--production"}), "editor", null);
        try bunProcess1.spawn();

        const deshaderVsCodeExt = "editor/deshader-vscode";
        var bunProcess2 = self.initSubprocess(&bunInstallCmd, deshaderVsCodeExt, null);
        try bunProcess2.spawn();

        const oglResult = try oglProcess.wait();
        if (oglResult.Exited != 0) {
            std.log.err("Subprocess for making opengl exited with error code {}", .{oglResult.Exited});
        }

        const bunProcess2Result = try bunProcess2.wait();
        if (bunProcess2Result.Exited != 0) {
            std.log.err("Node.js dependencies installation failed for deshader-vscode", .{});
        }
        var webpackProcess = self.initSubprocess(&.{ "bun", "compile-web" }, deshaderVsCodeExt, null);
        try webpackProcess.spawn();
        if ((try webpackProcess.wait()).Exited != 0) {
            std.log.err("VSCode extension compilation failed", .{});
        }
        if ((try bunProcess1.wait()).Exited != 0) {
            std.log.err("Node.js dependencies installation failed for editor", .{});
        }

        progressNode.end();
    }
};
const CompressStep = struct {
    step: std.build.Step,
    source: std.build.LazyPath,
    generatedFile: std.Build.GeneratedFile,

    pub fn init(b: *std.build.Builder, source: std.build.LazyPath) *@This() {
        var self = b.allocator.create(@This()) catch unreachable;
        self.* = .{
            .source = source,
            .step = std.build.Step.init(.{ .id = .custom, .makeFn = make, .name = "compress", .owner = b }),
            .generatedFile = undefined,
        };
        self.generatedFile = .{ .step = &self.step };
        return self;
    }

    fn make(step: *std.build.Step, progressNode: *std.Progress.Node) anyerror!void {
        const self = @fieldParentPtr(@This(), "step", step);
        progressNode.activate();
        defer progressNode.end();
        const source = self.source.getPath(step.owner);
        const reader = try std.fs.openFileAbsolute(source, .{});
        var buffer: [10 * 1024 * 1024]u8 = undefined;
        const size = try reader.readAll(&buffer);
        var hash = step.owner.cache.hash;
        // Random bytes to make unique. Refresh this with new random bytes when
        // implementation is modified in a non-backwards-compatible way.
        hash.add(@as(u32, 0xad95e922));
        hash.addBytes(buffer[0..size]);
        const dest = try step.owner.cache_root.join(step.owner.allocator, &.{ "c", "compressed", &hash.final(), std.fs.path.basename(source) });
        self.generatedFile.path = dest;
        if (step.owner.cache_root.handle.access(dest, .{})) |_| {
            // This is the hot path, success.
            step.result_cached = true;
            return;
        } else |outer_err| switch (outer_err) {
            error.FileNotFound => {
                const dest_dirname = std.fs.path.dirname(dest).?;
                step.owner.cache_root.handle.makePath(dest_dirname) catch |err| {
                    return step.fail("unable to make path '{}{s}': {s}", .{
                        step.owner.cache_root, dest_dirname, @errorName(err),
                    });
                };

                const rand_int = std.crypto.random.int(u64);
                const tmp_sub_path = try std.fs.path.join(
                    step.owner.allocator,
                    &.{ "tmp", &std.Build.hex64(rand_int), std.fs.path.basename(dest) },
                );
                const tmp_sub_path_dirname = std.fs.path.dirname(tmp_sub_path).?;

                step.owner.cache_root.handle.makePath(tmp_sub_path_dirname) catch |err| {
                    return step.fail("unable to make temporary directory '{}{s}': {s}", .{
                        step.owner.cache_root, tmp_sub_path_dirname, @errorName(err),
                    });
                };

                const file = try step.owner.cache_root.handle.createFile(tmp_sub_path, .{});
                var compressor = try std.compress.zlib.compressStream(step.owner.allocator, file.writer(), .{});
                const wrote_size = try compressor.write(buffer[0..size]);
                if (wrote_size != size) {
                    return step.fail("unable to write all bytes to compressor", .{});
                }
                try compressor.finish();
                compressor.deinit();
                file.close();
                reader.close();

                step.owner.cache_root.handle.rename(tmp_sub_path, dest) catch |err| switch (err) {
                    error.PathAlreadyExists => {
                        // Other process beat us to it. Clean up the temp file.
                        step.owner.cache_root.handle.deleteFile(tmp_sub_path) catch |e| {
                            try step.addError("warning: unable to delete temp file '{}{s}': {s}", .{
                                step.owner.cache_root, tmp_sub_path, @errorName(e),
                            });
                        };
                        step.result_cached = true;
                        return;
                    },
                    else => {
                        return step.fail("unable to rename options from '{}{s}' to '{}{s}': {s}", .{
                            step.owner.cache_root, tmp_sub_path,
                            step.owner.cache_root, dest,
                            @errorName(err),
                        });
                    },
                };
            },
            else => |e| return step.fail("unable to access options file '{}{s}': {s}", .{
                step.owner.cache_root, dest, @errorName(e),
            }),
        }
    }
};

fn appendFiles(step: *std.build.Step.Compile, files: *std.ArrayList(String), toAdd: anytype) !void {
    inline for (toAdd) |addThis| {
        const compress = CompressStep.init(step.step.owner, std.build.FileSource.relative(addThis));
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
                const innerDir = try std.fs.openIterableDirAbsolute(try it.dir.realpathAlloc(b.allocator, file.name), .{});
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

const PrintStep = struct {
    step: std.build.Step,
    message: String,

    fn init(b: *std.build.Builder, name: String, message: String) @This() {
        return .{
            .step = std.build.Step.init(.{
                .owner = b,
                .id = .custom,
                .name = name,
                .makeFn = @This().makeFn,
            }),
            .message = message,
        };
    }

    fn makeFn(step: *std.build.Step, progressNode: *std.Progress.Node) anyerror!void {
        progressNode.activate();
        const self = @fieldParentPtr(@This(), "step", step);
        std.log.err("{s}", .{self.message});
        progressNode.end();
    }
};

const AddGlProcsStep = struct {
    step: std.build.Step,
    libNames: []const String,
    symbolPrefixes: []const String,
    symbolsOutput: std.build.LazyPath,
    generated_file: std.Build.GeneratedFile,
    generated_count_file: std.Build.GeneratedFile,

    fn init(b: *std.build.Builder, name: String, libNames: []const String, symbolPrefixes: []const String, symbolEnumeratorOutput: std.build.LazyPath) *@This() {
        const self = b.allocator.create(AddGlProcsStep) catch @panic("OOM");
        self.* = @This(){
            .step = std.build.Step.init(.{
                .owner = b,
                .id = .options,
                .name = name,
                .makeFn = make,
            }),
            .symbolsOutput = symbolEnumeratorOutput,
            .generated_file = undefined,
            .generated_count_file = undefined,
            .libNames = libNames,
            .symbolPrefixes = symbolPrefixes,
        };
        self.generated_file = .{ .step = &self.step };
        self.generated_count_file = .{ .step = &self.step };
        return self;
    }

    fn make(step: *std.build.Step, progressNode: *std.Progress.Node) anyerror!void {
        progressNode.activate();
        defer progressNode.end();
        const self = @fieldParentPtr(@This(), "step", step);
        const symbolsFile = try std.fs.cwd().openFile(self.symbolsOutput.generated.getPath(), .{});
        const reader = symbolsFile.reader();
        var glProcs = std.StringArrayHashMap(void).init(step.owner.allocator);
        defer glProcs.deinit();
        while (try reader.readUntilDelimiterOrEofAlloc(self.step.owner.allocator, '\n', 1024 * 1024)) |symbolsLine| {
            defer self.step.owner.allocator.free(symbolsLine);
            var tokens = std.mem.splitScalar(u8, symbolsLine, ' ');
            const libName = tokens.next();
            const symbolName = tokens.next();
            if (libName == null or symbolName == null) {
                continue;
            }
            for (self.libNames) |selfLibName| {
                if (std.mem.indexOf(u8, libName.?, selfLibName) != null) {
                    for (self.symbolPrefixes) |prefix| {
                        if (std.mem.startsWith(u8, symbolName.?, prefix)) {
                            try glProcs.put(self.step.owner.dupe(symbolName.?), {});
                        }
                    }
                }
            }
        }
        const output = try std.mem.join(step.owner.allocator, "\n", glProcs.keys());
        // This is more or less copied from Options step.
        const basename = "procs.txt";
        const count_basename = "procs_count.zig";

        // Hash contents to file name.
        var hash = step.owner.cache.hash;
        // Random bytes to make unique. Refresh this with new random bytes when
        // implementation is modified in a non-backwards-compatible way.
        hash.add(@as(u32, 0xad95e922));
        hash.addBytes(output);
        const h = hash.final();
        const sub_path = "c" ++ std.fs.path.sep_str ++ h ++ std.fs.path.sep_str ++ basename;
        const sub_path_count = "c" ++ std.fs.path.sep_str ++ h ++ std.fs.path.sep_str ++ count_basename;

        self.generated_file.path = try step.owner.cache_root.join(step.owner.allocator, &.{sub_path});
        self.generated_count_file.path = try step.owner.cache_root.join(step.owner.allocator, &.{sub_path_count});
        if (step.owner.cache_root.handle.access(sub_path, .{})) {
            // This is the hot path, success.
            step.result_cached = true;
            return;
        } else |outer_err| switch (outer_err) {
            error.FileNotFound => {
                const sub_dirname = std.fs.path.dirname(sub_path).?;
                step.owner.cache_root.handle.makePath(sub_dirname) catch |e| {
                    return step.fail("unable to make path '{}{s}': {s}", .{
                        step.owner.cache_root, sub_dirname, @errorName(e),
                    });
                };

                const rand_int = std.crypto.random.int(u64);
                const tmp_sub_path = "tmp" ++ std.fs.path.sep_str ++
                    std.Build.hex64(rand_int) ++ std.fs.path.sep_str ++
                    basename;
                const count_tmp_sub_path = "tmp" ++ std.fs.path.sep_str ++
                    std.Build.hex64(rand_int) ++ std.fs.path.sep_str ++
                    count_basename;
                const tmp_sub_path_dirname = std.fs.path.dirname(tmp_sub_path).?;

                step.owner.cache_root.handle.makePath(tmp_sub_path_dirname) catch |err| {
                    return step.fail("unable to make temporary directory '{}{s}': {s}", .{
                        step.owner.cache_root, tmp_sub_path_dirname, @errorName(err),
                    });
                };

                step.owner.cache_root.handle.writeFile(tmp_sub_path, output) catch |err| {
                    return step.fail("unable to write procs to '{}{s}': {s}", .{
                        step.owner.cache_root, tmp_sub_path, @errorName(err),
                    });
                };
                const count = std.fmt.allocPrint(step.owner.allocator, "pub const count = {d};", .{glProcs.count()}) catch unreachable;
                defer step.owner.allocator.free(count);
                step.owner.cache_root.handle.writeFile(count_tmp_sub_path, count) catch |err| {
                    return step.fail("unable to write proc count to '{}{s}': {s}", .{
                        step.owner.cache_root, count_tmp_sub_path, @errorName(err),
                    });
                };

                step.owner.cache_root.handle.rename(tmp_sub_path, sub_path) catch |err| switch (err) {
                    error.PathAlreadyExists => {
                        // Other process beat us to it. Clean up the temp file.
                        step.owner.cache_root.handle.deleteFile(tmp_sub_path) catch |e| {
                            try step.addError("warning: unable to delete temp file '{}{s}': {s}", .{
                                step.owner.cache_root, tmp_sub_path, @errorName(e),
                            });
                        };
                        step.result_cached = true;
                        return;
                    },
                    else => {
                        return step.fail("unable to rename procs file from '{}{s}' to '{}{s}': {s}", .{
                            step.owner.cache_root, tmp_sub_path,
                            step.owner.cache_root, sub_path,
                            @errorName(err),
                        });
                    },
                };
                step.owner.cache_root.handle.rename(count_tmp_sub_path, sub_path_count) catch |err| switch (err) {
                    error.PathAlreadyExists => {
                        // Other process beat us to it. Clean up the temp file.
                        step.owner.cache_root.handle.deleteFile(count_tmp_sub_path) catch |e| {
                            try step.addError("warning: unable to delete temp file '{}{s}': {s}", .{
                                step.owner.cache_root, count_tmp_sub_path, @errorName(e),
                            });
                        };
                        step.result_cached = true;
                        return;
                    },
                    else => {
                        return step.fail("unable to rename procs count from '{}{s}' to '{}{s}': {s}", .{
                            step.owner.cache_root, count_tmp_sub_path,
                            step.owner.cache_root, sub_path_count,
                            @errorName(err),
                        });
                    },
                };
            },
            else => |e| return step.fail("unable to access procs file '{}{s}': {s}", .{
                step.owner.cache_root, sub_path, @errorName(e),
            }),
        }
    }
};

fn exampleSubProgram(bootstraper: *std.build.Step.Compile, name: String, path: String, modules: anytype) *std.build.Step.Compile {
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
        .{ .dest_sub_path = std.fs.path.join(step.owner.allocator, &.{ "example", name }) catch unreachable },
    );
    step.dependOn(&install.step);
    return subExe;
}
