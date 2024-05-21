// TODO: support MESA debug extensions? (MESA_program_debug, MESA_shader_debug)
// TODO: support GL_ARB_shading_language_include (nvidia's), GL_GOOGLE_include_directive and GL_GOOGLE_cpp_style_line_directive
// TODO: error checking
// TODO: support older OpenGL, GLES
const std = @import("std");
const builtin = @import("builtin");
const gl = @import("gl");
const decls = @import("../declarations/shaders.zig");
const shaders = @import("../services/shaders.zig");
const storage = @import("../services/storage.zig");
const instrumentation = @import("../services/instrumentation.zig");
const log = @import("../log.zig").DeshaderLog;
const common = @import("../common.zig");
const commands = @import("../commands.zig");
const args = @import("args");
const main = @import("../main.zig");
const loaders = @import("loaders.zig");
const debug = @import("../services/debug.zig");
const ids = @cImport(@cInclude("commands.h"));

const CString = [*:0]const u8;
const String = []const u8;
const Buffer = []u8;

const BufferType = enum(gl.GLenum) {
    AtomicCounter = gl.ATOMIC_COUNTER_BUFFER,
    ShaderStorage = gl.SHADER_STORAGE_BUFFER,
    TransformFeedback = gl.TRANSFORM_FEEDBACK_BUFFER,
    Uniform = gl.UNIFORM_BUFFER,
};
const UniformTarget = enum { thread_selector, step_selector, bp_selector };

/// The service instance that belongs to currently selected context.
pub threadlocal var current: *shaders = undefined;

// Managed per-context state
var state: std.AutoHashMapUnmanaged(*shaders, struct {
    readback_step_buffers: std.AutoHashMapUnmanaged(usize, Buffer) = .{},
    unifoms_for_shaders: std.AutoArrayHashMapUnmanaged(usize, std.EnumMap(UniformTarget, gl.GLint)) = .{},
    primitives_written_queries: std.ArrayListUnmanaged(gl.GLuint) = .{},

    // memory for used indexed buffer binding indexed. OpenGL does not provide a standard way to query them.
    indexed_buffer_bindings: std.EnumMap(BufferType, usize) = .{},

    // Handles for the debug output objects
    stack_trace_ref: gl.GLuint = gl.NONE,
    print_ref: gl.GLuint = gl.NONE,
    replacement_attachment_textures: [32]gl.GLuint = [_]gl.GLuint{0} ** 32,
    debug_fbo: gl.GLuint = undefined,
    max_xfb_streams: gl.GLint = 0,
    max_xfb_buffers: gl.GLint = 0,
    max_xfb_sep_components: gl.GLint = 0,
    max_xfb_sep_attribs: gl.GLint = 0,
    max_xfb_interleaved_components: gl.GLint = 0,
    max_attachments: gl.GLuint = 0,
}) = .{};

fn defaultCompileShader(source: decls.SourcesPayload, instrumented: CString, length: i32) callconv(.C) u8 {
    const shader: gl.GLuint = @intCast(source.ref);
    if (length > 0) {
        gl.shaderSource(shader, 1, &instrumented, &length);
    } else {
        const lengths_i32 = if (source.lengths) |lengths| blk: {
            var result = common.allocator.alloc(i32, @intCast(source.count)) catch |err| {
                log.err("Failed to allocate memory for shader sources lengths: {any}", .{err});
                return 1;
            };
            for (lengths[0..source.count], result[0..source.count]) |len, *target| {
                target.* = @intCast(len);
            }
            break :blk result;
        } else null;
        defer if (lengths_i32) |l| common.allocator.free(l);
        gl.shaderSource(shader, @intCast(source.count), source.sources, if (lengths_i32) |l| l.ptr else null);
    }
    gl.compileShader(shader);

    var info_length: gl.GLsizei = undefined;
    gl.getShaderiv(shader, gl.INFO_LOG_LENGTH, &info_length);
    if (info_length > 0) {
        const info_log: [*:0]gl.GLchar = common.allocator.allocSentinel(gl.GLchar, @intCast(info_length - 1), 0) catch |err| {
            log.err("Failed to allocate memory for shader info log: {any}", .{err});
            return 1;
        };
        defer common.allocator.free(info_log[0..@intCast(info_length)]);
        gl.getShaderInfoLog(shader, info_length, null, info_log);
        var paths: ?String = null;
        if (source.count > 0 and source.paths != null) {
            if (common.joinInnerZ(common.allocator, "; ", source.paths.?[0..source.count])) |joined| {
                paths = joined;
            } else |err| {
                log.warn("Failed to join shader paths: {any}", .{err});
            }
        }
        log.info("Shader {d} at path '{?s}' info:\n{s}", .{ shader, paths, info_log });
        var success: gl.GLint = undefined;
        gl.getShaderiv(shader, gl.COMPILE_STATUS, &success);
        if (success == 0) {
            log.err("Shader {d} compilation failed", .{shader});
            return 1;
        }
    }
    return 0;
}

/// If count is 0, the function will only link the program. Otherwise it will attach the shaders in the order they are stored in the payload.
fn defaultLink(self: decls.ProgramPayload) callconv(.C) u8 {
    const program: gl.GLuint = @intCast(self.ref);
    var i: usize = 0;
    while (i < self.count) : (i += 1) {
        gl.attachShader(program, @intCast(self.shaders.?[i]));
        if (gl.getError() != gl.NO_ERROR) {
            log.err("Failed to attach shader {d} to program {d}", .{ self.shaders.?[i], program });
            return 1;
        }
    }
    gl.linkProgram(program);

    var info_length: gl.GLsizei = undefined;
    gl.getProgramiv(program, gl.INFO_LOG_LENGTH, &info_length);
    if (info_length > 0) {
        const info_log: [*:0]gl.GLchar = common.allocator.allocSentinel(gl.GLchar, @intCast(info_length - 1), 0) catch |err| {
            log.err("Failed to allocate memory for program info log: {any}", .{err});
            return 1;
        };
        defer common.allocator.free(info_log[0..@intCast(info_length)]);

        gl.getProgramInfoLog(program, info_length, &info_length, info_log);
        log.info("Program {d}:{?s} info:\n{s}", .{ program, self.path, info_log });

        var success: gl.GLint = undefined;
        gl.getProgramiv(program, gl.LINK_STATUS, &success);
        if (success == 0) {
            log.err("Program {d} linking failed", .{program});
            return 1;
        }
    }
    return 0;
}

fn updateBufferIndexInfo(buffer: gl.GLuint, index: gl.GLuint, buffer_type: BufferType) void {
    const c_state = state.getPtr(current) orelse return;
    if (buffer == 0) { //un-bind
        c_state.indexed_buffer_bindings.put(buffer_type, 0);
    } else {
        const existing = c_state.indexed_buffer_bindings.get(buffer_type) orelse 0;
        c_state.indexed_buffer_bindings.put(buffer_type, existing | index);
    }
}

pub export fn glBindBufferBase(target: gl.GLenum, index: gl.GLuint, buffer: gl.GLuint) void {
    gl.bindBufferBase(target, index, buffer);
    if (gl.getError() == gl.NO_ERROR) {
        updateBufferIndexInfo(buffer, index, @enumFromInt(target));
    }
}

pub export fn glBindBufferRange(target: gl.GLenum, index: gl.GLuint, buffer: gl.GLuint, offset: gl.GLintptr, size: gl.GLsizeiptr) void {
    gl.bindBufferRange(target, index, buffer, offset, size);
    if (gl.getError() == gl.NO_ERROR) {
        updateBufferIndexInfo(buffer, index, @enumFromInt(target));
    }
}

pub export fn glCreateShader(stage: gl.GLenum) gl.GLuint {
    const new_platform_source = gl.createShader(stage);

    const ref: usize = @intCast(new_platform_source);
    if (current.Shaders.appendUntagged(ref)) |new| {
        _ = shaders.Shader.MemorySource.fromPayload(current.Shaders.allocator, decls.SourcesPayload{
            .ref = ref,
            .stage = @enumFromInt(stage),
            .compile = defaultCompileShader,
            .count = 1,
            .language = decls.LanguageType.GLSL,
        }, 0, new) catch |err| {
            log.warn("Failed to add shader source {x} cache because of alocation: {any}", .{ new_platform_source, err });
            return new_platform_source;
        };
    } else |err| {
        log.warn("Failed to add shader source {x} cache: {any}", .{ new_platform_source, err });
    }

    return new_platform_source;
}

pub export fn glCreateShaderProgramv(stage: gl.GLenum, count: gl.GLsizei, sources: [*][*:0]const gl.GLchar) gl.GLuint {
    const source_type: decls.Stage = @enumFromInt(stage);
    const new_platform_program = gl.createShaderProgramv(stage, count, sources);
    const new_platform_sources = common.allocator.alloc(gl.GLuint, @intCast(count)) catch |err| {
        log.err("Failed to allocate memory for shader sources: {any}", .{err});
        return 0;
    };
    defer common.allocator.free(new_platform_sources);

    var source_count: c_int = undefined;
    gl.getAttachedShaders(new_platform_program, count, &source_count, new_platform_sources.ptr);
    std.debug.assert(source_count == 1);
    var lengths = common.allocator.alloc(usize, 1) catch |err| {
        log.err("Failed to allocate memory for shader sources lengths: {any}", .{err});
        return 0;
    };
    lengths[0] = std.mem.len(sources[0]);

    current.sourcesCreateUntagged(decls.SourcesPayload{
        .ref = @intCast(new_platform_sources[0]),
        .stage = source_type,
        .count = @intCast(count),
        .sources = sources,
        .lengths = lengths.ptr,
        .compile = defaultCompileShader,
        .language = decls.LanguageType.GLSL,
    }) catch |err| {
        log.warn("Failed to add shader source {x} cache: {any}", .{ new_platform_sources[0], err });
    };

    return new_platform_program;
}

