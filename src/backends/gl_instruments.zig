const std = @import("std");
const shaders = @import("../services/shaders.zig");
const instruments = @import("../services/instruments.zig");
const commands = @import("../commands.zig");
const decls = @import("../declarations/instruments.zig");
const log = @import("common").log;
const gl = @import("gl");

const uvec2 = struct { u32, u32 };

// TODO: maybe make the instruments stateful?
pub const Step = struct {
    const id = instruments.Step.id;

    pub fn onBeforeDraw(_: *shaders, instrumentation: *shaders.InstrumentationResult) anyerror!void {
        // Update uniforms
        const program = instrumentation.stages.values()[0].params.context.program;
        if (instrumentation.uniforms_invalidated) if (instruments.Step.controls(&program.channels)) |controls| {
            if (controls.desired_step) |target| {
                const step_selector_ref = gl.GetUniformLocation(program.ref, instruments.Step.desired_step);
                if (step_selector_ref >= 0) {
                    gl.Uniform1ui(step_selector_ref, target);
                    log.debug("Setting desired step to {d}", .{target});
                } else {
                    log.warn("Could not find step selector uniform in program {x}", .{program.ref});
                }

                const bp_selector = gl.GetUniformLocation(program.ref, instruments.Step.desired_bp);
                if (bp_selector >= 0) {
                    gl.Uniform1ui(bp_selector, @intCast(controls.desired_bp));
                    log.debug("Setting desired breakpoint to {d}", .{controls.desired_bp});
                } else log.warn("Could not find bp selector uniform in program {x}", .{program.ref});
            }
        };
    }

    pub fn onResult(service: *shaders, instrumentation: *const shaders.InstrumentationResult, _: *const decls.PlatformParamsGL) anyerror!void {
        var it = instrumentation.stages.iterator();
        while (it.next()) |entry| {
            var bp_hit_ids = std.AutoArrayHashMapUnmanaged(usize, void){};
            defer bp_hit_ids.deinit(service.allocator);

            var selected_thread_rstep: ?usize = null;
            const instr_state = entry.value_ptr.*;
            const shader_ref = entry.key_ptr.*;
            const shader: *std.ArrayListUnmanaged(shaders.Shader.SourcePart) = service.Shaders.all.get(shader_ref) orelse {
                log.warn("Shader {d} not found in the database", .{shader_ref});
                continue;
            };

            const selected_thread = instr_state.globalSelectedThread();
            // Retrieve the hit storage
            if (instr_state.channels.out.get(instruments.Step.id)) |stor| if (stor.readback.data) |data| {
                const threads_hits = std.mem.bytesAsSlice(
                    uvec2,
                    data,
                );
                // Scan for hits
                var max_hit: u32 = 0;
                var max_hit_id: u32 = 0;
                for (0..instr_state.channels.totalThreadsCount()) |global_index| {
                    const hit: uvec2 = threads_hits[global_index];
                    if (hit[1] > 0) { // 1-based (0 means no hit)
                        const hit_id = hit[0];
                        const hit_index = hit[1] - 1;
                        // find the corresponding step index for SourceInterface
                        const offsets = if (instr_state.channels.of) |pos| for (0.., pos) |i, po| {
                            if (po >= hit_id) {
                                break .{ i, po };
                            }
                        } else .{ 0, 0 } else null;
                        if (offsets) |off| {
                            const source_part = shader.items[off[0]];
                            const local_hit_id = hit_id - off[1];
                            if (source_part.breakpoints.contains(local_hit_id)) // Maybe should be stored in Result.Channels instead as snapshot (more thread-safe?)
                                _ = try bp_hit_ids.getOrPut(service.allocator, local_hit_id);
                        }

                        if (global_index == selected_thread) {
                            instr_state.reached_step = .{ .index = hit_index, .id = hit_id };
                            log.debug("Selected thread reached step ID {d} index {d}", .{ hit_id, hit_index });
                            if (offsets) |off| {
                                selected_thread_rstep = hit_id - off[1];
                            }
                        }
                        if (hit_index >= max_hit) {
                            max_hit = hit_index;
                            max_hit_id = hit_id;
                        }
                    }
                }

                if (instr_state.reached_step == null and !shaders.single_pause_mode) {
                    // TODO should not really occur
                    log.err("Stop was not reached but breakpoint was", .{});
                    if (max_hit != 0) {
                        instr_state.reached_step = .{ .id = max_hit_id, .index = max_hit };
                    }
                }

                const running = try shaders.Running.Locator.from(service, shader_ref);
                if (bp_hit_ids.count() > 0) {
                    if (commands.instance) |comm| {
                        try comm.eventBreak(.stopOnBreakpoint, .{
                            .ids = bp_hit_ids.keys(),
                            .shader = running.impl,
                        });
                    }
                } else if (selected_thread_rstep) |reached_step| {
                    if (commands.instance) |comm| {
                        try comm.eventBreak(.stop, .{
                            .step = reached_step,
                            .shader = running.impl,
                        });
                    }
                }
            };
        }
    }
};

const MAX_VARIABLES_SIZE = 1024 * 1024; // 1MB

pub const Variables = struct {
    variables_buffer: [MAX_VARIABLES_SIZE]u8 = undefined,
};

pub const StackTrace = struct {
    stack_trace_buffer: [shaders.STACK_TRACE_MAX]shaders.StackTraceT = undefined,

    pub fn onBeforeDraw(_: *shaders, instrumentation: *shaders.InstrumentationResult) anyerror!void {
        // Update uniforms
        if (instrumentation.uniforms_invalidated) {
            for (instrumentation.stages.keys(), instrumentation.stages.values()) |shader_ref, state| {
                if (state.channels.controls.get(instruments.StackTrace.thread_selector_id)) |thread_selector_ident| {
                    const thread_select_ref = gl.GetUniformLocation(instrumentation.stages.values()[0].params.context.program, @ptrCast(thread_selector_ident));
                    if (thread_select_ref >= 0) {
                        const selected_thread = state.globalSelectedThread();
                        gl.Uniform1ui(thread_select_ref, @intCast(selected_thread));
                        log.debug("Setting selected thread to {d}", .{selected_thread});
                    } else {
                        log.warn("Could not find thread selector uniform in shader {x}", .{shader_ref});
                    }
                }
            }
        }
    }
};
