// Copyright (C) 2025  Ondřej Sabela
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const shaders = @import("../services/shaders.zig");
const instruments = @import("../services/instruments.zig");
const commands = @import("../commands.zig");
const decls = @import("../declarations/instruments.zig");
const log = @import("common").log;
const gl = @import("gl");

const uvec2 = struct { u32, u32 };

// TODO: maybe make the instruments stateful?
/// Processes the output from the `Step` instrument - the stepping and breakpoints logic.
pub const Step = struct {
    const id = instruments.Step.id;

    pub fn onBeforeDraw(_: *shaders, instrumentation: *shaders.InstrumentationResult) anyerror!void {
        // Update uniforms
        const program = instrumentation.stages.values()[0].params.context.program;
        if (instrumentation.uniforms_invalidated) if (instruments.Step.controls(&program.channels)) |controls| {
            if (controls.desired_step) |target| {
                const step_selector_ref = gl.GetUniformLocation(program.ref.cast(gl.uint), instruments.Step.desired_step);
                if (step_selector_ref >= 0) {
                    gl.Uniform1ui(step_selector_ref, target);
                    log.debug("Setting desired step to {d}", .{target});
                } else {
                    log.warn("Could not find step selector uniform in program {x}", .{program.ref});
                }

                const bp_selector = gl.GetUniformLocation(program.ref.cast(gl.uint), instruments.Step.desired_bp);
                if (bp_selector >= 0) {
                    gl.Uniform1ui(bp_selector, @intCast(controls.desired_bp));
                    log.debug("Setting desired breakpoint to {d}", .{controls.desired_bp});
                } else log.warn("Could not find bp selector uniform in program {x}", .{program.ref});
            }
        };
    }

    pub fn onResult(service: *shaders, instrumentation: *const shaders.InstrumentationResult, readbacks: *const std.AutoArrayHashMapUnmanaged(decls.InstrumentId, decls.Readback), _: *const decls.PlatformParamsGL) anyerror!void {
        var it = instrumentation.stages.iterator();
        while (it.next()) |entry| {
            // Debug adapter Breakpoint IDs
            var bp_hit_ids = std.AutoArrayHashMapUnmanaged(usize, void){};
            defer bp_hit_ids.deinit(service.allocator);

            var selected_thread_rstep: ?usize = null;
            const instr_state = entry.value_ptr.*;
            const shader_ref = entry.key_ptr.*;

            const selected_thread = instr_state.globalSelectedThread();
            // Retrieve the hit storage
            if (readbacks.get(instruments.Step.id)) |readback|
                if (instruments.Step.responses(&instr_state.params.context.program.channels)) |responses| {
                    const threads_hits = std.mem.bytesAsSlice(
                        uvec2,
                        readback.data,
                    );
                    // Scan for hits
                    var min_source: u32 = std.math.maxInt(u32);
                    var min_global: u32 = std.math.maxInt(u32);
                    var min_thread: usize = std.math.maxInt(u32);
                    for (0..instr_state.channels.totalThreadsCount()) |thread| {
                        const hit: uvec2 = threads_hits[thread];
                        if (hit[1] > 0) { // 1-based (0 means no hit)
                            const hit_global_i = hit[0];
                            // The index within the source file
                            const hit_source_i = hit[1] - 1;
                            // find the corresponding local step for SourcePart
                            const offset = try responses.localStepOffset(hit_global_i);
                            const local = hit_global_i - offset.offset;

                            if (offset.part.breakpoints.get(local)) |bp|
                                _ = try bp_hit_ids.getOrPut(service.allocator, bp.id);

                            if (thread == selected_thread) {
                                responses.reached_step = .{ .source = hit_source_i, .global = hit_global_i };
                                log.debug("Selected thread reached step ID {d} index {d}", .{ hit_global_i, hit_source_i });
                                selected_thread_rstep = local;
                            }
                            if (hit_source_i <= min_source) {
                                min_source = hit_source_i;
                                min_global = hit_global_i;
                                min_thread = thread;
                            }
                        }
                    }

                    if (responses.reached_step == null and !shaders.single_pause_mode) {
                        // Some step was reached in different than the selected thread
                        // TODO should not really occur
                        log.err("Step {d} was reached in source {d} in non-selected thread {d}", .{ min_global, min_source, min_thread });
                        if (min_source != 0) {
                            responses.reached_step = .{ .global = min_global, .source = min_source };
                        }
                    }

                    const running = try shaders.Running.Locator.from(service, shader_ref);
                    if (bp_hit_ids.count() > 0) {
                        if (commands.instance) |comm| {
                            try comm.eventBreak(.stopOnBreakpoint, .{
                                .ids = bp_hit_ids.keys(),
                                .thread = running.impl,
                            });
                        }
                    } else if (selected_thread_rstep) |reached_step| { // There was no breakpoint at this step, so the event is "stepping"
                        if (commands.instance) |comm| {
                            try comm.eventBreak(.stop, .{
                                .step = reached_step,
                                .thread = running.impl,
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
    // TODO dynamic buffer
    stack_trace_buffer: [instruments.StackTrace.default_max_entries]instruments.StackTrace.StackTraceT = undefined,

    pub fn onBeforeDraw(service: *shaders, instrumentation: *shaders.InstrumentationResult) anyerror!void {
        // Update uniforms
        if (instrumentation.uniforms_invalidated) {
            for (instrumentation.stages.keys(), instrumentation.stages.values()) |shader_ref, state| {
                const source_part = service.Shaders.all.get(shader_ref).?.items[0];
                const thread_selector = try service.allocator.dupeZ(u8, instruments.StackTrace.threadSelector(source_part.stage));
                defer service.allocator.free(thread_selector);
                const thread_select_ref = gl.GetUniformLocation(source_part.program.?.ref.cast(gl.uint), thread_selector.ptr);
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
};