//
// Drawing functions - the heart of shader instrumentaton
//

// guards the access to break_condition
var break_mutex = std.Thread.Mutex{};
var break_after_draw = false;
fn processOutput(r: InstrumentationResult) !void {
    defer if (break_after_draw) break_mutex.unlock();
    if (break_after_draw) break_mutex.lock();

    var it = r.result.state.iterator();
    while (it.next()) |entry| {
        var bp_hit_ids = std.AutoArrayHashMapUnmanaged(usize, void){};
        defer bp_hit_ids.deinit(common.allocator);

        var selected_thread_rstep: ?usize = null;
        const c_state = state.getPtr(current) orelse return error.NoState;
        const instr_state = entry.value_ptr.*;
        const shader_ref = entry.key_ptr.*;
        const shader: *std.ArrayListUnmanaged(shaders.Shader.SourceInterface) = current.Shaders.all.get(shader_ref) orelse {
            log.warn("Shader {d} not found in the database", .{shader_ref});
            continue;
        };

        const selected_thread = instr_state.globalSelectedThread();
        if (instr_state.outputs.step_storage) |*stor| {
            // Examine if something was hit
            const threads_hits: Buffer = c_state.readback_step_buffers.get(stor.ref.?).?;
            switch (stor.location) {
                .Interface => |interface| {
                    switch (current.Shaders.all.get(shader_ref).?.items[0].stage) {
                        .gl_fragment, .vk_fragment => {
                            var previous_pack_buffer: gl.GLuint = undefined; // save previous host state
                            gl.getIntegerv(gl.PIXEL_PACK_BUFFER_BINDING, @ptrCast(&previous_pack_buffer));
                            gl.bindBuffer(gl.PIXEL_PACK_BUFFER, 0);

                            // blit to the original framebuffer
                            gl.bindFramebuffer(gl.READ_FRAMEBUFFER, c_state.debug_fbo);
                            gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, r.platform_params.previous_fbo);
                            var i: gl.GLenum = 0;
                            while (i < r.platform_params.draw_buffers_len) : (i += 1) {
                                gl.readBuffer(@as(gl.GLenum, gl.COLOR_ATTACHMENT0) + i);
                                gl.drawBuffer(r.platform_params.draw_buffers[i]);
                                gl.blitFramebuffer(0, 0, @intCast(instr_state.params.screen[0]), @intCast(instr_state.params.screen[1]), 0, 0, @intCast(instr_state.params.screen[0]), @intCast(instr_state.params.screen[1]), gl.COLOR_BUFFER_BIT, gl.NEAREST);
                            }
                            gl.blitFramebuffer(0, 0, @intCast(instr_state.params.screen[0]), @intCast(instr_state.params.screen[1]), 0, 0, @intCast(instr_state.params.screen[0]), @intCast(instr_state.params.screen[1]), gl.STENCIL_BUFFER_BIT | gl.DEPTH_BUFFER_BIT, gl.NEAREST);

                            // read pixels to the main memory
                            var previous_read_buffer: gl.GLenum = undefined;
                            gl.getIntegerv(gl.READ_BUFFER, @ptrCast(&previous_read_buffer));
                            gl.readBuffer(@as(gl.GLenum, @intCast(interface.location)) + gl.COLOR_ATTACHMENT0);

                            gl.readnPixels(
                                0,
                                0,
                                @intCast(instr_state.params.screen[0]),
                                @intCast(instr_state.params.screen[1]),
                                gl.RED_INTEGER,
                                gl.UNSIGNED_BYTE, // The same format as the texture
                                @intCast(threads_hits.len),
                                threads_hits.ptr,
                            );

                            // restore the previous framebuffer binding
                            gl.bindBuffer(gl.PIXEL_PACK_BUFFER, previous_pack_buffer);
                            gl.readBuffer(previous_read_buffer);

                            gl.bindFramebuffer(gl.FRAMEBUFFER, r.platform_params.previous_fbo);
                            gl.bindFramebuffer(gl.READ_FRAMEBUFFER, r.platform_params.previous_read_fbo);
                            gl.drawBuffers(@intCast(r.platform_params.draw_buffers_len), &r.platform_params.draw_buffers);
                        },
                        else => unreachable, // TODO transform feedback
                    }
                },
                .Buffer => |_| {
                    gl.getNamedBufferSubData(@intCast(stor.ref.?), 0, @intCast(threads_hits.len), threads_hits.ptr);
                },
            }

            var max_hit: u32 = 0;
            for (0..instr_state.params.screen[1]) |y| {
                for (0..instr_state.params.screen[0]) |x| {
                    const global_index: usize = x + y * instr_state.params.screen[0];
                    if (threads_hits[global_index] > 0) { // 1-based (0 means no hit)
                        const hit_id = threads_hits[global_index] - 1;
                        // find the corresponding step index for SourceInterface
                        const offsets = if (instr_state.outputs.parts_offsets) |pos| for (0.., pos) |i, po| {
                            if (po >= hit_id) {
                                break .{ i, po };
                            }
                        } else .{ 0, 0 } else null;
                        if (offsets) |off| {
                            const source_part = shader.items[off[0]];
                            const local_hit_id = hit_id - off[1];
                            if (source_part.breakpoints.contains(local_hit_id)) // Maybe should be stored in Result.Outputs instead as snapshot (more thread-safe?)
                                _ = try bp_hit_ids.getOrPut(common.allocator, local_hit_id);
                        }

                        if (global_index == selected_thread) {
                            instr_state.reached_step = hit_id;
                            log.debug("Selected thread reached step {d}", .{hit_id});
                            if (offsets) |off| {
                                selected_thread_rstep = hit_id - off[1];
                            }
                        }
                        max_hit = @max(max_hit, hit_id);
                    }
                }
            }

            if (instr_state.reached_step == null and !shaders.single_pause_mode) {
                // TODO should not really occur
                log.err("Stop was not reached but breakpoint was", .{});
                if (max_hit != 0) instr_state.reached_step = max_hit;
            }
        }
        const running_shader = try shaders.running.getOrPut(.{ .service = current, .shader = shader_ref });
        if (bp_hit_ids.count() > 0) {
            if (common.command_listener) |comm| {
                try comm.eventBreak(.stopOnBreakpoint, .{
                    .ids = bp_hit_ids.keys(),
                    .shader = @intFromPtr(running_shader.key_ptr),
                });
            }
        } else if (selected_thread_rstep) |reached_step| {
            if (common.command_listener) |comm| {
                try comm.eventBreak(.stop, .{
                    .step = reached_step,
                    .shader = @intFromPtr(running_shader.key_ptr),
                });
            }
        }
    }
}

fn deinitTexture(out_storage: *instrumentation.OutputStorage, _: std.mem.Allocator) void {
    if (out_storage.ref) |r| {
        gl.deleteTextures(1, @ptrCast(&r));
        const entry = state.getPtr(current).?.readback_step_buffers.fetchRemove(r);
        if (entry) |e| {
            common.allocator.free(e.value);
        }
    }
}

fn deinitBuffer(out_storage: *instrumentation.OutputStorage, _: std.mem.Allocator) void {
    if (out_storage.ref) |r| {
        gl.deleteBuffers(1, @ptrCast(&r));
    }
}

