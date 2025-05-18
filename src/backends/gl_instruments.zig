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
const decls = @import("../declarations/instrumentation.zig");
const log = @import("common").log;
const gl = @import("gl");
const backend = @import("gl.zig");

// TODO: maybe make the instruments stateful?

/// Processes the output from the `Step` instrument - the stepping and breakpoints logic.
pub const Step = struct {
    const id = instruments.Step.id;

    pub fn onBeforeDraw(_: *shaders, instrumentation: decls.Result) anyerror!void {
        // Update uniforms
        const program = shaders.Shader.Program.fromOpaque(instrumentation.program);
        const p_state = &program.state.?;
        if (p_state.uniforms_dirty) if (instruments.Step.controls(&p_state.channels)) |controls| {
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

    pub fn onResult(
        service: *shaders,
        instrumentation: decls.Result,
        readbacks: *const std.AutoArrayHashMapUnmanaged(decls.ReadbackId, decls.Readback),
        _: *const decls.PlatformParamsGL,
    ) anyerror!void {
        const program = shaders.Shader.Program.fromOpaque(instrumentation.program);
        const p_state = &program.state.?;

        // Debug adapter Breakpoint IDs
        var bp_hit_ids = std.AutoArrayHashMapUnmanaged(usize, void){};
        defer bp_hit_ids.deinit(service.allocator);

        var selected_thread_rstep: ?usize = null;
        var reached_stage: ?shaders.Shader.Stage.Ref = null;

        // Retrieve the hit storage
        if (readbacks.get(instruments.Step.id)) |readback| // TODO readbacks are null after re-inistrumentation
            if (instruments.Step.responses(&p_state.channels)) |responses| {
                const threads_hits = std.mem.bytesAsSlice(
                    instruments.Step.Responses.ReachedStep,
                    readback.data,
                );
                // Scan for hits
                var min_id: instruments.Step.T = std.math.maxInt(instruments.Step.T);
                var min_counter: instruments.Step.T = std.math.maxInt(instruments.Step.T);
                var min_thread: usize = std.math.maxInt(u32);
                var min_stage: ?shaders.Shader.Stage.Ref = null;
                for (0.., threads_hits) |thread, hit| {
                    if (hit.id > 0) { // 1-based (0 means no hit)
                        const step_counter_i = hit.counter;
                        // The index within the global step number space
                        const step_global_i = hit.id - 1;
                        // find the corresponding local step for SourcePart
                        const offset = try responses.localStepOffset(step_global_i);
                        const local = step_global_i - offset.offset;

                        if (offset.part.step_breakpoints.get(local)) |global_bp_id|
                            _ = try bp_hit_ids.getOrPut(service.allocator, global_bp_id);

                        const selected_thread = try offset.part.stage.linearSelectedThread();

                        if (thread == selected_thread) {
                            responses.reached = .{
                                .id = step_global_i,
                                .counter = step_counter_i,
                            };
                            log.debug("Selected thread reached step counter {d} ID {d}", .{ step_counter_i, step_global_i });
                            selected_thread_rstep = local;
                            reached_stage = offset.part.stage.ref;
                        }
                        if (step_global_i <= min_id) {
                            min_id = step_global_i;
                            min_counter = step_counter_i;
                            min_thread = thread;
                            min_stage = offset.part.stage.ref;
                        }
                    }
                }

                if (responses.reached == null and !shaders.single_pause_mode) {
                    // Some step was reached in different than the selected thread
                    // TODO should not really occur
                    log.err("Step counter {d} ID {d} was reached in non-selected thread {d}", .{ min_counter, min_id, min_thread });
                    if (min_id != 0) {
                        responses.reached = .{ .counter = min_counter, .id = min_id };
                    }
                    reached_stage = min_stage;
                }

                if (bp_hit_ids.count() > 0) {
                    const running = try shaders.Running.Locator.from(service, reached_stage.?);
                    if (commands.instance) |comm| {
                        try comm.eventBreak(.stopOnBreakpoint, .{
                            .ids = bp_hit_ids.keys(),
                            .thread = running.impl,
                        }, backend.waiterServe);
                    }
                } else if (selected_thread_rstep) |reached_step| { // There was no breakpoint at this step, so the event is "stepping"
                    const running = try shaders.Running.Locator.from(service, reached_stage.?);
                    if (commands.instance) |comm| {
                        try comm.eventBreak(.stop, .{
                            .step = reached_step,
                            .thread = running.impl,
                        }, backend.waiterServe);
                    }
                }
            };
    }
};

pub const Variables = struct {};

pub const StackTrace = struct {
    pub fn onBeforeDraw(service: *shaders, instrumentation: decls.Result) anyerror!void {
        const program = shaders.Shader.Program.fromOpaque(instrumentation.program);
        if (program.state.?.uniforms_dirty) {
            // Update uniforms
            var stages = program.stages.iterator();
            while (stages.next()) |entry| {
                const shader_ref = entry.key_ptr.*;
                const stage = entry.value_ptr.*;

                const thread_selector = try service.allocator.dupeZ(u8, instruments.StackTrace.threadSelector(stage.stage));
                defer service.allocator.free(thread_selector);
                const thread_select_ref = gl.GetUniformLocation(stage.program.?.ref.cast(gl.uint), thread_selector.ptr);
                if (thread_select_ref >= 0) {
                    const selected_thread = try stage.linearSelectedThread();
                    gl.Uniform1ui(thread_select_ref, @intCast(selected_thread));
                    log.debug("Setting selected thread to {d}", .{selected_thread});
                } else {
                    log.warn("Could not find thread selector uniform in stage {x}", .{shader_ref});
                }
            }
        }
    }
};
