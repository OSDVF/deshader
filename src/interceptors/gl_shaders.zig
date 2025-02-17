// Copyright (C) 2024  Ondřej Sabela
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
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

//! Rendering and shader instrumentation service implementation for OpenGL.
//! Contains functions prefixed with `gl` which are interceptor functions for OpenGL API calls.

// TODO: support MESA debug extensions? (MESA_program_debug, MESA_shader_debug)
// TODO: support GL_ARB_shading_language_include (nvidia's), GL_GOOGLE_include_directive and GL_GOOGLE_cpp_style_line_directive
// TODO: error checking
// TODO: support older OpenGL, GLES
// https://github.com/msqrt/shader-printf
// TODO: deleting objects
const std = @import("std");
const builtin = @import("builtin");
const gl = @import("gl");
const options = @import("options");
const decls = @import("../declarations/shaders.zig");
const shaders = @import("../services/shaders.zig");
const storage = @import("../services/storage.zig");
const instrumentation = @import("../services/instrumentation.zig");
const common = @import("common");
const log = common.log;
const commands = @import("../commands.zig");
const args = @import("args");
const main = @import("../main.zig");
const loaders = @import("loaders.zig");
const debug = @import("../services/debug.zig");
const ids = @cImport(@cInclude("commands.h"));

const CString = [*:0]const u8;
const String = []const u8;
const uvec2 = struct { u32, u32 };
const Support = instrumentation.Processor.Config.Support;
const Ref = usize;

const MAX_VARIABLES_SIZE = 1024 * 1024; // 1MB

const BufferType = enum(gl.@"enum") {
    AtomicCounter = gl.ATOMIC_COUNTER_BUFFER,
    ShaderStorage = gl.SHADER_STORAGE_BUFFER,
    TransformFeedback = gl.TRANSFORM_FEEDBACK_BUFFER,
    Uniform = gl.UNIFORM_BUFFER,
};
const UniformTargets = struct {
    thread_selector: ?gl.int = null,
    step_selector: ?gl.int = null,
    bp_selector: ?gl.int = null,
};

/// The service instance which belongs to currently selected context.
pub threadlocal var current: *shaders = undefined;

// Managed per-context state
const State = struct {
    proc_table: ?gl.ProcTable = null,
    readback_step_buffers: std.AutoHashMapUnmanaged(usize, []uvec2) = .{},
    stack_trace_buffer: [shaders.STACK_TRACE_MAX]shaders.StackTraceT = undefined,
    variables_buffer: [MAX_VARIABLES_SIZE]u8 = undefined,
    uniforms_for_shaders: std.AutoArrayHashMapUnmanaged(usize, UniformTargets) = .{},
    primitives_written_queries: std.ArrayListUnmanaged(gl.uint) = .{},

    // memory for used indexed buffer binding indexed. OpenGL does not provide a standard way to query them.
    indexed_buffer_bindings: std.EnumMap(BufferType, usize) = .{},
    search_paths: std.AutoHashMapUnmanaged(Ref, []String) = .{},

    // Handles for the debug output objects
    stack_trace_ref: gl.uint = gl.NONE,
    variables_ref: gl.uint = gl.NONE,
    print_ref: gl.uint = gl.NONE,
    replacement_attachment_textures: [32]gl.uint = [_]gl.uint{0} ** 32,
    debug_fbo: gl.uint = undefined,
    max_xfb_streams: gl.int = 0,
    max_xfb_buffers: gl.int = 0,
    max_xfb_sep_components: gl.int = 0,
    max_xfb_sep_attribs: gl.int = 0,
    max_xfb_interleaved_components: gl.int = 0,
    max_attachments: gl.uint = 0,

    fn deinit(s: *@This()) void {
        var sit = s.search_paths.valueIterator();
        while (sit.next()) |val| {
            for (val.*) |v| {
                common.allocator.free(v);
            }
            common.allocator.free(val.*);
        }
        s.search_paths.deinit(common.allocator);

        var it = s.readback_step_buffers.valueIterator();
        while (it.next()) |val| {
            common.allocator.free(val.*);
        }
        s.readback_step_buffers.deinit(common.allocator);
        const prev_proc_table = gl.getCurrentProcTable();
        gl.makeProcTableCurrent(@ptrCast(&s.proc_table));
        gl.DeleteQueries(@intCast(s.primitives_written_queries.items.len), s.primitives_written_queries.items.ptr);
        s.primitives_written_queries.deinit(common.allocator);

        s.uniforms_for_shaders.deinit(common.allocator);
        for (s.replacement_attachment_textures) |t| {
            if (t != 0) {
                gl.DeleteTextures(1, @constCast(@ptrCast(&t)));
            }
        }
        if (s.stack_trace_ref != gl.NONE) {
            gl.DeleteBuffers(1, (&s.stack_trace_ref)[0..1]);
        }
        if (s.variables_ref != gl.NONE) {
            gl.DeleteBuffers(1, @ptrCast(&s.variables_ref));
        }
        gl.makeProcTableCurrent(prev_proc_table);
    }
};
var state: std.AutoHashMapUnmanaged(*shaders, State) = .{};

fn defaultCompileShader(source: decls.SourcesPayload, instrumented: CString, length: i32) callconv(.C) u8 {
    const shader: gl.uint = @intCast(source.ref);
    if (length > 0) {
        gl.ShaderSource(shader, 1, @ptrCast(&instrumented), @ptrCast(&length));
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
        gl.ShaderSource(shader, @intCast(source.count), source.sources orelse {
            log.err("No sources provided for shader {d}", .{shader});
            return 1;
        }, if (lengths_i32) |l| l.ptr else null);
    }
    gl.CompileShader(shader);

    var info_length: gl.sizei = undefined;
    gl.GetShaderiv(shader, gl.INFO_LOG_LENGTH, &info_length);
    if (info_length > 0) {
        const info_log: [*:0]gl.char = common.allocator.allocSentinel(gl.char, @intCast(info_length - 1), 0) catch |err| {
            log.err("Failed to allocate memory for shader info log: {any}", .{err});
            return 1;
        };
        defer common.allocator.free(info_log[0..@intCast(info_length)]);
        gl.GetShaderInfoLog(shader, info_length, null, info_log);
        var paths: ?String = null;
        if (source.count > 0 and source.paths != null) {
            if (common.joinInnerZ(common.allocator, "; ", source.paths.?[0..source.count])) |joined| {
                paths = joined;
            } else |err| {
                log.warn("Failed to join shader paths: {any}", .{err});
            }
        }
        log.info("Shader {d} at path '{?s}' info:\n{s}", .{ shader, paths, info_log });
        var success: gl.int = undefined;
        gl.GetShaderiv(shader, gl.COMPILE_STATUS, &success);
        if (success == 0) {
            log.err("Shader {d} compilation failed", .{shader});
            return 1;
        }
    }
    return 0;
}

fn defaultGetShaderSource(ref: Ref, _: ?CString, _: usize) callconv(.C) ?CString {
    const shader: gl.uint = @intCast(ref);
    var length: gl.sizei = undefined;
    gl.GetShaderiv(shader, gl.SHADER_SOURCE_LENGTH, &length);
    if (length == 0) {
        log.err("Shader {d} has no source", .{shader});
        return null;
    }
    const source: [*:0]gl.char = common.allocator.allocSentinel(gl.char, @intCast(length), 0) catch |err| {
        log.err("Failed to allocate memory for shader source: {any}", .{err});
        return null;
    };
    defer common.allocator.free(source[0..@intCast(length)]);
    gl.GetShaderSource(shader, length, &length, source);
    return source;
}

/// If count is 0, the function will only link the program. Otherwise it will attach the shaders in the order they are stored in the payload.
fn defaultLink(self: decls.ProgramPayload) callconv(.C) u8 {
    const program: gl.uint = @intCast(self.ref);
    var i: usize = 0;
    while (i < self.count) : (i += 1) {
        gl.AttachShader(program, @intCast(self.shaders.?[i]));
        if (gl.GetError() != gl.NO_ERROR) {
            log.err("Failed to attach shader {d} to program {d}", .{ self.shaders.?[i], program });
            return 1;
        }
    }
    gl.LinkProgram(program);

    var info_length: gl.sizei = undefined;
    gl.GetProgramiv(program, gl.INFO_LOG_LENGTH, &info_length);
    if (info_length > 0) {
        const info_log: [*:0]gl.char = common.allocator.allocSentinel(gl.char, @intCast(info_length - 1), 0) catch |err| {
            log.err("Failed to allocate memory for program info log: {any}", .{err});
            return 1;
        };
        defer common.allocator.free(info_log[0..@intCast(info_length) :0]);

        gl.GetProgramInfoLog(program, info_length, &info_length, info_log);
        log.info("Program {d}:{?s} info:\n{s}", .{ program, self.path, info_log });

        var success: gl.int = undefined;
        gl.GetProgramiv(program, gl.LINK_STATUS, &success);
        if (success == 0) {
            log.err("Program {d} linking failed", .{program});
            return 1;
        }
    }
    return 0;
}

fn updateBufferIndexInfo(buffer: gl.uint, index: gl.uint, buffer_type: BufferType) void {
    const c_state = state.getPtr(current) orelse return;
    if (buffer == 0) { //un-bind
        c_state.indexed_buffer_bindings.put(buffer_type, 0);
    } else {
        const existing = c_state.indexed_buffer_bindings.get(buffer_type) orelse 0;
        c_state.indexed_buffer_bindings.put(buffer_type, existing | index);
    }
}

pub export fn glBindBufferBase(target: gl.@"enum", index: gl.uint, buffer: gl.uint) void {
    gl.BindBufferBase(target, index, buffer);
    if (gl.GetError() == gl.NO_ERROR) {
        updateBufferIndexInfo(buffer, index, @enumFromInt(target));
    }
}