/// Prepare debug output buffers for instrumented shaders execution
fn prepareStorage(input: InstrumentationResult) !InstrumentationResult {
    var result = input;
    if (result.result.invalidated) {
        if (common.command_listener) |comm| {
            try comm.sendEvent(.invalidated, debug.InvalidatedEvent{ .areas = &.{debug.InvalidatedEvent.Areas.threads} });
        }
    }
    const c_state = state.getPtr(current) orelse return error.NoState;
    // Prepare storage for stack traces (there is always only one stack trace and the program which writes to it is dynamically selected)
    if (c_state.stack_trace_ref == gl.NONE) {
        gl.genBuffers(1, &c_state.stack_trace_ref);
        var previous: gl.GLint = undefined;
        gl.getIntegerv(gl.SHADER_STORAGE_BUFFER_BINDING, &previous);
        if (previous >= 0) {
            gl.bindBuffer(gl.SHADER_STORAGE_BUFFER, c_state.stack_trace_ref);
            gl.bufferStorage(gl.SHADER_STORAGE_BUFFER, shaders.STACK_TRACE_MAX * @sizeOf(shaders.StackTraceT), null, gl.MAP_READ_BIT | gl.MAP_PERSISTENT_BIT);
            current.stack_trace_buffer = @ptrCast(gl.mapBuffer(gl.SHADER_STORAGE_BUFFER, gl.READ_ONLY));
            gl.bindBuffer(gl.SHADER_STORAGE_BUFFER, @intCast(previous));
        } else {
            log.err("Stack trace buffer allocation error", .{});
        }
    }

    var plat_params = &result.platform_params;
    var it = result.result.state.iterator();
    while (it.next()) |state_entry| {
        var instr_state = state_entry.value_ptr.*;
        // Update uniforms
        if (result.result.uniforms_invalidated) {
            const uniforms = try state.getPtr(current).?.unifoms_for_shaders.getOrPut(common.allocator, state_entry.key_ptr.*);
            if (!uniforms.found_existing) {
                uniforms.value_ptr.* = std.EnumMap(UniformTarget, gl.GLint){};
            }

            var thread_select_ref: gl.GLint = undefined;
            if (uniforms.value_ptr.get(UniformTarget.thread_selector)) |ref| {
                thread_select_ref = ref;
            } else {
                // TODO explicit locations, pack to vec4 type
                thread_select_ref = gl.getUniformLocation(result.platform_params.program, instr_state.outputs.thread_selector_ident.ptr);
                uniforms.value_ptr.put(UniformTarget.thread_selector, thread_select_ref);
            }
            if (thread_select_ref >= 0) {
                const selected_thread = instr_state.globalSelectedThread();
                gl.uniform1ui(thread_select_ref, @intCast(selected_thread));
                log.debug("Setting selected thread to {d}", .{selected_thread});
            } else {
                log.err("Could not find thread selector uniform in the program {x}", .{result.platform_params.program});
            }

            if (instr_state.target_step) |target| {
                var step_selector_ref: gl.GLint = undefined;
                if (uniforms.value_ptr.get(UniformTarget.step_selector)) |ref| {
                    step_selector_ref = ref;
                } else {
                    step_selector_ref = gl.getUniformLocation(result.platform_params.program, instr_state.outputs.desired_step_ident.ptr);
                    uniforms.value_ptr.put(UniformTarget.step_selector, step_selector_ref);
                }

                if (step_selector_ref >= 0) {
                    gl.uniform1ui(step_selector_ref, @intCast(target));
                    log.debug("Setting desired step to {d}", .{target});
                } else {
                    log.err("Could not find step selector uniform in the program {x}", .{result.platform_params.program});
                }
            }

            const bp_selector = if (uniforms.value_ptr.get(UniformTarget.bp_selector)) |ref| ref else blk: {
                const ref = gl.getUniformLocation(result.platform_params.program, instr_state.outputs.desired_bp_ident.ptr);
                uniforms.value_ptr.put(UniformTarget.bp_selector, ref);
                break :blk ref;
            };
            if (bp_selector >= 0) {
                gl.uniform1ui(bp_selector, @intCast(instr_state.target_bp));
                log.debug("Setting desired breakpoint to {d}", .{instr_state.target_bp});
            } else log.err("Could not find bp selector uniform in the program {x}", .{result.platform_params.program});
        }
        const context_state = state.getPtr(current).?;
        // Prepare storage for step counters
        if (instr_state.outputs.step_storage) |*stor| {
            const total_length = instr_state.outputs.totalThreadsCount();
            switch (stor.location) {
                .Interface => |interface| { // `id` should be the last attachment index
                    switch (current.Shaders.all.get(state_entry.key_ptr.*).?.items[0].stage) {
                        .gl_fragment, .vk_fragment => {
                            var max_draw_buffers: gl.GLuint = undefined;
                            gl.getIntegerv(gl.MAX_DRAW_BUFFERS, @ptrCast(&max_draw_buffers));
                            {
                                var i: gl.GLenum = 0;
                                while (i < max_draw_buffers) : (i += 1) {
                                    var previous: gl.GLenum = undefined;
                                    gl.getIntegerv(gl.DRAW_BUFFER0 + i, @ptrCast(&previous));
                                    switch (previous) {
                                        gl.NONE => {
                                            plat_params.draw_buffers_len = i;
                                            for (i + 1..max_draw_buffers) |j| {
                                                plat_params.draw_buffers[j] = gl.NONE;
                                            }
                                            break;
                                        },
                                        gl.BACK => plat_params.draw_buffers[i] = gl.BACK_LEFT,
                                        gl.FRONT => plat_params.draw_buffers[i] = gl.FRONT_LEFT,
                                        gl.FRONT_AND_BACK => plat_params.draw_buffers[i] = gl.BACK_LEFT,
                                        gl.LEFT => plat_params.draw_buffers[i] = gl.FRONT_LEFT,
                                        gl.RIGHT => plat_params.draw_buffers[i] = gl.FRONT_RIGHT,
                                        else => plat_params.draw_buffers[i] = previous,
                                    }
                                }
                            }
                            // create debug draw buffers spec
                            var draw_buffers = [_]gl.GLenum{gl.NONE} ** 32;
                            {
                                var i: gl.GLenum = 0;
                                while (i <= interface.location) : (i += 1) {
                                    draw_buffers[i] = @as(gl.GLenum, gl.COLOR_ATTACHMENT0) + i;
                                }
                            }

                            var debug_texture: gl.GLuint = undefined;
                            if (stor.ref == null) {
                                // Create a debug attachment for the framebuffer
                                gl.genTextures(1, &debug_texture);
                                gl.bindTexture(gl.TEXTURE_2D, debug_texture);
                                gl.texImage2D(gl.TEXTURE_2D, 0, gl.R32UI, @intCast(instr_state.params.screen[0]), @intCast(instr_state.params.screen[1]), 0, gl.RED_INTEGER, gl.UNSIGNED_INT, null);
                                try context_state.readback_step_buffers.put(common.allocator, debug_texture, try common.allocator.alloc(u8, total_length));
                                stor.ref = debug_texture;
                                stor.deinit_host = &deinitTexture;
                            } else {
                                debug_texture = @intCast(stor.ref.?);
                            }

                            // Attach the texture to the current framebuffer
                            gl.getIntegerv(gl.FRAMEBUFFER_BINDING, @ptrCast(&plat_params.previous_fbo));
                            gl.getIntegerv(gl.READ_FRAMEBUFFER_BINDING, @ptrCast(&plat_params.previous_read_fbo));

                            var current_fbo: gl.GLuint = plat_params.previous_fbo;
                            if (plat_params.previous_fbo == 0) {
                                // default framebuffer does not support attachments so we must replace it with a custom one
                                if (c_state.debug_fbo == 0) {
                                    gl.genFramebuffers(1, &c_state.debug_fbo);
                                }
                                gl.bindFramebuffer(gl.FRAMEBUFFER, c_state.debug_fbo);
                                //create depth and stencil attachment
                                var depth_stencil: gl.GLuint = undefined;
                                gl.genRenderbuffers(1, &depth_stencil);
                                gl.bindRenderbuffer(gl.RENDERBUFFER, depth_stencil);
                                gl.renderbufferStorage(gl.RENDERBUFFER, gl.DEPTH24_STENCIL8, @intCast(instr_state.params.screen[0]), @intCast(instr_state.params.screen[1]));
                                gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_STENCIL_ATTACHMENT, gl.RENDERBUFFER, depth_stencil);
                                for (0..interface.location) |i| {
                                    // create all previous color attachments
                                    if (c_state.replacement_attachment_textures[i] == 0) { // TODO handle resolution change
                                        gl.genTextures(1, &c_state.replacement_attachment_textures[i]);
                                    }
                                    gl.bindTexture(gl.TEXTURE_2D, c_state.replacement_attachment_textures[i]);
                                    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, @intCast(instr_state.params.screen[0]), @intCast(instr_state.params.screen[1]), 0, gl.RGBA, gl.FLOAT, null);
                                }
                                current_fbo = c_state.debug_fbo;
                            }
                            gl.namedFramebufferTexture(current_fbo, gl.COLOR_ATTACHMENT0 + @as(gl.GLenum, @intCast(interface.location)), debug_texture, 0);
                            gl.drawBuffers(@as(gl.GLsizei, @intCast(interface.location)) + 1, &draw_buffers);
                        },
                        else => unreachable, //TODO transform feedback
                    }
                },
                .Buffer => |binding| {
                    if (stor.ref == null) {
                        var new: gl.GLuint = undefined;
                        gl.genBuffers(1, &new);
                        gl.namedBufferStorage(new, @intCast(total_length), null, 0);
                        stor.deinit_host = &deinitBuffer;
                        gl.bindBufferBase(gl.SHADER_STORAGE_BUFFER, @intCast(binding), @intCast(new));
                        try context_state.readback_step_buffers.put(common.allocator, new, try common.allocator.alloc(u8, total_length));
                        stor.ref = new;
                    }
                },
            }
        }
        if (instr_state.outputs.stack_trace) |st_storage| {
            gl.bindBufferBase(gl.SHADER_STORAGE_BUFFER, @intCast(st_storage.location.Buffer), c_state.stack_trace_ref);
        }
    }
    return result;
}

fn getFrambufferSize(fbo: gl.GLuint) [2]gl.GLint {
    if (fbo == 0) {
        var viewport: [4]gl.GLint = undefined;
        gl.getIntegerv(gl.VIEWPORT, &viewport);
        return .{ viewport[2], viewport[3] };
    }
    var attachment_object_name: gl.GLuint = 0;
    gl.getFramebufferAttachmentParameteriv(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, @ptrCast(&attachment_object_name));

    var attachment_object_type: gl.GLint = 0;
    gl.getFramebufferAttachmentParameteriv(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &attachment_object_type);

    var result = [_]gl.GLint{ 0, 0 };
    if (attachment_object_type == gl.TEXTURE) {
        gl.getTextureLevelParameteriv(attachment_object_name, 0, gl.TEXTURE_WIDTH, @ptrCast(&result[0]));
        gl.getTextureLevelParameteriv(gl.TEXTURE_2D, 0, gl.TEXTURE_HEIGHT, @ptrCast(&result[1]));
    } else if (attachment_object_type == gl.RENDERBUFFER) {
        gl.getNamedRenderbufferParameteriv(attachment_object_name, gl.RENDERBUFFER_WIDTH, @ptrCast(&result[0]));
        gl.getNamedRenderbufferParameteriv(attachment_object_name, gl.RENDERBUFFER_HEIGHT, @ptrCast(&result[1]));
    }
    return result;
}

/// query the output interface of the last shader in the pipeline. This is normally the fragment shader.
fn getOutputInterface(program: gl.GLuint) !std.ArrayList(usize) {
    var out_interface = std.ArrayList(usize).init(common.allocator);
    var count: gl.GLuint = undefined;
    gl.getProgramInterfaceiv(program, gl.PROGRAM_OUTPUT, gl.ACTIVE_RESOURCES, @ptrCast(&count));
    // filter out used outputs
    {
        var i: gl.GLuint = 0;
        var name: [64:0]gl.GLchar = undefined;
        while (i < count) : (i += 1) {
            gl.getProgramResourceName(program, gl.PROGRAM_OUTPUT, i, 64, null, &name);
            if (!std.mem.startsWith(u8, &name, instrumentation.Processor.prefix)) {
                const location: gl.GLint = gl.getProgramResourceLocation(program, gl.PROGRAM_OUTPUT, &name);
                // is negative on error (program has compile errors...)
                if (location >= 0) {
                    try out_interface.append(@intCast(location));
                }
            }
        }
    }
    std.sort.heap(usize, out_interface.items, {}, std.sort.asc(usize));
    return out_interface;
}

