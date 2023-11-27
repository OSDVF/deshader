const std = @import("std");
const builtin = @import("builtin");
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
    const transitive_procs = @import("transitive_exports");

    fn createCBackendTrampoline(comptime target: *?*const anyopaque) type {
        // Trampoline generator
        return struct { // Captures `target`
            fn intercepted() callconv(.Naked) noreturn { // Naked trampoline preserves caller arguments
                @setRuntimeSafety(false);
                // This is a workaround to support C backend with many different compilers
                // Because they can use any register for storing [target]
                asm volatile ("push %%rbx");
                asm volatile ("push %%rcx");
                asm volatile ("mov %[target], %%rax"
                    :
                    : [target] "X" (target),
                    : "rax"
                );
                asm volatile ("mov (%%rax), %%rax"); //dereference target
                asm volatile ("pop %%rcx");
                asm volatile ("pop %%rbx");
                asm volatile ("jmp *%%rax");
            }
        };
    }
    fn createTrampoline(comptime target: String) type {
        // Trampoline generator
        return struct { // Captures `target`
            fn intercepted() callconv(.Naked) noreturn { // Naked trampoline preserves caller arguments
                @setRuntimeSafety(false);
                asm volatile ("jmp *%[target]" //Zig compiler respects the rax constraint so we dont need to save other registers
                    :
                    : [target] "{rax}" (@field(transitive_procs, target)),
                    : "rax"
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
            // First pass to count the number of functions to export
            const recursive_procs_decls = @typeInfo(transitive_procs).Struct.decls;
            {
                @setEvalBranchQuota(150000); // Really a lot of functions to export
                var i = 0;
                eachRecursiveProc: inline for (recursive_procs_decls) |decl| {
                    const symbol_name = decl.name;
                    inline for (loaders.all_exported_names) |exported| {
                        if (exported != null and std.mem.eql(u8, exported.?, symbol_name)) {
                            continue :eachRecursiveProc;
                        }
                    }
                    const symbol = if (builtin.target.ofmt == .c) //
                        createCBackendTrampoline(&@field(transitive_procs, symbol_name)).intercepted
                    else
                        createTrampoline(symbol_name).intercepted;
                    @export(symbol, .{ .name = symbol_name });
                    defer i += 1;
                }

                count = i;
            }

            //
            // A second pass to fill `names` and `mapping` array
            //
            {
                var new_names: [count]String = undefined;
                names = &new_names;

                comptime var i = 0;
                eachRecursiveProc: inline for (recursive_procs_decls) |decl| {
                    const symbol_name = decl.name;
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
        inline for (names) |symbol_name| {
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
                @field(transitive_procs, symbol_name) = symbol_target.?;
            } else {
                DeshaderLog.err("Failed to find symbol {s}", .{symbol_name});
            }
        }
    }
};