pub export fn glBindBufferRange(target: gl.@"enum", index: gl.uint, buffer: gl.uint, offset: gl.intptr, size: gl.sizeiptr) void {
    gl.BindBufferRange(target, index, buffer, offset, size);
    if (gl.GetError() == gl.NO_ERROR) {
        updateBufferIndexInfo(buffer, index, @enumFromInt(target));
    }
}

pub export fn glCreateShader(stage: gl.@"enum") gl.uint {
    const new_platform_source = gl.CreateShader(stage);

    const ref: usize = @intCast(new_platform_source);
    if (current.Shaders.appendUntagged(ref)) |new| {
        new.stored.* = shaders.Shader.SourcePart.init(current.Shaders.allocator, decls.SourcesPayload{
            .ref = ref,
            .stage = @enumFromInt(stage),
            .compile = defaultCompileShader,
            .currentSource = defaultGetShaderSource,
            .count = 1,
            .language = decls.LanguageType.GLSL,
        }, 0) catch |err| {
            log.warn("Failed to add shader source {x} cache because of alocation: {any}", .{ new_platform_source, err });
            return new_platform_source;
        };
    } else |err| {
        log.warn("Failed to add shader source {x} cache: {any}", .{ new_platform_source, err });
    }

    return new_platform_source;
}

pub export fn glCreateShaderProgramv(stage: gl.@"enum", count: gl.sizei, sources: [*][*:0]const gl.char) gl.uint {
    const source_type: decls.Stage = @enumFromInt(stage);
    const new_platform_program = gl.CreateShaderProgramv(stage, count, sources);
    const new_platform_sources = common.allocator.alloc(gl.uint, @intCast(count)) catch |err| {
        log.err("Failed to allocate memory for shader sources: {any}", .{err});
        return 0;
    };
    defer common.allocator.free(new_platform_sources);

    var source_count: c_int = undefined;
    gl.GetAttachedShaders(new_platform_program, count, &source_count, new_platform_sources.ptr);
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
        .currentSource = defaultGetShaderSource,
        .language = decls.LanguageType.GLSL,
    }) catch |err| {
        log.warn("Failed to add shader source {x} cache: {any}", .{ new_platform_sources[0], err });
    };

    return new_platform_program;
}

/// Compile shaders with #include support
export fn glCompileShaderIncludeARB(shader: gl.uint, count: gl.sizei, paths: ?[*][*:0]const gl.char, lengths: ?[*:0]const gl.int) void {
    gl.CompileShaderIncludeARB(shader, count, paths, lengths);
    if (gl.GetError() != gl.NO_ERROR) {
        return;
    }

    // Store the search paths for the shader
    wrapErrorHandling(actions.updateSearchPaths, .{ shader, count, paths, lengths });
}

export fn glCompileShader(shader: gl.uint) void {
    gl.CompileShader(shader);
    if (gl.GetError() != gl.NO_ERROR) {
        return;
    }

    // Store the search paths for the shader
    wrapErrorHandling(actions.updateSearchPaths, .{ shader, 0, null, null });
}

// Functions to be wrapped by error handling
const actions = struct {
    fn updateSearchPaths(shader: gl.uint, count: gl.sizei, paths: ?[*][*:0]const gl.char, lengths: ?[*]const gl.int) !void {
        const c_state = state.getPtr(current) orelse return;
        if (paths) |p| {
            const paths_d = try common.allocator.alloc(String, @intCast(count));
            for (p, paths_d, 0..) |path, *d, i| {
                d.* = try common.allocator.dupe(u8, path[0..realLength(if (lengths) |l| l[i] else -1, path)]);
            }

            try c_state.search_paths.put(common.allocator, @intCast(shader), paths_d);
        } else {
            // Free the paths
            if (c_state.search_paths.fetchRemove(@intCast(shader))) |kv| {
                for (kv.value) |v| {
                    common.allocator.free(v);
                }
                common.allocator.free(kv.value);
            }
        }
    }

    fn createNamedString(namelen: gl.int, name: CString, stringlen: gl.int, string: CString) !void {
        const result = try current.Shaders.appendUntagged(0); // Special key 0 means "named strings"
        result.stored.* = try shaders.Shader.SourcePart.init(common.allocator, decls.SourcesPayload{
            .currentSource = namedStringSourceAlloc,
            .free = freeNamedString,
            .language = decls.LanguageType.GLSL,
            .lengths = &.{@intCast(stringlen)},
            .ref = 0,
            .sources = &.{string},
        }, 0);
        _ = try current.Shaders.assignTag(0, result.index, name[0..realLength(namelen, name)], .Error);
    }
};

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
        const shader: *std.ArrayListUnmanaged(shaders.Shader.SourcePart) = current.Shaders.all.get(shader_ref) orelse {
            log.warn("Shader {d} not found in the database", .{shader_ref});
            continue;
        };

        const selected_thread = instr_state.globalSelectedThread();
        if (instr_state.outputs.step_storage) |*stor| {
            // Retrieve the hit storage
            const threads_hits = c_state.readback_step_buffers.get(stor.ref.?).?;
            switch (stor.location) {
                .Interface => |interface| {
                    switch (current.Shaders.all.get(shader_ref).?.items[0].stage) {
                        .gl_fragment, .vk_fragment => {
                            var previous_pack_buffer: gl.uint = undefined; // save previous host state
                            gl.GetIntegerv(gl.PIXEL_PACK_BUFFER_BINDING, @ptrCast(&previous_pack_buffer));
                            gl.BindBuffer(gl.PIXEL_PACK_BUFFER, 0);

                            // blit to the original framebuffer
                            gl.BindFramebuffer(gl.READ_FRAMEBUFFER, c_state.debug_fbo);
                            gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, r.platform_params.previous_fbo);
                            var i: gl.@"enum" = 0;
                            while (i < r.platform_params.draw_buffers_len) : (i += 1) {
                                gl.ReadBuffer(@as(gl.@"enum", gl.COLOR_ATTACHMENT0) + i);
                                gl.DrawBuffer(r.platform_params.draw_buffers[i]);
                                gl.BlitFramebuffer(0, 0, @intCast(instr_state.params.screen[0]), @intCast(instr_state.params.screen[1]), 0, 0, @intCast(instr_state.params.screen[0]), @intCast(instr_state.params.screen[1]), gl.COLOR_BUFFER_BIT, gl.NEAREST);
                            }
                            gl.BlitFramebuffer(0, 0, @intCast(instr_state.params.screen[0]), @intCast(instr_state.params.screen[1]), 0, 0, @intCast(instr_state.params.screen[0]), @intCast(instr_state.params.screen[1]), gl.STENCIL_BUFFER_BIT | gl.DEPTH_BUFFER_BIT, gl.NEAREST);

                            // read pixels to the main memory
                            var previous_read_buffer: gl.@"enum" = undefined;
                            gl.GetIntegerv(gl.READ_BUFFER, @ptrCast(&previous_read_buffer));
                            gl.ReadBuffer(@as(gl.@"enum", @intCast(interface.location)) + gl.COLOR_ATTACHMENT0);

                            gl.ReadnPixels(
                                0,
                                0,
                                @intCast(instr_state.params.screen[0]),
                                @intCast(instr_state.params.screen[1]),
                                gl.RG_INTEGER,
                                gl.UNSIGNED_BYTE, // The same format as the texture
                                @intCast(threads_hits.len),
                                threads_hits.ptr,
                            );

                            // restore the previous framebuffer binding
                            gl.BindBuffer(gl.PIXEL_PACK_BUFFER, previous_pack_buffer);
                            gl.ReadBuffer(previous_read_buffer);

                            gl.BindFramebuffer(gl.FRAMEBUFFER, r.platform_params.previous_fbo);
                            gl.BindFramebuffer(gl.READ_FRAMEBUFFER, r.platform_params.previous_read_fbo);
                            gl.DrawBuffers(@intCast(r.platform_params.draw_buffers_len), &r.platform_params.draw_buffers);
                        },
                        else => unreachable, // TODO transform feedback
                    }
                },
                .Buffer => |_| {
                    gl.GetNamedBufferSubData(@intCast(stor.ref.?), 0, @intCast(threads_hits.len), threads_hits.ptr);
                },
            }

            // Scan for hits
            var max_hit: u32 = 0;
            var max_hit_id: u32 = 0;
            for (0..instr_state.outputs.totalThreadsCount()) |global_index| {
                const hit: uvec2 = threads_hits[global_index];
                if (hit[1] > 0) { // 1-based (0 means no hit)
                    const hit_id = hit[0];
                    const hit_index = hit[1] - 1;
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
        }

        if (instr_state.outputs.variables) |vars| {
            gl.GetNamedBufferSubData(c_state.variables_ref, 0, MAX_VARIABLES_SIZE, &c_state.variables_buffer);
            for (vars) |_| {}
        }

        if (instr_state.outputs.stack_trace) |_| {
            gl.GetNamedBufferSubData(c_state.stack_trace_ref, 0, shaders.STACK_TRACE_MAX * @sizeOf(shaders.StackTraceT), &c_state.stack_trace_buffer);
        }

        const running = try shaders.Running.Locator.from(current, shader_ref);
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
    }
}

fn deinitTexture(out_storage: *instrumentation.OutputStorage, _: std.mem.Allocator) void {
    if (out_storage.ref) |*r| {
        gl.DeleteTextures(1, @ptrCast(r));
        const entry = state.getPtr(current).?.readback_step_buffers.fetchRemove(r.*);
        if (entry) |e| {
            common.allocator.free(e.value);
        }
    }
}