const GeneralParams = struct {
    max_buffers: gl.GLuint,
    used_buffers: std.ArrayList(usize),
};
fn getGeneralParams(program_ref: gl.GLuint) !GeneralParams {
    var max_buffers: gl.GLuint = undefined;
    gl.getIntegerv(gl.MAX_SHADER_STORAGE_BUFFER_BINDINGS, @ptrCast(&max_buffers));

    // used bindings
    var used_buffers = try std.ArrayList(usize).initCapacity(common.allocator, 16);
    // used indexes
    var used_buffers_count: gl.GLuint = undefined;
    gl.getProgramInterfaceiv(program_ref, gl.SHADER_STORAGE_BLOCK, gl.ACTIVE_RESOURCES, @ptrCast(&used_buffers_count));
    var i: gl.GLuint = 0;
    while (i < used_buffers_count) : (i += 1) { // for each buffer index
        var binding: gl.GLuint = undefined; // get the binding number
        gl.getProgramResourceiv(program_ref, gl.SHADER_STORAGE_BLOCK, i, 1, gl.BUFFER_BINDING, 1, null, @ptrCast(&binding));
        try used_buffers.append(binding);
    }

    return GeneralParams{ .max_buffers = max_buffers, .used_buffers = used_buffers };
}

const InstrumentationResult = struct {
    platform_params: struct {
        previous_fbo: gl.GLuint = 0,
        previous_read_fbo: gl.GLuint = 0,
        draw_buffers: [32]gl.GLenum = undefined,
        draw_buffers_len: gl.GLuint = 0,
        program: gl.GLuint = 0,
    },
    result: shaders.InstrumentationResult,
};
fn instrumentDraw(vertices: gl.GLint, instances: gl.GLsizei) !InstrumentationResult {
    // Find currently bound shaders
    // Instrumentation
    // - Add debug outputs to the shaders (framebuffer attachments, buffers)
    // - Rewrite shader code to write into the debug outputs
    // - Dispatch debugging draw calls and read the outputs while a breakpoint or a step is reached
    // Call the original draw call...

    const c_state = state.getPtr(current) orelse return error.NoState;

    // TODO glGet*() calls can cause synchronization and can be harmful to performance

    var program_ref: gl.GLuint = undefined;
    gl.getIntegerv(gl.CURRENT_PROGRAM, @ptrCast(&program_ref)); // GL API is stupid and uses GLint for GLuint
    if (program_ref == 0) {
        log.info("No program bound for the draw call", .{});
        return error.NoProgramBound;
    }

    // Check if transform feedback is active -> no fragment shader will be executed
    var some_feedback_buffer: gl.GLint = undefined;
    gl.getIntegerv(gl.TRANSFORM_FEEDBACK_BUFFER_BINDING, &some_feedback_buffer);
    // TODO or check indexed_buffer_bindings[BufferType.TransformFeedback] != 0 ?

    // Can be u5 because maximum attachments is limited to 32 by the API, and is often limited to 8
    // TODO query GL_PROGRAM_OUTPUT to check actual used attachments
    var used_attachments = try std.ArrayList(u5).initCapacity(common.allocator, @intCast(c_state.max_attachments));
    defer used_attachments.deinit();

    if (current.Programs.all.get(program_ref)) |program_target| {
        // NOTE we assume that all attachments that shader really uses are bound
        var current_fbo: gl.GLuint = undefined;
        if (some_feedback_buffer == 0) { // if no transform feedback is active

            gl.getIntegerv(gl.FRAMEBUFFER_BINDING, @ptrCast(&current_fbo));
            if (current_fbo != 0) {
                // query bound attacahments
                var i: gl.GLuint = 0;
                while (i < c_state.max_attachments) : (i += 1) {
                    const attachment_id = gl.COLOR_ATTACHMENT0 + i;
                    var attachment_type: gl.GLint = undefined;
                    gl.getNamedFramebufferAttachmentParameteriv(current_fbo, attachment_id, gl.FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &attachment_type);
                    if (attachment_type != gl.NONE) {
                        try used_attachments.append(@intCast(i)); // we hope that it will be less or equal to 32 so safe cast to u5
                    }
                }
            } else {
                try used_attachments.append(0); // the default color attachment
            }
        }

        // Get screen size
        const screen = if (some_feedback_buffer == 0) getFrambufferSize(current_fbo) else [_]gl.GLint{ 0, 0 };
        var general_params = try getGeneralParams(program_ref);
        defer general_params.used_buffers.deinit();

        var used_fragment_interface = std.ArrayList(usize).init(common.allocator);
        defer used_fragment_interface.deinit();
        var used_vertex_interface = std.ArrayList(usize).init(common.allocator);
        defer used_vertex_interface.deinit();

        var stages_it = program_target.stages.valueIterator();
        var has_fragment_shader = false;
        while (stages_it.next()) |stage| {
            if (stage.*.items[0].stage.isFragment()) {
                has_fragment_shader = true;
                break;
            }
        }

        if (has_fragment_shader) {
            const rast_discard = gl.isEnabled(gl.RASTERIZER_DISCARD);
            if (rast_discard == gl.TRUE) {
                used_vertex_interface = try getOutputInterface(program_ref);
                gl.disable(gl.RASTERIZER_DISCARD);
                used_fragment_interface = try getOutputInterface(program_ref);
                gl.enable(gl.RASTERIZER_DISCARD);
            } else {
                used_fragment_interface = try getOutputInterface(program_ref);
                gl.enable(gl.RASTERIZER_DISCARD);
                used_vertex_interface = try getOutputInterface(program_ref);
                gl.disable(gl.RASTERIZER_DISCARD);
            }
        } else {
            used_vertex_interface = try getOutputInterface(program_ref);
        }

        //
        // Instrument the currently bound program
        //

        const screen_u = [_]usize{ @intCast(screen[0]), @intCast(screen[1]) };

        var buffer_mode: gl.GLint = 0;
        gl.getProgramiv(program_ref, gl.TRANSFORM_FEEDBACK_BUFFER_MODE, &buffer_mode);

        return InstrumentationResult{
            .result = try current.instrument(program_target, .{
                .allocator = common.allocator,
                .used_buffers = general_params.used_buffers,
                .used_interface = used_fragment_interface,
                .max_attachments = c_state.max_attachments,
                .max_buffers = general_params.max_buffers,
                .max_xfb = if (buffer_mode == gl.SEPARATE_ATTRIBS) @max(0, c_state.max_xfb_streams * c_state.max_xfb_sep_components) else @max(0, c_state.max_xfb_interleaved_components),
                .vertices = @intCast(vertices),
                .instances = @intCast(instances),
                .screen = screen_u,
                .compute = [_]usize{ 0, 0, 0, 0, 0, 0 },
            }),
            .platform_params = .{
                .program = program_ref,
            },
        };
    } else {
        log.warn("Program {d} not found in database", .{program_ref});
        return error.NoProgramFound;
    }
}

fn instrumentCompute(num_groups: [3]usize) !InstrumentationResult {
    var program_ref: gl.GLuint = undefined;
    gl.getIntegerv(gl.CURRENT_PROGRAM, @ptrCast(&program_ref)); // GL API is stupid and uses GLint for GLuint
    if (program_ref == 0) {
        log.info("No program bound for the dispatch call", .{});
        return error.NoProgramBound;
    }
    const general_params = try getGeneralParams(program_ref);
    defer general_params.used_buffers.deinit();

    //
    // Instrument the currently bound program
    //
    if (current.Programs.all.get(program_ref)) |program_target| {
        // NOTE program_target must be a pointer otherwise instrumentation cache would be cleared
        var empty = std.ArrayList(usize).init(common.allocator);
        defer empty.deinit();
        var group_sizes: [3]gl.GLint = undefined;
        gl.getProgramiv(program_ref, gl.COMPUTE_WORK_GROUP_SIZE, &group_sizes[0]);
        return InstrumentationResult{
            .result = try current.instrument(program_target, .{
                .allocator = common.allocator,
                .used_buffers = general_params.used_buffers,
                .used_interface = empty,
                .max_attachments = 0,
                .max_buffers = general_params.max_buffers,
                .max_xfb = 0,
                .vertices = 0,
                .instances = 0,
                .screen = [_]usize{ 0, 0 },
                .compute = [_]usize{
                    num_groups[0],
                    num_groups[1],
                    num_groups[2],
                    @intCast(group_sizes[0]),
                    @intCast(group_sizes[1]),
                    @intCast(group_sizes[2]),
                },
            }),
            .platform_params = .{ .program = program_ref },
        };
    } else {
        log.warn("Program {d} not found in database", .{program_ref});
        return error.NoProgramFound;
    }
}

fn beginXfbQueries() void {
    const c_state = state.getPtr(current).?;
    const queries = &c_state.primitives_written_queries;
    for (0..@intCast(c_state.max_xfb_buffers)) |i| {
        var xfb_stream: gl.GLint = 0;
        gl.getIntegeri_v(gl.TRANSFORM_FEEDBACK_BUFFER_BINDING, @intCast(i), &xfb_stream);
        if (xfb_stream != 0) {
            queries.ensureTotalCapacity(common.allocator, i) catch |err| {
                log.err("Failed to allocate memory for xfb queries: {}", .{err});
                return;
            };
            const len = queries.items.len;
            if (len <= i) {
                queries.expandToCapacity();
                for (len..i) |q| {
                    queries.items[q] = 0; // any valid id would be probably greater... I promise
                }
            }
            if (queries.items[i] == 0) {
                gl.genQueries(1, &queries.items[i]);
            }
            gl.beginQueryIndexed(gl.TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN, @intCast(i), queries.items[i]);
        }
    }
}

