const std = @import("std");
const gl = @import("gl");
const common = @import("../common.zig");

const loaders = @import("loaders.zig");
const APIs = @import("loaders.zig").APIs;
const DeshaderLog = @import("../log.zig").DeshaderLog;

const String = []const u8;

//
// Graphics API interception with trampoline generators
//
pub const TransitiveSymbols = struct {
    var mapping: [@import("transitive_exports_count").count]gl.FunctionPointer = undefined;
    var context_count: usize = 0;

    fn create(comptime index: usize) type { // Trampoline generator
        return struct { // Captures `i` and `RecursiveSymbols.mapping[]`
            fn intercepted() callconv(.Naked) noreturn { // Naked trampoline preserves caller arguments
                @setRuntimeSafety(false);
                asm volatile ("jmp *%[target]"
                    : //no outputs
                    : [target] "r" (mapping[index]), // inputs
                );
            }
        };
    }
    // Fill the mappings
    pub fn loadOriginal() !void {
        comptime var count: usize = 0;
        comptime var names: []String = undefined;

        // Export all known GL and VK functions
        comptime {
            //
            // Transitively export all GL, VK and system-specific (GLX, EGL) functions
            //
            var recursive_procs = std.mem.splitScalar(u8, @embedFile("transitive_exports"), '\n');
            {
                @setEvalBranchQuota(150000); // Really a lot of functions to export
                var i = 0;
                eachRecursiveProc: inline while (recursive_procs.next()) |symbol_name| {
                    inline for (loaders.all_exported_names) |exported| {
                        if (exported != null and std.mem.eql(u8, exported.?, symbol_name)) {
                            continue :eachRecursiveProc;
                        }
                    }
                    defer i += 1;

                    @export(create(i).intercepted, .{ .name = symbol_name });
                }

                count = i;
                recursive_procs.reset();
            }

            //
            // A second pass to fill `names` array
            //
            {
                var new_names: [count]String = undefined;
                names = &new_names;

                comptime var i = 0;
                eachRecursiveProc: inline while (recursive_procs.next()) |symbol_name| {
                    inline for (loaders.all_exported_names) |exported| {
                        if (exported != null and std.mem.eql(u8, exported.?, symbol_name)) {
                            continue :eachRecursiveProc;
                        }
                    }
                    defer i += 1;
                    names[i] = symbol_name;
                }
            }
        } // end comptime

        //
        // Runtime loadOriginal() code
        //

        // Fill the mappings array
        var i: usize = 0;
        inline for (names) |symbol_name| {
            defer i += 1;
            const prefix = symbol_name[0];
            var lib = switch (prefix) { // TODO specify different mapping discriminator than a prefix
                'g' => APIs.gl.glX.lib,
                'v' => APIs.vk.lib.?,
                'e' => APIs.gl.egl.lib,
                'w' => APIs.gl.wgl.lib,
                else => @panic(try std.fmt.allocPrint(common.allocator, "Unknown GL or VK function prefix: {c}", .{prefix})),
            };
            const with_null = try common.allocator.dupeZ(u8, symbol_name);
            defer common.allocator.free(with_null);

            const symbol_target = lib.?.lookup(gl.FunctionPointer, with_null);
            if (symbol_target != null) {
                mapping[i] = symbol_target.?;
            } else {
                DeshaderLog.err("Failed to find symbol {s}", .{symbol_name});
            }
        }
    }
};
