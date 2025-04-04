const std = @import("std");
const options = @import("options");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const allocator = gpa.allocator();

    const base_dir = try std.fs.selfExeDirPathAlloc(allocator);

    for (options.exampleNames) |example_name| {
        const example_path = try std.fs.path.join(allocator, &.{ base_dir, "deshader-examples", example_name });
        std.log.debug("spawning {s}", .{example_path});
        var child_process = std.process.Child.init(&.{example_path}, allocator);

        printResult(try child_process.spawnAndWait());
    }
}

fn printResult(term: std.process.Child.Term) void {
    switch (term) {
        .Exited => |result| {
            if (result != 0) {
                std.log.warn("child exited with status code {}", .{result});
            }
        },
        .Signal => |signal| {
            std.log.warn("child exited with signal {}", .{signal});
        },
        .Stopped => |signal| {
            std.log.warn("child stopped with signal {}", .{signal});
        },
        .Unknown => |status| {
            std.log.warn("child exited with unknown status {}", .{status});
        },
    }
}