fn endXfbQueries() void {
    const c_state = state.getPtr(current).?;
    const queries = &c_state.primitives_written_queries;
    for (0..@intCast(c_state.max_xfb_buffers)) |i| { // TODO streams vs buffers
        if (queries.items[i] != -1) {
            gl.endQueryIndexed(gl.TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN, @intCast(i));
        }
    }
}

fn dispatchDebug(
    result_or_error: @typeInfo(@TypeOf(instrumentDraw)).Fn.return_type.?,
    comptime dispatch_func: anytype,
    d_args: anytype,
) void {
    dispatchDebugImpl(result_or_error, dispatch_func, d_args, false);
}

fn dispatchDebugImpl(
    result_or_error: @typeInfo(@TypeOf(instrumentDraw)).Fn.return_type.?,
    comptime dispatch_func: anytype,
    d_args: anytype,
    comptime xfb: bool,
) void {
    _ = _try: {
        while (true) {
            shaders.user_action = false;
            const prepared = prepareStorage(result_or_error catch |err| break :_try err) catch |err| break :_try err;
            if (xfb) {
                beginXfbQueries();
            }
            @call(.auto, dispatch_func, d_args);
            if (xfb) {
                endXfbQueries();
            }
            processOutput(prepared) catch |err| break :_try err;
            if (!shaders.user_action) {
                break;
            }
        }
    } catch |err| {
        log.err("Failed to process instrumentation: {} {}", .{ err, @errorReturnTrace() orelse &common.null_trace });
    };
}

// TODO
// pub export fn glDispatchComputeGroupSizeARB(num_groups_x: gl.GLuint, num_groups_y: gl.GLuint, num_groups_z: gl.GLuint, group_size_x: gl.GLuint, group_size_y: gl.GLuint, group_size_z: gl.GLuint) void {
//     if (shaders.instance.checkDebuggingOrRevert()) {
//         dispatchDebug(instrumentCompute, .{[_]usize{ @intCast(num_groups_x), @intCast(num_groups_y), @intCast(num_groups_z) }},gl.dispatchComputeGroupSizeARB,.{num_groups_x, num_groups_y, num_groups_z, group_size_x, group_size_y, group_size_z});
//     } else gl.dispatchComputeGroupSizeARB(num_groups_x, num_groups_y, num_groups_z, group_size_x, group_size_y, group_size_z);
// }

pub export fn glDispatchCompute(num_groups_x: gl.GLuint, num_groups_y: gl.GLuint, num_groups_z: gl.GLuint) void {
    if (current.checkDebuggingOrRevert()) {
        dispatchDebug(instrumentCompute([_]usize{ @intCast(num_groups_x), @intCast(num_groups_y), @intCast(num_groups_z) }), gl.dispatchCompute, .{ num_groups_x, num_groups_y, num_groups_z });
    } else gl.dispatchCompute(num_groups_x, num_groups_y, num_groups_z);
}

const IndirectComputeCommand = extern struct {
    num_groups_x: gl.GLuint,
    num_groups_y: gl.GLuint,
    num_groups_z: gl.GLuint,
};
pub export fn glDispatchComputeIndirect(address: gl.GLintptr) void {
    if (current.checkDebuggingOrRevert()) {
        var command = IndirectComputeCommand{ .num_groups_x = 1, .num_groups_y = 1, .num_groups_z = 1 };
        //check GL_DISPATCH_INDIRECT_BUFFER
        var buffer: gl.GLint = 0;
        gl.getIntegerv(gl.DISPATCH_INDIRECT_BUFFER_BINDING, @ptrCast(&buffer));
        if (buffer != 0) {
            gl.getNamedBufferSubData(@intCast(buffer), address, @sizeOf(IndirectComputeCommand), &command);
        }

        dispatchDebug(instrumentCompute([_]usize{ @intCast(command.num_groups_x), @intCast(command.num_groups_y), @intCast(command.num_groups_z) }), gl.dispatchComputeIndirect, .{address});
    } else gl.dispatchComputeIndirect(address);
}

pub export fn glDrawArrays(mode: gl.GLenum, first: gl.GLint, count: gl.GLsizei) void {
    if (current.checkDebuggingOrRevert()) {
        dispatchDebugImpl(instrumentDraw(count, 1), gl.drawArrays, .{ mode, first, count }, true);
    } else gl.drawArrays(mode, first, count);
}

pub export fn glDrawArraysInstanced(mode: gl.GLenum, first: gl.GLint, count: gl.GLsizei, instanceCount: gl.GLsizei) void {
    if (current.checkDebuggingOrRevert()) {
        dispatchDebugImpl(instrumentDraw(count, instanceCount), gl.drawArraysInstanced, .{ mode, first, count, instanceCount }, true);
    } else gl.drawArraysInstanced(mode, first, count, instanceCount);
}

pub export fn glDrawElements(mode: gl.GLenum, count: gl.GLsizei, _type: gl.GLenum, indices: ?*const anyopaque) void {
    if (current.checkDebuggingOrRevert()) {
        dispatchDebugImpl(instrumentDraw(count, 1), gl.drawElements, .{ mode, count, _type, indices }, true);
    } else gl.drawElements(mode, count, _type, indices);
}

pub export fn glDrawElementsInstanced(mode: gl.GLenum, count: gl.GLsizei, _type: gl.GLenum, indices: ?*const anyopaque, instanceCount: gl.GLsizei) void {
    if (current.checkDebuggingOrRevert()) {
        dispatchDebugImpl(instrumentDraw(count, instanceCount), gl.drawElementsInstanced, .{ mode, count, _type, indices, instanceCount }, true);
    } else gl.drawElementsInstanced(mode, count, _type, indices, instanceCount);
}

pub export fn glDrawElementsBaseVertex(mode: gl.GLenum, count: gl.GLsizei, _type: gl.GLenum, indices: ?*const anyopaque, basevertex: gl.GLint) void {
    if (current.checkDebuggingOrRevert()) {
        dispatchDebugImpl(instrumentDraw(count, 1), gl.drawElementsBaseVertex, .{ mode, count, _type, indices, basevertex }, true);
    } else gl.drawElementsBaseVertex(mode, count, _type, indices, basevertex);
}

pub export fn glDrawElementsInstancedBaseVertex(mode: gl.GLenum, count: gl.GLsizei, _type: gl.GLenum, indices: ?*const anyopaque, instanceCount: gl.GLsizei, basevertex: gl.GLint) void {
    if (current.checkDebuggingOrRevert()) {
        dispatchDebugImpl(instrumentDraw(count, instanceCount), gl.drawElementsInstancedBaseVertex, .{ mode, count, _type, indices, instanceCount, basevertex }, true);
    } else gl.drawElementsInstancedBaseVertex(mode, count, _type, indices, instanceCount, basevertex);
}

pub export fn glDrawRangeElements(mode: gl.GLenum, start: gl.GLuint, end: gl.GLuint, count: gl.GLsizei, _type: gl.GLenum, indices: ?*const anyopaque) void {
    if (current.checkDebuggingOrRevert()) {
        dispatchDebugImpl(instrumentDraw(count, 1), gl.drawRangeElements, .{ mode, start, end, count, _type, indices }, true);
    } else gl.drawRangeElements(mode, start, end, count, _type, indices);
}

pub export fn glDrawRangeElementsBaseVertex(mode: gl.GLenum, start: gl.GLuint, end: gl.GLuint, count: gl.GLsizei, _type: gl.GLenum, indices: ?*const anyopaque, basevertex: gl.GLint) void {
    if (current.checkDebuggingOrRevert()) {
        dispatchDebugImpl(instrumentDraw(count, 1), gl.drawRangeElementsBaseVertex, .{ mode, start, end, count, _type, indices, basevertex }, true);
    } else gl.drawRangeElementsBaseVertex(mode, start, end, count, _type, indices, basevertex);
}

pub export fn glDrawElementsInstancedBaseVertexBaseInstance(mode: gl.GLenum, count: gl.GLsizei, _type: gl.GLenum, indices: ?*const anyopaque, instanceCount: gl.GLsizei, basevertex: gl.GLint, baseInstance: gl.GLuint) void {
    if (current.checkDebuggingOrRevert()) {
        dispatchDebugImpl(instrumentDraw(count, instanceCount), gl.drawElementsInstancedBaseVertexBaseInstance, .{ mode, count, _type, indices, instanceCount, basevertex, baseInstance }, true);
    } else gl.drawElementsInstancedBaseVertexBaseInstance(mode, count, _type, indices, instanceCount, basevertex, baseInstance);
}

pub export fn glDrawElementsInstancedBaseInstance(mode: gl.GLenum, count: gl.GLsizei, _type: gl.GLenum, indices: ?*const anyopaque, instanceCount: gl.GLsizei, baseInstance: gl.GLuint) void {
    if (current.checkDebuggingOrRevert()) {
        dispatchDebugImpl(instrumentDraw(count, instanceCount), gl.drawElementsInstancedBaseInstance, .{ mode, count, _type, indices, instanceCount, baseInstance }, true);
    } else gl.drawElementsInstancedBaseInstance(mode, count, _type, indices, instanceCount, baseInstance);
}

