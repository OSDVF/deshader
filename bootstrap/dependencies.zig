const std = @import("std");
const builtin = @import("builtin");
const String = []const u8;

pub const DependenciesStep = struct {
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

        const env_map: *std.process.EnvMap = try self.step.owner.allocator.create(std.process.EnvMap);
        env_map.* = try std.process.getEnvMap(step.owner.allocator);
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
