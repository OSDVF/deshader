const std = @import("std");
const builtin = @import("builtin");
const gl = @import("gl");
const decls = @import("../declarations/shaders.zig");
const shaders = @import("../services/shaders.zig");
const log = @import("../log.zig").DeshaderLog;
const common = @import("../common.zig");

const CString = [*:0]const u8;
const String = []const u8;

fn defaultCompileShader(source: decls.SourcesPayload) callconv(.C) u8 {
    const shader: gl.GLuint = @intCast(source.ref);
    gl.shaderSource(shader, @intCast(source.count), source.sources, null);
    gl.compileShader(shader);

    var info_length: gl.GLsizei = undefined;
    var info_log: [*:0]gl.GLchar = undefined;
    gl.getShaderInfoLog(shader, 0, &info_length, info_log);
    if (info_length > 0) {
        var paths: ?String = null;
        if (source.count > 0 and source.paths != null) {
            if (common.joinInnerZ(common.allocator, "; ", source.paths.?[0..source.count])) |joined| {
                paths = joined;
            } else |err| {
                log.warn("Failed to join shader paths: {any}", .{err});
            }
        }
        log.err("shader {d}{?s} compilation failed:\n{s}", .{ shader, paths, info_log });
        gl.deleteShader(shader);
        return 1;
    }
    return 0;
}

fn defaultLink(ref: usize, path: ?CString, sources: [*]decls.SourcesPayload, count: usize, context: ?*const anyopaque) callconv(.C) u8 {
    _ = context;
    const program: gl.GLuint = @intCast(ref);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        gl.attachShader(program, @intCast(sources[i].ref));
    }
    gl.linkProgram(program);

    var info_length: gl.GLsizei = undefined;
    var info_log: [*:0]gl.GLchar = undefined;
    gl.getProgramInfoLog(program, 0, &info_length, info_log);
    if (info_length > 0) {
        log.err("program {d}:{?s} linking failed: {s}", .{ program, path, info_log });
        gl.deleteProgram(program);
        return 1;
    }
    return 0;
}

pub export fn glCreateShader(shaderType: gl.GLenum) gl.GLuint {
    const new_platform_source = gl.createShader(shaderType);

    shaders.Sources.putUntagged(decls.SourcesPayload{
        .ref = @intCast(new_platform_source),
        .type = @enumFromInt(shaderType),
        .compile = defaultCompileShader,
    }, false) catch |err| {
        log.warn("Failed to add shader source {x} cache: {any}", .{ new_platform_source, err });
    };

    return new_platform_source;
}

pub export fn glCreateShaderProgramv(shaderType: gl.GLenum, count: gl.GLsizei, sources: [*][*:0]const gl.GLchar) gl.GLuint {
    const source_type: decls.SourceType = @enumFromInt(shaderType);
    const new_platform_program = gl.createShaderProgramv(shaderType, count, sources);
    var new_platform_sources = common.allocator.alloc(gl.GLuint, @intCast(count)) catch |err| {
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

    shaders.Sources.putUntagged(decls.SourcesPayload{
        .ref = @intCast(new_platform_sources[0]),
        .type = source_type,
        .count = @intCast(count),
        .sources = sources,
        .lengths = lengths.ptr,
        .compile = defaultCompileShader,
    }, false) catch |err| {
        log.warn("Failed to add shader source {x} cache: {any}", .{ new_platform_sources[0], err });
    };

    shaders.Programs.putUntagged(decls.ProgramPayload{ .ref = @intCast(new_platform_program), .link = defaultLink, .program = decls.PipelinePayload{ .type = decls.SourceTypeToPipeline.map(source_type), .pipeline = switch (source_type) {
        .gl_compute, .vk_compute => .{ .Compute = .{ .compute = new_platform_sources[0] } },
        .gl_vertex, .vk_vertex => .{ .Rasterize = .{ .vertex = new_platform_sources[0], .fragment = 0 } },
        .gl_fragment, .vk_fragment => .{ .Rasterize = .{ .fragment = new_platform_sources[0], .vertex = 0 } },
        .gl_geometry, .vk_geometry => .{ .Rasterize = .{ .geometry = new_platform_sources[0], .vertex = 0, .fragment = 0 } },
        .gl_tess_control, .vk_tess_control => .{ .Rasterize = .{ .tess_control = new_platform_sources[0], .vertex = 0, .fragment = 0 } },
        .gl_tess_evaluation, .vk_tess_evaluation => .{ .Rasterize = .{ .tess_evaluation = new_platform_sources[0], .vertex = 0, .fragment = 0 } },
        .vk_raygen => .{ .Ray = .{ .raygen = new_platform_sources[0], .closesthit = 0, .miss = 0 } },
        .vk_anyhit => .{ .Ray = .{ .anyhit = new_platform_sources[0], .raygen = 0, .closesthit = 0, .miss = 0 } },
        .vk_closesthit => .{ .Ray = .{ .closesthit = new_platform_sources[0], .raygen = 0, .miss = 0 } },
        .vk_miss => .{ .Ray = .{ .miss = new_platform_sources[0], .raygen = 0, .closesthit = 0 } },
        .vk_intersection => .{ .Ray = .{ .intersection = new_platform_sources[0], .raygen = 0, .closesthit = 0, .miss = 0 } },
        .vk_callable => .{ .Ray = .{ .callable = new_platform_sources[0], .raygen = 0, .miss = 0, .closesthit = 0 } },
        else => unreachable,
    } } }, false) catch |err| {
        log.warn("Failed to add program {x} cache: {any}", .{ new_platform_program, err });
    };

    return new_platform_program;
}

pub export fn glShaderSource(shader: gl.GLuint, count: gl.GLsizei, sources: [*][*:0]const gl.GLchar, lengths: ?[*]gl.GLint) void {
    var new_lengths: ?[*]usize = if (lengths != null) (common.allocator.alloc(usize, @intCast(count)) catch |err| {
        log.err("Failed to allocate memory for shader sources lengths: {any}", .{err});
        return;
    }).ptr else null;
    if (lengths != null) {
        const ucount: usize = @intCast(count);
        for (lengths.?[0..ucount], new_lengths.?[0..ucount]) |len, *target| {
            target.* = @intCast(len);
        }
    }
    shaders.Sources.putUntagged(decls.SourcesPayload{
        .ref = @intCast(shader),
        .count = @intCast(count),
        .sources = sources,
        .lengths = new_lengths,
    }, true) catch |err| {
        log.warn("Failed to add shader source {x} cache: {any}", .{ shader, err });
    };
    gl.shaderSource(shader, count, sources, lengths);
}

pub export fn glCreateProgram() gl.GLuint {
    const new_platform_program = gl.createProgram();
    shaders.Programs.putUntagged(decls.ProgramPayload{
        .ref = @intCast(new_platform_program),
        .link = defaultLink,
    }, false) catch |err| {
        log.warn("Failed to add program {x} cache: {any}", .{ new_platform_program, err });
    };

    return new_platform_program;
}

pub export fn glAttachShader(program: gl.GLuint, shader: gl.GLuint) void {
    shaders.programAttachSource(@intCast(program), @intCast(shader)) catch |err| {
        log.err("Failed to attach shader {x} to program {x}: {any}", .{ shader, program, err });
    };

    gl.attachShader(program, shader);
}
