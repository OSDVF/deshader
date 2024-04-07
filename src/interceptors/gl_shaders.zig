// TODO: support MESA debug extensions? (MESA_program_debug, MESA_shader_debug)
// TODO: support GL_ARB_shading_language_include
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
const args = @import("args");
const main = @import("../main.zig");
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

/// memory for used indexed buffer binding indexed. OpenGL does not provide a standard way to query them.
var indexed_buffer_bindings = std.EnumMap(BufferType, usize){};
var readback_breakpoint_textures = std.AutoHashMapUnmanaged(usize, Buffer){};
var replacement_attachment_textures: [32]gl.GLuint = [_]gl.GLuint{0} ** 32;
var debug_fbo: gl.GLuint = undefined;

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
        defer if (source.lengths) |l| common.allocator.free(l[0..source.count]);
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

fn defaultLink(self: *decls.ProgramPayload) callconv(.C) u8 {
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
    if (buffer == 0) { //un-bind
        indexed_buffer_bindings.put(buffer_type, 0);
    } else {
        const existing = indexed_buffer_bindings.get(buffer_type) orelse 0;
        indexed_buffer_bindings.put(buffer_type, existing | index);
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

pub export fn glCreateShader(shaderType: gl.GLenum) gl.GLuint {
    const new_platform_source = gl.createShader(shaderType);

    const stored = shaders.Shader.MemorySource.fromPayload(shaders.instance.Shaders.allocator, decls.SourcesPayload{
        .ref = @intCast(new_platform_source),
        .type = @enumFromInt(shaderType),
        .compile = defaultCompileShader,
        .count = 1,
        .language = decls.LanguageType.GLSL,
    }, 0) catch |err| {
        log.warn("Failed to add shader source {x} cache because of alocation: {any}", .{ new_platform_source, err });
        return new_platform_source;
    };
    shaders.instance.Shaders.appendUntagged(stored.super) catch |err| {
        log.warn("Failed to add shader source {x} cache: {any}", .{ new_platform_source, err });
    };

    return new_platform_source;
}

pub export fn glCreateShaderProgramv(shaderType: gl.GLenum, count: gl.GLsizei, sources: [*][*:0]const gl.GLchar) gl.GLuint {
    const source_type: decls.SourceType = @enumFromInt(shaderType);
    const new_platform_program = gl.createShaderProgramv(shaderType, count, sources);
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

    shaders.instance.sourcesCreateUntagged(decls.SourcesPayload{
        .ref = @intCast(new_platform_sources[0]),
        .type = source_type,
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

pub export fn glLinkProgram(program: gl.GLuint) void {
    gl.linkProgram(program);
    const program_obj = shaders.instance.Programs.all.get(program);
    if (program_obj) |p| {
        var program_target = &p.items[0];
        // query fragment shader output interface
        var fragment_output_count: gl.GLuint = undefined;
        gl.getProgramInterfaceiv(program, gl.PROGRAM_OUTPUT, gl.ACTIVE_RESOURCES, @ptrCast(&fragment_output_count));
        // filter out used outputs
        {
            var i: gl.GLuint = 0;
            while (i < fragment_output_count) : (i += 1) {
                var name: [64]gl.GLchar = undefined;
                gl.getProgramResourceName(program, gl.PROGRAM_OUTPUT, i, 64, null, &name);
                const location: gl.GLint = gl.getProgramResourceLocation(program, gl.PROGRAM_OUTPUT, &name);
                program_target.setUsedOutput(@intCast(location));
            }
        }
    }
}

//
// Drawing functions - the heart of shader instrumentaton
//

// guards the access to break_condition
var break_mutex = std.Thread.Mutex{};
var break_after_draw = false;
fn processOutput(result_or_error: @typeInfo(@TypeOf(prepareStorage)).Fn.return_type.?) void {
    defer if (break_after_draw) break_mutex.unlock();
    if (break_after_draw) break_mutex.lock();

    _ = try_blk: {
        var r: InstrumentationResult = result_or_error catch |err| break :try_blk err;
        defer r.result.outputs.deinit(common.allocator); // do not free the inner data because they are owned by the program's cache
        const Range = struct {
            start: usize,
            end: usize,
        };
        var breakpoint_hits = std.AutoHashMapUnmanaged(usize, std.ArrayListUnmanaged(Range)){};
        defer {
            var it = breakpoint_hits.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(common.allocator);
            }
            breakpoint_hits.deinit(common.allocator);
        }
        var breakpoint_hit_ids = std.ArrayListUnmanaged(usize){};
        defer breakpoint_hit_ids.deinit(common.allocator);

        var it = r.result.outputs.iterator();
        while (it.next()) |entry| {
            const o = entry.value_ptr.*;
            if (o.breakpoints) |*bps| {
                // Examine if something was hit
                var threads_hits: Buffer = undefined;
                switch (bps.type) {
                    .Attachment => |id| {
                        threads_hits = readback_breakpoint_textures.get(bps.ref.?).?;
                        var previous_pack_buffer: gl.GLuint = undefined; // save previous host state
                        gl.getIntegerv(gl.PIXEL_PACK_BUFFER_BINDING, @ptrCast(&previous_pack_buffer));
                        gl.bindBuffer(gl.PIXEL_PACK_BUFFER, 0);

                        // blit to the original framebuffer
                        gl.bindFramebuffer(gl.READ_FRAMEBUFFER, debug_fbo);
                        gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, r.params.previous_fbo);
                        var i: gl.GLenum = 0;
                        while (i < r.params.draw_buffers_len) : (i += 1) {
                            gl.readBuffer(@as(gl.GLenum, gl.COLOR_ATTACHMENT0) + i);
                            gl.drawBuffer(r.params.draw_buffers[i]);
                            gl.blitFramebuffer(0, 0, @intCast(r.params.screen[0]), @intCast(r.params.screen[1]), 0, 0, @intCast(r.params.screen[0]), @intCast(r.params.screen[1]), gl.COLOR_BUFFER_BIT, gl.NEAREST);
                        }
                        gl.blitFramebuffer(0, 0, @intCast(r.params.screen[0]), @intCast(r.params.screen[1]), 0, 0, @intCast(r.params.screen[0]), @intCast(r.params.screen[1]), gl.STENCIL_BUFFER_BIT | gl.DEPTH_BUFFER_BIT, gl.NEAREST);

                        // read pixels to the main memory
                        var previous_read_buffer: gl.GLenum = undefined;
                        gl.getIntegerv(gl.READ_BUFFER, @ptrCast(&previous_read_buffer));
                        gl.readBuffer(@as(gl.GLenum, gl.COLOR_ATTACHMENT0) + id);

                        gl.readnPixels(
                            0,
                            0,
                            @intCast(r.params.screen[0]),
                            @intCast(r.params.screen[1]),
                            gl.RED_INTEGER,
                            gl.UNSIGNED_BYTE, // The same format as the texture
                            @intCast(threads_hits.len),
                            threads_hits.ptr,
                        );

                        // restore the previous framebuffer binding
                        gl.bindBuffer(gl.PIXEL_PACK_BUFFER, previous_pack_buffer);
                        gl.readBuffer(previous_read_buffer);

                        gl.bindFramebuffer(gl.FRAMEBUFFER, r.params.previous_fbo);
                        gl.bindFramebuffer(gl.READ_FRAMEBUFFER, r.params.previous_read_fbo);
                        gl.drawBuffers(@intCast(r.params.draw_buffers_len), &r.params.draw_buffers);
                    },
                    else => unreachable,
                }

                for (0..r.params.screen[1]) |y| {
                    for (0..r.params.screen[0]) |x| {
                        const global_index: usize = x + y * r.params.screen[0];
                        if (threads_hits[global_index] > 0) {
                            const bp_hit_entry = breakpoint_hits.getOrPut(common.allocator, threads_hits[global_index]) catch |err| break :try_blk err;
                            if (!bp_hit_entry.found_existing) {
                                bp_hit_entry.value_ptr.* = std.ArrayListUnmanaged(Range){};
                                breakpoint_hit_ids.append(common.allocator, threads_hits[global_index] - 1) // offset by 1 because 0 means no hit
                                catch |err| break :try_blk err;
                            }
                            var found = false;
                            for (bp_hit_entry.value_ptr.items) |*range| {
                                if (range.start < global_index) {
                                    if (range.end == global_index - 1) {
                                        range.end = global_index;
                                        found = true;
                                    }
                                }
                            }
                            if (!found) {
                                bp_hit_entry.value_ptr.append(common.allocator, Range{ .start = global_index, .end = global_index }) catch |err| break :try_blk err;
                            }
                        }
                    }
                }
            }
        }
        if (breakpoint_hits.count() > 0) {
            if (common.command_listener) |comm| {
                comm.eventBreak(.stopOnBreakpoint, breakpoint_hit_ids.items) catch |err| break :try_blk err;
            }
        }
    } catch |err| {
        log.warn("Failed to process instrumentation output: {}", .{err});
    };
}

fn deinitTexture(out_storage: *instrumentation.OutputStorage, _: std.mem.Allocator) void {
    if (out_storage.ref) |r| {
        gl.deleteTextures(1, @ptrCast(&r));
        const entry = readback_breakpoint_textures.fetchRemove(r);
        if (entry) |e| {
            common.allocator.free(e.value);
        }
    }
}

/// Prepare debug output buffers
fn prepareStorage(result_or_error: @typeInfo(@TypeOf(instrumentDraw)).Fn.return_type.?) !InstrumentationResult {
    var result: InstrumentationResult = try result_or_error;
    if (result.result.invalidated) {
        if (common.command_listener) |comm| {
            try comm.sendEvent(.invalidated, debug.InvalidatedEvent{ .areas = &.{debug.InvalidatedEvent.Areas.threads} });
        }
    }

    var params = &result.params;
    var it = result.result.outputs.valueIterator();
    while (it.next()) |outputs| {
        // Prepare storage for breakpoints
        if (outputs.*.breakpoints) |*bps| {
            switch (bps.type) {
                .Attachment => |id| { // `id` should be the last attachment index
                    var max_draw_buffers: gl.GLuint = undefined;
                    gl.getIntegerv(gl.MAX_DRAW_BUFFERS, @ptrCast(&max_draw_buffers));
                    {
                        var i: gl.GLenum = 0;
                        while (i < max_draw_buffers) : (i += 1) {
                            var previous: gl.GLenum = undefined;
                            gl.getIntegerv(gl.DRAW_BUFFER0 + i, @ptrCast(&previous));
                            switch (previous) {
                                gl.NONE => {
                                    params.draw_buffers_len = i;
                                    for (i + 1..max_draw_buffers) |j| {
                                        params.draw_buffers[j] = gl.NONE;
                                    }
                                    break;
                                },
                                gl.BACK => params.draw_buffers[i] = gl.BACK_LEFT,
                                gl.FRONT => params.draw_buffers[i] = gl.FRONT_LEFT,
                                gl.FRONT_AND_BACK => params.draw_buffers[i] = gl.BACK_LEFT,
                                gl.LEFT => params.draw_buffers[i] = gl.FRONT_LEFT,
                                gl.RIGHT => params.draw_buffers[i] = gl.FRONT_RIGHT,
                                else => params.draw_buffers[i] = previous,
                            }
                        }
                    }
                    // create debug draw buffers spec
                    var draw_buffers = [_]gl.GLenum{gl.NONE} ** 32;
                    {
                        var i: gl.GLenum = 0;
                        while (i <= id) : (i += 1) {
                            draw_buffers[i] = @as(gl.GLenum, gl.COLOR_ATTACHMENT0) + i;
                        }
                    }

                    var debug_texture: gl.GLuint = undefined;
                    if (bps.ref == null) {
                        // Create a debug attachment for the framebuffer
                        gl.genTextures(1, &debug_texture);
                        gl.bindTexture(gl.TEXTURE_2D, debug_texture);
                        gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8UI, @intCast(params.screen[0]), @intCast(params.screen[1]), 0, gl.RED_INTEGER, gl.UNSIGNED_BYTE, null);
                        try readback_breakpoint_textures.put(common.allocator, debug_texture, try common.allocator.alloc(u8, params.screen[0] * params.screen[1]));
                        bps.ref = debug_texture;
                        bps.deinit_host = &deinitTexture;
                    } else {
                        debug_texture = @intCast(bps.ref.?);
                    }

                    // Attach the texture to the current framebuffer
                    var current_fbo: gl.GLuint = undefined;
                    gl.getIntegerv(gl.FRAMEBUFFER_BINDING, @ptrCast(&current_fbo));
                    var current_read_fbo: gl.GLuint = undefined;
                    gl.getIntegerv(gl.READ_FRAMEBUFFER_BINDING, @ptrCast(&current_read_fbo));
                    params.previous_read_fbo = current_read_fbo;
                    params.previous_fbo = current_fbo;

                    if (current_fbo == 0) {
                        // default framebuffer does not support attachments so we must replace it with a custom one
                        if (debug_fbo == 0) {
                            gl.genFramebuffers(1, &debug_fbo);
                        }
                        gl.bindFramebuffer(gl.FRAMEBUFFER, debug_fbo);
                        //create depth and stencil attachment
                        var depth_stencil: gl.GLuint = undefined;
                        gl.genRenderbuffers(1, &depth_stencil);
                        gl.bindRenderbuffer(gl.RENDERBUFFER, depth_stencil);
                        gl.renderbufferStorage(gl.RENDERBUFFER, gl.DEPTH24_STENCIL8, @intCast(params.screen[0]), @intCast(params.screen[1]));
                        gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_STENCIL_ATTACHMENT, gl.RENDERBUFFER, depth_stencil);
                        for (0..id) |i| {
                            // create all previous color attachments
                            if (replacement_attachment_textures[i] == 0) { // TODO handle resolution change
                                gl.genTextures(1, &replacement_attachment_textures[i]);
                            }
                            gl.bindTexture(gl.TEXTURE_2D, replacement_attachment_textures[i]);
                            gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, @intCast(params.screen[0]), @intCast(params.screen[1]), 0, gl.RGBA, gl.FLOAT, null);
                        }
                        current_fbo = debug_fbo;
                    }
                    gl.namedFramebufferTexture(current_fbo, @as(gl.GLenum, gl.COLOR_ATTACHMENT0) + id, debug_texture, 0);
                    gl.drawBuffers(id + 1, &draw_buffers);
                },
                else => unreachable,
            }
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
    params: struct {
        screen: [2]usize = [_]usize{ 0, 0 },
        compute: [3]usize = [_]usize{ 0, 0, 0 },
        previous_fbo: gl.GLuint = 0,
        previous_read_fbo: gl.GLuint = 0,
        draw_buffers: [32]gl.GLenum = undefined, // see shaders.Program.used_outputs
        draw_buffers_len: gl.GLuint = 0,
    },
    result: shaders.InstrumentationResult,
};
fn instrumentDraw(vertices: gl.GLint, instances: gl.GLsizei) !InstrumentationResult {
    // Find currently bound shaders
    // Instrumentation
    // - Add debug outputs to the shaders (framebuffer attachments, buffers)
    // - Rewrite shader code to write into the debug outputs
    // - Duplicate the draw call
    // - Read the outputs
    // Call the original draw call
    // Break if a breakpoint was reached

    // TODO glGet*() calls can cause synchronization and be harmful to performance

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

    // add debug attachments
    var max_attachments: gl.GLuint = undefined;
    gl.getIntegerv(gl.MAX_COLOR_ATTACHMENTS, @ptrCast(&max_attachments));

    // Can be u5 because maximum attachments is limited to 32 by the API, and is often limited to 8
    // TODO query GL_PROGRAM_OUTPUT to check actual used attachments
    var free_attachments = try std.ArrayList(u5).initCapacity(common.allocator, @intCast(max_attachments));
    defer free_attachments.deinit();

    if (shaders.instance.Programs.all.get(program_ref)) |program| {
        // NOTE we assume that all attachments that shader really uses are bound
        var current_fbo: gl.GLuint = undefined;
        if (some_feedback_buffer == 0) { // if no transform feedback is active

            gl.getIntegerv(gl.FRAMEBUFFER_BINDING, @ptrCast(&current_fbo));
            // query bound attacahments
            if (current_fbo == debug_fbo or current_fbo == 0) {
                for (0..max_attachments) |i| {
                    if (program.items[0].used_outputs[i] == 0) {
                        try free_attachments.append(@intCast(i));
                    }
                }
            } else {
                var i: gl.GLuint = 0;
                while (i < max_attachments) : (i += 1) {
                    const attachment_id = gl.COLOR_ATTACHMENT0 + i;
                    var attachment_type: gl.GLint = undefined;
                    gl.getNamedFramebufferAttachmentParameteriv(current_fbo, attachment_id, gl.FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &attachment_type);
                    if (attachment_type == gl.NONE) {
                        try free_attachments.append(@intCast(i)); // we hope that it will be less or equal to 32 so safe cast to u5
                    }
                }
            }
        }

        // Get screen size
        const screen = if (some_feedback_buffer == 0) getFrambufferSize(current_fbo) else [_]gl.GLint{ 0, 0 };
        var general_params = try getGeneralParams(program_ref);
        defer general_params.used_buffers.deinit();

        //
        // Instrument the currently bound program
        //

        // NOTE program_target must be a pointer otherwise instrumentation cache would be cleared
        var program_target = &program.items[0]; //TODO is program always a single item?
        const stages: []const decls.SourceType = if (vertices > 0) //
            if (some_feedback_buffer == 0) &[_]decls.SourceType{ //
                .gl_fragment,
                .gl_vertex,
                .gl_geometry,
                .gl_tess_control,
                .gl_tess_evaluation,
                .gl_mesh,
                .gl_task,
            } else &[_]decls.SourceType{
                .gl_vertex,
                .gl_geometry,
                .gl_tess_control,
                .gl_tess_evaluation,
                .gl_mesh,
                .gl_task,
            }
        else
            &[_]decls.SourceType{
                .gl_fragment,
            };
        const screen_u = [_]usize{ @intCast(screen[0]), @intCast(screen[1]) };
        return InstrumentationResult{
            .result = try program_target.instrument(.{
                .allocator = common.allocator,
                .free_attachments = free_attachments,
                .used_buffers = general_params.used_buffers,
                .used_xfb = @intCast(indexed_buffer_bindings.get(BufferType.TransformFeedback) orelse 0),
                .max_buffers = general_params.max_buffers,
                .vertices = @intCast(vertices),
                .instances = @intCast(instances),
                .screen = screen_u,
                .compute = [_]usize{ 0, 0, 0 },
            }, std.EnumSet(decls.SourceType).initMany(stages)),
            .params = .{
                .screen = screen_u,
            },
        };
    } else {
        log.warn("Program {d} not found in database", .{program_ref});
        return error.NoProgramFound;
    }
}

fn instrumentCompute(dim: [3]usize) !InstrumentationResult {
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
    if (shaders.instance.Programs.all.get(program_ref)) |program| {
        // NOTE program_target must be a pointer otherwise instrumentation cache would be cleared
        var program_target = &program.items[0]; //TODO is program always a single item?
        var empty = std.ArrayList(u5).init(common.allocator);
        defer empty.deinit();
        return InstrumentationResult{
            .result = try program_target.instrument(.{
                .allocator = common.allocator,
                .free_attachments = empty,
                .used_buffers = general_params.used_buffers,
                .used_xfb = @intCast(indexed_buffer_bindings.get(BufferType.TransformFeedback) orelse 0),
                .max_buffers = general_params.max_buffers,
                .vertices = 0,
                .instances = 0,
                .screen = [_]usize{ 0, 0 },
                .compute = dim,
            }, std.EnumSet(decls.SourceType).initOne(.gl_compute)),
            .params = .{
                .compute = dim,
            },
        };
    } else {
        log.warn("Program {d} not found in database", .{program_ref});
        return error.NoProgramFound;
    }
}

pub export fn glDispatchCompute(num_groups_x: gl.GLuint, num_groups_y: gl.GLuint, num_groups_z: gl.GLuint) void {
    if (shaders.instance.debugging) {
        const prepared = prepareStorage(instrumentCompute([_]usize{ @intCast(num_groups_x), @intCast(num_groups_y), @intCast(num_groups_z) }));
        gl.dispatchCompute(num_groups_x, num_groups_y, num_groups_z);
        processOutput(prepared);
    } else gl.dispatchCompute(num_groups_x, num_groups_y, num_groups_z);
}

const IndirectComputeCommand = extern struct {
    num_groups_x: gl.GLuint,
    num_groups_y: gl.GLuint,
    num_groups_z: gl.GLuint,
};
pub export fn glDispatchComputeIndirect(indirect: ?*const IndirectComputeCommand) void {
    if (shaders.instance.debugging) {
        const i = if (indirect) |i| i.* else IndirectComputeCommand{ .num_groups_x = 1, .num_groups_y = 1, .num_groups_z = 1 };
        const prepared = prepareStorage(instrumentCompute([_]usize{ @intCast(i.num_groups_x), @intCast(i.num_groups_y), @intCast(i.num_groups_z) }));
        gl.dispatchComputeIndirect(@intFromPtr(indirect));
        processOutput(prepared);
    } else gl.dispatchComputeIndirect(@intFromPtr(indirect));
}

pub export fn glDrawArrays(mode: gl.GLenum, first: gl.GLint, count: gl.GLsizei) void {
    if (shaders.instance.debugging) {
        const prepared = prepareStorage(instrumentDraw(count, 1));
        gl.drawArrays(mode, first, count);
        processOutput(prepared);
    } else gl.drawArrays(mode, first, count);
}

pub export fn glDrawArraysInstanced(mode: gl.GLenum, first: gl.GLint, count: gl.GLsizei, instanceCount: gl.GLsizei) void {
    if (shaders.instance.debugging) {
        const prepared = prepareStorage(instrumentDraw(count, instanceCount));
        gl.drawArraysInstanced(mode, first, count, instanceCount);
        processOutput(prepared);
    } else gl.drawArraysInstanced(mode, first, count, instanceCount);
}

pub export fn glDrawElements(mode: gl.GLenum, count: gl.GLsizei, _type: gl.GLenum, indices: ?*const anyopaque) void {
    if (shaders.instance.debugging) {
        const prepared = prepareStorage(instrumentDraw(count, 1));
        gl.drawElements(mode, count, _type, indices);
        processOutput(prepared);
    } else gl.drawElements(mode, count, _type, indices);
}

pub export fn glDrawElementsInstanced(mode: gl.GLenum, count: gl.GLsizei, _type: gl.GLenum, indices: ?*const anyopaque, instanceCount: gl.GLsizei) void {
    if (shaders.instance.debugging) {
        const prepared = prepareStorage(instrumentDraw(count, instanceCount));
        gl.drawElementsInstanced(mode, count, _type, indices, instanceCount);
        processOutput(prepared);
    } else gl.drawElementsInstanced(mode, count, _type, indices, instanceCount);
}

pub export fn glDrawElementsBaseVertex(mode: gl.GLenum, count: gl.GLsizei, _type: gl.GLenum, indices: ?*const anyopaque, basevertex: gl.GLint) void {
    if (shaders.instance.debugging) {
        const prepared = prepareStorage(instrumentDraw(count, 1));
        gl.drawElementsBaseVertex(mode, count, _type, indices, basevertex);
        processOutput(prepared);
    } else gl.drawElementsBaseVertex(mode, count, _type, indices, basevertex);
}

pub export fn glDrawElementsInstancedBaseVertex(mode: gl.GLenum, count: gl.GLsizei, _type: gl.GLenum, indices: ?*const anyopaque, instanceCount: gl.GLsizei, basevertex: gl.GLint) void {
    if (shaders.instance.debugging) {
        const prepared = prepareStorage(instrumentDraw(count, instanceCount));
        gl.drawElementsInstancedBaseVertex(mode, count, _type, indices, instanceCount, basevertex);
        processOutput(prepared);
    } else gl.drawElementsInstancedBaseVertex(mode, count, _type, indices, instanceCount, basevertex);
}

pub export fn glDrawRangeElements(mode: gl.GLenum, start: gl.GLuint, end: gl.GLuint, count: gl.GLsizei, _type: gl.GLenum, indices: ?*const anyopaque) void {
    if (shaders.instance.debugging) {
        const prepared = prepareStorage(instrumentDraw(count, 1));
        gl.drawRangeElements(mode, start, end, count, _type, indices);
        processOutput(prepared);
    } else gl.drawRangeElements(mode, start, end, count, _type, indices);
}

pub export fn glDrawRangeElementsBaseVertex(mode: gl.GLenum, start: gl.GLuint, end: gl.GLuint, count: gl.GLsizei, _type: gl.GLenum, indices: ?*const anyopaque, basevertex: gl.GLint) void {
    if (shaders.instance.debugging) {
        const prepared = prepareStorage(instrumentDraw(count, 1));
        gl.drawRangeElementsBaseVertex(mode, start, end, count, _type, indices, basevertex);
        processOutput(prepared);
    } else gl.drawRangeElementsBaseVertex(mode, start, end, count, _type, indices, basevertex);
}

pub export fn glDrawElementsInstancedBaseVertexBaseInstance(mode: gl.GLenum, count: gl.GLsizei, _type: gl.GLenum, indices: ?*const anyopaque, instanceCount: gl.GLsizei, basevertex: gl.GLint, baseInstance: gl.GLuint) void {
    if (shaders.instance.debugging) {
        const prepared = prepareStorage(instrumentDraw(count, instanceCount));
        gl.drawElementsInstancedBaseVertexBaseInstance(mode, count, _type, indices, instanceCount, basevertex, baseInstance);
        processOutput(prepared);
    } else gl.drawElementsInstancedBaseVertexBaseInstance(mode, count, _type, indices, instanceCount, basevertex, baseInstance);
}

pub export fn glDrawElementsInstancedBaseInstance(mode: gl.GLenum, count: gl.GLsizei, _type: gl.GLenum, indices: ?*const anyopaque, instanceCount: gl.GLsizei, baseInstance: gl.GLuint) void {
    if (shaders.instance.debugging) {
        const prepared = prepareStorage(instrumentDraw(count, instanceCount));
        gl.drawElementsInstancedBaseInstance(mode, count, _type, indices, instanceCount, baseInstance);
        processOutput(prepared);
    } else gl.drawElementsInstancedBaseInstance(mode, count, _type, indices, instanceCount, baseInstance);
}

const IndirectCommand = extern struct {
    count: gl.GLuint, //again opengl mismatch GLuint vs GLint
    instanceCount: gl.GLuint,
    first: gl.GLuint,
    baseInstance: gl.GLuint,
};
pub fn parseIndirect(indirect: ?*const IndirectCommand) IndirectCommand {
    return if (indirect) |i| i.* else IndirectCommand{ .count = 0, .instanceCount = 1, .first = 0, .baseInstance = 0 };
}

pub export fn glDrawArraysIndirect(mode: gl.GLenum, indirect: ?*const IndirectCommand) void {
    if (shaders.instance.debugging) {
        const i = parseIndirect(indirect);
        const prepared = prepareStorage(instrumentDraw(@intCast(i.count), @intCast(i.instanceCount)));
        gl.drawArraysIndirect(mode, indirect);
        processOutput(prepared);
    } else gl.drawArraysIndirect(mode, indirect);
}

pub export fn glDrawElementsIndirect(mode: gl.GLenum, _type: gl.GLenum, indirect: ?*const IndirectCommand) void {
    if (shaders.instance.debugging) {
        const i = parseIndirect(indirect);
        const prepared = prepareStorage(instrumentDraw(@intCast(i.count), @intCast(i.instanceCount)));
        gl.drawElementsIndirect(mode, _type, indirect);
        processOutput(prepared);
    } else gl.drawElementsIndirect(mode, _type, indirect);
}

pub export fn glDrawArraysInstancedBaseInstance(mode: gl.GLenum, first: gl.GLint, count: gl.GLsizei, instanceCount: gl.GLsizei, baseInstance: gl.GLuint) void {
    if (shaders.instance.debugging) {
        const prepared = prepareStorage(instrumentDraw(count, instanceCount));
        gl.drawArraysInstancedBaseInstance(mode, first, count, instanceCount, baseInstance);
        processOutput(prepared);
    } else gl.drawArraysInstancedBaseInstance(mode, first, count, instanceCount, baseInstance);
}

pub export fn glDrawTransformFeedback(mode: gl.GLenum, id: gl.GLuint) void {
    if (shaders.instance.debugging) {
        const prepared = prepareStorage(instrumentDraw(0, 1)); // Drawing transform feedback does not dispatch vertex shader
        gl.drawTransformFeedback(mode, id);
        processOutput(prepared);
    } else gl.drawTransformFeedback(mode, id);
}

pub export fn glDrawTransformFeedbackInstanced(mode: gl.GLenum, id: gl.GLuint, instanceCount: gl.GLsizei) void {
    if (shaders.instance.debugging) {
        const prepared = prepareStorage(instrumentDraw(0, instanceCount));
        gl.drawTransformFeedbackInstanced(mode, id, instanceCount);
        processOutput(prepared);
    } else gl.drawTransformFeedbackInstanced(mode, id, instanceCount);
}

pub export fn glDrawTransformFeedbackStream(mode: gl.GLenum, id: gl.GLuint, stream: gl.GLuint) void {
    if (shaders.instance.debugging) {
        const prepared = prepareStorage(instrumentDraw(0, 1));
        gl.drawTransformFeedbackStream(mode, id, stream);
        processOutput(prepared);
    } else gl.drawTransformFeedbackStream(mode, id, stream);
}

pub export fn glDrawTransformFeedbackStreamInstanced(mode: gl.GLenum, id: gl.GLuint, stream: gl.GLuint, instanceCount: gl.GLsizei) void {
    if (shaders.instance.debugging) {
        const prepared = prepareStorage(instrumentDraw(0, instanceCount));
        gl.drawTransformFeedbackStreamInstanced(mode, id, stream, instanceCount);
        processOutput(prepared);
    } else gl.drawTransformFeedbackStreamInstanced(mode, id, stream, instanceCount);
}

/// For fast switch-branching on strings
fn hashStr(str: String) u32 {
    return std.hash.CityHash32.hash(str);
}
const ArgsIterator = struct {
    i: usize = 0,
    s: String,
    pub fn next(self: *@This()) ?String {
        var token: ?String = null;
        if (self.i < self.s.len) {
            if (self.s[self.i] == '\"') {
                const end = std.mem.indexOfScalar(u8, self.s[self.i + 1 ..], '\"') orelse return null;
                token = self.s[self.i + 1 .. self.i + 1 + end];
                self.i += end + 2;
            } else {
                const end = std.mem.indexOfScalar(u8, self.s[self.i..], ' ') orelse (self.s.len - self.i);
                token = self.s[self.i .. self.i + end];
                self.i += end;
            }
            if (self.i < self.s.len and self.s[self.i] == ' ') {
                self.i += 1;
            }
        }
        return token;
    }
};

const MAX_SHADER_PRAGMA_SCAN = 128;
/// Supports pragmas:
/// #pragma deshader [property] "[value1]" "[value2]"
/// #pragma deshader source "path/to/virtual/or/workspace/relative/file.glsl"
/// #pragma deshader source-link "path/to/etc/file.glsl" - link to previous source
/// #pragma deshader source-purge-previous "path/to/etc/file.glsl" - purge previous source (if exists)
/// #pragma deshader workspace "/another/real/path" "/virtual/path" - include real path in vitual workspace
/// #pragma deshader workspace-overwrite "/absolute/real/path" "/virtual/path" - purge all previous virtual paths and include real path in vitual workspace
/// Does not support multiline pragmas with \ at the end of line
pub export fn glShaderSource(shader: gl.GLuint, count: gl.GLsizei, sources: [*][*:0]const gl.GLchar, lengths: ?[*]gl.GLint) void {
    std.debug.assert(count != 0);
    // convert from gl.GLint to usize array
    const wide_count: usize = @intCast(count);
    var lengths_wide: ?[*]usize = if (lengths != null) (common.allocator.alloc(usize, wide_count) catch |err| {
        log.err("Failed to allocate memory for shader sources lengths: {any}", .{err});
        return;
    }).ptr else null;
    if (lengths != null) {
        for (lengths.?[0..wide_count], lengths_wide.?[0..wide_count]) |len, *target| {
            target.* = @intCast(len);
        }
    }
    defer if (lengths_wide) |l| common.allocator.free(l[0..wide_count]);

    // Create untagged shader source
    shaders.instance.sourceSource(decls.SourcesPayload{
        .ref = @intCast(shader),
        .count = @intCast(count),
        .sources = sources,
        .lengths = lengths_wide,
        .language = decls.LanguageType.GLSL,
    }, true) catch |err| {
        log.warn("Failed to add shader source {x} cache: {any}", .{ shader, err });
    };
    gl.shaderSource(shader, count, sources, lengths);

    // Maybe assign tag and create workspaces
    // Scan for pragmas
    for (sources[0..wide_count], lengths_wide.?[0..wide_count], 0..) |source, len, source_i| {
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
                    var arg_iter = ArgsIterator{ .s = line, .i = pragma_found + pragma_text.len };
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
                                    shaders.instance.mapPhysicalToVirtual(options.positionals[0], .{ .sources = .{ .tagged = options.positionals[1] } }) catch |err| failedWorkspacePath(options.positionals[0], err);
                                },
                                .source => {
                                    shaders.instance.Shaders.assignTag(@intCast(shader), source_i, options.positionals[0], .Error) catch |err| objLabErr(options.positionals[0], shader, source_i, err);
                                },
                                .@"source-link" => {
                                    shaders.instance.Shaders.assignTag(@intCast(shader), source_i, options.positionals[0], .Link) catch |err| objLabErr(options.positionals[0], shader, source_i, err);
                                },
                                .@"source-purge-previous" => {
                                    shaders.instance.Shaders.assignTag(@intCast(shader), source_i, options.positionals[0], .Overwrite) catch |err| objLabErr(options.positionals[0], shader, source_i, err);
                                },
                                .breakpoint => {
                                    if (shaders.instance.Shaders.all.get(@intCast(shader))) |stored| {
                                        if (stored.items.len > source_i) {
                                            const new = shaders.Breakpoint{ .line = line_i + 1 }; // The breakpoint is in fact targeted on the next line
                                            if (stored.items[source_i].addBreakpoint(new, common.allocator, null, source_i)) |bp| {
                                                defer common.allocator.free(bp.path);
                                                log.debug("Shader {d} source {d}: breakpoint at line {d}", .{ shader, source_i, line_i });
                                                // push an event to the debugger
                                                if (common.command_listener != null and common.command_listener.?.hasClient()) {
                                                    common.command_listener.?.sendEvent(.breakpoint, debug.BreakpointEvent{ .breakpoint = bp, .reason = .new }) catch {};
                                                } else {
                                                    shaders.instance.breakpoints_to_send.append(shaders.instance.allocator, .{ shader, source_i, bp.id.? }) catch {};
                                                }
                                            } else |err| {
                                                log.warn("Failed to add breakpoint for shader {x} source {d}: {any}", .{ shader, source_i, err });
                                            }
                                        } else {
                                            log.warn("Shader {d} source {d} not found", .{ shader, source_i });
                                        }
                                    } else log.debug("Shader {d} not found", .{shader});
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
    shaders.instance.Programs.appendUntagged(shaders.Shader.Program{
        .ref = @intCast(new_platform_program),
        .link = defaultLink,
        .stat = storage.Stat.now(),
    }) catch |err| {
        log.warn("Failed to add program {x} cache: {any}", .{ new_platform_program, err });
    };

    return new_platform_program;
}

pub export fn glAttachShader(program: gl.GLuint, shader: gl.GLuint) void {
    shaders.instance.programAttachSource(@intCast(program), @intCast(shader)) catch |err| {
        log.err("Failed to attach shader {x} to program {x}: {any}", .{ shader, program, err });
    };

    gl.attachShader(program, shader);
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
            gl.PROGRAM => shaders.instance.Programs.untagIndex(name, 0) catch |err| {
                log.warn("Failed to remove tag for program {x}: {any}", .{ name, err });
            },
            gl.SHADER => shaders.instance.Shaders.untagAll(name) catch |err| {
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
                    while (it.next()) |current| {
                        var it2 = std.mem.splitScalar(u8, current, ':');
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
                            log.err("Failed to parse tag {s} for shader {x}", .{ current, name });
                            continue;
                        }
                        shaders.instance.Shaders.assignTag(@intCast(name), index, tag.?, behavior) catch |err| objLabErr(label.?[0..real_length], name, index, err);
                    }
                } else {
                    shaders.instance.Shaders.assignTag(@intCast(name), 0, label.?[0..real_length], .Error) catch |err| objLabErr(label.?[0..real_length], name, 0, err);
                }
            },
            gl.PROGRAM => shaders.instance.Programs.assignTag(@intCast(name), 0, label.?[0..real_length], .Error) catch |err| objLabErr(label.?[0..real_length], name, 0, err),
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
                            shaders.instance.mapPhysicalToVirtual(real_path, .{ .sources = .{ .tagged = virtual_path } }) catch |err| failedWorkspacePath(buf.?[0..real_length], err);
                        } else failedWorkspacePath(buf.?[0..real_length], error.@"No virtual path specified");
                    } else failedWorkspacePath(buf.?[0..real_length], error.@"No real path specified");
                }
            },
            ids.COMMAND_WORKSPACE_REMOVE => if (buf == null) { //Remove all
                shaders.instance.clearWorkspacePaths();
            } else { //Remove
                const real_length = realLength(length, buf);
                var it = std.mem.split(u8, buf.?[0..real_length], "<-");
                if (it.next()) |real_path| {
                    if (!(shaders.instance.removeWorkspacePath(real_path, if (it.next()) |v| shaders.GenericLocator.parse(v) catch |err| return failedRemoveWorkspacePath(buf.?[0..real_length], err) else null) catch false)) {
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

//TODO: glSpecializeShader glShaderBinary

pub fn deinit() void {
    var it = readback_breakpoint_textures.valueIterator();
    while (it.next()) |val| {
        common.allocator.free(val.*);
    }
    readback_breakpoint_textures.deinit(common.allocator);
    for (replacement_attachment_textures) |t| {
        if (t != 0) {
            gl.deleteTextures(1, &t);
        }
    }
}