fn deinitBuffer(out_storage: *instrumentation.OutputStorage, _: std.mem.Allocator) void {
    if (out_storage.ref) |r| {
        var cast: gl.uint = @intCast(r);
        gl.DeleteBuffers(1, (&cast)[0..1]);
    }
}

/// Prepare debug output buffers for instrumented shaders execution
fn prepareStorage(input: InstrumentationResult) !InstrumentationResult {
    var result = input; // make mutable
    if (result.result.invalidated) {
        if (commands.instance) |comm| {
            try comm.sendEvent(.invalidated, debug.InvalidatedEvent{ .areas = &.{debug.InvalidatedEvent.Areas.threads} });
        }
    }
    const c_state = state.getPtr(current) orelse return error.NoState;
    // Prepare storage for stack traces (there is always only one stack trace and the program which writes to it is dynamically selected)
    if (c_state.stack_trace_ref == gl.NONE) {
        gl.CreateBuffers(1, (&c_state.stack_trace_ref)[0..1]);
        gl.NamedBufferStorage(c_state.stack_trace_ref, shaders.STACK_TRACE_MAX * @sizeOf(shaders.StackTraceT), null, gl.CLIENT_STORAGE_BIT);
    }
    if (c_state.variables_ref == gl.NONE) {
        gl.CreateBuffers(1, @ptrCast(&c_state.variables_ref));
        gl.NamedBufferStorage(c_state.variables_ref, MAX_VARIABLES_SIZE, null, gl.CLIENT_STORAGE_BIT);
    }

    var plat_params = &result.platform_params;
    var it = result.result.state.iterator();
    while (it.next()) |state_entry| { // for each shader stage (in the order they are executed)
        var instr_state = state_entry.value_ptr.*;
        const shader_ref = state_entry.key_ptr.*;
        // Update uniforms
        if (result.result.uniforms_invalidated) {
            const uniforms = try state.getPtr(current).?.uniforms_for_shaders.getOrPut(common.allocator, shader_ref);
            if (!uniforms.found_existing) {
                uniforms.value_ptr.* = UniformTargets{};
            }

            const thread_select_ref = gl.GetUniformLocation(result.platform_params.program, instr_state.outputs.thread_selector_ident.ptr);
            if (thread_select_ref >= 0) {
                uniforms.value_ptr.thread_selector = thread_select_ref;
                const selected_thread = instr_state.globalSelectedThread();
                gl.Uniform1ui(thread_select_ref, @intCast(selected_thread));
                log.debug("Setting selected thread to {d}", .{selected_thread});
            } else {
                log.warn("Could not find thread selector uniform in shader {x}", .{shader_ref});
            }

            if (instr_state.target_step) |target| {
                const step_selector_ref = gl.GetUniformLocation(result.platform_params.program, instr_state.outputs.desired_step_ident.ptr);
                if (step_selector_ref >= 0) {
                    uniforms.value_ptr.step_selector = step_selector_ref;
                    gl.Uniform1ui(step_selector_ref, target);
                    log.debug("Setting desired step to {d}", .{target});
                } else {
                    log.warn("Could not find step selector uniform in shader {x}", .{shader_ref});
                }
            }

            const bp_selector = gl.GetUniformLocation(result.platform_params.program, instr_state.outputs.desired_bp_ident.ptr);
            if (bp_selector >= 0) {
                uniforms.value_ptr.bp_selector = bp_selector;
                gl.Uniform1ui(bp_selector, @intCast(instr_state.target_bp));
                log.debug("Setting desired breakpoint to {d}", .{instr_state.target_bp});
            } else log.warn("Could not find bp selector uniform in shader {x}", .{shader_ref});
        }
        const context_state = state.getPtr(current).?;
        // Prepare storage for step counters
        if (instr_state.outputs.step_storage) |*stor| {
            const total_length = instr_state.outputs.totalThreadsCount();
            switch (stor.location) {
                .Interface => |interface| { // `id` should be the last attachment index
                    switch (current.Shaders.all.get(shader_ref).?.items[0].stage) {
                        .gl_fragment, .vk_fragment => {
                            var max_draw_buffers: gl.uint = undefined;
                            gl.GetIntegerv(gl.MAX_DRAW_BUFFERS, @ptrCast(&max_draw_buffers));
                            {
                                var i: gl.@"enum" = 0;
                                while (i < max_draw_buffers) : (i += 1) {
                                    var previous: gl.@"enum" = undefined;
                                    gl.GetIntegerv(gl.DRAW_BUFFER0 + i, @ptrCast(&previous));
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
                            var draw_buffers = [_]gl.@"enum"{gl.NONE} ** 32;
                            {
                                var i: gl.@"enum" = 0;
                                while (i <= interface.location) : (i += 1) {
                                    draw_buffers[i] = @as(gl.@"enum", gl.COLOR_ATTACHMENT0) + i;
                                }
                            }

                            var debug_texture: gl.uint = undefined;
                            if (stor.ref == null) {
                                // Create a debug attachment for the framebuffer
                                gl.GenTextures(1, (&debug_texture)[0..1]);
                                gl.BindTexture(gl.TEXTURE_2D, debug_texture);
                                gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RG32UI, @intCast(instr_state.params.screen[0]), @intCast(instr_state.params.screen[1]), 0, gl.RG_INTEGER, gl.UNSIGNED_INT, null);
                                try context_state.readback_step_buffers.put(common.allocator, debug_texture, try common.allocator.alloc(uvec2, total_length * 2)); // is an array of uvec2
                                stor.ref = debug_texture;
                                stor.deinit_host = &deinitTexture;
                            } else {
                                debug_texture = @intCast(stor.ref.?);
                            }

                            // Attach the texture to the current framebuffer
                            gl.GetIntegerv(gl.FRAMEBUFFER_BINDING, @ptrCast(&plat_params.previous_fbo));
                            gl.GetIntegerv(gl.READ_FRAMEBUFFER_BINDING, @ptrCast(&plat_params.previous_read_fbo));

                            var current_fbo: gl.uint = plat_params.previous_fbo;
                            if (plat_params.previous_fbo == 0) {
                                // default framebuffer does not support attachments so we must replace it with a custom one
                                if (c_state.debug_fbo == 0) {
                                    gl.GenFramebuffers(1, (&c_state.debug_fbo)[0..1]);
                                }
                                gl.BindFramebuffer(gl.FRAMEBUFFER, c_state.debug_fbo);
                                //create depth and stencil attachment
                                var depth_stencil: gl.uint = undefined;
                                gl.GenRenderbuffers(1, (&depth_stencil)[0..1]);
                                gl.BindRenderbuffer(gl.RENDERBUFFER, depth_stencil);
                                gl.RenderbufferStorage(gl.RENDERBUFFER, gl.DEPTH24_STENCIL8, @intCast(instr_state.params.screen[0]), @intCast(instr_state.params.screen[1]));
                                gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_STENCIL_ATTACHMENT, gl.RENDERBUFFER, depth_stencil);
                                for (0..interface.location) |i| {
                                    // create all previous color attachments
                                    if (c_state.replacement_attachment_textures[i] == 0) { // TODO handle resolution change
                                        gl.GenTextures(1, @ptrCast(&c_state.replacement_attachment_textures[i]));
                                    }
                                    gl.BindTexture(gl.TEXTURE_2D, c_state.replacement_attachment_textures[i]);
                                    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA, @intCast(instr_state.params.screen[0]), @intCast(instr_state.params.screen[1]), 0, gl.RGBA, gl.FLOAT, null);
                                }
                                current_fbo = c_state.debug_fbo;
                            }
                            gl.NamedFramebufferTexture(current_fbo, gl.COLOR_ATTACHMENT0 + @as(gl.@"enum", @intCast(interface.location)), debug_texture, 0);
                            gl.DrawBuffers(@as(gl.sizei, @intCast(interface.location)) + 1, &draw_buffers);
                        },
                        else => unreachable, //TODO transform feedback
                    }
                },
                .Buffer => |binding| {
                    if (stor.ref == null) {
                        var new: gl.uint = undefined;
                        gl.GenBuffers(1, (&new)[0..1]);
                        gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, @intCast(binding), @intCast(new));
                        gl.NamedBufferStorage(new, @intCast(total_length * 2), null, gl.CLIENT_STORAGE_BIT);
                        stor.deinit_host = &deinitBuffer;
                        try context_state.readback_step_buffers.put(common.allocator, new, try common.allocator.alloc(uvec2, total_length * 2));
                        stor.ref = new;
                    }
                },
            }
        }
        if (instr_state.outputs.stack_trace) |st_storage| { // not created dynamically as in the case of step storage, because there is always only one stack trace buffer (the one of the currently paused shader)
            gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, @intCast(st_storage.location.Buffer), c_state.stack_trace_ref);
        }
        if (instr_state.outputs.variables_storage) |var_storage| {
            gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, @intCast(var_storage.location.Buffer), c_state.variables_ref);
        }
    }
    return result;
}

fn getFrambufferSize(fbo: gl.uint) [2]gl.int {
    if (fbo == 0) {
        var viewport: [4]gl.int = undefined;
        gl.GetIntegerv(gl.VIEWPORT, &viewport);
        return .{ viewport[2], viewport[3] };
    }
    var attachment_object_name: gl.uint = 0;
    gl.GetFramebufferAttachmentParameteriv(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, @ptrCast(&attachment_object_name));

    var attachment_object_type: gl.int = 0;
    gl.GetFramebufferAttachmentParameteriv(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &attachment_object_type);

    var result = [_]gl.int{ 0, 0 };
    if (attachment_object_type == gl.TEXTURE) {
        gl.GetTextureLevelParameteriv(attachment_object_name, 0, gl.TEXTURE_WIDTH, @ptrCast(&result[0]));
        gl.GetTextureLevelParameteriv(gl.TEXTURE_2D, 0, gl.TEXTURE_HEIGHT, @ptrCast(&result[1]));
    } else if (attachment_object_type == gl.RENDERBUFFER) {
        gl.GetNamedRenderbufferParameteriv(attachment_object_name, gl.RENDERBUFFER_WIDTH, @ptrCast(&result[0]));
        gl.GetNamedRenderbufferParameteriv(attachment_object_name, gl.RENDERBUFFER_HEIGHT, @ptrCast(&result[1]));
    }
    return result;
}

