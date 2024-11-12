const std = @import("std");
const String = []const u8;

/// Parse output from `nm` or `dumpbin` and generate a list of symbols.
pub const ListGlProcsStep = struct {
    step: std.Build.Step,
    libNames: []const String,
    symbolPrefixes: []const String,
    symbolsOutput: std.Build.LazyPath,
    generated_file: std.Build.GeneratedFile,
    target: std.Target.Os.Tag,

    pub fn init(b: *std.Build, target: std.Target.Os.Tag, name: String, libNames: []const String, symbolPrefixes: []const String, symbolEnumeratorOutput: std.Build.LazyPath) *@This() {
        const self = b.allocator.create(ListGlProcsStep) catch @panic("OOM");
        self.* = @This(){
            .step = std.Build.Step.init(.{
                .owner = b,
                .id = .options,
                .name = name,
                .makeFn = make,
            }),
            .symbolsOutput = symbolEnumeratorOutput,
            .generated_file = undefined,
            .libNames = libNames,
            .symbolPrefixes = symbolPrefixes,
            .target = target,
        };
        self.generated_file = .{ .step = &self.step };
        return self;
    }

    fn make(step: *std.Build.Step, progressNode: std.Progress.Node) anyerror!void {
        const node = progressNode.start("List GL procs", 1);
        defer node.end();
        const self: *@This() = @fieldParentPtr("step", step);
        const symbolsFile = try std.fs.cwd().openFile(self.symbolsOutput.generated.file.getPath(), .{});
        const reader = symbolsFile.reader();
        var glProcs = std.StringArrayHashMap(void).init(step.owner.allocator);
        defer glProcs.deinit();
        while (try reader.readUntilDelimiterOrEofAlloc(self.step.owner.allocator, '\n', 1024 * 1024)) |symbolsLine| {
            defer self.step.owner.allocator.free(symbolsLine);
            var tokens = std.mem.tokenizeScalar(u8, symbolsLine, ' ');
            const libName = tokens.next();
            const symbolNameUnix = tokens.next();
            if (self.target == .windows) {
                const offset = tokens.next();
                if (offset == null) { //one more not needed token for windows
                    continue;
                }
            }
            if (libName == null or symbolNameUnix == null) {
                continue;
            }
            if (self.target == .windows) {
                const symbolNameWindows = tokens.next();
                if (symbolNameWindows == null) {
                    continue;
                }
                for (self.symbolPrefixes) |prefix| {
                    if (std.mem.startsWith(u8, symbolNameWindows.?, prefix)) {
                        try glProcs.put(self.step.owner.fmt("pub var {s}", .{symbolNameWindows.?}), {});
                    }
                }
            } else for (self.libNames) |selfLibName| {
                if (std.mem.indexOf(u8, libName.?, selfLibName) != null) {
                    for (self.symbolPrefixes) |prefix| { // macOS symbols are prefixed with underscore
                        if (std.mem.startsWith(u8, if (self.target == .macos) symbolNameUnix.?[1..] else symbolNameUnix.?, prefix)) {
                            try glProcs.put(self.step.owner.fmt("pub var {s}", .{symbolNameUnix.?}), {});
                        }
                    }
                }
            }
        }
        try glProcs.put("", {});
        const output = try std.mem.join(step.owner.allocator, ":?*const anyopaque = undefined;\n", glProcs.keys());
        // This is more or less copied from Options step.
        const basename = "procs.zig";

        // Hash contents to file name.
        var man = step.owner.graph.cache.obtain();
        defer man.deinit();
        // Random bytes to make unique. Refresh this with new random bytes when
        // implementation is modified in a non-backwards-compatible way.
        man.hash.add(@as(u32, 0xad95e921));
        man.hash.addBytes(output);
        const h = man.hash.final();
        const sub_path = "c" ++ std.fs.path.sep_str ++ h ++ std.fs.path.sep_str ++ basename;

        self.generated_file.path = try step.owner.cache_root.join(step.owner.allocator, &.{sub_path});
        if (try step.cacheHit(&man)) {
            // This is the hot path, success.
            return;
        }
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
        const tmp_sub_path_dirname = std.fs.path.dirname(tmp_sub_path).?;

        step.owner.cache_root.handle.makePath(tmp_sub_path_dirname) catch |err| {
            return step.fail("unable to make temporary directory '{}{s}': {s}", .{
                step.owner.cache_root, tmp_sub_path_dirname, @errorName(err),
            });
        };

        step.owner.cache_root.handle.writeFile(.{ .data = output, .sub_path = tmp_sub_path }) catch |err| {
            return step.fail("unable to write procs to '{}{s}': {s}", .{
                step.owner.cache_root, tmp_sub_path, @errorName(err),
            });
        };
        const count = try std.fmt.allocPrint(step.owner.allocator, "pub const count = {d};", .{glProcs.count()});
        defer step.owner.allocator.free(count);

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

        try step.writeManifest(&man);
    }
};
