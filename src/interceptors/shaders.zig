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

    shaders.Shaders.appendUntagged(shaders.Shader.Source{
        .ref = @intCast(new_platform_source),
        .type = @enumFromInt(shaderType),
        .compile = defaultCompileShader,
    }) catch |err| {
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

    shaders.sourcesCreateUntagged(decls.SourcesPayload{
        .ref = @intCast(new_platform_sources[0]),
        .type = source_type,
        .count = @intCast(count),
        .sources = sources,
        .lengths = lengths.ptr,
        .compile = defaultCompileShader,
    }) catch |err| {
        log.warn("Failed to add shader source {x} cache: {any}", .{ new_platform_sources[0], err });
    };

    return new_platform_program;
}

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
    shaders.sourceReplaceUntagged(decls.SourcesPayload{
        .ref = @intCast(shader),
        .count = @intCast(count),
        .sources = sources,
        .lengths = lengths_wide,
    }) catch |err| {
        log.warn("Failed to add shader source {x} cache: {any}", .{ shader, err });
    };
    gl.shaderSource(shader, count, sources, lengths);
}

pub export fn glCreateProgram() gl.GLuint {
    const new_platform_program = gl.createProgram();
    shaders.Programs.appendUntagged(shaders.Shader.Program{
        .ref = @intCast(new_platform_program),
        .link = defaultLink,
    }) catch |err| {
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
