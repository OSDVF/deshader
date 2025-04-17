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
// along with this program. If not, see <https://www.gnu.org/licenses/>.

//! ## Instrumentation Runtime Backend for OpenGL
//!
//! See `instrumentation` for details about the whole instrumentation architecture design.
//!  Rendering and shader instrumentation frontend service implementation for OpenGL.
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
const instr_decls = @import("../declarations/instruments.zig");
const shaders = @import("../services/shaders.zig");
const storage = @import("../services/storage.zig");
const Processor = @import("../services/processor.zig");
const instruments = @import("../services/instruments.zig");
const gl_instruments = @import("gl_instruments.zig");
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
const Support = Processor.Config.Support;

const BufferType = enum(gl.@"enum") {
    AtomicCounter = gl.ATOMIC_COUNTER_BUFFER,
    ShaderStorage = gl.SHADER_STORAGE_BUFFER,
    TransformFeedback = gl.TRANSFORM_FEEDBACK_BUFFER,
    Uniform = gl.UNIFORM_BUFFER,
};

/// Managed per-context state. Stores descriptive information which cannot be directly queried from OpenGL.
const ContextState = struct {
    proc_table: gl.ProcTable = undefined,
    gl: loaders.GlBackend, // TODO: encapsulate the whole gl_shaders into a backend-specific service
    primitives_written_queries: std.ArrayListUnmanaged(gl.uint) = .empty,

    // memory for used indexed buffer binding indexed. OpenGL does not provide a standard way to query them.
    indexed_buffer_bindings: std.EnumMap(BufferType, usize) = .{},
    search_paths: std.AutoHashMapUnmanaged(shaders.Shader.StageRef, []String) = .empty,

    replacement_attachment_textures: [32]gl.uint = [_]gl.uint{0} ** 32,
    /// Readback buffers for the
    readbacks: std.AutoHashMapUnmanaged(instr_decls.InstrumentId, Readback) = .empty,
    max_buffers: gl.int = 0,
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

        const prev_proc_table = gl.getCurrentProcTable();
        gl.makeProcTableCurrent(&s.proc_table);
        gl.DeleteQueries(@intCast(s.primitives_written_queries.items.len), s.primitives_written_queries.items.ptr);
        s.primitives_written_queries.deinit(common.allocator);

        for (s.replacement_attachment_textures) |t| {
            if (t != 0) {
                gl.DeleteTextures(1, @constCast(@ptrCast(&t)));
            }
        }
        {
            var it = s.readbacks.valueIterator();
            while (it.next()) |v| {
                v.deinit();
            }
        }
        s.readbacks.deinit(common.allocator);
        gl.makeProcTableCurrent(prev_proc_table);
    }
};

pub const Readback = struct {
    data: []u8,
    /// Handle to the storage created in the GL API.
    /// GL_BUFFER or GL_TEXTURE
    ref: gl.uint,

    fn deinit(self: *@This()) void {
        common.allocator.free(self.data);
        if (gl.IsBuffer(self.ref) == gl.TRUE) {
            gl.DeleteBuffers(1, (&self.ref)[0..1]);
        } else {
            gl.DeleteTextures(1, (&self.ref)[0..1]);
        }
    }
};

const Request = enum { BorrowContext };
const Response = enum { ContextFree };

/// API-backend wide state of instrumentation for all contexts. Indexed by the GL context address.
var state: std.HashMapUnmanaged(*const shaders.BackendContext, ContextState, common.AddressContext(*const shaders.BackendContext), 80) = .empty;
var waiter = common.Waiter(Request, Response){};
/// The globalservice instance which belongs to currently selected context.
pub threadlocal var current: *shaders = undefined;

// Functions to be wrapped by error handling
const actions = struct {
    fn updateSearchPaths(shader: gl.uint, count: gl.sizei, paths: ?[*][*:0]const gl.char, lengths: ?[*]const gl.int) !void {
        const c_state = state.getPtr(current.context) orelse return;
        if (paths) |p| {
            const paths_d = try common.allocator.alloc(String, @intCast(count));
            for (p, paths_d, 0..) |path, *d, i| {
                d.* = try common.allocator.dupe(u8, path[0..realLength(if (lengths) |l| l[i] else -1, path)]);
            }

            try c_state.search_paths.put(common.allocator, @enumFromInt(shader), paths_d);
        } else {
            // Free the paths
            if (c_state.search_paths.fetchRemove(@enumFromInt(shader))) |kv| {
                for (kv.value) |v| {
                    common.allocator.free(v);
                }
                common.allocator.free(kv.value);
            }
        }
    }

    fn createNamedString(namelen: gl.int, name: CString, stringlen: gl.int, string: CString) !void {
        const result = try current.Shaders.appendUntagged(.named_strings);
        result.stored.* = try shaders.Shader.SourcePart.init(common.allocator, decls.SourcesPayload{
            .currentSource = namedStringSourceAlloc,
            .free = freeNamedString,
            .language = decls.LanguageType.GLSL,
            .lengths = &.{@intCast(stringlen)},
            .ref = 0,
            .sources = &.{string},
        }, 0);
        _ = try current.Shaders.assignTag(.named_strings, result.index, name[0..realLength(namelen, name)], .Error);
    }
};

//
//#region Instrumentation
//

/// Holds the state before the instrumentation process
const Snapshot = struct {
    /// The previous drawBuffers configuration
    draw_buffers: [32]c_uint = [_]c_uint{0} ** 32,
    draw_buffers_len: c_uint = 0,
    pixel_pack_buffer: c_uint = undefined,
    pack: Pack = undefined,
    unpack: Pack = undefined,
    /// The previous read framebuffer binding
    read_fbo: gl.uint = 0,
    read_buffer: gl.uint = undefined,
    /// The previous framebuffer binding
    fbo: gl.uint = 0,

    /// (un)pack parameters
    const Pack = struct {
        swap_bytes: bool,
        lsb_first: bool,
        row_length: gl.int,
        image_height: gl.int,
        skip_rows: gl.int,
        skip_pixels: gl.int,
        skip_images: gl.int,
        alignment: gl.int,
    };

    fn getGlParams(comptime Schema: type, comptime prefix: String) Schema {
        var result: Schema = undefined;
        inline for (@typeInfo(Schema).@"struct".fields) |field| {
            const f = &@field(result, field.name);
            comptime var enum_name: [field.name.len]u8 = undefined;
            _ = comptime std.ascii.upperString(&enum_name, field.name);
            switch (@TypeOf(f.*)) {
                gl.int => gl.GetIntegerv(@field(gl, prefix ++ enum_name), @ptrCast(f)),
                gl.boolean => gl.GetBooleanv(@field(gl, prefix ++ enum_name), @ptrCast(f)),
                else => {},
            }
        }
        return result;
    }

    fn restoreGlParams(comptime Schema: type, source: Schema, comptime function: String, comptime prefix: String) void {
        inline for (@typeInfo(Schema).@"struct".fields) |field| {
            const f = @field(source, field.name);
            comptime var enum_name: [field.name.len]u8 = undefined;
            _ = comptime std.ascii.upperString(&enum_name, field.name);
            const gl_function = @field(gl, function);
            switch (@TypeOf(f)) {
                gl.int => gl_function(@field(gl, prefix ++ enum_name), f),
                gl.boolean => gl_function(@field(gl, prefix ++ enum_name), @intFromBool(f)),
                else => {},
            }
        }
    }

    fn capture(program: *const shaders.Shader.Program) @This() {
        var snapshot = Snapshot{}; // TODO do not use undefined to be sure that every field is set
        //
        // Bindings
        //

        // Framebuffers
        gl.GetIntegerv(gl.FRAMEBUFFER_BINDING, @ptrCast(&snapshot.fbo));
        gl.GetIntegerv(gl.READ_FRAMEBUFFER_BINDING, @ptrCast(&snapshot.read_fbo));

        // Pixel pack buffer
        gl.GetIntegerv(gl.PIXEL_PACK_BUFFER_BINDING, @ptrCast(&snapshot.pixel_pack_buffer));
        // Read buffer
        gl.GetIntegerv(gl.READ_BUFFER, @ptrCast(&snapshot.read_buffer));

        // (un)pack parameters
        snapshot.pack = getGlParams(Pack, "PACK_");
        snapshot.unpack = getGlParams(Pack, "UNPACK_");

        //
        // Other configurations
        //

        var it = program.stages.valueIterator();
        while (it.next()) |parts| {
            const shader_stage = parts.*.items[0].stage;

            switch (shader_stage) {
                .gl_fragment, .vk_fragment => {
                    // get GL_DRAW_BUFFERi
                    var max_draw_buffers: gl.uint = undefined;
                    gl.GetIntegerv(gl.MAX_DRAW_BUFFERS, @ptrCast(&max_draw_buffers));
                    {
                        var i: gl.@"enum" = 0;
                        while (i < max_draw_buffers) : (i += 1) {
                            var previous: gl.@"enum" = undefined;
                            gl.GetIntegerv(gl.DRAW_BUFFER0 + i, @ptrCast(&previous));
                            switch (previous) {
                                gl.BACK => {
                                    snapshot.draw_buffers[i] = gl.BACK_LEFT;
                                    snapshot.draw_buffers_len = i + 1;
                                },
                                gl.FRONT => {
                                    snapshot.draw_buffers[i] = gl.FRONT_LEFT;
                                    snapshot.draw_buffers_len = i + 1;
                                },
                                gl.FRONT_AND_BACK => {
                                    snapshot.draw_buffers[i] = gl.BACK_LEFT;
                                    snapshot.draw_buffers_len = i + 1;
                                },
                                gl.LEFT => {
                                    snapshot.draw_buffers[i] = gl.FRONT_LEFT;
                                    snapshot.draw_buffers_len = i + 1;
                                },
                                gl.RIGHT => {
                                    snapshot.draw_buffers[i] = gl.FRONT_RIGHT;
                                    snapshot.draw_buffers_len = i + 1;
                                },
                                gl.NONE => snapshot.draw_buffers[i] = previous,
                                else => {
                                    snapshot.draw_buffers[i] = previous;
                                    snapshot.draw_buffers_len = i + 1;
                                },
                            }
                        }
                    }
                },
                else => {},
            }
        }
        return snapshot;
    }

    fn restore(snapshot: Snapshot) !void {
        log.info("Restoring pipeline state", .{});
        var it = current.state.valueIterator();
        while (it.next()) |value| {
            for (value.instruments.values()) |instrument| {
                if (instrument.onRestore) |onRestore| {
                    onRestore(current) catch |err| {
                        log.err("Instrumentation backend onRestore failed: {} at {?}", .{ err, @errorReturnTrace() });
                    };
                }
            }
        }
        gl.DrawBuffers(@intCast(snapshot.draw_buffers_len), &snapshot.draw_buffers);
        gl.ReadBuffer(snapshot.read_fbo);

        // restore the previous framebuffer binding
        gl.BindBuffer(gl.PIXEL_PACK_BUFFER, snapshot.pixel_pack_buffer);

        // (un)pack parameters
        restoreGlParams(Snapshot.Pack, snapshot.pack, "PixelStorei", "PACK_");
        restoreGlParams(Snapshot.Pack, snapshot.unpack, "PixelStorei", "UNPACK_");
    }
};

