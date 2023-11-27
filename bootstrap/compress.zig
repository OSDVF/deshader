const std = @import("std");

pub const CompressStep = struct {
    step: std.build.Step,
    source: std.build.LazyPath,
    generatedFile: std.Build.GeneratedFile,

    pub fn init(b: *std.build.Builder, source: std.build.LazyPath) !*@This() {
        var self = try b.allocator.create(@This());
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