const IndirectCommand = extern struct {
    count: gl.GLuint, //again opengl mismatch GLuint vs GLint
    instanceCount: gl.GLuint,
    first: gl.GLuint,
    baseInstance: gl.GLuint,
};
pub fn parseIndirect(indirect: ?*const IndirectCommand) IndirectCommand {
    // check if GL_DRAW_INDIRECT_BUFFER is bound
    var buffer: gl.GLuint = 0;
    gl.getIntegerv(gl.DRAW_INDIRECT_BUFFER_BINDING, @ptrCast(&buffer));
    if (buffer != 0) {
        // get the data from the buffer
        var data: IndirectCommand = undefined;
        gl.getBufferSubData(gl.DRAW_INDIRECT_BUFFER, @intFromPtr(indirect), @intCast(@sizeOf(IndirectCommand)), &data);

        return data;
    }

    return if (indirect) |i| i.* else IndirectCommand{ .count = 0, .instanceCount = 1, .first = 0, .baseInstance = 0 };
}

pub export fn glDrawArraysIndirect(mode: gl.GLenum, indirect: ?*const IndirectCommand) void {
    if (current.checkDebuggingOrRevert()) {
        const i = parseIndirect(indirect);
        dispatchDebugImpl(instrumentDraw(@intCast(i.count), @intCast(i.instanceCount)), gl.drawArraysIndirect, .{ mode, indirect }, true);
    } else gl.drawArraysIndirect(mode, indirect);
}

pub export fn glDrawElementsIndirect(mode: gl.GLenum, _type: gl.GLenum, indirect: ?*const IndirectCommand) void {
    if (current.checkDebuggingOrRevert()) {
        const i = parseIndirect(indirect);
        dispatchDebugImpl(instrumentDraw(@intCast(i.count), @intCast(i.instanceCount)), gl.drawElementsIndirect, .{ mode, _type, indirect }, true);
    } else gl.drawElementsIndirect(mode, _type, indirect);
}

pub export fn glDrawArraysInstancedBaseInstance(mode: gl.GLenum, first: gl.GLint, count: gl.GLsizei, instanceCount: gl.GLsizei, baseInstance: gl.GLuint) void {
    if (current.checkDebuggingOrRevert()) {
        dispatchDebugImpl(instrumentDraw(count, instanceCount), gl.drawArraysInstancedBaseInstance, .{ mode, first, count, instanceCount, baseInstance }, true);
    } else gl.drawArraysInstancedBaseInstance(mode, first, count, instanceCount, baseInstance);
}

pub export fn glDrawTransformFeedback(mode: gl.GLenum, id: gl.GLuint) void {
    if (current.checkDebuggingOrRevert()) {
        const query = state.getPtr(current).?.primitives_written_queries.items[0];
        // get GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN
        var primitiveCount: gl.GLint = undefined;
        gl.getQueryObjectiv(query, gl.QUERY_RESULT, &primitiveCount);
        dispatchDebugImpl(instrumentDraw(primitiveCount, 1), gl.drawTransformFeedback, .{ mode, id }, true);
    } else gl.drawTransformFeedback(mode, id);
}

pub export fn glDrawTransformFeedbackInstanced(mode: gl.GLenum, id: gl.GLuint, instanceCount: gl.GLsizei) void {
    if (current.checkDebuggingOrRevert()) {
        const query = state.getPtr(current).?.primitives_written_queries.items[0];
        // get GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN
        var primitiveCount: gl.GLint = undefined;
        gl.getQueryObjectiv(query, gl.QUERY_RESULT, &primitiveCount);
        dispatchDebugImpl(instrumentDraw(primitiveCount, instanceCount), gl.drawTransformFeedbackInstanced, .{ mode, id, instanceCount }, true);
    } else gl.drawTransformFeedbackInstanced(mode, id, instanceCount);
}

pub export fn glDrawTransformFeedbackStream(mode: gl.GLenum, id: gl.GLuint, stream: gl.GLuint) void {
    if (current.checkDebuggingOrRevert()) {
        const query = state.getPtr(current).?.primitives_written_queries.items[stream];
        // get GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN
        var primitiveCount: gl.GLint = undefined;
        gl.getQueryObjectiv(query, gl.QUERY_RESULT, &primitiveCount);
        dispatchDebugImpl(instrumentDraw(primitiveCount, 1), gl.drawTransformFeedbackStream, .{ mode, id, stream }, true);
    } else gl.drawTransformFeedbackStream(mode, id, stream);
}

pub export fn glDrawTransformFeedbackStreamInstanced(mode: gl.GLenum, id: gl.GLuint, stream: gl.GLuint, instanceCount: gl.GLsizei) void {
    if (current.checkDebuggingOrRevert()) {
        const query = state.getPtr(current).?.primitives_written_queries.items[stream];
        // get GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN
        var primitiveCount: gl.GLint = undefined;
        gl.getQueryObjectiv(query, gl.QUERY_RESULT, &primitiveCount);
        dispatchDebugImpl(instrumentDraw(primitiveCount, instanceCount), gl.drawTransformFeedbackStreamInstanced, .{ mode, id, stream, instanceCount }, true);
    } else gl.drawTransformFeedbackStreamInstanced(mode, id, stream, instanceCount);
}

/// For fast switch-branching on strings
fn hashStr(str: String) u32 {
    return std.hash.CityHash32.hash(str);
}

const MAX_SHADER_PRAGMA_SCAN = 128;
/// Supports pragmas:
/// #pragma deshader [property] "[value1]" "[value2]"
/// #pragma deshader source "path/to/virtual/or/workspace/relative/file.glsl"
/// #pragma deshader source-link "path/to/etc/file.glsl" - link to previous source
/// #pragma deshader source-purge-previous "path/to/etc/file.glsl" - purge previous source (if exists)
/// #pragma deshader workspace "/another/real/path" "/virtual/path" - include real path in vitual workspace
/// #pragma deshader workspace-overwrite "/absolute/real/path" "/virtual/path" - purge all previous virtual paths and include real path in vitual workspace
/// Does not support multiline pragmas with \ at the end of line
// TODO mutliple shaders for the same stage (OpenGL treats them as if concatenated)
pub export fn glShaderSource(shader: gl.GLuint, count: gl.GLsizei, sources: [*][*:0]const gl.GLchar, lengths: ?[*]gl.GLint) void {
    std.debug.assert(count != 0);
    const single_chunk = commands.setting_vars.singleChunkShader;

    // convert from gl.GLint to usize array
    const wide_count: usize = @intCast(count);
    var lengths_wide: ?[*]usize = if (lengths != null or single_chunk) (common.allocator.alloc(usize, wide_count) catch |err| {
        log.err("Failed to allocate memory for shader sources lengths: {any}", .{err});
        return;
    }).ptr else null;
    var total_length: usize = if (single_chunk) 0 else undefined;

    var merged: [:0]u8 = undefined;
    defer if (single_chunk) common.allocator.free(merged);

    if (lengths != null) {
        for (lengths.?[0..wide_count], lengths_wide.?[0..wide_count]) |len, *target| {
            target.* = @intCast(len);
            if (single_chunk) {
                total_length += target.*;
            }
        }
    }
    if (single_chunk) {
        if (lengths == null) {
            for (sources[0..wide_count], lengths_wide.?) |s, *l| {
                const len = std.mem.len(s);
                l.* = len;
                total_length += len;
            }
        }
        merged = common.allocator.allocSentinel(u8, total_length, 0) catch |err| {
            log.err("Failed to allocate memory for shader sources lengths: {any}", .{err});
            return;
        };

        var offset: usize = 0;
        for (sources[0..wide_count], 0..) |s, i| {
            const len = lengths_wide.?[i];
            @memcpy(merged[offset .. offset + len], s[0..len]);
            offset += len;
        }
    }
    defer if (lengths_wide) |l| common.allocator.free(l[0..wide_count]);

    const shader_wide: usize = @intCast(shader);
    // Create untagged shader source
    current.sourceSource(decls.SourcesPayload{
        .ref = shader_wide,
        .count = if (single_chunk) 1 else wide_count,
        .sources = if (single_chunk) (&[_]CString{merged.ptr}).ptr else sources,
        .lengths = if (single_chunk) (&[_]usize{total_length}).ptr else lengths_wide,
        .language = decls.LanguageType.GLSL,
    }, true) catch |err| {
        log.warn("Failed to add shader source {x} cache: {any}", .{ shader, err });
    };
    gl.shaderSource(shader, count, sources, lengths);

    // Maybe assign tag and create workspaces
    // Scan for pragmas
    for (if (single_chunk) &.{merged.ptr} else sources[0..wide_count], if (single_chunk) &.{total_length} else lengths_wide.?[0..wide_count], 0..) |source, len, source_i| {
        var it = std.mem.splitScalar(u8, source[0..len], '\n');
        var in_block_comment = false;
        var line_i: usize = 0;
        while (it.next()) |line| : (line_i += 1) {
            // GLSL cannot have strings so we can just search for uncommented pragma
            var pragma_found: usize = std.math.maxInt(usize);
            var comment_found: usize = std.math.maxInt(usize);
            const pragma_text = "#pragma deshader";
            if (std.ascii.indexOfIgnoreCase(line, pragma_text)) |i| {
                pragma_found = i;
            }
            if (std.mem.indexOf(u8, line, "/*")) |i| {
                if (i < pragma_found) {
                    in_block_comment = true;
                    comment_found = @min(comment_found, i);
                }
            }
            if (std.mem.indexOf(u8, line, "*/")) |_| {
                in_block_comment = false;
            }
            if (std.mem.indexOf(u8, line, "//")) |i| {
                if (i < pragma_found) {
                    comment_found = @min(comment_found, i);
                }
            }
            if (pragma_found != std.math.maxInt(usize)) {
                if (comment_found > pragma_found and !in_block_comment) {
                    var arg_iter = common.CliArgsIterator{ .s = line, .i = pragma_found + pragma_text.len };
                    // skip leading whitespace
                    while (line[arg_iter.i] == ' ' or line[arg_iter.i] == '\t') {
                        arg_iter.i += 1;
                    }
                    var ec = args.ErrorCollection.init(common.allocator);
                    defer ec.deinit();
                    if (args.parseWithVerb(
                        struct {},
                        union(enum) {
                            breakpoint: void,
                            workspace: void,
                            source: void,
                            @"source-link": void,
                            @"source-purge-previous": void,
                        },
                        &arg_iter,
                        common.allocator,
                        args.ErrorHandling{ .collect = &ec },
                    )) |options| {
                        defer options.deinit();
                        if (options.verb) |v| {
                            switch (v) {
                                // Workspace include
                                .workspace => {
                                    current.mapPhysicalToVirtual(options.positionals[0], .{ .sources = .{ .tagged = options.positionals[1] } }) catch |err| failedWorkspacePath(options.positionals[0], err);
                                },
                                .source => {
                                    current.Shaders.assignTag(shader_wide, source_i, options.positionals[0], .Error) catch |err| objLabErr(options.positionals[0], shader, source_i, err);
                                },
                                .@"source-link" => {
                                    current.Shaders.assignTag(shader_wide, source_i, options.positionals[0], .Link) catch |err| objLabErr(options.positionals[0], shader, source_i, err);
                                },
                                .@"source-purge-previous" => {
                                    current.Shaders.assignTag(shader_wide, source_i, options.positionals[0], .Overwrite) catch |err| objLabErr(options.positionals[0], shader, source_i, err);
                                },
                                .breakpoint => {
                                    const new = debug.SourceBreakpoint{ .line = line_i + 1 }; // The breakpoint is in fact targeted on the next line
                                    if (current.addBreakpoint(.{ .untagged = .{ .ref = shader_wide, .part = source_i } }, new)) |bp| {
                                        if (bp.id) |stop_id| { // if verified
                                            log.debug("Shader {x} part {d}: breakpoint at line {d}, column {?d}", .{ shader, source_i, line_i, bp.column });
                                            // push an event to the debugger
                                            if (common.command_listener != null and common.command_listener.?.hasClient()) {
                                                common.command_listener.?.sendEvent(.breakpoint, debug.BreakpointEvent{ .breakpoint = bp, .reason = .new }) catch {};
                                            } else {
                                                current.breakpoints_to_send.append(current.allocator, .{ shader, source_i, stop_id }) catch {};
                                            }
                                        } else {
                                            log.warn("Breakpoint at line {d} for shader {x} part {d} could not be placed.", .{ line_i, source_i, shader });
                                        }
                                    } else |err| {
                                        log.warn("Failed to add breakpoint for shader {x} part {d}: {any}", .{ shader, source_i, err });
                                    }
                                },
                            }
                        } else {
                            log.warn("Unknown pragma: {s}", .{line});
                        }
                    } else |err| {
                        log.warn("Failed to parse pragma in shader source: {s}, because of {}", .{ line, err });
                    }
                    for (ec.errors()) |err| {
                        log.info("Pragma parsing: {} at {s}", .{ err.kind, err.option });
                    }
                } else {
                    log.debug("Ignoring pragma in shader source: {s}, because is at {d} and comment at {d}, block: {any}", .{ line, pragma_found, comment_found, in_block_comment });
                }
            }
        }
    }
}