fn dispatchDebugCompute(
    comptime instrument_func: anytype,
    i_args: anytype,
    comptime dispatch_func: anytype,
    d_args: anytype,
) void {
    var program_ref: gl.uint = undefined;
    gl.GetIntegerv(gl.CURRENT_PROGRAM, @ptrCast(&program_ref)); // GL API is stupid and uses GLint for GLuint

    if (program_ref != 0) blk: {
        if (current.Programs.all.get(@enumFromInt(program_ref))) |program| {
            var general_params = getGeneralParams(program_ref) catch |err| {
                log.err("Failed to get general params for dispatch call {} at {?}", .{ err, @errorReturnTrace() });
                break :blk;
            };
            defer general_params.used_buffers.deinit(common.allocator);
            dispatchDebugImpl(program, instrument_func, i_args ++ .{ program, general_params }, dispatch_func, d_args, false) catch |err| {
                log.err("Failed to process instrumentation: {}\n{}", .{ err, @errorReturnTrace() orelse &common.null_trace });
            };
            return;
        } else {
            log.err("Program {x} not found in database", .{program_ref});
        }
    } else {
        log.info("No program bound for dispatch call", .{});
    }

    // At this point, the instrumentation was not possible, so just call the original function
    @call(.auto, dispatch_func, d_args);
}

fn dispatchDebugDraw(
    comptime instrument_func: anytype,
    i_args: anytype,
    comptime dispatch_func: anytype,
    d_args: anytype,
) void {
    var program_ref: gl.uint = undefined;
    gl.GetIntegerv(gl.CURRENT_PROGRAM, @ptrCast(&program_ref)); // GL API is stupid and uses GLint for GLuint

    if (program_ref != 0) blk: {
        if (current.Programs.all.get(@enumFromInt(program_ref))) |program| {
            var context_params = getContextParams(program) catch |err| {
                log.err("Failed to get general params for dispatch call {} at {?}", .{ err, @errorReturnTrace() });
                break :blk;
            };

            defer context_params.deinit(common.allocator);
            dispatchDebugImpl(program, instrument_func, i_args ++ .{context_params}, dispatch_func, d_args, true) catch |err| {
                log.err("Failed to process instrumentation: {}\n{}", .{ err, @errorReturnTrace() orelse &common.null_trace });
            };
            return;
        } else {
            log.err("Program {x} not found in database", .{program_ref});
        }
    } else {
        log.info("No program bound for dispatch call", .{});
    }
}

fn dispatchDebugImpl(
    program: *shaders.Shader.Program,
    comptime instrument_func: anytype,
    i_args: anytype,
    comptime dispatch_func: anytype,
    d_args: anytype,
    comptime xfb: bool,
) !void {
    // Find currently bound shaders
    // Instrumentation
    // - Add debug outputs to the shaders (framebuffer attachments, buffers)
    // - Rewrite shader code to write into the debug outputs
    // - Dispatch debugging draw calls and read the outputs while a breakpoint or a step is reached
    // Call the original draw call...

    const snapshot = Snapshot.capture(program);
    while (true) {
        shaders.user_action = false;
        // Instrument the currently bound program
        var instrumentation: shaders.InstrumentationResult = try @call(.auto, instrument_func, i_args);
        defer instrumentation.deinit(current.allocator);

        const platform = try prepareStorage(&instrumentation, snapshot);

        if (xfb) {
            beginXfbQueries();
        }
        @call(.auto, dispatch_func, d_args);
        if (xfb) {
            endXfbQueries();
        }

        try processOutput(instrumentation, platform);

        if (!shaders.user_action) {
            break;
        }
    }
    try snapshot.restore();
}

fn instrumentDraw(vertices: gl.int, instances: gl.sizei, params: shaders.State.Params.Context) !shaders.InstrumentationResult {
    return current.instrumentProgram(params.program, .{
        .allocator = common.allocator,
        .vertices = @intCast(vertices),
        .instances = @intCast(instances),
        .compute = [_]usize{ 0, 0, 0, 0, 0, 0 },
        .context = params,
    });
}

fn instrumentCompute(num_groups: [3]usize, program: *shaders.Shader.Program, general_params: GeneralParams) !shaders.InstrumentationResult {
    var empty = std.ArrayListUnmanaged(usize){};
    defer empty.deinit(common.allocator);
    const c_state = state.getPtr(current.context).?;
    var group_sizes: [3]gl.int = undefined;
    gl.GetProgramiv(program.ref.cast(gl.uint), gl.COMPUTE_WORK_GROUP_SIZE, &group_sizes[0]);
    return current.instrumentProgram(program, .{
        .allocator = common.allocator,
        .vertices = 0,
        .instances = 0,
        .compute = [_]usize{
            num_groups[0],
            num_groups[1],
            num_groups[2],
            @intCast(group_sizes[0]),
            @intCast(group_sizes[1]),
            @intCast(group_sizes[2]),
        },
        .context = .{
            .used_buffers = general_params.used_buffers,
            .used_interface = empty,
            .max_attachments = 0,
            .max_buffers = @intCast(c_state.max_buffers),
            .max_xfb = 0,
            .screen = [_]usize{ 0, 0 },
            .search_paths = if (state.getPtr(current.context)) |s| s.search_paths else null,
            .program = program,
        },
    });
}

const PlatformFormat = struct {
    format: gl.@"enum",
    type: gl.@"enum",
    internal_format: gl.int,
};