/// query the output interface of the last shader in the pipeline. This is normally the fragment shader.
fn getOutputInterface(program: gl.uint) !std.ArrayList(usize) {
    var out_interface = std.ArrayList(usize).init(common.allocator);
    var count: gl.uint = undefined;
    gl.GetProgramInterfaceiv(program, gl.PROGRAM_OUTPUT, gl.ACTIVE_RESOURCES, @ptrCast(&count));
    // filter out used outputs
    {
        var i: gl.uint = 0;
        var name: [64:0]gl.char = undefined;
        while (i < count) : (i += 1) {
            gl.GetProgramResourceName(program, gl.PROGRAM_OUTPUT, i, 64, null, &name);
            if (!std.mem.startsWith(u8, &name, instrumentation.Processor.prefix)) {
                const location: gl.int = gl.GetProgramResourceLocation(program, gl.PROGRAM_OUTPUT, &name);
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
    max_buffers: gl.uint,
    used_buffers: std.ArrayList(usize),
};
fn getGeneralParams(program_ref: gl.uint) !GeneralParams {
    var max_buffers: gl.uint = undefined;
    gl.GetIntegerv(gl.MAX_SHADER_STORAGE_BUFFER_BINDINGS, @ptrCast(&max_buffers));

    // used bindings
    var used_buffers = try std.ArrayList(usize).initCapacity(common.allocator, 16);
    // used indexes
    var used_buffers_count: gl.uint = undefined;
    gl.GetProgramInterfaceiv(program_ref, gl.SHADER_STORAGE_BLOCK, gl.ACTIVE_RESOURCES, @ptrCast(&used_buffers_count));
    var i: gl.uint = 0;
    while (i < used_buffers_count) : (i += 1) { // for each buffer index
        var binding: gl.uint = undefined; // get the binding number
        const param: gl.@"enum" = gl.BUFFER_BINDING;
        gl.GetProgramResourceiv(program_ref, gl.SHADER_STORAGE_BLOCK, i, 1, &param, 1, null, @ptrCast(&binding));
        try used_buffers.append(binding);
    }

    return GeneralParams{ .max_buffers = max_buffers, .used_buffers = used_buffers };
}

const InstrumentationResult = struct {
    platform_params: struct {
        previous_fbo: gl.uint = 0,
        previous_read_fbo: gl.uint = 0,
        draw_buffers: [32]gl.@"enum" = undefined,
        draw_buffers_len: gl.uint = 0,
        program: gl.uint = 0,
    },
    result: shaders.InstrumentationResult,
};
fn instrumentDraw(vertices: gl.int, instances: gl.sizei) !InstrumentationResult {
    // Find currently bound shaders
    // Instrumentation
    // - Add debug outputs to the shaders (framebuffer attachments, buffers)
    // - Rewrite shader code to write into the debug outputs
    // - Dispatch debugging draw calls and read the outputs while a breakpoint or a step is reached
    // Call the original draw call...

    const c_state = state.getPtr(current) orelse return error.NoState;

    // TODO glGet*() calls can cause synchronization and can be harmful to performance

    var program_ref: gl.uint = undefined;
    gl.GetIntegerv(gl.CURRENT_PROGRAM, @ptrCast(&program_ref)); // GL API is stupid and uses GLint for GLuint
    if (program_ref == 0) {
        log.info("No program bound for the draw call", .{});
        return error.NoProgramBound;
    }

    // Check if transform feedback is active -> no fragment shader will be executed
    var some_feedback_buffer: gl.int = undefined;
    gl.GetIntegerv(gl.TRANSFORM_FEEDBACK_BUFFER_BINDING, @ptrCast(&some_feedback_buffer));
    // TODO or check indexed_buffer_bindings[BufferType.TransformFeedback] != 0 ?

    // Can be u5 because maximum attachments is limited to 32 by the API, and is often limited to 8
    // TODO query GL_PROGRAM_OUTPUT to check actual used attachments
    var used_attachments = try std.ArrayList(u5).initCapacity(common.allocator, @intCast(c_state.max_attachments));
    defer used_attachments.deinit();

    if (current.Programs.all.get(program_ref)) |program_target| {
        // NOTE we assume that all attachments that shader really uses are bound
        var current_fbo: gl.uint = undefined;
        if (some_feedback_buffer == 0) { // if no transform feedback is active

            gl.GetIntegerv(gl.FRAMEBUFFER_BINDING, @ptrCast(&current_fbo));
            if (current_fbo != 0) {
                // query bound attacahments
                var i: gl.uint = 0;
                while (i < c_state.max_attachments) : (i += 1) {
                    const attachment_id = gl.COLOR_ATTACHMENT0 + i;
                    var attachment_type: gl.int = undefined;
                    gl.GetNamedFramebufferAttachmentParameteriv(current_fbo, attachment_id, gl.FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &attachment_type);
                    if (attachment_type != gl.NONE) {
                        try used_attachments.append(@intCast(i)); // we hope that it will be less or equal to 32 so safe cast to u5
                    }
                }
            } else {
                try used_attachments.append(0); // the default color attachment
            }
        }

        // Get screen size
        const screen = if (some_feedback_buffer == 0) getFrambufferSize(current_fbo) else [_]gl.int{ 0, 0 };
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
            const rast_discard = gl.IsEnabled(gl.RASTERIZER_DISCARD);
            if (rast_discard == gl.TRUE) {
                used_vertex_interface = try getOutputInterface(program_ref);
                gl.Disable(gl.RASTERIZER_DISCARD);
                used_fragment_interface = try getOutputInterface(program_ref);
                gl.Enable(gl.RASTERIZER_DISCARD);
            } else {
                used_fragment_interface = try getOutputInterface(program_ref);
                gl.Enable(gl.RASTERIZER_DISCARD);
                used_vertex_interface = try getOutputInterface(program_ref);
                gl.Disable(gl.RASTERIZER_DISCARD);
            }
        } else {
            used_vertex_interface = try getOutputInterface(program_ref);
        }

        //
        // Instrument the currently bound program
        //

        const screen_u = [_]usize{ @intCast(screen[0]), @intCast(screen[1]) };

        var buffer_mode: gl.int = 0;
        gl.GetProgramiv(program_ref, gl.TRANSFORM_FEEDBACK_BUFFER_MODE, &buffer_mode);

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
                .search_paths = c_state.search_paths,
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
    var program_ref: gl.uint = undefined;
    gl.GetIntegerv(gl.CURRENT_PROGRAM, @ptrCast(&program_ref)); // GL API is stupid and uses GLint for GLuint
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
        var group_sizes: [3]gl.int = undefined;
        gl.GetProgramiv(program_ref, gl.COMPUTE_WORK_GROUP_SIZE, &group_sizes[0]);
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
                .search_paths = if (state.getPtr(current)) |s| s.search_paths else null,
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
    // TODO handle stale queries from previous frame
    for (0..@intCast(c_state.max_xfb_buffers)) |i| {
        var xfb_stream: gl.int = 0;
        // check if some buffer is bound to the stream `i`
        gl.GetIntegeri_v(gl.TRANSFORM_FEEDBACK_BUFFER_BINDING, @intCast(i), (&xfb_stream)[0..1]);
        if (xfb_stream != 0) {
            queries.ensureTotalCapacity(common.allocator, i) catch |err| {
                log.err("Failed to allocate memory for xfb queries: {}", .{err});
                return;
            };
            const len = queries.items.len;
            const none = std.math.maxInt(gl.uint);
            if (len <= i) {
                queries.expandToCapacity();
                for (len..i) |q| {
                    queries.items[q] = none;
                }
            }
            if (queries.items[i] == none) {
                gl.GenQueries(1, (&queries.items[i])[0..1]);
            }
            gl.BeginQueryIndexed(gl.TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN, @intCast(i), queries.items[i]);
        }
    }
}

fn endXfbQueries() void {
    const c_state = state.getPtr(current).?;
    const queries = &c_state.primitives_written_queries;
    for (queries.items, 0..) |q, i| { // TODO streams vs buffers
        if (q != std.math.maxInt(gl.uint)) {
            gl.EndQueryIndexed(gl.TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN, @intCast(i));
        }
    }
}

fn dispatchDebug(
    comptime instrument_func: anytype,
    i_args: anytype,
    comptime dispatch_func: anytype,
    d_args: anytype,
) void {
    dispatchDebugImpl(instrument_func, i_args, dispatch_func, d_args, false) catch |err| {
        log.err("Failed to process instrumentation: {}\n{}", .{ err, @errorReturnTrace() orelse &common.null_trace });
    };
}

fn dispatchDebugDraw(
    comptime instrument_func: anytype,
    i_args: anytype,
    comptime dispatch_func: anytype,
    d_args: anytype,
) void {
    dispatchDebugImpl(instrument_func, i_args, dispatch_func, d_args, true) catch |err| {
        log.err("Failed to process instrumentation: {}\n{}", .{ err, @errorReturnTrace() orelse &common.null_trace });
    };
}

fn dispatchDebugImpl(
    comptime instrument_func: anytype,
    i_args: anytype,
    comptime dispatch_func: anytype,
    d_args: anytype,
    comptime xfb: bool,
) !void {
    while (true) {
        shaders.user_action = false;
        const prepared = try prepareStorage(try @call(.auto, instrument_func, i_args));
        if (xfb) {
            beginXfbQueries();
        }
        @call(.auto, dispatch_func, d_args);
        if (xfb) {
            endXfbQueries();
        }
        try processOutput(prepared);
        if (!shaders.user_action) {
            break;
        }
    }
    try restoreState();
}

fn restoreState() !void {
    log.info("Restoring pipeline state", .{});
    const c_state = state.getPtr(current) orelse return error.NoState;
    for (c_state.uniforms_for_shaders.values()) |uniform| {
        inline for (@typeInfo(UniformTargets).Struct.fields) |field| {
            if (@field(uniform, field.name)) |location|
                gl.Uniform1ui(location, 0); // reset desired step/breakpoint/thread to 0
        }
    }
}

// Drawing functions
pub usingnamespace struct {

    // TODO
    // pub export fn glDispatchComputeGroupSizeARB(num_groups_x: gl.uint, num_groups_y: gl.uint, num_groups_z: gl.uint, group_size_x: gl.uint, group_size_y: gl.uint, group_size_z: gl.uint) void {
    //     if (shaders.instance.checkDebuggingOrRevert()) {
    //         dispatchDebug(instrumentCompute, .{ .{[_]usize{ @intCast(num_groups_x), @intCast(num_groups_y), @intCast(num_groups_z) }},gl.DispatchComputeGroupSizeARB,.{num_groups_x, num_groups_y, num_groups_z, group_size_x, group_size_y, group_size_z});
    //     } else gl.DispatchComputeGroupSizeARB(num_groups_x, num_groups_y, num_groups_z, group_size_x, group_size_y, group_size_z);
    // }

    pub export fn glDispatchCompute(num_groups_x: gl.uint, num_groups_y: gl.uint, num_groups_z: gl.uint) void {
        if (everyFrame()) {
            dispatchDebug(instrumentCompute, .{[_]usize{ @intCast(num_groups_x), @intCast(num_groups_y), @intCast(num_groups_z) }}, gl.DispatchCompute, .{ num_groups_x, num_groups_y, num_groups_z });
        } else gl.DispatchCompute(num_groups_x, num_groups_y, num_groups_z);
    }

    const IndirectComputeCommand = extern struct {
        num_groups_x: gl.uint,
        num_groups_y: gl.uint,
        num_groups_z: gl.uint,
    };
    pub export fn glDispatchComputeIndirect(address: gl.intptr) void {
        if (everyFrame()) {
            var command = IndirectComputeCommand{ .num_groups_x = 1, .num_groups_y = 1, .num_groups_z = 1 };
            //check GL_DISPATCH_INDIRECT_BUFFER
            var buffer: gl.int = 0;
            gl.GetIntegerv(gl.DISPATCH_INDIRECT_BUFFER_BINDING, @ptrCast(&buffer));
            if (buffer != 0) {
                gl.GetNamedBufferSubData(@intCast(buffer), address, @sizeOf(IndirectComputeCommand), &command);
            }

            dispatchDebug(instrumentCompute, .{[_]usize{ @intCast(command.num_groups_x), @intCast(command.num_groups_y), @intCast(command.num_groups_z) }}, gl.DispatchComputeIndirect, .{address});
        } else gl.DispatchComputeIndirect(address);
    }

    pub export fn glDrawArrays(mode: gl.@"enum", first: gl.int, count: gl.sizei) void {
        if (everyFrame()) {
            dispatchDebugDraw(instrumentDraw, .{ count, 1 }, gl.DrawArrays, .{ mode, first, count });
        } else gl.DrawArrays(mode, first, count);
    }

    pub export fn glDrawArraysInstanced(mode: gl.@"enum", first: gl.int, count: gl.sizei, instanceCount: gl.sizei) void {
        if (everyFrame()) {
            dispatchDebugDraw(instrumentDraw, .{ count, instanceCount }, gl.DrawArraysInstanced, .{ mode, first, count, instanceCount });
        } else gl.DrawArraysInstanced(mode, first, count, instanceCount);
    }

    pub export fn glDrawElements(mode: gl.@"enum", count: gl.sizei, _type: gl.@"enum", indices: usize) void {
        if (everyFrame()) {
            dispatchDebugDraw(instrumentDraw, .{ count, 1 }, gl.DrawElements, .{ mode, count, _type, indices });
        } else gl.DrawElements(mode, count, _type, indices);
    }

    pub export fn glDrawElementsInstanced(mode: gl.@"enum", count: gl.sizei, _type: gl.@"enum", indices: ?*const anyopaque, instanceCount: gl.sizei) void {
        if (everyFrame()) {
            dispatchDebugDraw(instrumentDraw, .{ count, instanceCount }, gl.DrawElementsInstanced, .{ mode, count, _type, indices, instanceCount });
        } else gl.DrawElementsInstanced(mode, count, _type, indices, instanceCount);
    }

    pub export fn glDrawElementsBaseVertex(mode: gl.@"enum", count: gl.sizei, _type: gl.@"enum", indices: ?*const anyopaque, basevertex: gl.int) void {
        if (everyFrame()) {
            dispatchDebugDraw(instrumentDraw, .{ count, 1 }, gl.DrawElementsBaseVertex, .{ mode, count, _type, indices, basevertex });
        } else gl.DrawElementsBaseVertex(mode, count, _type, indices, basevertex);
    }

    pub export fn glDrawElementsInstancedBaseVertex(mode: gl.@"enum", count: gl.sizei, _type: gl.@"enum", indices: ?*const anyopaque, instanceCount: gl.sizei, basevertex: gl.int) void {
        if (everyFrame()) {
            dispatchDebugDraw(instrumentDraw, .{ count, instanceCount }, gl.DrawElementsInstancedBaseVertex, .{ mode, count, _type, indices, instanceCount, basevertex });
        } else gl.DrawElementsInstancedBaseVertex(mode, count, _type, indices, instanceCount, basevertex);
    }

    pub export fn glDrawRangeElements(mode: gl.@"enum", start: gl.uint, end: gl.uint, count: gl.sizei, _type: gl.@"enum", indices: ?*const anyopaque) void {
        if (everyFrame()) {
            dispatchDebugDraw(instrumentDraw, .{ count, 1 }, gl.DrawRangeElements, .{ mode, start, end, count, _type, indices });
        } else gl.DrawRangeElements(mode, start, end, count, _type, indices);
    }

    pub export fn glDrawRangeElementsBaseVertex(mode: gl.@"enum", start: gl.uint, end: gl.uint, count: gl.sizei, _type: gl.@"enum", indices: ?*const anyopaque, basevertex: gl.int) void {
        if (everyFrame()) {
            dispatchDebugDraw(instrumentDraw, .{ count, 1 }, gl.DrawRangeElementsBaseVertex, .{ mode, start, end, count, _type, indices, basevertex });
        } else gl.DrawRangeElementsBaseVertex(mode, start, end, count, _type, indices, basevertex);
    }

    pub export fn glDrawElementsInstancedBaseVertexBaseInstance(mode: gl.@"enum", count: gl.sizei, _type: gl.@"enum", indices: ?*const anyopaque, instanceCount: gl.sizei, basevertex: gl.int, baseInstance: gl.uint) void {
        if (everyFrame()) {
            dispatchDebugDraw(instrumentDraw, .{ count, instanceCount }, gl.DrawElementsInstancedBaseVertexBaseInstance, .{ mode, count, _type, indices, instanceCount, basevertex, baseInstance });
        } else gl.DrawElementsInstancedBaseVertexBaseInstance(mode, count, _type, indices, instanceCount, basevertex, baseInstance);
    }

    pub export fn glDrawElementsInstancedBaseInstance(mode: gl.@"enum", count: gl.sizei, _type: gl.@"enum", indices: ?*const anyopaque, instanceCount: gl.sizei, baseInstance: gl.uint) void {
        if (everyFrame()) {
            dispatchDebugDraw(instrumentDraw, .{ count, instanceCount }, gl.DrawElementsInstancedBaseInstance, .{ mode, count, _type, indices, instanceCount, baseInstance });
        } else gl.DrawElementsInstancedBaseInstance(mode, count, _type, indices, instanceCount, baseInstance);
    }

    const IndirectCommand = extern struct {
        count: gl.uint, //again opengl mismatch GLuint vs GLint
        instanceCount: gl.uint,
        first: gl.uint,
        baseInstance: gl.uint,
    };
    pub fn parseIndirect(indirect: ?*const IndirectCommand) IndirectCommand {
        // check if GL_DRAW_INDIRECT_BUFFER is bound
        var buffer: gl.uint = 0;
        gl.GetIntegerv(gl.DRAW_INDIRECT_BUFFER_BINDING, @ptrCast(&buffer));
        if (buffer != 0) {
            // get the data from the buffer
            var data: IndirectCommand = undefined;
            gl.GetBufferSubData(gl.DRAW_INDIRECT_BUFFER, @intCast(@intFromPtr(indirect)), @intCast(@sizeOf(IndirectCommand)), &data);

            return data;
        }

        return if (indirect) |i| i.* else IndirectCommand{ .count = 0, .instanceCount = 1, .first = 0, .baseInstance = 0 };
    }

    pub export fn glDrawArraysIndirect(mode: gl.@"enum", indirect: ?*const IndirectCommand) void {
        if (everyFrame()) {
            const i = parseIndirect(indirect);
            dispatchDebugDraw(instrumentDraw, .{ @as(gl.sizei, @intCast(i.count)), @as(gl.sizei, @intCast(i.instanceCount)) }, gl.DrawArraysIndirect, .{ mode, indirect });
        } else gl.DrawArraysIndirect(mode, indirect);
    }

    pub export fn glDrawElementsIndirect(mode: gl.@"enum", _type: gl.@"enum", indirect: ?*const IndirectCommand) void {
        if (everyFrame()) {
            const i = parseIndirect(indirect);
            dispatchDebugDraw(instrumentDraw, .{ @as(gl.sizei, @intCast(i.count)), @as(gl.sizei, @intCast(i.instanceCount)) }, gl.DrawElementsIndirect, .{ mode, _type, indirect });
        } else gl.DrawElementsIndirect(mode, _type, indirect);
    }

    pub export fn glDrawArraysInstancedBaseInstance(mode: gl.@"enum", first: gl.int, count: gl.sizei, instanceCount: gl.sizei, baseInstance: gl.uint) void {
        if (everyFrame()) {
            dispatchDebugDraw(instrumentDraw, .{ count, instanceCount }, gl.DrawArraysInstancedBaseInstance, .{ mode, first, count, instanceCount, baseInstance });
        } else gl.DrawArraysInstancedBaseInstance(mode, first, count, instanceCount, baseInstance);
    }

    pub export fn glDrawTransformFeedback(mode: gl.@"enum", id: gl.uint) void {
        if (everyFrame()) {
            const query = state.getPtr(current).?.primitives_written_queries.items[0];
            // get GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN
            var primitiveCount: gl.int = undefined;
            gl.GetQueryObjectiv(query, gl.QUERY_RESULT, &primitiveCount);
            dispatchDebugDraw(instrumentDraw, .{ primitiveCount, 1 }, gl.DrawTransformFeedback, .{ mode, id });
        } else gl.DrawTransformFeedback(mode, id);
    }

    pub export fn glDrawTransformFeedbackInstanced(mode: gl.@"enum", id: gl.uint, instanceCount: gl.sizei) void {
        if (everyFrame()) {
            const query = state.getPtr(current).?.primitives_written_queries.items[0];
            // get GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN
            var primitiveCount: gl.int = undefined;
            gl.GetQueryObjectiv(query, gl.QUERY_RESULT, &primitiveCount);
            dispatchDebugDraw(instrumentDraw, .{ primitiveCount, instanceCount }, gl.DrawTransformFeedbackInstanced, .{ mode, id, instanceCount });
        } else gl.DrawTransformFeedbackInstanced(mode, id, instanceCount);
    }

    pub export fn glDrawTransformFeedbackStream(mode: gl.@"enum", id: gl.uint, stream: gl.uint) void {
        if (everyFrame()) {
            const query = state.getPtr(current).?.primitives_written_queries.items[stream];
            // get GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN
            var primitiveCount: gl.int = undefined;
            gl.GetQueryObjectiv(query, gl.QUERY_RESULT, &primitiveCount);
            dispatchDebugDraw(instrumentDraw, .{ primitiveCount, 1 }, gl.DrawTransformFeedbackStream, .{ mode, id, stream });
        } else gl.DrawTransformFeedbackStream(mode, id, stream);
    }

    pub export fn glDrawTransformFeedbackStreamInstanced(mode: gl.@"enum", id: gl.uint, stream: gl.uint, instanceCount: gl.sizei) void {
        if (everyFrame()) {
            const query = state.getPtr(current).?.primitives_written_queries.items[stream];
            // get GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN
            var primitiveCount: gl.int = undefined;
            gl.GetQueryObjectiv(query, gl.QUERY_RESULT, &primitiveCount);
            dispatchDebugDraw(instrumentDraw, .{ primitiveCount, instanceCount }, gl.DrawTransformFeedbackStreamInstanced, .{ mode, id, stream, instanceCount });
        } else gl.DrawTransformFeedbackStreamInstanced(mode, id, stream, instanceCount);
    }
};

/// For fast switch-branching on strings
fn hashStr(str: String) u32 {
    return std.hash.CityHash32.hash(str);
}

/// Maximum number of lines from the shader source to scan for deshader pragmas
const MAX_SHADER_PRAGMA_SCAN = 128;
/// Supports pragmas:
/// ```glsl
/// #pragma deshader [property] "[value1]" "[value2]"
/// #pragma deshader breakpoint
/// #pragma deshader breakpoint-if [expression]
/// #pragma deshader breakpoint-after [expression]
/// #pragma deshader print "format string" [value1] [value2] ...
/// #pragma deshader print-if [expression] "format string" [value1] [value2] ...
/// #pragma deshader source "path/to/virtual/or/workspace/relative/file.glsl"
/// #pragma deshader source-link "path/to/etc/file.glsl" - link to previous source
/// #pragma deshader source-purge-previous "path/to/etc/file.glsl" - purge previous source (if exists)
/// #pragma deshader workspace "/another/real/path" "/virtual/path" - include real path in vitual workspace (for the current context)
/// #pragma deshader workspace-overwrite "/absolute/real/path" "/virtual/path" - purge all previous virtual paths and include real path in vitual workspace
/// ```
/// Does not support multiline pragmas with \ at the end of line
// TODO mutliple shaders for the same stage (OpenGL treats them as if concatenated)
pub export fn glShaderSource(shader: gl.uint, count: gl.sizei, sources: [*][*:0]const gl.char, lengths: ?[*]gl.int) void {
    std.debug.assert(count != 0);
    const single_chunk = commands.setting_vars.singleChunkShader;

    // convert from gl.int to usize array
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
    gl.ShaderSource(shader, count, sources, lengths);
}

pub export fn glCreateProgram() gl.uint {
    const new_platform_program = gl.CreateProgram();
    current.programCreateUntagged(decls.ProgramPayload{
        .ref = @intCast(new_platform_program),
        .link = defaultLink,
    }) catch |err| {
        log.warn("Failed to add program {x} to storage: {any}", .{ new_platform_program, err });
    };

    return new_platform_program;
}

pub export fn glAttachShader(program: gl.uint, shader: gl.uint) void {
    current.programAttachSource(@intCast(program), @intCast(shader)) catch |err| {
        log.err("Failed to attach shader {x} to program {x}: {any}", .{ shader, program, err });
    };

    gl.AttachShader(program, shader);
}

pub export fn glDetachShader(program: gl.uint, shader: gl.uint) void {
    current.programDetachSource(@intCast(program), @intCast(shader)) catch |err| {
        log.err("Failed to detach shader {x} from program {x}: {any}", .{ shader, program, err });
    };

    gl.DetachShader(program, shader);
}

pub const errors = struct {
    pub fn workspacePath(path: anytype, err: anytype) void {
        log.warn("Failed to add workspace path {s}: {any}", .{ path, err });
    }
    pub fn removeWorkspacePath(path: anytype, err: anytype) void {
        log.warn("Failed to remove workspace path {s}: {any}", .{ path, err });
    }
    pub fn tag(label: String, name: gl.uint, index: usize, err: anytype) void {
        log.err("Failed to assign tag {s} for {d} index {d}: {any}", .{ label, name, index, err });
    }
};

fn realLength(length: gl.sizei, label: ?CString) usize {
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
/// To link with a physical file, use virtual path relative to some workspace root. Use `glDebugMessageInsert`, `glGetObjectLabel` , `deshaderPhysicalWorkspace` or `#pragma deshader workspace` to set workspace roots.
pub export fn glObjectLabel(identifier: gl.@"enum", name: gl.uint, length: gl.sizei, label: ?CString) void {
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
                        _ = current.Shaders.assignTag(@intCast(name), index, tag.?, behavior) catch |err| errors.tag(label.?[0..real_length], name, index, err);
                    }
                } else {
                    _ = current.Shaders.assignTag(@intCast(name), 0, label.?[0..real_length], .Error) catch |err| errors.tag(label.?[0..real_length], name, 0, err);
                }
            },
            gl.PROGRAM => _ = current.Programs.assignTag(@intCast(name), 0, label.?[0..real_length], .Error) catch |err| errors.tag(label.?[0..real_length], name, 0, err),
            else => {}, // TODO support other objects?
        }
    }
    callIfLoaded("ObjectLabel", .{ identifier, name, length, label });
}

