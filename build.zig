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
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    const deshaderCompileOptions = .{
        .name = "deshader",
        .root_source_file = .{ .path = "src/main.zig" },
        .main_mod_path = .{ .path = "src" },
        .target = target,
        .optimize = optimize,
    };
    const optionLinkage = b.option(Linkage, "linkage", "Select linkage type for deshader library") orelse Linkage.Dynamic;
    const deshaderLib: *std.build.Step.Compile = if (optionLinkage == .Static) b.addStaticLibrary(deshaderCompileOptions) else b.addSharedLibrary(deshaderCompileOptions);
    const optionWolfSSL = b.option(bool, "wolfSSL", "Link against WolfSSL available on this system (produces smaller binaries)") orelse false;
    var wolfssl: *std.build.Step.Compile = undefined;
    if (optionWolfSSL) {
        deshaderLib.linkSystemLibrary("wolfssl");
        deshaderLib.addIncludePath(.{ .path = ZigServe.sdkPath("/vendor/wolfssl/") });
    } else {
        wolfssl = ZigServe.createWolfSSL(b, target);
        deshaderLib.linkLibrary(wolfssl);
    }
    const glModule = openGlModule(b);
    deshaderLib.addModule("gl", glModule);
    const vulkanXmlInput = b.build_root.join(b.allocator, &[_]String{"libs/Vulkan-Docs/xml/vk.xml"}) catch unreachable;
    const vkzig_dep = b.dependency("vulkan_zig", .{
        .registry = @as(String, vulkanXmlInput),
    });
    const vkzigBindings = vkzig_dep.module("vulkan-zig");
    deshaderLib.addModule("vulkan-zig", vkzigBindings);

    const options = b.addOptions();
    const optionGLAdditionalLoader = b.option(String, "GlAddLoader", "Name of additional exposed function which will call GL function loader");
    const optionVkAddInstanceLoader = b.option(String, "VkAddInstanceLoader", "Name of additional exposed function which will call Vulkan instance function loader");
    const optionVkAddDeviceLoader = b.option(String, "VkAddDeviceLoader", "Name of additional exposed function which will call Vulkan device function loader");
    options.addOption(?String, "GlAddLoader", optionGLAdditionalLoader);
    options.addOption(?String, "VkAddDeviceLoader", optionVkAddDeviceLoader);
    options.addOption(?String, "VkAddInstanceLoader", optionVkAddInstanceLoader);

    const positron = PositronSdk.getPackage(b, "positron");
    deshaderLib.addModule("positron", positron);
    PositronSdk.linkPositron(deshaderLib, null);
    //
    // Steps for building generated and embedded files
    //
    var stubGenCmd = b.step("generate_stubs", "Generate .zig file with function stubs for deshader library");
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
        const editorDirectory = "editor";
        const editorFiles = std.fs.cwd().readFileAlloc(b.allocator, editorDirectory ++ "/required.txt", 1024 * 1024) catch undefined;
        var editorFilesLines = std.mem.splitScalar(u8, editorFiles, '\n');
        editorFilesLines.reset();
        while (editorFilesLines.next()) |line| {
            appendFiles(deshaderLib, &files, .{
                std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ editorDirectory, line }) catch unreachable,
            }) catch unreachable;
        }

        // Add the file names as an option to the exe, making it available
        // as a string array at comptime in main.zig
        options.addOption([]const String, "files", files.items);
        options.addOption(String, "editorDir", editorDirectory);
        deshaderLib.addOptions("options", options);

        const deshaderLibCmd = b.step("deshader", "Install deshader library");
        deshaderLibCmd.dependOn(&b.addInstallArtifact(deshaderLib, .{}).step);

        //
        // Emit H File
        //
        const headerGenCmd = b.step("generate_header", "Generate C header file for deshader library");
        const headerGenExe = b.addExecutable(.{
            .name = "generate_header",
            .root_source_file = .{ .path = "src/tools/generate_header.zig" },
            .main_mod_path = .{ .path = "src" },
            .target = target,
            .optimize = optimize,
        });
        headerGenExe.addAnonymousModule("header_gen", .{
            .source_file = .{ .path = "libs/zig-header-gen/src/header_gen.zig" },
        });
        headerGenExe.addModule("positron", positron);
        headerGenExe.addModule("gl", glModule);
        if (optionWolfSSL) {
            headerGenExe.linkSystemLibrary("wolfssl");
        } else {
            headerGenExe.linkLibrary(wolfssl);
        }

        var headerGenOptions = b.addOptions();
        headerGenOptions.addOption([]const String, "files", &[_]String{});
        headerGenOptions.addOption(
            String,
            "emitHDir",
            std.fs.path.join(b.allocator, &[_]String{ b.install_path, "include" }) catch unreachable,
        );
        headerGenOptions.addOption(?String, "GlAddLoader", optionGLAdditionalLoader);
        headerGenOptions.addOption(?String, "VkAddInstanceLoader", optionVkAddInstanceLoader);
        headerGenOptions.addOption(?String, "VkAddDeviceLoader", optionVkAddDeviceLoader);
        headerGenExe.addOptions("options", headerGenOptions);
        PositronSdk.linkPositron(headerGenExe, null);
        const headerGenInstall = b.addInstallArtifact(headerGenExe, .{});
        headerGenCmd.dependOn(&headerGenInstall.step);
        deshaderLibCmd.dependOn(&b.addRunArtifact(headerGenInstall.artifact).step);

        //
        // Emit .zig file with function stubs
        //
        const emitExe: bool = b.option(bool, "emitExe", "Emit stub generator as an executable file") orelse false;
        if (emitExe) {
            // Create an executable that performs the stub generation with stdout as output
            const stubGenExe = b.addExecutable(.{
                .name = "generate_stubs",
                .root_source_file = .{ .path = "src/tools/generate_stubs.zig" },
                .optimize = optimize,
                .target = target,
                .main_mod_path = .{ .path = "src" },
            });
            stubGenCmd.dependOn(&b.addInstallArtifact(stubGenExe, .{}).step);
        } else {
            // Or generate them right here in the build process
            const stubGenSrc = @import("src/tools/generate_stubs.zig");
            var stubGen: *stubGenSrc.GenerateStubsStep = b.allocator.create(stubGenSrc.GenerateStubsStep) catch unreachable;
            stubGen.* = stubGenSrc.GenerateStubsStep.init(
                b,
                std.fs.createFileAbsolute(
                    std.fs.path.join(b.allocator, &[_]String{ b.install_path, "include", "deshader.zig" }) catch unreachable,
                    .{},
                ) catch unreachable,
            );
            stubGenCmd.dependOn(&stubGen.step);
            deshaderLibCmd.dependOn(&stubGen.step);
        }
    }

    //
    // Example usage demonstration application
    //
    const exampleStep = b.step("example", "Run example app with integrated deshader debugging");
    exampleStep.dependOn(&deshaderLib.step);

    const exampleExe = b.addExecutable(.{
        .name = "example",
        .root_source_file = .{ .path = "example/example.zig" },
        .main_mod_path = .{ .path = "example" },
        .target = target,
        .optimize = optimize,
    });
    exampleExe.linkLibrary(deshaderLib);
    exampleExe.addModule("gl", glModule);
    // Use mach-glfw
    const glfw_dep = b.dependency("mach_glfw", .{
        .target = exampleExe.target,
        .optimize = exampleExe.optimize,
    });
    exampleExe.addModule("mach-glfw", glfw_dep.module("mach-glfw"));
    @import("mach_glfw").link(glfw_dep.builder, exampleExe);
    exampleStep.dependOn(stubGenCmd);
    const deshaderStubs = b.addModule("deshader", .{
        .source_file = .{ .path = "zig-out/include/deshader.zig" },
    });
    exampleExe.addModule("deshader", deshaderStubs);
    exampleStep.dependOn(&b.addInstallArtifact(exampleExe, .{}).step);

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

fn appendFiles(step: *std.build.Step.Compile, files: *std.ArrayList(String), toAdd: anytype) !void {
    inline for (toAdd) |addThis| {
        step.addAnonymousModule(addThis, .{
            .source_file = std.build.FileSource.relative(addThis),
        });
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
        _ = progressNode;
        const self = @fieldParentPtr(PrintStep, "step", step);
        std.log.err("{s}", .{self.message});
    }
};