/// Converts texture/vertex attribute format to GL "format", "type" and "internal format", which can be further used by TexImage2D
fn formatToPlatform(format: Processor.OutputStorage.Location.Format) PlatformFormat {
    return switch (format) {
        .@"4F32" => .{
            .format = gl.RGBA,
            .type = gl.FLOAT,
            .internal_format = gl.RGBA32F,
        },
        .@"3F32" => .{
            .format = gl.RGB,
            .type = gl.FLOAT,
            .internal_format = gl.RGB32F,
        },
        .@"2F32" => .{
            .format = gl.RG,
            .type = gl.FLOAT,
            .internal_format = gl.RG32F,
        },
        .@"1F32" => .{
            .format = gl.RED,
            .type = gl.FLOAT,
            .internal_format = gl.R32F,
        },
        .@"4F16" => .{
            .format = gl.RGBA,
            .type = gl.HALF_FLOAT,
            .internal_format = gl.RGBA16F,
        },
        .@"3F16" => .{
            .format = gl.RGB,
            .type = gl.HALF_FLOAT,
            .internal_format = gl.RGB16F,
        },
        .@"2F16" => .{
            .format = gl.RG,
            .type = gl.HALF_FLOAT,
            .internal_format = gl.RG16F,
        },
        .@"1F16" => .{
            .format = gl.RED,
            .type = gl.HALF_FLOAT,
            .internal_format = gl.R16F,
        },
        .@"4F8" => .{
            .format = gl.RGBA,
            .type = gl.FLOAT,
            .internal_format = gl.RGBA8,
        },
        .@"3F8" => .{
            .format = gl.RGB,
            .type = gl.FLOAT,
            .internal_format = gl.RGB8,
        },
        .@"2F8" => .{
            .format = gl.RG,
            .type = gl.FLOAT,
            .internal_format = gl.RG8,
        },
        .@"1F8" => .{
            .format = gl.RED,
            .type = gl.FLOAT,
            .internal_format = gl.R8,
        },
        .@"4U8" => .{
            .format = gl.RGBA,
            .type = gl.UNSIGNED_BYTE,
            .internal_format = gl.RGBA8UI,
        },
        .@"3U8" => .{
            .format = gl.RGB,
            .type = gl.UNSIGNED_BYTE,
            .internal_format = gl.RGB8UI,
        },
        .@"2U8" => .{
            .format = gl.RG,
            .type = gl.UNSIGNED_BYTE,
            .internal_format = gl.RG8UI,
        },
        .@"1U8" => .{
            .format = gl.RED,
            .type = gl.UNSIGNED_BYTE,
            .internal_format = gl.R8UI,
        },
        .@"4U32" => .{
            .format = gl.RGBA_INTEGER,
            .type = gl.UNSIGNED_INT,
            .internal_format = gl.RGBA32UI,
        },
        .@"3U32" => .{
            .format = gl.RGB_INTEGER,
            .type = gl.UNSIGNED_INT,
            .internal_format = gl.RGB32UI,
        },
        .@"2U32" => .{
            .format = gl.RG_INTEGER,
            .type = gl.UNSIGNED_INT,
            .internal_format = gl.RG32UI,
        },
        .@"1U32" => .{
            .format = gl.RED_INTEGER,
            .type = gl.UNSIGNED_INT,
            .internal_format = gl.R32UI,
        },
        .@"4I32" => .{
            .format = gl.RGBA_INTEGER,
            .type = gl.INT,
            .internal_format = gl.RGBA32I,
        },
        .@"3I32" => .{
            .format = gl.RGB_INTEGER,
            .type = gl.INT,
            .internal_format = gl.RGB32I,
        },
        .@"2I32" => .{
            .format = gl.RG_INTEGER,
            .type = gl.INT,
            .internal_format = gl.RG32I,
        },
        .@"1I32" => .{
            .format = gl.RED_INTEGER,
            .type = gl.INT,
            .internal_format = gl.R32I,
        },
        .@"1I8" => .{
            .format = gl.RED_INTEGER,
            .type = gl.BYTE,
            .internal_format = gl.R8I,
        },
        .@"2I8" => .{
            .format = gl.RG_INTEGER,
            .type = gl.BYTE,
            .internal_format = gl.RG8I,
        },
        .@"3I8" => .{
            .format = gl.RGB_INTEGER,
            .type = gl.BYTE,
            .internal_format = gl.RGB8I,
        },
        .@"4I8" => .{
            .format = gl.RGBA_INTEGER,
            .type = gl.BYTE,
            .internal_format = gl.RGBA8I,
        },
        .@"1U16" => .{
            .format = gl.RED_INTEGER,
            .type = gl.UNSIGNED_SHORT,
            .internal_format = gl.R16UI,
        },
        .@"2U16" => .{
            .format = gl.RG_INTEGER,
            .type = gl.UNSIGNED_SHORT,
            .internal_format = gl.RG16UI,
        },
        .@"3U16" => .{
            .format = gl.RGB_INTEGER,
            .type = gl.UNSIGNED_SHORT,
            .internal_format = gl.RGB16UI,
        },
        .@"4U16" => .{
            .format = gl.RGBA_INTEGER,
            .type = gl.UNSIGNED_SHORT,
            .internal_format = gl.RGBA16UI,
        },
        .@"1I16" => .{
            .format = gl.RED_INTEGER,
            .type = gl.SHORT,
            .internal_format = gl.R16I,
        },
        .@"2I16" => .{
            .format = gl.RG_INTEGER,
            .type = gl.SHORT,
            .internal_format = gl.RG16I,
        },
        .@"3I16" => .{
            .format = gl.RGB_INTEGER,
            .type = gl.SHORT,
            .internal_format = gl.RGB16I,
        },
        .@"4I16" => .{
            .format = gl.RGBA_INTEGER,
            .type = gl.SHORT,
            .internal_format = gl.RGBA16I,
        },
    };
}

/// Prepare debug output buffers for instrumented shaders execution
fn prepareStorage(instrumentation: *shaders.InstrumentationResult, snapshot: Snapshot) !instr_decls.PlatformParamsGL {
    // TODO do not perform this when no instrumentation occured
    var result: instr_decls.PlatformParamsGL = undefined;
    if (instrumentation.invalidated) {
        if (commands.instance) |comm| {
            try comm.sendEvent(.invalidated, debug.InvalidatedEvent{ .areas = &.{debug.InvalidatedEvent.Areas.threads} });
        }
    }
    const c_state = state.getPtr(current.context) orelse return error.NoState;
    var draw_buffers = [_]gl.@"enum"{gl.NONE} ** 32;
    @memcpy(draw_buffers[0..snapshot.draw_buffers_len], snapshot.draw_buffers[0..snapshot.draw_buffers_len]);
    var draw_buffers_len = snapshot.draw_buffers_len;

    var it = instrumentation.stages.iterator();
    while (it.next()) |state_entry| { // for each shader stage (in the order they are executed)
        var instr_state = state_entry.value_ptr.*;
        const shader_ref = state_entry.key_ptr.*;
        const shader_stage = current.Shaders.all.get(shader_ref).?.items[0].stage;
        //
        // Prepare storages
        //
        for (instr_state.channels.out.keys(), instr_state.channels.out.values()) |key, stor| {
            const readback = try c_state.readbacks.getOrPut(common.allocator, key);
            if (!readback.found_existing) {
                readback.value_ptr.data = try common.allocator.alloc(u8, stor.size);
            }

            switch (stor.location) {
                .interface => |interface| { // `id` should be the last attachment index
                    switch (shader_stage) {
                        .gl_fragment, .vk_fragment => {
                            // append to debug draw buffers spec
                            {
                                var i: gl.@"enum" = 0;
                                while (i <= interface.location) : (i += 1) {
                                    draw_buffers[i] = @as(gl.@"enum", gl.COLOR_ATTACHMENT0) + i;
                                }
                                draw_buffers_len = @intCast(interface.location + 1);
                            }

                            if (!readback.found_existing) {
                                // Create a debug attachment for the framebuffer
                                gl.GenTextures(1, (&readback.value_ptr.ref)[0..1]);
                                gl.BindTexture(gl.TEXTURE_2D, readback.value_ptr.ref);
                                const format = formatToPlatform(interface.format);
                                gl.TexImage2D(gl.TEXTURE_2D, 0, format.internal_format, @intCast(instr_state.params.context.screen[0]), @intCast(instr_state.params.context.screen[1]), 0, format.format, format.type, null);
                            }

                            // Attach the debug-output-channel textures to the current framebuffer (or create a new if there is none)
                            result.fbo = snapshot.fbo;
                            if (snapshot.fbo == 0) {
                                // default framebuffer does not support attachments so we must replace it with a custom one
                                if (result.fbo == 0) {
                                    gl.GenFramebuffers(1, (&result.fbo)[0..1]);
                                }
                                gl.BindFramebuffer(gl.FRAMEBUFFER, result.fbo);
                                //create depth and stencil attachment
                                var depth_stencil: gl.uint = undefined;
                                gl.GenRenderbuffers(1, (&depth_stencil)[0..1]);
                                gl.BindRenderbuffer(gl.RENDERBUFFER, depth_stencil);
                                gl.RenderbufferStorage(gl.RENDERBUFFER, gl.DEPTH24_STENCIL8, @intCast(instr_state.params.context.screen[0]), @intCast(instr_state.params.context.screen[1]));
                                gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_STENCIL_ATTACHMENT, gl.RENDERBUFFER, depth_stencil);
                                for (0..interface.location) |i| {
                                    // create all previous color attachments
                                    if (c_state.replacement_attachment_textures[i] == 0) { // TODO handle resolution change
                                        gl.GenTextures(1, @ptrCast(&c_state.replacement_attachment_textures[i]));
                                    }
                                    gl.BindTexture(gl.TEXTURE_2D, c_state.replacement_attachment_textures[i]); //TODO mimic original texture formats
                                    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA, @intCast(instr_state.params.context.screen[0]), @intCast(instr_state.params.context.screen[1]), 0, gl.RGBA, gl.FLOAT, null);
                                }
                            }
                            gl.NamedFramebufferTexture(result.fbo, gl.COLOR_ATTACHMENT0 + @as(gl.@"enum", @intCast(interface.location)), readback.value_ptr.ref, 0);
                        },
                        else => unreachable, //TODO transform feedback
                    }
                },
                .buffer => |buffer| {
                    if (!readback.found_existing) {
                        gl.GenBuffers(1, (&readback.value_ptr.ref)[0..1]);
                        gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, @intCast(buffer.binding), readback.value_ptr.ref);
                        gl.NamedBufferStorage(readback.value_ptr.ref, @intCast(readback.value_ptr.data.len), null, gl.CLIENT_STORAGE_BIT);
                    }
                },
            }
        }
        for (instr_state.instruments.values()) |*instr| {
            if (instr.onBeforeDraw) |onBeforeDraw| {
                onBeforeDraw(current, instrumentation) catch |err| {
                    log.err("Instrumentation backend onBeforeDraw failed: {} at {?}", .{ err, @errorReturnTrace() });
                };
            }
        }
    }
    // Apply the new drawBuffers spec
    if (draw_buffers_len > snapshot.draw_buffers_len) {
        gl.DrawBuffers(@as(gl.sizei, @intCast(draw_buffers_len)), &draw_buffers);
    }
    return result;
}