/// Set `size`, `identifier` and `name` to 0 to use this function for mapping physical paths to virtual paths.
/// Set `physical` to null to remove all mappings for that virtual path.
///
/// **NOTE**: the original signature is `glGetObjectLabel(identifier: @"enum", name: uint, bufSize: sizei, length: [*c]sizei, label: [*c]char)`
pub export fn glGetObjectLabel(_identifier: gl.@"enum", _name: gl.uint, _size: gl.sizei, virtual: CString, physical: CString) void {
    if (_identifier == 0 and _name == 0 and _size == 0) {
        if (@intFromPtr(virtual) != 0) {
            if (@intFromPtr(virtual) != 0) {
                current.mapPhysicalToVirtual(std.mem.span(virtual), .{ .sources = .{ .name = .{ .tagged = std.mem.span(physical) } } }) catch |err| errors.workspacePath(virtual, err);
            } else {
                current.clearWorkspacePaths();
            }
        }
    } else {
        callIfLoaded("GetObjectLabel", .{ _identifier, _name, _size, hardCast([*c]gl.sizei, virtual), hardCast([*c]gl.char, physical) });
    }
}

fn hardCast(comptime T: type, val: anytype) T {
    return @as(T, @alignCast(@ptrCast(@constCast(val))));
}

fn namedStringSourceAlloc(_: usize, path: ?CString, length: usize) callconv(.C) ?CString {
    if (path) |p| {
        var result_len: gl.int = undefined;
        gl.GetNamedStringivARB(@intCast(length), p, gl.NAMED_STRING_LENGTH_ARB, &result_len);
        const result = common.allocator.allocSentinel(u8, @intCast(result_len), 0) catch |err| {
            log.warn("Failed to allocate memory for named string {s}: {any}", .{ p[0..length], err });
            return null;
        };
        gl.GetNamedStringARB(@intCast(length), p, result_len, &result_len, result.ptr);
        if (gl.GetError() != gl.NO_ERROR) {
            log.warn("Failed to get named string {s}", .{p[0..length]});
            common.allocator.free(result);
            return null;
        }
        return result;
    }
    return null;
}

