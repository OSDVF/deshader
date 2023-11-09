const std = @import("std");
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
        log.warn("Failed to add shader source {x} to virtual filesystem: {any}", .{ new_platform_source, err });
    };

    return new_platform_source;
}

pub export fn glCreateProgram() gl.GLuint {
    const new_platform_program = gl.createProgram();
    shaders.Programs.putUntagged(decls.ProgramPayload{
        .ref = @intCast(new_platform_program),
        .link = defaultLink,
    }, false) catch |err| {
        log.warn("Failed to add program {x} to virtual filesystem: {any}", .{ new_platform_program, err });
    };

    return new_platform_program;
}

pub export fn glAttachShader(program: gl.GLuint, shader: gl.GLuint) void {
    shaders.programAttachSource(@intCast(program), @intCast(shader)) catch |err| {
        log.err("Failed to attach shader {x} to program {x}: {any}", .{ shader, program, err });
    };

    gl.attachShader(program, shader);
}
