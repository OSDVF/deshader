const std = @import("std");
const builtin = @import("builtin");
const memory = @import("../src/common/memory.zig");
const String = []const u8;

/// `make`s opengl definitions, installs node.js dependencies for the editor and editor extension, and builds VCPKG dependencies for Windows
pub const DependenciesStep = struct {
    step: std.Build.Step,
    target: std.Target,
    sub_steps: std.ArrayList(SubStep),
    no_fail: bool = false,
    env_map: *std.process.EnvMap,

    const SubStep = struct {
        name: String,
        args: ?[]const String = null,
        cwd: ?String = null,
        process: ?std.process.Child = null,
        progress_node: std.Progress.Node = undefined,
        create: ?*const fn (step: *std.Build.Step, progressNode: std.Progress.Node, arg: ?String) anyerror!void = null,
        arg: ?String = null,
        after: ?[]SubStep = null,

        fn deinit(self: *SubStep, allocator: std.mem.Allocator) void {
            if (self.args) |a|
                allocator.free(a);
            if (self.after) |a| {
                for (a) |aa| {
                    aa.deinit(allocator);
                }
                allocator.free(a);
            }
        }
    };

    pub fn init(b: *std.Build, name: String, target: std.Target, env: *std.process.EnvMap) DependenciesStep {
        return DependenciesStep{
            .env_map = env,
            .target = target,
            .step = std.Build.Step.init(
                .{
                    .name = name,
                    .makeFn = DependenciesStep.doStep,
                    .owner = b,
                    .id = .custom,
                },
            ),
            .sub_steps = std.ArrayList(SubStep).init(b.allocator),
        };
    }

    pub fn initSubprocess(self: *DependenciesStep, argv: []const String, cwd: ?String) !std.process.Child {
        return .{
            .id = undefined,
            .allocator = self.step.owner.allocator,
            .argv = argv,
            .cwd = cwd,
            .env_map = self.env_map,
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

    fn noFail(self: *DependenciesStep, step: String, err: anytype, trace: ?*std.builtin.StackTrace) !void {
        if (!self.no_fail) {
            return self.step.fail("Dependecy build step \"{s}\" failed: {} trace: {?}", .{ step, err, trace });
        } else {
            std.log.err("Dependecy build step \"{s}\" failed: {}", .{ step, err });
        }
    }

    pub fn doStep(step: *std.Build.Step, progressNode: std.Progress.Node) anyerror!void {
        const self: *DependenciesStep = @fieldParentPtr("step", step);
        try self.env_map.put("ZIG_PATH", self.step.owner.graph.zig_exe);

        defer self.sub_steps.deinit();

        const node = progressNode.start("Dependencies", self.sub_steps.items.len);

        try self.doSubSteps(self.sub_steps.items, node);

        defer node.end();
    }

    pub fn editor(self: *DependenciesStep) !void {
        // Check for Bun
        var bun_out: u8 = undefined;
        if (self.step.owner.runAllowFail(&.{ "bun", "--version" }, &bun_out, .Inherit)) |output| check: {
            const version = std.SemanticVersion.parse(std.mem.trim(u8, output, " \t\n")) catch |err| {
                std.log.err("Could not parse Bun version: {}", .{err});
                break :check;
            };
            if (!(version.major >= 1 and version.minor >= 1 and version.patch >= 34)) {
                std.log.err("Bun is older than 1.1.34, please update it by running 'bun upgrade'", .{});
            }
        } else |err| {
            std.log.info("Error when checking Bun version {})", .{err});
        }

        // Init
        const deshaderVsCodeExt = "editor/deshader-vscode";
        const compile_verb = if (self.step.owner.release_mode == .off) "compile-prod" else "compile-dev";
        try self.sub_steps.append(.{
            .name = "Installing node.js dependencies by Bun for deshader-vscode",
            .args = try self.step.owner.allocator.dupe(String, &.{ "bun", "install", "--frozen-lockfile" }),
            .cwd = deshaderVsCodeExt,
            .after = try self.step.owner.allocator.dupe(SubStep, &[_]SubStep{
                .{ .name = "Compiling deshader-vscode extension", .args = try self.step.owner.allocator.dupe(String, &.{ "bun", compile_verb }), .cwd = deshaderVsCodeExt },
            }),
        });
        try self.sub_steps.append(.{ .name = "Installing node.js dependencies by Bun for editor", .args = try self.step.owner.allocator.dupe(String, &.{ "bun", "install", "--frozen-lockfile", "--production" }), .cwd = "editor" });
    }

    pub fn vcpkg(self: *DependenciesStep, triplet: ?String) !void {
        // TODO overlay to empty port when system library is available
        if (self.target.os.tag == .macos and builtin.os.tag != .macos) {
            compileInstallNameTool(self.step.owner);
        }
        const step = self.step;
        const debug = self.step.owner.release_mode == .off;
        const use_triplet: String = triplet orelse try std.mem.concat(step.owner.allocator, u8, &.{ (if (self.target.cpu.arch == .x86) "x86" else "x64") ++ "-", switch (self.target.os.tag) {
            .windows => "windows",
            .linux => "linux",
            .macos => if (builtin.os.tag == .macos) "osx" else "osx-zig",
            else => @panic("Unsupported OS"),
        }, if (self.target.os.tag == .windows and self.target.abi != .msvc) (if (debug) "-zig-dbg" else "-zig-rel") else "" });

        const sub_sub = try self.step.owner.allocator.dupe(SubStep, &[_]SubStep{SubStep{
            .name = "Rename VCPKG artifacts",
            .create = struct {
                // After building VCPKG libraries rename the output files
                fn create(step2: *std.Build.Step, _: std.Progress.Node, tripl: ?String) anyerror!void {
                    const debug2 = step2.owner.release_mode == .off;
                    std.log.info("Renaming VCPKG artifacts", .{});
                    const bin_path = step2.owner.pathJoin(&.{ "build", "vcpkg_installed", tripl.?, if (debug2) "debug" else "", "bin" });
                    defer step2.owner.allocator.free(bin_path);
                    try doOnEachFileIf(step2, bin_path, hasLibPrefix, removeLibPrefix);
                    try doOnEachFileIf(step2, bin_path, hasWrongSuffix, renameSuffix);
                    const lib_path = step2.owner.pathJoin(&.{ "build", "vcpkg_installed", tripl.?, if (debug2) "debug" else "", "lib" });
                    defer step2.owner.allocator.free(lib_path);
                    try doOnEachFileIf(step2, lib_path, hasLibPrefix, removeLibPrefix);
                    try doOnEachFileIf(step2, lib_path, hasWrongSuffix, renameSuffix);
                }
            }.create,
            .arg = use_triplet,
        }});

        try self.sub_steps.append(.{
            .name = "Building VCPKG dependencies",
            .args = step.owner.dupeStrings(&.{ "vcpkg", "install", "--triplet", use_triplet, "--x-install-root=build/vcpkg_installed" }),
            .after = if (self.target.os.tag == .windows) sub_sub else null,
        });
    }

    fn doSubSteps(self: *DependenciesStep, sub_steps: []SubStep, progressNode: std.Progress.Node) !void {
        // Spawn
        for (sub_steps) |*sub_step| {
            if (sub_step.create) |c| {
                try c(&self.step, progressNode, sub_step.arg);
            }
            if (sub_step.args) |args| {
                var sub_process = try self.initSubprocess(args, sub_step.cwd);
                if (self.step.owner.verbose) {
                    const joined = try std.mem.join(self.step.owner.allocator, " ", sub_process.argv);
                    defer self.step.owner.allocator.free(joined);
                    std.log.info("Running: {s} in dir {?s}", .{ joined, sub_process.cwd });
                }
                if (sub_process.spawn()) {
                    const sub_progress_node = progressNode.start(sub_step.name, 1);
                    sub_step.process = sub_process;
                    sub_step.progress_node = sub_progress_node;
                } else |err| try self.noFail(sub_step.name, err, @errorReturnTrace());
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
                        try self.doSubSteps(after, progressNode);
                    }
                } else |err| try self.noFail(sub_step.name, err, @errorReturnTrace());

                progressNode.setCompletedItems(i + 1);
                defer sub_step.progress_node.end();
            }
            //sub_step.deinit(self.step.owner.allocator);
        }
    }

    fn doOnEachFileIf(step: *std.Build.Step, path: String, predicate: *const fn (name: String) bool, func: *const fn (alloc: std.mem.Allocator, dir: std.fs.Dir, file: std.fs.Dir.Entry) void) !void {
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
        return std.mem.startsWith(u8, name, "lib") and !std.mem.endsWith(u8, name, ".a") and !std.mem.endsWith(u8, name, ".dll");
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

fn compileInstallNameTool(b: *std.Build) void { // is used within VCPKG and CMake build process when building for macOS
    _ = b.build_root.handle.access("build/install_name_tool", .{}) catch
        b.run(&.{ b.graph.zig_exe, "c++", "bootstrap/install_name_tool/src/install_name_tool.cpp", "bootstrap/install_name_tool/src/patchelf.cpp", "-I", "bootstrap/install_name_tool/include", "-o", "build/install_name_tool" });
}