fn freeNamedString(_: Ref, _: *const anyopaque, string: CString) callconv(.C) void {
    common.allocator.free(std.mem.span(string));
}

/// Named strings from ARB_shading_language_include can be used for labeling shader source files ("parts" in Deshader)
pub export fn glNamedStringARB(_type: gl.@"enum", _namelen: gl.int, _name: ?CString, _stringlen: gl.int, _string: ?CString) void {
    if (_string) |s| if (_name) |n|
        wrapErrorHandling(actions.createNamedString, .{ _namelen, n, _stringlen, s });

    callIfLoaded("NamedStringARB", .{ _type, _namelen, _name, _stringlen, _string });
}

/// use glDebugMessageInsert with these parameters to set workspace root
/// source = GL_DEBUG_SOURCE_APPLICATION
/// type = DEBUG_TYPE_OTHER
/// severity = GL_DEBUG_SEVERITY_HIGH
/// buf = /real/absolute/workspace/root<-/virtual/workspace/root
///
/// id = 0xde5ade4 == 233156068 => add workspace
/// id = 0xde5ade5 == 233156069 => remove workspace with the name specified in `buf` or remove all (when buf == null)
pub export fn glDebugMessageInsert(source: gl.@"enum", _type: gl.@"enum", id: gl.uint, severity: gl.@"enum", length: gl.sizei, buf: ?[*:0]const gl.char) void {
    if (source == gl.DEBUG_SOURCE_APPLICATION and _type == gl.DEBUG_TYPE_OTHER and severity == gl.DEBUG_SEVERITY_HIGH) {
        switch (id) {
            ids.COMMAND_WORKSPACE_ADD => {
                if (buf != null) { //Add
                    const real_length = realLength(length, buf);
                    var it = std.mem.split(u8, buf.?[0..real_length], "<-");
                    if (it.next()) |real_path| {
                        if (it.next()) |virtual_path| {
                            current.mapPhysicalToVirtual(real_path, .{ .sources = .{ .name = .{ .tagged = virtual_path } } }) catch |err| errors.workspacePath(buf.?[0..real_length], err);
                        } else errors.workspacePath(buf.?[0..real_length], error.@"No virtual path specified");
                    } else errors.workspacePath(buf.?[0..real_length], error.@"No real path specified");
                }
            },
            ids.COMMAND_WORKSPACE_REMOVE => if (buf == null) { //Remove all
                current.clearWorkspacePaths();
            } else { //Remove
                const real_length = realLength(length, buf);
                var it = std.mem.split(u8, buf.?[0..real_length], "<-");
                if (it.next()) |real_path| {
                    if (!(current.removeWorkspacePath(real_path, if (it.next()) |v| shaders.ResourceLocator.parse(v) catch |err| return errors.removeWorkspacePath(buf.?[0..real_length], err) else null) catch false)) {
                        errors.removeWorkspacePath(buf.?[0..real_length], error.@"No such real path in workspace");
                    }
                }
            },
            ids.COMMAND_VERSION => {
                main.deshaderVersion(@constCast(@alignCast(@ptrCast(buf))));
            },
            else => {},
        }
    }
    callIfLoaded("DebugMessageInsert", .{ source, _type, id, severity, length, buf });
}