pub export fn glCreateProgram() gl.GLuint {
    const new_platform_program = gl.createProgram();
    current.programCreateUntagged(decls.ProgramPayload{
        .ref = @intCast(new_platform_program),
        .link = defaultLink,
    }) catch |err| {
        log.warn("Failed to add program {x} to storage: {any}", .{ new_platform_program, err });
    };

    return new_platform_program;
}

pub export fn glAttachShader(program: gl.GLuint, shader: gl.GLuint) void {
    current.programAttachSource(@intCast(program), @intCast(shader)) catch |err| {
        log.err("Failed to attach shader {x} to program {x}: {any}", .{ shader, program, err });
    };

    gl.attachShader(program, shader);
}

pub export fn glDetachShader(program: gl.GLuint, shader: gl.GLuint) void {
    current.programDetachSource(@intCast(program), @intCast(shader)) catch |err| {
        log.err("Failed to detach shader {x} from program {x}: {any}", .{ shader, program, err });
    };

    gl.detachShader(program, shader);
}

fn objLabErr(label: String, name: gl.GLuint, index: usize, err: anytype) void {
    log.err("Failed to assign tag {s} for {d} index {d}: {any}", .{ label, name, index, err });
}

fn realLength(length: gl.GLsizei, label: ?CString) usize {
    if (length < 0) {
        // Then label is null-terminated and length is ignored.
        return std.mem.len(label.?);
    } else {
        return @intCast(length);
    }
}

/// Label expressed as fragment.frag or separately for each part like 0:include.glsl;1:program.frag
/// 0 is index of shader source part
/// include.glsl is tag for shader source part
/// Tags for program parts are separated by ;
///
/// To permit using same virtual path for multiple shader sources use
/// l0:path/to/file.glsl
/// To purge all previous source parts linked with this path use
/// p0:path/to/file.glsl
/// To link with a physical file, use virtual path relative to some workspace root. Use glDebugMessageInsert or #pragma deshader workspace to set workspace roots.
pub export fn glObjectLabel(identifier: gl.GLenum, name: gl.GLuint, length: gl.GLsizei, label: ?CString) void {
    if (label == null) {
        // Then the tag is meant to be removed.
        switch (identifier) {
            gl.PROGRAM => current.Programs.untagIndex(name, 0) catch |err| {
                log.warn("Failed to remove tag for program {x}: {any}", .{ name, err });
            },
            gl.SHADER => current.Shaders.untagAll(name) catch |err| {
                log.warn("Failed to remove all tags for shader {x}: {any}", .{ name, err });
            },
            else => {}, // TODO support other objects?
        }
    } else {
        const real_length = realLength(length, label);
        switch (identifier) {
            gl.SHADER => {
                if (std.mem.indexOfScalar(u8, label.?[0..128], ':') != null) {
                    var it = std.mem.splitScalar(u8, label.?[0..real_length], ';');
                    while (it.next()) |current_p| {
                        var it2 = std.mem.splitScalar(u8, current_p, ':');
                        var first = it2.first();
                        var behavior = decls.ExistsBehavior.Error;
                        switch (first[0]) {
                            'l' => {
                                first = first[1..first.len];
                                behavior = .Link;
                            },
                            'p' => {
                                first = first[1..first.len];
                                behavior = .Overwrite;
                            },
                            else => {},
                        }
                        const index = std.fmt.parseUnsigned(usize, first, 10) catch std.math.maxInt(usize);
                        const tag = it2.next();
                        if (tag == null or index == std.math.maxInt(usize)) {
                            log.err("Failed to parse tag {s} for shader {x}", .{ current_p, name });
                            continue;
                        }
                        current.Shaders.assignTag(@intCast(name), index, tag.?, behavior) catch |err| objLabErr(label.?[0..real_length], name, index, err);
                    }
                } else {
                    current.Shaders.assignTag(@intCast(name), 0, label.?[0..real_length], .Error) catch |err| objLabErr(label.?[0..real_length], name, 0, err);
                }
            },
            gl.PROGRAM => current.Programs.assignTag(@intCast(name), 0, label.?[0..real_length], .Error) catch |err| objLabErr(label.?[0..real_length], name, 0, err),
            else => {}, // TODO support other objects?
        }
    }
}

fn failedWorkspacePath(path: String, err: anytype) void {
    log.warn("Failed to add workspace path {s}: {any}", .{ path, err });
}
fn failedRemoveWorkspacePath(path: String, err: anytype) void {
    log.warn("Failed to remove workspace path {s}: {any}", .{ path, err });
}

/// use glDebugMessageInsert with these parameters to set workspace root
/// source = GL_DEBUG_SOURCE_APPLICATION
/// type = DEBUG_TYPE_OTHER
/// severity = GL_DEBUG_SEVERITY_HIGH
/// buf = /real/absolute/workspace/root<-/virtual/workspace/root
///
/// id = 0xde5ade4 == 233156068 => add workspace
/// id = 0xde5ade5 == 233156069 => remove workspace with the name specified in `buf` or remove all (when buf == null)
pub export fn glDebugMessageInsert(source: gl.GLenum, _type: gl.GLenum, id: gl.GLuint, severity: gl.GLenum, length: gl.GLsizei, buf: ?[*:0]const gl.GLchar) void {
    if (source == gl.DEBUG_SOURCE_APPLICATION and _type == gl.DEBUG_TYPE_OTHER and severity == gl.DEBUG_SEVERITY_HIGH) {
        switch (id) {
            ids.COMMAND_WORKSPACE_ADD => {
                if (buf != null) { //Add
                    const real_length = realLength(length, buf);
                    var it = std.mem.split(u8, buf.?[0..real_length], "<-");
                    if (it.next()) |real_path| {
                        if (it.next()) |virtual_path| {
                            current.mapPhysicalToVirtual(real_path, .{ .sources = .{ .tagged = virtual_path } }) catch |err| failedWorkspacePath(buf.?[0..real_length], err);
                        } else failedWorkspacePath(buf.?[0..real_length], error.@"No virtual path specified");
                    } else failedWorkspacePath(buf.?[0..real_length], error.@"No real path specified");
                }
            },
            ids.COMMAND_WORKSPACE_REMOVE => if (buf == null) { //Remove all
                current.clearWorkspacePaths();
            } else { //Remove
                const real_length = realLength(length, buf);
                var it = std.mem.split(u8, buf.?[0..real_length], "<-");
                if (it.next()) |real_path| {
                    if (!(current.removeWorkspacePath(real_path, if (it.next()) |v| shaders.GenericLocator.parse(v) catch |err| return failedRemoveWorkspacePath(buf.?[0..real_length], err) else null) catch false)) {
                        failedRemoveWorkspacePath(buf.?[0..real_length], error.@"No such real path in workspace");
                    }
                }
            },
            ids.COMMAND_EDITOR_SHOW => _ = main.deshaderEditorWindowShow(),
            ids.COMMAND_EDITOR_TERMINATE => _ = main.deshaderEditorWindowTerminate(),
            ids.COMMAND_EDITOR_WAIT => _ = main.deshaderEditorWindowWait(),
            else => {},
        }
    }
    gl.debugMessageInsert(source, _type, id, severity, length, buf);
}
const ids_array = blk: {
    const ids_decls = @typeInfo(ids).Struct.decls;
    var command_count = 0;
    @setEvalBranchQuota(2000);
    for (ids_decls) |decl| {
        if (std.mem.startsWith(u8, decl.name, "COMMAND_")) {
            command_count += 1;
        }
    }
    var vals: [command_count]c_uint = undefined;
    var i = 0;
    @setEvalBranchQuota(3000);
    for (ids_decls) |decl| {
        if (std.mem.startsWith(u8, decl.name, "COMMAND_")) {
            vals[i] = @field(ids, decl.name);
            i += 1;
        }
    }
    break :blk vals;
};

