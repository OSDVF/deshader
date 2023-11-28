const std = @import("std");
const String = []const u8;

pub const ListGlProcsStep = struct {
    step: std.build.Step,
    libNames: []const String,
    symbolPrefixes: []const String,
    symbolsOutput: std.build.LazyPath,
    generated_file: std.Build.GeneratedFile,

    pub fn init(b: *std.build.Builder, name: String, libNames: []const String, symbolPrefixes: []const String, symbolEnumeratorOutput: std.build.LazyPath) *@This() {
        const self = b.allocator.create(ListGlProcsStep) catch @panic("OOM");
        self.* = @This(){
            .step = std.build.Step.init(.{
                .owner = b,
                .id = .options,
                .name = name,
                .makeFn = make,
            }),
            .symbolsOutput = symbolEnumeratorOutput,
            .generated_file = undefined,
            .libNames = libNames,
            .symbolPrefixes = symbolPrefixes,
        };
        self.generated_file = .{ .step = &self.step };
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
                            try glProcs.put(self.step.owner.fmt("pub var {s}", .{symbolName.?}), {});
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
        var hash = step.owner.cache.hash;
        // Random bytes to make unique. Refresh this with new random bytes when
        // implementation is modified in a non-backwards-compatible way.
        hash.add(@as(u32, 0xad95e925));
        hash.addBytes(output);
        const h = hash.final();
        const sub_path = "c" ++ std.fs.path.sep_str ++ h ++ std.fs.path.sep_str ++ basename;

        self.generated_file.path = try step.owner.cache_root.join(step.owner.allocator, &.{sub_path});
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
            },
            else => |e| return step.fail("unable to access procs file '{}{s}': {s}", .{
                step.owner.cache_root, sub_path, @errorName(e),
            }),
        }
    }
};