/// Impement glReadnPixels for contexts older than Gl 4.5 and set pixel pack parameters to defaults
fn readPixels(x: gl.int, y: gl.int, width: gl.sizei, height: gl.sizei, format: gl.@"enum", @"type": gl.@"enum", buf_size: usize, pixels: [*]u8) std.mem.Allocator.Error!void {
    // Reset pixel pack parameters
    gl.BindBuffer(gl.PIXEL_PACK_BUFFER, 0); // we do not want any PIXEL_PACK_BUFFER to be bound

    gl.PixelStorei(gl.PACK_SWAP_BYTES, 0);
    gl.PixelStorei(gl.PACK_LSB_FIRST, 0);
    gl.PixelStorei(gl.PACK_ROW_LENGTH, 0);
    gl.PixelStorei(gl.PACK_SKIP_ROWS, 0);
    gl.PixelStorei(gl.PACK_SKIP_PIXELS, 0);
    gl.PixelStorei(gl.PACK_SKIP_IMAGES, 0);
    gl.PixelStorei(gl.PACK_ALIGNMENT, 1);

    if (isProcLoaded("ReadnPixels")) {
        gl.ReadnPixels(x, y, width, height, format, @"type", @intCast(buf_size), pixels);
    } else {
        const pixels_size: usize = @intCast((width - x) * (height - y));
        if (pixels_size > buf_size) {
            log.warn("glReadnPixels is not supported, falling back to glReadPixels. Source size is {d}, buffer size is {d}", .{ pixels_size, buf_size });
            const temp = try common.allocator.alloc(u8, pixels_size);
            defer common.allocator.free(temp);
            gl.ReadPixels(x, y, width, height, format, @"type", temp.ptr);
            @memcpy(pixels, temp[0..buf_size]);
            // TODO do not use memcpy but instead move or realloc or resize
        } else {
            gl.ReadPixels(x, y, width, height, format, @"type", pixels);
        }
    }
}

fn processOutput(instrumentation: shaders.InstrumentationResult, platform: instr_decls.PlatformParamsGL) !void {
    const c_state = state.getPtr(current.context).?;
    for (instrumentation.stages.keys(), instrumentation.stages.values()) |shader_ref, st| {
        const stage = current.Shaders.all.get(shader_ref).?.items[0].stage;
        for (st.channels.out.keys(), st.channels.out.values()) |key, stor| {
            if (!stor.lazy) {
                const readback: *Readback = c_state.readbacks.getPtr(key).?;
                switch (stor.location) {
                    .interface => |interface| {
                        switch (stage) {
                            .gl_fragment, .vk_fragment => {
                                // read pixels to the main memory synchronously
                                gl.ReadBuffer(@as(gl.@"enum", @intCast(interface.location)) + gl.COLOR_ATTACHMENT0);
                                const format = formatToPlatform(interface.format);

                                try readPixels(
                                    @intCast(interface.x),
                                    @intCast(interface.y),
                                    @intCast(st.params.context.screen[0]),
                                    @intCast(st.params.context.screen[1]),
                                    format.format,
                                    format.type, // The same format as the texture
                                    @intCast(readback.data.len),
                                    readback.data.ptr,
                                );
                            },
                            else => unreachable, // TODO transform feedback
                        }
                    },
                    .buffer => |buffer| {
                        gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, readback.ref);
                        gl.GetBufferSubData(gl.SHADER_STORAGE_BUFFER, @intCast(buffer.offset), @intCast(readback.data.len), readback.data.ptr);
                    },
                }
            }
        }
    }
    for (current.instrument_clients.items) |*instrument| {
        if (instrument.onResult) |onResult| {
            onResult(current, &instrumentation, &platform) catch |err| {
                log.err("Instrumentation client onResult failed: {}", .{err});
            };
        }
    }
}

//#endregion

//
//#region State queries
//
const GeneralParams = struct {
    used_buffers: std.ArrayListUnmanaged(usize),
};
fn getGeneralParams(program_ref: gl.uint) !GeneralParams {
    // used bindings
    var used_buffers = std.ArrayListUnmanaged(usize){};
    // used indexes
    var used_buffers_count: gl.uint = undefined;
    gl.GetProgramInterfaceiv(program_ref, gl.SHADER_STORAGE_BLOCK, gl.ACTIVE_RESOURCES, @ptrCast(&used_buffers_count));
    var i: gl.uint = 0;
    while (i < used_buffers_count) : (i += 1) { // for each buffer index
        var binding: gl.uint = undefined; // get the binding number
        const param: gl.@"enum" = gl.BUFFER_BINDING;
        gl.GetProgramResourceiv(program_ref, gl.SHADER_STORAGE_BLOCK, i, 1, &param, 1, null, @ptrCast(&binding));
        try used_buffers.append(common.allocator, binding);
    }

    return GeneralParams{ .used_buffers = used_buffers };
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
fn getOutputInterface(program: gl.uint) !std.ArrayListUnmanaged(usize) {
    var out_interface = std.ArrayListUnmanaged(usize){};
    var count: gl.uint = undefined;
    gl.GetProgramInterfaceiv(program, gl.PROGRAM_OUTPUT, gl.ACTIVE_RESOURCES, @ptrCast(&count));
    // filter out used outputs
    {
        var i: gl.uint = 0;
        var name: [64:0]gl.char = undefined;
        while (i < count) : (i += 1) {
            gl.GetProgramResourceName(program, gl.PROGRAM_OUTPUT, i, 64, null, &name);
            if (!std.mem.startsWith(u8, &name, Processor.templates.prefix)) {
                const location: gl.int = gl.GetProgramResourceLocation(program, gl.PROGRAM_OUTPUT, &name);
                // is negative on error (program has compile errors...)
                if (location >= 0) {
                    try out_interface.append(common.allocator, @intCast(location));
                }
            }
        }
    }
    std.sort.heap(usize, out_interface.items, {}, std.sort.asc(usize));
    return out_interface;
}

fn getContextParams(program: *shaders.Shader.Program) !shaders.State.Params.Context {
    const c_state = state.getPtr(current.context) orelse return error.NoState;

    // Check if transform feedback is active -> no fragment shader will be executed
    var some_feedback_buffer: gl.int = undefined;
    gl.GetIntegerv(gl.TRANSFORM_FEEDBACK_BUFFER_BINDING, @ptrCast(&some_feedback_buffer));
    // TODO or check indexed_buffer_bindings[BufferType.TransformFeedback] != 0 ?

    // Can be u5 because maximum attachments is limited to 32 by the API, and is often limited to 8
    // TODO query GL_PROGRAM_OUTPUT to check actual used attachments
    var used_attachments = try std.ArrayList(u5).initCapacity(common.allocator, @intCast(c_state.max_attachments));
    defer used_attachments.deinit();

    // NOTE we assume that all attachments that shader really uses are bound
    var current_fbo: gl.uint = undefined;
    gl.GetIntegerv(gl.FRAMEBUFFER_BINDING, @ptrCast(&current_fbo));

    // Get screen size
    const screen = if (some_feedback_buffer == 0) getFrambufferSize(current_fbo) else [_]gl.int{ 0, 0 };
    const general_params = try getGeneralParams(program.ref.cast(gl.uint));

    var used_fragment_interface = std.ArrayListUnmanaged(usize){};
    //TODO var used_vertex_interface = std.ArrayListUnmanaged(usize){};

    var stages_it = program.stages.valueIterator();
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
            //used_vertex_interface = try getOutputInterface(@intCast(program.ref));
            gl.Disable(gl.RASTERIZER_DISCARD);
            used_fragment_interface = try getOutputInterface(program.ref.cast(gl.uint));
            gl.Enable(gl.RASTERIZER_DISCARD);
        } else {
            used_fragment_interface = try getOutputInterface(program.ref.cast(gl.uint));
            gl.Enable(gl.RASTERIZER_DISCARD);
            //used_vertex_interface = try getOutputInterface(@intCast(program.ref));
            gl.Disable(gl.RASTERIZER_DISCARD);
        }
    } else {
        //used_vertex_interface = try getOutputInterface(@intCast(program.ref));
    }
    const screen_u = [_]usize{ @intCast(screen[0]), @intCast(screen[1]) };

    var buffer_mode: gl.int = 0;
    gl.GetProgramiv(program.ref.cast(gl.uint), gl.TRANSFORM_FEEDBACK_BUFFER_MODE, &buffer_mode);
    return shaders.State.Params.Context{
        .max_attachments = c_state.max_attachments,
        .max_buffers = @intCast(c_state.max_buffers),
        .max_xfb = if (buffer_mode == gl.SEPARATE_ATTRIBS) @max(0, c_state.max_xfb_streams * c_state.max_xfb_sep_components) else @max(0, c_state.max_xfb_interleaved_components),
        .program = program,
        .search_paths = c_state.search_paths,
        .screen = screen_u,
        .used_buffers = general_params.used_buffers,
        .used_interface = used_fragment_interface,
    };
}