/// Fallback for compatibility with OpenGL < 4.3
/// Used from C when DESHADER_COMPATIBILITY is set
pub export fn glTransformFeedbackVaryings(_program: gl.GLuint, length: gl.GLsizei, buf: ?[*:0]const gl.GLchar, id: gl.GLenum) void {
    if (_program == 0) {
        if (std.mem.indexOfScalar(c_uint, &ids_array, id) != null) {
            glDebugMessageInsert(gl.DEBUG_SOURCE_APPLICATION, gl.DEBUG_TYPE_OTHER, id, gl.DEBUG_SEVERITY_HIGH, length, buf);
        }
    }
    gl.transformFeedbackVaryings(_program, length, @alignCast(@ptrCast(buf)), id);
}

//TODO glSpecializeShader glShaderBinary
//TODO SGI context extensions
pub const context_procs = if (builtin.os.tag == .windows)
    struct {
        pub export fn wglMakeCurrent(hdc: *const anyopaque, context: ?*const anyopaque) c_int {
            const result = loaders.APIs.gl.wgl.make_current[0](hdc, context);
            if (context) |c| makeCurrent(loaders.APIs.gl.wgl, c);
            return result;
        }

        pub export fn wglMakeContextCurrentARB(hdc: *const anyopaque, read: *const anyopaque, write: *const anyopaque, context: *const anyopaque) c_int {
            const result = loaders.APIs.gl.wgl.make_current[1](hdc, read, write, context);
            if (context) |c| makeCurrent(loaders.APIs.gl.wgl, c);
            return result;
        }

        pub export fn wglCreateContextAttribsARB(hdc: *const anyopaque, share: *const anyopaque, attribs: ?[*]c_int) *const anyopaque {
            const result = loaders.APIs.gl.wgl.create[1](hdc, share, attribs);
            if (result) {
                makeCurrent(loaders.APIs.gl.wgl, result);
            }
            return result;
        }

        pub export fn wglCreateContext(hdc: *const anyopaque) *const anyopaque {
            const result = loaders.APIs.gl.wgl.create[0](hdc);
            if (result) {
                makeCurrent(loaders.APIs.gl.wgl, result);
            }
            return result;
        }
    }
else
    struct {
        pub export fn glXMakeCurrent(display: *const anyopaque, drawable: c_ulong, context: ?*const anyopaque) c_int {
            const result = loaders.APIs.gl.glX.make_current[0](display, drawable, context);
            if (context) |c| makeCurrent(loaders.APIs.gl.glX, c);
            return result;
        }

        pub export fn glXMakeContextCurrent(display: *const anyopaque, read: c_ulong, write: c_ulong, context: ?*const anyopaque) c_int {
            const result = loaders.APIs.gl.glX.make_current[1](display, read, write, context);
            if (context) |c| makeCurrent(loaders.APIs.gl.glX, c);
            return result;
        }

        pub export fn glXCreateContext(display: *const anyopaque, vis: *const anyopaque, share: *const anyopaque, direct: c_int) ?*const anyopaque {
            const result = loaders.APIs.gl.glX.create[0](display, vis, share, direct);
            if (result) |r| {
                makeCurrent(loaders.APIs.gl.glX, r);
            }
            return result;
        }

        pub export fn glXCreateNewContext(display: *const anyopaque, render_type: c_int, share: *const anyopaque, direct: c_int) ?*const anyopaque {
            const result = loaders.APIs.gl.glX.create[1](display, render_type, share, direct);
            if (result) |r| {
                makeCurrent(loaders.APIs.gl.glX, r);
            }
            return result;
        }

        pub export fn glXCreateContextAttribsARB(display: *const anyopaque, vis: *const anyopaque, share: *const anyopaque, direct: c_int, attribs: ?[*]const c_int) ?*const anyopaque {
            const result = loaders.APIs.gl.glX.create[2](display, vis, share, direct, attribs);
            if (result) |r| {
                makeCurrent(loaders.APIs.gl.glX, r);
            }
            return result;
        }

        pub export fn eglMakeCurrent(display: *const anyopaque, read: *const anyopaque, write: *const anyopaque, context: ?*const anyopaque) c_uint {
            const result = loaders.APIs.gl.egl.make_current[0](display, read, write, context);
            if (context) |c| makeCurrent(loaders.APIs.gl.egl, c);
            return result;
        }

        pub export fn eglCreateContext(display: *const anyopaque, config: *const anyopaque, share: *const anyopaque, attribs: ?[*]c_int) ?*const anyopaque {
            const result = loaders.APIs.gl.egl.create[0](display, config, share, attribs);
            if (result) |r| {
                makeCurrent(loaders.APIs.gl.egl, r);
            }
            return result;
        }
    };

pub fn supportCheck(extension_iterator: anytype) bool {
    while (extension_iterator.next()) |ex| {
        if (std.mem.endsWith(u8, ex, "shader_storage_buffer_object")) {
            return true;
        }
    }
    return false;
}

// TODO destroying contexts
/// Performs context switching and initialization
pub fn makeCurrent(comptime api: anytype, context: *const anyopaque) void {
    _ = _try: {
        const result = shaders.services.getOrPut(common.allocator, context) catch |err| break :_try err;
        if (!result.found_existing) {
            if (!api.late_loaded) {
                loaders.loadGlLib() catch |err| break :_try err;
                // Late load all GL funcitions
                gl.load(api.loader.?, loaders.useLoader) catch |err|
                    log.err("Failed to load some GL functions: {any}", .{err});
                api.late_loaded = true;
            }

            log.debug("Initializing service {x} for context {x}", .{ @intFromPtr(result.value_ptr), @intFromPtr(context) });
            const buffers_supported = blk: {
                if (gl.getString(gl.EXTENSIONS)) |exs| {
                    var it = std.mem.splitScalar(u8, std.mem.span(exs), ' ');
                    break :blk supportCheck(&it);
                }
                // getString vs getStringi
                const ExtensionInterator = struct {
                    num: gl.GLint,
                    i: gl.GLuint,

                    fn next(self: *@This()) ?String {
                        const ex = gl.getStringi(gl.EXTENSIONS, self.i);
                        self.i += 1;
                        return if (ex) |e| std.mem.span(e) else null;
                    }
                };
                var it = ExtensionInterator{ .num = undefined, .i = 0 };
                gl.getIntegerv(gl.NUM_EXTENSIONS, &it.num);
                break :blk supportCheck(&it);
            };

            result.value_ptr.* = shaders{ .context = context, .support = .{
                .buffers = buffers_supported,
            } };

            // Initialize per-context variables
            const c_state = (state.getOrPut(common.allocator, result.value_ptr) catch |err| break :_try err).value_ptr;
            c_state.* = .{};
            if (c_state.max_xfb_streams == 0) {
                gl.getIntegerv(gl.MAX_COLOR_ATTACHMENTS, @ptrCast(&c_state.max_attachments));
                gl.getIntegerv(gl.MAX_TRANSFORM_FEEDBACK_BUFFERS, &c_state.max_xfb_buffers);
                gl.getIntegerv(gl.MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS, &c_state.max_xfb_interleaved_components);
                gl.getIntegerv(gl.MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS, &c_state.max_xfb_sep_attribs);
                gl.getIntegerv(gl.MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS, &c_state.max_xfb_sep_components);
                gl.getIntegerv(gl.MAX_VERTEX_STREAMS, &c_state.max_xfb_streams);
            }

            result.value_ptr.init(common.allocator) catch |err| break :_try err;

            // Send a notification to debug adapter client
            if (common.command_listener) |cl| {
                cl.sendEvent(.invalidated, debug.InvalidatedEvent{ .areas = &.{.contexts}, .numContexts = shaders.services.count() }) catch |err| break :_try err;
            }
        }
        current = result.value_ptr;
    } catch |err| {
        log.err("Failed to init GL library {}", .{err});
    };
}

pub fn deinit() void {
    for (shaders.services.values()) |*val| {
        val.deinit();
    }
    shaders.services.deinit(common.allocator);
    var per_context_it = state.valueIterator();
    while (per_context_it.next()) |s| {
        var it = s.readback_step_buffers.valueIterator();
        while (it.next()) |val| {
            common.allocator.free(val.*);
        }
        s.readback_step_buffers.deinit(common.allocator);
        gl.deleteQueries(@intCast(s.primitives_written_queries.items.len), s.primitives_written_queries.items.ptr);
        s.primitives_written_queries.deinit(common.allocator);

        s.unifoms_for_shaders.deinit(common.allocator);
        for (s.replacement_attachment_textures) |t| {
            if (t != 0) {
                gl.deleteTextures(1, &t);
            }
        }
        if (s.stack_trace_ref != gl.NONE) {
            gl.deleteBuffers(1, &s.stack_trace_ref);
        }
    }
    state.deinit(common.allocator);
}