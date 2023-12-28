const std = @import("std");
const builtin = @import("builtin");
const String = []const u8;

/// `make`s opengl definitions, installs node.js dependencies for the editor and editor extension, and builds VCPKG dependencies for Windows
pub const DependenciesStep = struct {
    step: std.build.Step,
    target: std.zig.CrossTarget,
    vcpgk: bool,

    const SubStep = struct {
        name: String,
        args: ?[]const String = null,
        cwd: ?String = null,
        env_map: ?*std.process.EnvMap = null,
        process: ?std.process.Child = null,
        progress_node: std.Progress.Node = undefined,
        create: ?*const fn (step: *std.build.Step, progressNode: *std.Progress.Node, arg: ?*const anyopaque) anyerror!void = null,
        arg: ?*const anyopaque = null,
        after: ?[]SubStep = null,
    };

    pub fn init(b: *std.build.Builder, target: std.zig.CrossTarget, vcpkg: bool) DependenciesStep {
        return DependenciesStep{
            .target = target,
            .vcpgk = vcpkg,
            .step = std.build.Step.init(
                .{
                    .name = "dependencies",
                    .makeFn = DependenciesStep.doStep,
                    .owner = b,
                    .id = .custom,
                },
            ),
        };
    }

    pub fn initSubprocess(self: *DependenciesStep, argv: []const String, cwd: ?String, env_map: ?*std.process.EnvMap) std.process.Child {
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

    fn noFail(step: String, err: anytype) void {
        std.log.err("Dependecy build step \"{s}\" failed: {}", .{ step, err });
    }

    pub fn doStep(step: *std.build.Step, progressNode: *std.Progress.Node) anyerror!void {
        const self: *DependenciesStep = @fieldParentPtr(DependenciesStep, "step", step);

        var sub_steps = std.ArrayList(SubStep).init(step.owner.allocator);
        defer sub_steps.deinit();

        const env_map: *std.process.EnvMap = try self.step.owner.allocator.create(std.process.EnvMap);
        env_map.* = try std.process.getEnvMap(step.owner.allocator);
        try env_map.put("NOTEST", "y");

        progressNode.setEstimatedTotalItems(6);
        progressNode.activate();

        // Init
        try sub_steps.append(.{ .name = "Building OpenGL definitions", .args = &.{ "make", "all" }, .env_map = env_map, .cwd = "./libs/zig-opengl" });
        const bunInstallCmd = if (builtin.os.tag == .windows) [_]String{ "wsl", "--exec", "bash", "-c", "~/.bun/bin/bun install --frozen-lockfile" } else [_]String{ "bun", "install", "--frozen-lockfile" };
        const deshaderVsCodeExt = "editor/deshader-vscode";
        try sub_steps.append(.{ .name = "Installing node.js dependencies by Bun for deshader-vscode", .args = &bunInstallCmd, .env_map = env_map, .cwd = deshaderVsCodeExt });
        try sub_steps.append(.{ .name = "Installing node.js dependencies by Bun for editor", .args = &bunInstallCmd ++ &[_]String{"--production"}, .env_map = env_map, .cwd = "editor" });
        try sub_steps.append(.{ .name = "Compiling deshader-vscode extension", .args = if (builtin.os.tag == .windows) &.{ "wsl", "--exec", "bash", "-c", "~/.bun/bin/bun compile web" } else &.{ "bun", "compile-web" }, .env_map = env_map, .cwd = deshaderVsCodeExt });

        if (self.vcpgk) {
            const triplet = try std.mem.concat(step.owner.allocator, u8, &.{ (if (self.target.getCpuArch() == .x86) "x86" else "x64") ++ "-", switch (self.target.getOsTag()) {
                .windows => "windows",
                .linux => "linux",
                .macos => "osx",
                else => @panic("Unsupported OS"),
            }, if (self.target.getOsTag() != builtin.os.tag) "-cross" else "" });

            var sub_sub = [_]SubStep{SubStep{
                .name = "Rename VCPKG artifact",
                .create = struct {
                    // After building VCPKG libraries rename the output files
                    fn create(step2: *std.build.Step, _: *std.Progress.Node, arg: ?*const anyopaque) anyerror!void {
                        std.log.info("Renaming VCPKG artifacts", .{});
                        const tripl = @as(*const String, @alignCast(@ptrCast(arg)));
                        const bin_path = try std.fs.path.join(step2.owner.allocator, &.{ "build", "vcpkg_installed", tripl.*, "bin" });
                        defer step2.owner.allocator.free(bin_path);
                        //try doOnEachFileIf(step2, bin_path, hasLibPrefix, removeLibPrefix);
                        try doOnEachFileIf(step2, bin_path, hasWrongSuffix, renameSuffix);
                        const lib_path = try std.fs.path.join(step2.owner.allocator, &.{ "build", "vcpkg_installed", tripl.*, "lib" });
                        defer step2.owner.allocator.free(lib_path);
                        //try doOnEachFileIf(step2, lib_path, hasLibPrefix, removeLibPrefix);
                        try doOnEachFileIf(step2, lib_path, hasWrongSuffix, renameSuffix);
                        step2.owner.allocator.free(tripl.*);
                    }
                }.create,
                .arg = @ptrCast(&triplet),
            }};

            try sub_steps.append(.{
                .name = "Building VCPKG dependencies",
                .args = &.{ "vcpkg", "install", "--triplet", triplet, "--x-install-root=build/vcpkg_installed" },
                .after = if (self.target.getOsTag() == .windows and builtin.os.tag != .windows) &sub_sub else null,
            });
        }

        progressNode.setEstimatedTotalItems(sub_steps.items.len);

        self.doSubSteps(sub_steps.items, progressNode);

        progressNode.end();
    }

    fn doSubSteps(self: *DependenciesStep, sub_steps: []SubStep, progressNode: *std.Progress.Node) void {
        // Spawn
        for (sub_steps) |*sub_step| {
            if (sub_step.create) |c| {
                c(&self.step, progressNode, sub_step.arg) catch |err| {
                    std.log.err("Could not create sub-step {s}: {}", .{ sub_step.name, err });
                };
            }
            if (sub_step.args) |args| {
                var sub_process = self.initSubprocess(args, sub_step.cwd, sub_step.env_map);
                if (sub_process.spawn()) {
                    var sub_progress_node = progressNode.start(sub_step.name, 1);
                    sub_progress_node.activate();
                    sub_step.process = sub_process;
                    sub_step.progress_node = sub_progress_node;
                } else |err| noFail(sub_step.name, err);
            }
        }

        // Wait
        for (sub_steps, 0..) |*sub_step, i| {
            if (sub_step.process) |*proc| {
                if (proc.wait()) |result| {
                    if (result.Exited != 0) {
                        std.log.err("Dependency build step \"{s}\" failed with exit code {d}", .{ sub_step.name, result.Exited });
                    }
                    if (sub_step.after) |after| {
                        self.doSubSteps(after, progressNode);
                    }
                } else |err| {
                    std.log.err("Dependency build step \"{s}\" failed: {}", .{ sub_step.name, err });
                }

                progressNode.setCompletedItems(i + 1);
                sub_step.progress_node.end();
            }
        }
    }

    fn doOnEachFileIf(step: *std.build.Step, path: String, predicate: *const fn (name: String) bool, func: *const fn (alloc: std.mem.Allocator, dir: std.fs.Dir, file: std.fs.Dir.Entry) void) !void {
        var dir = try step.owner.build_root.handle.openDir(path, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterateAssumeFirstIteration();
        while (try it.next()) |file| {
            if (file.kind == .file) {
                if (predicate(file.name)) {
                    func(step.owner.allocator, dir, file);
                }
            }
        }
    }

    fn hasLibPrefix(name: String) bool {
        return std.mem.startsWith(u8, name, "lib");
    }

    fn hasWrongSuffix(name: String) bool {
        return std.mem.endsWith(u8, name, "dll.a");
    }

    fn removeLibPrefix(_: std.mem.Allocator, dir: std.fs.Dir, file: std.fs.Dir.Entry) void {
        dir.rename(file.name, file.name[3..]) catch |err| {
            std.log.err("Could not rename prefix {s}: {}", .{ file.name, err });
        };
    }

    fn renameSuffix(alloc: std.mem.Allocator, dir: std.fs.Dir, file: std.fs.Dir.Entry) void {
        const new_name = std.mem.concat(alloc, u8, &.{ file.name[0 .. file.name.len - 5], if (file.name[file.name.len - 6] == '.') "" else ".", "lib" }) catch @panic("OOM");
        defer alloc.free(new_name);
        dir.rename(file.name, new_name) catch |err| {
            std.log.err("Could not rename suffix {s}: {}", .{ file.name, err });
        };
    }
};