fn beginXfbQueries() void {
    const c_state = state.getPtr(current.context).?;
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
    const c_state = state.getPtr(current.context).?;
    const queries = &c_state.primitives_written_queries;
    for (queries.items, 0..) |q, i| { // TODO streams vs buffers
        if (q != std.math.maxInt(gl.uint)) {
            gl.EndQueryIndexed(gl.TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN, @intCast(i));
        }
    }
}
//#endregion

//
//#region Drawing functions
//

fn FirstOrEmptyTuple(comptime T: type) type {
    const fields = std.meta.fields(T);
    return @Type(std.builtin.Type{ .@"struct" = .{
        .is_tuple = true,
        .fields = if (fields.len > 0) fields[0..1] else &.{},
        .decls = &.{},
        .layout = .auto,
    } });
}

fn firstOrEmpty(t: anytype) FirstOrEmptyTuple(@TypeOf(t)) {
    return if (std.meta.fields(@TypeOf(t)).len > 0)
        .{t[0]}
    else
        .{};
}

/// Returns true if the frame should be debugged
fn beginFrame() bool {

    // Bring back the stolen context
    // TODO: what if the context was stolen from different than the main drawing thread
    const c_state = state.getPtr(current.context).?;

    switch (c_state.gl) {
        inline else => |params, backend| {
            const gl_backend = @field(loaders.APIs.gl, @tagName(backend));
            if (gl_backend.get_current) |get_current| {
                const prev_context = get_current();
                while (waiter.requests()) |req| {
                    switch (req) {
                        .BorrowContext => {
                            _ = callRestNull(gl_backend.make_current[0], firstOrEmpty(params));
                            waiter.respondWaitEaten(.ContextFree);
                        },
                    }
                }
                _ = callConcatArgs(gl_backend.make_current[0], params, .{prev_context});
                // makeCurrent(gl_backend, params, current.context);
            }
        },
    }

    current.bus.processQueueNoThrow();
    return current.checkDebuggingOrRevert();
}

inline fn endFrame() void {}

// TODO
// pub export fn glDispatchComputeGroupSizeARB(num_groups_x: gl.uint, num_groups_y: gl.uint, num_groups_z: gl.uint, group_size_x: gl.uint, group_size_y: gl.uint, group_size_z: gl.uint) callconv(.c) void {
//     if (shaders.instance.checkDebuggingOrRevert()) {
//         dispatchDebug(instrumentCompute, .{ .{[_]usize{ @intCast(num_groups_x), @intCast(num_groups_y), @intCast(num_groups_z) }},gl.DispatchComputeGroupSizeARB,.{num_groups_x, num_groups_y, num_groups_z, group_size_x, group_size_y, group_size_z});
//     } else gl.DispatchComputeGroupSizeARB(num_groups_x, num_groups_y, num_groups_z, group_size_x, group_size_y, group_size_z);
// }

pub export fn glDispatchCompute(num_groups_x: gl.uint, num_groups_y: gl.uint, num_groups_z: gl.uint) callconv(.c) void {
    defer endFrame();
    if (beginFrame()) {
        dispatchDebugCompute(instrumentCompute, .{[_]usize{ @intCast(num_groups_x), @intCast(num_groups_y), @intCast(num_groups_z) }}, gl.DispatchCompute, .{ num_groups_x, num_groups_y, num_groups_z });
    } else gl.DispatchCompute(num_groups_x, num_groups_y, num_groups_z);
}

const IndirectComputeCommand = extern struct {
    num_groups_x: gl.uint,
    num_groups_y: gl.uint,
    num_groups_z: gl.uint,
};
pub export fn glDispatchComputeIndirect(address: gl.intptr) callconv(.c) void {
    defer endFrame();
    if (beginFrame()) {
        var command = IndirectComputeCommand{ .num_groups_x = 1, .num_groups_y = 1, .num_groups_z = 1 };
        //check GL_DISPATCH_INDIRECT_BUFFER
        var buffer: gl.int = 0;
        gl.GetIntegerv(gl.DISPATCH_INDIRECT_BUFFER_BINDING, @ptrCast(&buffer));
        if (buffer != 0) {
            gl.GetNamedBufferSubData(@intCast(buffer), address, @sizeOf(IndirectComputeCommand), &command);
        }

        dispatchDebugCompute(instrumentCompute, .{[_]usize{ @intCast(command.num_groups_x), @intCast(command.num_groups_y), @intCast(command.num_groups_z) }}, gl.DispatchComputeIndirect, .{address});
    } else gl.DispatchComputeIndirect(address);
}

pub export fn glDrawArrays(mode: gl.@"enum", first: gl.int, count: gl.sizei) callconv(.c) void {
    defer endFrame();
    if (beginFrame()) {
        dispatchDebugDraw(instrumentDraw, .{ count, 1 }, gl.DrawArrays, .{ mode, first, count });
    } else gl.DrawArrays(mode, first, count);
}

pub export fn glDrawArraysInstanced(mode: gl.@"enum", first: gl.int, count: gl.sizei, instanceCount: gl.sizei) callconv(.c) void {
    defer endFrame();
    if (beginFrame()) {
        dispatchDebugDraw(instrumentDraw, .{ count, instanceCount }, gl.DrawArraysInstanced, .{ mode, first, count, instanceCount });
    } else gl.DrawArraysInstanced(mode, first, count, instanceCount);
}

pub export fn glDrawElements(mode: gl.@"enum", count: gl.sizei, _type: gl.@"enum", indices: usize) callconv(.c) void {
    defer endFrame();
    if (beginFrame()) {
        dispatchDebugDraw(instrumentDraw, .{ count, 1 }, gl.DrawElements, .{ mode, count, _type, indices });
    } else gl.DrawElements(mode, count, _type, indices);
}

pub export fn glDrawElementsInstanced(mode: gl.@"enum", count: gl.sizei, _type: gl.@"enum", indices: ?*const anyopaque, instanceCount: gl.sizei) callconv(.c) void {
    defer endFrame();
    if (beginFrame()) {
        dispatchDebugDraw(instrumentDraw, .{ count, instanceCount }, gl.DrawElementsInstanced, .{ mode, count, _type, indices, instanceCount });
    } else gl.DrawElementsInstanced(mode, count, _type, indices, instanceCount);
}

pub export fn glDrawElementsBaseVertex(mode: gl.@"enum", count: gl.sizei, _type: gl.@"enum", indices: ?*const anyopaque, basevertex: gl.int) callconv(.c) void {
    defer endFrame();
    if (beginFrame()) {
        dispatchDebugDraw(instrumentDraw, .{ count, 1 }, gl.DrawElementsBaseVertex, .{ mode, count, _type, indices, basevertex });
    } else gl.DrawElementsBaseVertex(mode, count, _type, indices, basevertex);
}

pub export fn glDrawElementsInstancedBaseVertex(mode: gl.@"enum", count: gl.sizei, _type: gl.@"enum", indices: ?*const anyopaque, instanceCount: gl.sizei, basevertex: gl.int) callconv(.c) void {
    defer endFrame();
    if (beginFrame()) {
        dispatchDebugDraw(instrumentDraw, .{ count, instanceCount }, gl.DrawElementsInstancedBaseVertex, .{ mode, count, _type, indices, instanceCount, basevertex });
    } else gl.DrawElementsInstancedBaseVertex(mode, count, _type, indices, instanceCount, basevertex);
}

pub export fn glDrawRangeElements(mode: gl.@"enum", start: gl.uint, end: gl.uint, count: gl.sizei, _type: gl.@"enum", indices: ?*const anyopaque) callconv(.c) void {
    defer endFrame();
    if (beginFrame()) {
        dispatchDebugDraw(instrumentDraw, .{ count, 1 }, gl.DrawRangeElements, .{ mode, start, end, count, _type, indices });
    } else gl.DrawRangeElements(mode, start, end, count, _type, indices);
}

pub export fn glDrawRangeElementsBaseVertex(mode: gl.@"enum", start: gl.uint, end: gl.uint, count: gl.sizei, _type: gl.@"enum", indices: ?*const anyopaque, basevertex: gl.int) callconv(.c) void {
    defer endFrame();
    if (beginFrame()) {
        dispatchDebugDraw(instrumentDraw, .{ count, 1 }, gl.DrawRangeElementsBaseVertex, .{ mode, start, end, count, _type, indices, basevertex });
    } else gl.DrawRangeElementsBaseVertex(mode, start, end, count, _type, indices, basevertex);
}

pub export fn glDrawElementsInstancedBaseVertexBaseInstance(mode: gl.@"enum", count: gl.sizei, _type: gl.@"enum", indices: ?*const anyopaque, instanceCount: gl.sizei, basevertex: gl.int, baseInstance: gl.uint) callconv(.c) void {
    defer endFrame();
    if (beginFrame()) {
        dispatchDebugDraw(instrumentDraw, .{ count, instanceCount }, gl.DrawElementsInstancedBaseVertexBaseInstance, .{ mode, count, _type, indices, instanceCount, basevertex, baseInstance });
    } else gl.DrawElementsInstancedBaseVertexBaseInstance(mode, count, _type, indices, instanceCount, basevertex, baseInstance);
}