/// Calls a function from the OpenGL context if it is available
fn callIfLoaded(comptime proc: String, a: anytype) voidOrOptional(returnType(@field(gl, proc))) {
    const proc_proc = @field(gl, proc);
    const proc_ret = returnType(proc_proc);
    const target_args = @typeInfo(@TypeOf(proc_proc)).Fn.params.len;
    const source_args = @typeInfo(@TypeOf(a)).Struct.fields.len;
    if (target_args != source_args) {
        @compileError("Parameter count mismatch in callIfLoaded(\"" ++ proc ++ "\",...). Expected " ++ (@as(u8, @truncate(target_args)) + '0') ++ ", got " ++ (@as(u8, @truncate(source_args)) + '0'));
    }
    // would need @coercesTo
    // inline for (@typeInfo(@TypeOf(proc_proc)).Fn.params, a, 0..) |dest, source, i| {
    //     comptime {
    //         if ( dest.type != @TypeOf(source)) {
    //             @compileError("Parameter " ++ [_]u8{@as(u8, @truncate(i)) + '0'} ++ " type mismatch in callIfLoaded(" ++ proc ++ "). " ++
    //                 "Expected " ++ (if (dest.type) |t| @typeName(t) else "{no type}") ++ ", got " ++ @typeName(@TypeOf(source)));
    //         }
    //     }
    // }
    return if (isProcLoaded(proc)) @call(.auto, proc_proc, a) else voidOrNull(proc_ret);
}

fn isProcLoaded(comptime proc: String) bool {
    return if (state.get(current)) |s| if (s.proc_table) |t| @intFromPtr(@field(t, proc)) != 0 else false else false;
}

fn voidOrOptional(comptime t: type) type {
    return if (t == void) void else ?t;
}

fn voidOrNull(comptime t: type) if (t == void) void else null {
    if (t == void) {} else return null;
}

