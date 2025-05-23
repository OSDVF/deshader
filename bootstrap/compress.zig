const std = @import("std");

pub const CompressStep = struct {
    step: std.Build.Step,
    source: std.Build.LazyPath,
    generatedFile: std.Build.GeneratedFile,

    pub fn init(b: *std.Build, source: std.Build.LazyPath) !*@This() {
        var self = try b.allocator.create(@This());
        self.* = .{
            .source = source,
            .step = std.Build.Step.init(.{ .id = .custom, .makeFn = make, .name = "compress", .owner = b }),
            // SAFETY: assigned right after
            .generatedFile = undefined,
        };
        self.generatedFile = .{ .step = &self.step };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        const self: *@This() = @fieldParentPtr("step", step);
        const node = options.progress_node.start(step.owner.fmt("compressing {s}", .{self.source.getPath(step.owner)}), 1);

        self.wrapped() catch |err| {
            try step.addError("compressing failed: {s} at {?}", .{ @errorName(err), @errorReturnTrace() });
        };

        defer node.end();
    }

    fn wrapped(self: *@This()) !void {
        var step = &self.step;
        const source = self.source.getPath(step.owner);
        const reader = std.fs.openFileAbsolute(source, .{}) catch |e| {
            return step.fail("unable to open file '{s}': {s}", .{ source, @errorName(e) });
        };

        const read = reader.readToEndAlloc(self.step.owner.allocator, 20 * 1024 * 1024) catch |e| {
            return step.fail("unable to read file '{s}': {s}", .{ source, @errorName(e) });
        };
        var man = step.owner.graph.cache.obtain();
        defer man.deinit();
        // Random bytes to make unique. Refresh this with new random bytes when
        // implementation is modified in a non-backwards-compatible way.
        man.hash.add(@as(u32, 0xad95e922));
        man.hash.addBytes(read);
        const dest = step.owner.pathJoin(&.{ "c", "compressed", &man.hash.final(), std.fs.path.basename(source) });
        self.generatedFile.path = try step.owner.cache_root.join(self.step.owner.allocator, &.{dest});
        if (try step.cacheHit(&man)) {
            // This is the hot path, success.
            return;
        }

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
        var stream = std.io.fixedBufferStream(read);
        try std.compress.zlib.compress(stream.reader(), file.writer(), .{});

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

        try step.writeManifest(&man);
    }
};