pub export fn glDrawElementsInstancedBaseInstance(mode: gl.@"enum", count: gl.sizei, _type: gl.@"enum", indices: ?*const anyopaque, instanceCount: gl.sizei, baseInstance: gl.uint) callconv(.c) void {
    defer endFrame();
    if (beginFrame()) {
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

pub export fn glDrawArraysIndirect(mode: gl.@"enum", indirect: ?*const IndirectCommand) callconv(.c) void {
    defer endFrame();
    if (beginFrame()) {
        const i = parseIndirect(indirect);
        dispatchDebugDraw(instrumentDraw, .{ @as(gl.sizei, @intCast(i.count)), @as(gl.sizei, @intCast(i.instanceCount)) }, gl.DrawArraysIndirect, .{ mode, indirect });
    } else gl.DrawArraysIndirect(mode, indirect);
}

pub export fn glDrawElementsIndirect(mode: gl.@"enum", _type: gl.@"enum", indirect: ?*const IndirectCommand) callconv(.c) void {
    defer endFrame();
    if (beginFrame()) {
        const i = parseIndirect(indirect);
        dispatchDebugDraw(instrumentDraw, .{ @as(gl.sizei, @intCast(i.count)), @as(gl.sizei, @intCast(i.instanceCount)) }, gl.DrawElementsIndirect, .{ mode, _type, indirect });
    } else gl.DrawElementsIndirect(mode, _type, indirect);
}

pub export fn glDrawArraysInstancedBaseInstance(mode: gl.@"enum", first: gl.int, count: gl.sizei, instanceCount: gl.sizei, baseInstance: gl.uint) callconv(.c) void {
    defer endFrame();
    if (beginFrame()) {
        dispatchDebugDraw(instrumentDraw, .{ count, instanceCount }, gl.DrawArraysInstancedBaseInstance, .{ mode, first, count, instanceCount, baseInstance });
    } else gl.DrawArraysInstancedBaseInstance(mode, first, count, instanceCount, baseInstance);
}

pub export fn glDrawTransformFeedback(mode: gl.@"enum", id: gl.uint) callconv(.c) void {
    defer endFrame();
    if (beginFrame()) {
        const query = state.getPtr(current.context).?.primitives_written_queries.items[0];
        // get GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN
        var primitiveCount: gl.int = undefined;
        gl.GetQueryObjectiv(query, gl.QUERY_RESULT, &primitiveCount);
        dispatchDebugDraw(instrumentDraw, .{ primitiveCount, 1 }, gl.DrawTransformFeedback, .{ mode, id });
    } else gl.DrawTransformFeedback(mode, id);
}

pub export fn glDrawTransformFeedbackInstanced(mode: gl.@"enum", id: gl.uint, instanceCount: gl.sizei) callconv(.c) void {
    defer endFrame();
    if (beginFrame()) {
        const query = state.getPtr(current.context).?.primitives_written_queries.items[0];
        // get GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN
        var primitiveCount: gl.int = undefined;
        gl.GetQueryObjectiv(query, gl.QUERY_RESULT, &primitiveCount);
        dispatchDebugDraw(instrumentDraw, .{ primitiveCount, instanceCount }, gl.DrawTransformFeedbackInstanced, .{ mode, id, instanceCount });
    } else gl.DrawTransformFeedbackInstanced(mode, id, instanceCount);
}

pub export fn glDrawTransformFeedbackStream(mode: gl.@"enum", id: gl.uint, stream: gl.uint) callconv(.c) void {
    defer endFrame();
    if (beginFrame()) {
        const query = state.getPtr(current.context).?.primitives_written_queries.items[stream];
        // get GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN
        var primitiveCount: gl.int = undefined;
        gl.GetQueryObjectiv(query, gl.QUERY_RESULT, &primitiveCount);
        dispatchDebugDraw(instrumentDraw, .{ primitiveCount, 1 }, gl.DrawTransformFeedbackStream, .{ mode, id, stream });
    } else gl.DrawTransformFeedbackStream(mode, id, stream);
}

pub export fn glDrawTransformFeedbackStreamInstanced(mode: gl.@"enum", id: gl.uint, stream: gl.uint, instanceCount: gl.sizei) callconv(.c) void {
    defer endFrame();
    if (beginFrame()) {
        const query = state.getPtr(current.context).?.primitives_written_queries.items[stream];
        // get GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN
        var primitiveCount: gl.int = undefined;
        gl.GetQueryObjectiv(query, gl.QUERY_RESULT, &primitiveCount);
        dispatchDebugDraw(instrumentDraw, .{ primitiveCount, instanceCount }, gl.DrawTransformFeedbackStreamInstanced, .{ mode, id, stream, instanceCount });
    } else gl.DrawTransformFeedbackStreamInstanced(mode, id, stream, instanceCount);
}
//#endregion

//
//#region Interface
//
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
pub export fn glShaderSource(shader: gl.uint, count: gl.sizei, sources: [*][*:0]const gl.char, lengths: ?[*]gl.int) callconv(.c) void {
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

/// Convenience function for wrapping function calls, catching errors and logging them
fn wrapErrorHandling(comptime function: anytype, _args: anytype) void {
    @call(.auto, function, _args) catch |err| {
        log.err("Error in {s}({}): {} {?}", .{ @typeName(@TypeOf(function)), _args, err, @errorReturnTrace() });
    };
}

fn defaultCompileShader(source: decls.SourcesPayload, instrumented: CString, length: i32) callconv(.c) u8 {
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
        if (length > 0) {
            log.debug("Shader {d} instrumented source: {s}", .{ shader, instrumented[0..@intCast(length)] });
        }
        for (0..source.count) |i| {
            const s = source.sources.?[i];
            log.debug("Shader {d} original source {d}: {s}", .{ shader, i, s[0..if (source.lengths) |l| l[i] else std.mem.len(s)] });
        }
        var success: gl.int = undefined;
        gl.GetShaderiv(shader, gl.COMPILE_STATUS, &success);
        if (success == 0) {
            log.err("Shader {d} compilation failed", .{shader});
            return 1;
        }
    }
    return 0;
}

fn defaultGetCurrentSource(ctx: ?*anyopaque, ref: usize, _: ?CString, _: usize) callconv(.c) ?CString {
    const service: *shaders = @alignCast(@ptrCast(ctx.?));
    const c_state = state.getPtr(@ptrCast(ctx.?)) orelse return null;

    if (waiter.request(.BorrowContext) != .ContextFree) {
        log.err("Could not borrow context from the drawing thead.", .{});
        return null;
    }
    const prev_context = switchContext(c_state.gl, service.context);

    const shader: gl.uint = @intCast(ref);
    var length: gl.sizei = undefined;
    // TODO bind the correct context
    gl.GetShaderiv(shader, gl.SHADER_SOURCE_LENGTH, &length);
    if (length == 0) {
        log.err("Shader {d} has no source", .{shader});
        return null;
    }
    const source: [*:0]gl.char = common.allocator.allocSentinel(gl.char, @intCast(length), 0) catch |err| {
        log.err("Failed to allocate memory for shader source: {any}", .{err});
        return null;
    };
    gl.GetShaderSource(shader, length, &length, source);

    setContext(c_state.gl, prev_context);
    waiter.eatingDone();
    return source;
}

/// If count is 0, the function will only link the program. Otherwise it will attach the shaders in the order they are stored in the payload.
fn defaultLink(self: decls.ProgramPayload) callconv(.c) u8 {
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
    const c_state = state.getPtr(current.context) orelse return;
    if (buffer == 0) { //un-bind
        c_state.indexed_buffer_bindings.put(buffer_type, 0);
    } else {
        const existing = c_state.indexed_buffer_bindings.get(buffer_type) orelse 0;
        c_state.indexed_buffer_bindings.put(buffer_type, existing | index);
    }
}

pub export fn glBindBufferBase(target: gl.@"enum", index: gl.uint, buffer: gl.uint) callconv(.c) void {
    gl.BindBufferBase(target, index, buffer);
    if (gl.GetError() == gl.NO_ERROR) {
        updateBufferIndexInfo(buffer, index, @enumFromInt(target));
    }
}

pub export fn glBindBufferRange(target: gl.@"enum", index: gl.uint, buffer: gl.uint, offset: gl.intptr, size: gl.sizeiptr) callconv(.c) void {
    gl.BindBufferRange(target, index, buffer, offset, size);
    if (gl.GetError() == gl.NO_ERROR) {
        updateBufferIndexInfo(buffer, index, @enumFromInt(target));
    }
}

pub export fn glCreateShader(stage: gl.@"enum") callconv(.c) gl.uint {
    const new_platform_source = gl.CreateShader(stage);

    const ref: shaders.Shader.StageRef = @enumFromInt(new_platform_source);
    if (current.Shaders.appendUntagged(ref)) |new| {
        new.stored.* = shaders.Shader.SourcePart.init(current.Shaders.allocator, decls.SourcesPayload{
            .ref = ref.toInt(),
            .stage = @enumFromInt(stage),
            .compile = defaultCompileShader,
            .currentSource = defaultGetCurrentSource,
            .context = current,
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

pub export fn glCreateShaderProgramv(stage: gl.@"enum", count: gl.sizei, sources: [*][*:0]const gl.char) callconv(.c) gl.uint {
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
        .currentSource = defaultGetCurrentSource,
        .language = decls.LanguageType.GLSL,
    }) catch |err| {
        log.warn("Failed to add shader source {x} cache: {any}", .{ new_platform_sources[0], err });
    };

    return new_platform_program;
}

/// Compile shaders with #include support
export fn glCompileShaderIncludeARB(shader: gl.uint, count: gl.sizei, paths: ?[*][*:0]const gl.char, lengths: ?[*:0]const gl.int) callconv(.c) void {
    gl.CompileShaderIncludeARB(shader, count, paths, lengths);
    if (gl.GetError() != gl.NO_ERROR) {
        return;
    }

    // Store the search paths for the shader
    wrapErrorHandling(actions.updateSearchPaths, .{ shader, count, paths, lengths });
}

export fn glCompileShader(shader: gl.uint) callconv(.c) void {
    gl.CompileShader(shader);
    if (gl.GetError() != gl.NO_ERROR) {
        return;
    }

    // Store the search paths for the shader
    wrapErrorHandling(actions.updateSearchPaths, .{ shader, 0, null, null });
}

pub export fn glCreateProgram() callconv(.c) gl.uint {
    const new_platform_program = gl.CreateProgram();
    current.programCreateUntagged(decls.ProgramPayload{
        .ref = @intCast(new_platform_program),
        .link = defaultLink,
        .context = current,
    }) catch |err| {
        log.warn("Failed to add program {x} to storage: {any}", .{ new_platform_program, err });
    };

    return new_platform_program;
}

pub export fn glAttachShader(program: gl.uint, shader: gl.uint) callconv(.c) void {
    current.programAttachSource(@enumFromInt(program), @enumFromInt(shader)) catch |err| {
        log.err("Failed to attach shader {x} to program {x}: {any}", .{ shader, program, err });
    };

    gl.AttachShader(program, shader);
}

pub export fn glDetachShader(program: gl.uint, shader: gl.uint) callconv(.c) void {
    current.programDetachSource(@enumFromInt(program), @enumFromInt(shader)) catch |err| {
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
pub export fn glObjectLabel(identifier: gl.@"enum", name: gl.uint, length: gl.sizei, label: ?CString) callconv(.c) void {
    if (label == null) {
        // Then the tag is meant to be removed.
        switch (identifier) {
            gl.PROGRAM => current.Programs.untagIndex(@enumFromInt(name), 0) catch |err| {
                log.warn("Failed to remove tag for program {x}: {any}", .{ name, err });
            },
            gl.SHADER => current.Shaders.untagAll(@enumFromInt(name)) catch |err| {
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
                        _ = current.Shaders.assignTag(@enumFromInt(name), index, tag.?, behavior) catch |err| errors.tag(label.?[0..real_length], name, index, err);
                    }
                } else {
                    _ = current.Shaders.assignTag(@enumFromInt(name), 0, label.?[0..real_length], .Error) catch |err| errors.tag(label.?[0..real_length], name, 0, err);
                }
            },
            gl.PROGRAM => _ = current.Programs.assignTag(@enumFromInt(name), 0, label.?[0..real_length], .Error) catch |err| errors.tag(label.?[0..real_length], name, 0, err),
            else => {}, // TODO support other objects?
        }
    }
    callIfLoaded("ObjectLabel", .{ identifier, name, length, label });
}

/// Set `size`, `identifier` and `name` to 0 to use this function for mapping physical paths to virtual paths.
/// Set `physical` to null to remove all mappings for that virtual path.
///
/// **NOTE**: the original signature is `glGetObjectLabel(identifier: @"enum", name: uint, bufSize: sizei, length: [*c]sizei, label: [*c]char)`
pub export fn glGetObjectLabel(_identifier: gl.@"enum", _name: gl.uint, _size: gl.sizei, virtual: CString, physical: CString) callconv(.c) void {
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

fn namedStringSourceAlloc(_: ?*anyopaque, _: usize, path: ?CString, length: usize) callconv(.c) ?CString {
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

fn freeNamedString(_: usize, _: ?*anyopaque, string: CString) callconv(.c) void {
    common.allocator.free(std.mem.span(string));
}

/// Named strings from ARB_shading_language_include can be used for labeling shader source files ("parts" in Deshader)
pub export fn glNamedStringARB(_type: gl.@"enum", _namelen: gl.int, _name: ?CString, _stringlen: gl.int, _string: ?CString) callconv(.c) void {
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
pub export fn glDebugMessageInsert(source: gl.@"enum", _type: gl.@"enum", id: gl.uint, severity: gl.@"enum", length: gl.sizei, buf: ?[*:0]const gl.char) callconv(.c) void {
    if (source == gl.DEBUG_SOURCE_APPLICATION and _type == gl.DEBUG_TYPE_OTHER and severity == gl.DEBUG_SEVERITY_HIGH) {
        switch (id) {
            ids.COMMAND_WORKSPACE_ADD => {
                if (buf != null) { //Add
                    const real_length = realLength(length, buf);
                    var it = std.mem.splitSequence(u8, buf.?[0..real_length], "<-");
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
                var it = std.mem.splitSequence(u8, buf.?[0..real_length], "<-");
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
fn callIfLoaded(comptime proc: String, a: anytype) VoidOrOptional(ReturnType(@field(gl, proc))) {
    const proc_proc = @field(gl, proc);
    const proc_ret = ReturnType(proc_proc);
    const target_args = @typeInfo(@TypeOf(proc_proc)).@"fn".params.len;
    const source_args = @typeInfo(@TypeOf(a)).@"struct".fields.len;
    if (target_args != source_args) {
        @compileError("Parameter count mismatch in callIfLoaded(\"" ++ proc ++ "\",...). Expected " ++ (@as(u8, @truncate(target_args)) + '0') ++ ", got " ++ (@as(u8, @truncate(source_args)) + '0'));
    }
    // would need @coercesTo
    // inline for (@typeInfo(@TypeOf(proc_proc)).@"fn".params, a, 0..) |dest, source, i| {
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
    return if (state.getPtr(current.context)) |s| @intFromPtr(@field(s.proc_table, proc)) != 0 else false;
}

fn VoidOrOptional(comptime t: type) type {
    return if (t == void) void else ?t;
}

fn voidOrNull(comptime t: type) if (t == void) void else null {
    if (t == void) {} else return null;
}

fn ReturnType(t: anytype) type {
    const t_type = @TypeOf(t);
    var fn_type = @typeInfo(if (t_type == type) t else t_type);
    switch (fn_type) {
        .pointer => |p| fn_type = @typeInfo(p.child),
        else => {},
    }
    return fn_type.@"fn".return_type.?;
}

const ids_array = blk: {
    const ids_decls = @typeInfo(ids).@"struct".decls;
    var command_count = 0;
    @setEvalBranchQuota(2000);
    for (ids_decls) |decl| {
        if (std.mem.startsWith(u8, decl.name, "COMMAND_")) {
            command_count += 1;
        }
    }
    var vals: [command_count]c_uint = undefined;
    var i = 0;
    @setEvalBranchQuota(5000);
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
pub export fn glBufferData(_target: gl.@"enum", _size: gl.sizeiptr, _data: ?*const anyopaque, _usage: gl.@"enum") callconv(.c) void {
    if (_target == 0) {
        @setEvalBranchQuota(5000);
        // Could be potentially a deshader command
        if (std.mem.indexOfScalar(c_uint, &ids_array, _usage) != null) {
            glDebugMessageInsert(gl.DEBUG_SOURCE_APPLICATION, gl.DEBUG_TYPE_OTHER, _usage, gl.DEBUG_SEVERITY_HIGH, @intCast(_size), @ptrCast(_data));
        }
    }
    gl.BufferData(_target, _size, _data, _usage);
}
//#endregion

//
//#region Context management
//

fn callConcatArgs(function: anytype, params: anytype, additional: anytype) ReturnType(@TypeOf(function)) {
    const ArgsT = std.meta.ArgsTuple(@typeInfo(@TypeOf(function)).pointer.child);
    var args_tuple: ArgsT = undefined;
    const params_len = std.meta.fields(@TypeOf(params)).len;
    const additional_len = std.meta.fields(@TypeOf(additional)).len;
    if (params_len + additional_len != std.meta.fields(ArgsT).len) {
        @compileError("The number of arguments does not match the function signature");
    }
    inline for (0..params_len + 1) |i| {
        if (i < params_len) {
            args_tuple[i] = params[i];
        } else {
            args_tuple[i] = additional[i - params_len];
        }
    }
    return @call(.auto, function, args_tuple);
}

fn callRestNull(function: anytype, params: anytype) ReturnType(@TypeOf(function)) {
    const ArgsT = std.meta.ArgsTuple(@typeInfo(@TypeOf(function)).pointer.child);
    var args_tuple: ArgsT = undefined;
    const params_len = std.meta.fields(@TypeOf(params)).len;
    inline for (0..std.meta.fields(ArgsT).len) |i| {
        if (i < params_len) {
            args_tuple[i] = params[i];
        } else {
            const t = @TypeOf(args_tuple[i]);
            switch (@typeInfo(t)) {
                .optional => {
                    args_tuple[i] = null;
                },
                .pointer => |p| {
                    if (p.is_allowzero) {
                        args_tuple[i] = null;
                    } else {
                        @compileError(std.fmt.comptimePrint("Argument {d} is {} and not allowzero.", .{ i, t }));
                    }
                },
                .int, .comptime_int => {
                    args_tuple[i] = 0;
                },
                else => {
                    @compileError(std.fmt.comptimePrint("Argument {d} is not nullable ({}).", .{ i, t }));
                },
            }
        }
    }
    return @call(.auto, function, args_tuple);
}

//TODO glSpecializeShader glShaderBinary
//TODO SGI context extensions
pub const context_procs = if (builtin.os.tag == .windows)
    struct {
        pub export fn wglMakeCurrent(hdc: *const anyopaque, context: ?*const anyopaque) c_int {
            const result = loaders.APIs.gl.wgl.make_current[0](hdc, context);
            wrapErrorHandling(makeCurrent, .{ loaders.APIs.gl.wgl, .{hdc}, context });
            return result;
        }

        pub export fn wglMakeContextCurrentARB(hReadDC: *const anyopaque, hDrawDC: *const anyopaque, hglrc: ?*const anyopaque) c_int {
            const result = loaders.APIs.gl.wgl.make_current[1](hReadDC, hDrawDC, hglrc);
            wrapErrorHandling(makeCurrent, .{ loaders.APIs.gl.wgl, .{hDrawDC}, hglrc });
            return result;
        }

        comptime { // also export as wglMakeContextCurrentEXT for compatibility
            @export(&wglMakeContextCurrentARB, .{ .name = "wglMakeContextCurrentEXT" });
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
            wrapErrorHandling(makeCurrent, .{ loaders.APIs.gl.glX, .{ display, drawable }, context });
            return result;
        }

        pub export fn glXMakeContextCurrent(display: *const anyopaque, read: c_ulong, write: c_ulong, context: ?*const anyopaque) c_int {
            const result = loaders.APIs.gl.glX.make_current[1](display, read, write, context);
            wrapErrorHandling(makeCurrent, .{ loaders.APIs.gl.glX, .{ display, write }, context });
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
            wrapErrorHandling(makeCurrent, .{ loaders.APIs.gl.egl, .{ display, read, write }, context });
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

noinline fn dumpProcTableErrors(c_state: *ContextState) void {
    var stderr = std.io.getStdErr();
    stderr.writeAll("\n") catch {};
    inline for (@typeInfo(gl.ProcTable).@"struct".fields) |decl| {
        const p = @field(c_state.proc_table, decl.name);
        if (@typeInfo(@TypeOf(p)) == .pointer) {
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

fn setContext(gl_backend_union: loaders.GlBackend, context: ?*const anyopaque) void {
    switch (gl_backend_union) {
        inline else => |params, backend| {
            const gl_backend = @field(loaders.APIs.gl, @tagName(backend));
            if (gl_backend.get_current != null) {
                if (context) |c|
                    _ = callConcatArgs(gl_backend.make_current[0], params, .{c})
                else
                    _ = callRestNull(gl_backend.make_current[0], firstOrEmpty(params));

                wrapErrorHandling(makeCurrent, .{ gl_backend, params, context });
            }
        },
    }
}

/// Switches the context to `ctx` and returns the previous context.
///
/// NOTE: Do not switch context when rendering is currently in progress. Use `drawing_mutex` to synchronize.
fn switchContext(gl_backend_union: loaders.GlBackend, ctx: *const anyopaque) ?*const anyopaque {
    switch (gl_backend_union) {
        inline else => |params, backend| {
            const gl_backend = @field(loaders.APIs.gl, @tagName(backend));
            const make_current = gl_backend.make_current[0];
            var prev_context: ?*const anyopaque = undefined;

            if (gl_backend.get_current) |get_current| {
                prev_context = get_current();
            }

            const success = callConcatArgs(make_current, params, .{ctx});
            wrapErrorHandling(makeCurrent, .{ gl_backend, params, ctx });

            if (success == 0) {
                log.err("Failed to switch context for {}", .{backend});
                return null;
            }
            return prev_context;
        },
    }
}

/// Performs context switching and initialization.
/// Initializes the internal procedure table, instrumentation frontend service, registers all instruments.
pub fn makeCurrent(comptime api: anytype, params: anytype, c: ?*const anyopaque) !void {
    if (c) |context| {
        current = try shaders.getOrAddService(@ptrCast(context), common.allocator);
        const result = try state.getOrPut(common.allocator, @ptrCast(context));
        const c_state = result.value_ptr;
        const gl_backend = @unionInit(loaders.GlBackend, api.name, params);
        if (result.found_existing) {
            gl.makeProcTableCurrent(&c_state.proc_table);
            c_state.gl = gl_backend;
        } else {
            // Initialize per-context variables
            c_state.* = .{
                .gl = gl_backend,
            };

            if (!api.late_loaded) {
                try loaders.loadGlLib();
                api.late_loaded = true;
            }
            // Late load all GL funcitions
            if (!c_state.proc_table.init(if (builtin.os.tag == .windows) struct {
                pub fn loader(name: CString) ?*const anyopaque {
                    return api.loader.?(name) orelse api.lib.?.lookup(*const anyopaque, std.mem.span(name));
                }
            }.loader else api.loader.?)) {
                log.err("Failed to load some GL functions.", .{});
                if (options.logInterception) @call(.never_inline, dumpProcTableErrors, .{c_state}) // Only do this if logging is enabled, because it adds a few megabytes to the binary size
                else log.debug("Build with -DlogInterception to show which ones.", .{});
            }

            gl.makeProcTableCurrent(&c_state.proc_table);

            log.debug("Initializing service {s} for context {x}", .{ current.name, @intFromPtr(context) });

            // Check for supported features of this context
            current.support = check: {
                if (gl.GetString(gl.EXTENSIONS)) |exs| {
                    var it = std.mem.splitScalar(u8, std.mem.span(exs), ' ');
                    log.debug("Supported GL_EXTENSIONS: {s}", .{exs});
                    break :check supportCheck(&it);
                } else {
                    // getString vs getStringi
                    const ExtensionInterator = struct {
                        num: gl.int,
                        i: gl.uint,

                        fn next(self: *@This()) ?String {
                            const ex = gl.GetStringi(gl.EXTENSIONS, self.i);
                            self.i += 1;
                            log.debug("Supported {?s}", .{ex});
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
                gl.GetIntegerv(gl.MAX_SHADER_STORAGE_BUFFER_BINDINGS, @ptrCast(&c_state.max_buffers));
                gl.GetIntegerv(gl.MAX_TRANSFORM_FEEDBACK_BUFFERS, (&c_state.max_xfb_buffers)[0..1]);
                gl.GetIntegerv(gl.MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS, (&c_state.max_xfb_interleaved_components)[0..1]);
                gl.GetIntegerv(gl.MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS, (&c_state.max_xfb_sep_attribs)[0..1]);
                gl.GetIntegerv(gl.MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS, (&c_state.max_xfb_sep_components)[0..1]);
                gl.GetIntegerv(gl.MAX_VERTEX_STREAMS, (&c_state.max_xfb_streams)[0..1]);
            }

            try contextInvalidatedEvent();
            try current.bus.addListener(null, &tagEvent);

            // Register all instruments
            // TODO specify Instrument external API
            var it = @constCast(&shaders.default_scoped_instruments).iterator();
            while (it.next()) |entry| {
                for (entry.value.*) |instr| {
                    try current.addInstrument(instr);
                }
            }
            for (default_instrument_clients) |instr| {
                try current.addInstrumentClient(instr);
            }
        }
    } else {
        gl.makeProcTableCurrent(null);
    }
}

fn contextInvalidatedEvent() !void {
    // Send a notification to debug adapter client
    if (commands.instance) |cl| {
        try cl.sendEvent(.invalidated, debug.InvalidatedEvent{ .areas = &.{.contexts}, .numContexts = shaders.servicesCount() });
    }
}

fn deleteContext(c: *const anyopaque, api: anytype, arg: anytype) bool {
    if (shaders.getService(@ptrCast(c))) |s| {
        log.info("Deleting context {x} with service {s}", .{ @intFromPtr(c), s.name });
        if (state.getPtr(s.context)) |c_state| c_state.deinit();
        std.debug.assert(state.remove(s.context));
        std.debug.assert(shaders.removeService(@ptrCast(c)));
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
//#endregion

pub const default_instrument_clients = blk: {
    var count = 0;
    const i_decls = std.meta.declarations(gl_instruments);
    for (i_decls) |decl| {
        const instr_def = @field(gl_instruments, decl.name);
        if ((@typeInfo(@TypeOf(instr_def)) != .@"struct")) {
            //probabaly not an instrument definition
            continue;
        }
        count += 1;
    }
    var instrs: [count]instr_decls.InstrumentClient = undefined;
    for (i_decls, 0..) |decl, i| {
        const instr_def = @field(gl_instruments, decl.name);
        if ((@typeInfo(@TypeOf(instr_def)) != .@"struct")) {
            //probabaly not an instrument definition
            continue;
        }
        const instr = instr_decls.InstrumentClient{
            .init = if (@hasField(instr_def, "init")) &instr_def.init else null,
            .deinit = if (@hasField(instr_def, "deinit")) &instr_def.deinit else null,
            .onBeforeDraw = if (@hasField(instr_def, "onBeforeDraw")) &instr_def.onBeforeDraw else null,
            .onResult = if (@hasField(instr_def, "onResult")) &instr_def.onResult else null,
            .onRestore = if (@hasField(instr_def, "onRestore")) &instr_def.onRestore else null,
        };
        instrs[i] = instr;
    }
    break :blk instrs;
};