fn returnType(t: anytype) type {
    return @typeInfo(@TypeOf(t)).Fn.return_type.?;
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
pub export fn glBufferData(_target: gl.@"enum", _size: gl.sizeiptr, _data: ?*const anyopaque, _usage: gl.@"enum") void {
    if (_target == 0) {
        // Could be potentially a deshader command
        if (std.mem.indexOfScalar(c_uint, &ids_array, _usage) != null) {
            glDebugMessageInsert(gl.DEBUG_SOURCE_APPLICATION, gl.DEBUG_TYPE_OTHER, _usage, gl.DEBUG_SEVERITY_HIGH, @intCast(_size), @ptrCast(_data));
        }
    }
    gl.BufferData(_target, _size, _data, _usage);
}

//TODO glSpecializeShader glShaderBinary
//TODO SGI context extensions
pub const context_procs = if (builtin.os.tag == .windows)
    struct {
        pub export fn wglMakeCurrent(hdc: *const anyopaque, context: ?*const anyopaque) c_int {
            const result = loaders.APIs.gl.wgl.make_current[0](hdc, context);
            loaders.APIs.gl.wgl.last_params = .{hdc};
            makeCurrent(loaders.APIs.gl.wgl, context);
            return result;
        }

        pub export fn wglMakeContextCurrentARB(hReadDC: *const anyopaque, hDrawDC: *const anyopaque, hglrc: ?*const anyopaque) c_int {
            const result = loaders.APIs.gl.wgl.make_current[1](hReadDC, hDrawDC, hglrc);
            loaders.APIs.gl.wgl.last_params = .{hDrawDC};
            makeCurrent(loaders.APIs.gl.wgl, hglrc);
            return result;
        }

        comptime {
            @export(wglMakeContextCurrentARB, .{ .name = "wglMakeContextCurrentEXT" });
        }

        pub export fn wglCreateContextAttribsARB(hdc: *const anyopaque, share: *const anyopaque, attribs: ?[*]c_int) ?*const anyopaque {
            const result = loaders.APIs.gl.wgl.create[1](hdc, share, attribs);

            return result;
        }

        pub export fn wglCreateContext(hdc: *const anyopaque) ?*const anyopaque {
            const result = loaders.APIs.gl.wgl.create[0](hdc);

            return result;
        }

        pub export fn wglDeleteContext(context: *const anyopaque) bool {
            return deleteContext(context, loaders.APIs.gl.wgl, .{});
        }
    }
else
    struct {
        //#region Context functions
        pub export fn glXMakeCurrent(display: *const anyopaque, drawable: c_ulong, context: ?*const anyopaque) c_int {
            const result = loaders.APIs.gl.glX.make_current[0](display, drawable, context);
            loaders.APIs.gl.glX.last_params = .{ display, drawable };
            makeCurrent(loaders.APIs.gl.glX, context);
            return result;
        }

        pub export fn glXMakeContextCurrent(display: *const anyopaque, read: c_ulong, write: c_ulong, context: ?*const anyopaque) c_int {
            const result = loaders.APIs.gl.glX.make_current[1](display, read, write, context);
            loaders.APIs.gl.glX.last_params = .{ display, write };
            makeCurrent(loaders.APIs.gl.glX, context);
            return result;
        }

        pub export fn glXCreateContext(display: *const anyopaque, vis: *const anyopaque, share: *const anyopaque, direct: c_int) ?*const anyopaque {
            const result = loaders.APIs.gl.glX.create[0](display, vis, share, direct);
            return result;
        }

        pub export fn glXCreateNewContext(display: *const anyopaque, render_type: c_int, share: *const anyopaque, direct: c_int) ?*const anyopaque {
            const result = loaders.APIs.gl.glX.create[1](display, render_type, share, direct);
            return result;
        }

        pub export fn glXCreateContextAttribsARB(display: *const anyopaque, vis: *const anyopaque, share: *const anyopaque, direct: c_int, attribs: ?[*]const c_int) ?*const anyopaque {
            const result = loaders.APIs.gl.glX.create[2](display, vis, share, direct, attribs);
            return result;
        }

        pub export fn eglMakeCurrent(display: *const anyopaque, read: *const anyopaque, write: *const anyopaque, context: ?*const anyopaque) c_uint {
            const result = loaders.APIs.gl.egl.make_current[0](display, read, write, context);
            loaders.APIs.gl.egl.last_params = .{ display, read, write };
            makeCurrent(loaders.APIs.gl.egl, context);
            return result;
        }

        pub export fn eglCreateContext(display: *const anyopaque, config: *const anyopaque, share: *const anyopaque, attribs: ?[*]c_int) ?*const anyopaque {
            const result = loaders.APIs.gl.egl.create[0](display, config, share, attribs);
            return result;
        }
        //#endregion

        //#region Context destroy functions
        pub export fn glXDestroyContext(display: *const anyopaque, context: *const anyopaque) bool {
            return deleteContext(context, loaders.APIs.gl.glX, .{display});
        }

        pub export fn eglDestroyContext(display: *const anyopaque, context: *const anyopaque) bool {
            return deleteContext(context, loaders.APIs.gl.glX, .{display});
        }
        //#endregion
    };

pub fn supportCheck(extension_iterator: anytype) Support {
    var result: Support = .{
        .buffers = false,
        .include = false,
        .max_variables_size = MAX_VARIABLES_SIZE,
        .all_once = false,
    };
    while (extension_iterator.next()) |ex| {
        if (std.ascii.endsWithIgnoreCase(ex, "shader_storage_buffer_object")) {
            result.buffers = true;
        } else if (std.ascii.endsWithIgnoreCase(ex, "include_directive")) {
            result.include = true;
        } else if (std.ascii.endsWithIgnoreCase(ex, "language_include")) {
            result.include = true;
        }
    }
    return result;
}

noinline fn dumpProcTableErrors(c_state: *State) void {
    var stderr = std.io.getStdErr();
    stderr.writeAll("\n") catch {};
    inline for (@typeInfo(gl.ProcTable).Struct.fields) |decl| {
        const p = @field(c_state.proc_table.?, decl.name);
        if (@typeInfo(@TypeOf(p)) == .Pointer) {
            if (@intFromPtr(p) == 0) {
                stderr.writeAll(decl.name) catch {};
                stderr.writeAll("\n") catch {};
            }
        }
    }
}

fn tagEvent(_: ?*const anyopaque, event: shaders.ResourceLocator.TagEvent, _: std.mem.Allocator) anyerror!void {
    const name = event.locator.name().?;
    callIfLoaded("ObjectLabel", .{
        @as(gl.@"enum", if (event.locator == .programs) gl.PROGRAM else gl.SHADER),
        @as(gl.uint, @intCast(event.ref)),
        @as(gl.int, if (event.action == .Assign) @intCast(name.len) else 0),
        if (event.action == .Assign) name.ptr else null,
    });
    if (event.action == .Assign) {
        deshaderDebugMessage("Tagged {s} {x} with {s}", .{ if (event.locator == .programs) "program" else "shader", event.ref, name }, gl.DEBUG_TYPE_OTHER, .info);
    } else {
        deshaderDebugMessage("Removed tag from {s}: {s} {x}", .{ if (event.locator == .programs) "program" else "shader", name, event.ref }, gl.DEBUG_TYPE_OTHER, .info);
    }
}

/// Returns true if the frame should be debugged
fn everyFrame() bool {
    current.bus.processQueueNoThrow();
    return current.checkDebuggingOrRevert();
}

fn deshaderDebugMessage(comptime fmt: String, fmt_args: anytype, @"type": gl.@"enum", severity: std.log.Level) void {
    if (isProcLoaded("DebugMessageInsert")) blk: {
        const message = std.fmt.allocPrint(common.allocator, fmt, fmt_args) catch |err| {
            log.err("{}", .{err});
            break :blk;
        };
        defer common.allocator.free(message);
        gl.DebugMessageInsert(gl.DEBUG_SOURCE_THIRD_PARTY, @"type", 0, switch (severity) {
            .debug => gl.DEBUG_SEVERITY_NOTIFICATION,
            .err => gl.DEBUG_SEVERITY_HIGH,
            .info => gl.DEBUG_SEVERITY_LOW,
            .warn => gl.DEBUG_SEVERITY_MEDIUM,
        }, @intCast(message.len), message.ptr);
        return;
    }

    switch (severity) {
        .debug => log.debug(fmt, fmt_args),
        .err => log.err(fmt, fmt_args),
        .info => log.info(fmt, fmt_args),
        .warn => log.warn(fmt, fmt_args),
    }
}

/// Performs context switching and initialization
pub fn makeCurrent(comptime api: anytype, c: ?*const anyopaque) void {
    if (c) |context| {
        _ = _try: {
            const result = shaders.getOrAddService(context, common.allocator) catch |err| break :_try err;
            const c_state = (state.getOrPut(common.allocator, result.value_ptr) catch |err| break :_try err).value_ptr;
            if (result.found_existing) {
                gl.makeProcTableCurrent(@ptrCast(&c_state.proc_table));
            } else {
                // Initialize per-context variables
                c_state.* = .{};

                if (!api.late_loaded) {
                    if (loaders.loadGlLib()) {
                        api.late_loaded = true;
                    } else |err| break :_try err;
                }
                if (c_state.proc_table == null) {
                    c_state.proc_table = undefined;
                    // Late load all GL funcitions
                    if (!c_state.proc_table.?.init(if (builtin.os.tag == .windows) struct {
                        pub fn loader(name: CString) ?*const anyopaque {
                            return api.loader.?(name) orelse api.lib.?.lookup(*const anyopaque, std.mem.span(name));
                        }
                    }.loader else api.loader.?)) {
                        log.err("Failed to load some GL functions.", .{});
                        if (options.logInterception) @call(.never_inline, dumpProcTableErrors, .{c_state}) // Only do this if logging is enabled, because it adds a few megabytes to the binary size
                        else log.debug("Build with -DlogInterception to show which ones.", .{});
                    }
                }

                gl.makeProcTableCurrent(&c_state.proc_table.?);

                log.debug("Initializing service {s} for context {x}", .{ result.value_ptr.name, @intFromPtr(context) });

                // Check for supported features of this context
                result.value_ptr.support = check: {
                    if (gl.GetString(gl.EXTENSIONS)) |exs| {
                        var it = std.mem.splitScalar(u8, std.mem.span(exs), ' ');
                        break :check supportCheck(&it);
                    } else {
                        // getString vs getStringi
                        const ExtensionInterator = struct {
                            num: gl.int,
                            i: gl.uint,

                            fn next(self: *@This()) ?String {
                                const ex = gl.GetStringi(gl.EXTENSIONS, self.i);
                                self.i += 1;
                                return if (ex) |e| std.mem.span(e) else null;
                            }
                        };
                        var it = ExtensionInterator{ .num = undefined, .i = 0 };
                        gl.GetIntegerv(gl.NUM_EXTENSIONS, (&it.num)[0..1]);
                        break :check supportCheck(&it);
                    }
                };

                if (c_state.max_xfb_streams == 0) {
                    gl.GetIntegerv(gl.MAX_COLOR_ATTACHMENTS, @ptrCast(&c_state.max_attachments));
                    gl.GetIntegerv(gl.MAX_TRANSFORM_FEEDBACK_BUFFERS, (&c_state.max_xfb_buffers)[0..1]);
                    gl.GetIntegerv(gl.MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS, (&c_state.max_xfb_interleaved_components)[0..1]);
                    gl.GetIntegerv(gl.MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS, (&c_state.max_xfb_sep_attribs)[0..1]);
                    gl.GetIntegerv(gl.MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS, (&c_state.max_xfb_sep_components)[0..1]);
                    gl.GetIntegerv(gl.MAX_VERTEX_STREAMS, (&c_state.max_xfb_streams)[0..1]);
                }

                contextInvalidatedEvent() catch |err| break :_try err;
                result.value_ptr.bus.addListener(tagEvent, null) catch |err| break :_try err;
            }
            current = result.value_ptr;
        } catch |err| {
            log.err("Failed to init GL library {}", .{err});
        };
    } else {
        gl.makeProcTableCurrent(null);
    }
}

/// Convenience function for wrapping function calls, catching errors and logging them
fn wrapErrorHandling(comptime function: anytype, _args: anytype) void {
    @call(.auto, function, _args) catch |err| {
        log.err("Error in {s}({}): {} {?}", .{ @typeName(@TypeOf(function)), _args, err, @errorReturnTrace() });
    };
}

fn contextInvalidatedEvent() !void {
    // Send a notification to debug adapter client
    if (commands.instance) |cl| {
        try cl.sendEvent(.invalidated, debug.InvalidatedEvent{ .areas = &.{.contexts}, .numContexts = shaders.servicesCount() });
    }
}

fn deleteContext(c: *const anyopaque, api: anytype, arg: anytype) bool {
    const prev_context = api.get_current.?();
    if (shaders.getService(c)) |s| {
        deinit: {
            // makeCurrent on Windows is illegal here
            if (builtin.os.tag != .windows and @call(.auto, api.make_current[0], api.last_params ++ .{c}) == 0) break :deinit;
            makeCurrent(api, c);
            if (state.getPtr(s)) |c_state| {
                c_state.deinit();
            }
            if (builtin.os.tag != .windows and @call(.auto, api.make_current[0], api.last_params ++ .{prev_context}) == 0) break :deinit;
            makeCurrent(api, prev_context);
        }
        std.debug.assert(state.remove(s));
        std.debug.assert(shaders.removeService(c, common.allocator));
        // Send a notification to debug adapter client
        contextInvalidatedEvent() catch {};
    }
    return @call(.auto, api.destroy.?, arg ++ .{c});
}

pub fn deinit() void {
    // there shouldn't be any services left if the host app has called deleteContext for all contexts, but to make sure...
    shaders.deinitServices(common.allocator);
    contextInvalidatedEvent() catch {};
    var per_context_it = state.valueIterator();
    while (per_context_it.next()) |s| {
        s.deinit();
    }
    state.deinit(common.allocator);
}
