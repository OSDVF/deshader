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
    const info_log: [*:0]gl.GLchar = undefined;
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
    const info_log: [*:0]gl.GLchar = undefined;
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

    const stored = shaders.Shader.MemorySource.fromPayload(shaders.Shaders.allocator, decls.SourcesPayload{
        .ref = @intCast(new_platform_source),
        .type = @enumFromInt(shaderType),
        .compile = defaultCompileShader,
        .count = 1,
    }, 0) catch |err| {
        log.warn("Failed to add shader source {x} cache because of alocation: {any}", .{ new_platform_source, err });
        return new_platform_source;
    };
    shaders.Shaders.appendUntagged(stored.super) catch |err| {
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

fn objLabErr(label: String, name: gl.GLuint, index: usize, err: anytype) void {
    log.err("Failed to assign tag {s} for {d} index {d}: {any}", .{ label, name, index, err });
}

/// Label expressed as 0:include.glsl;1:program.frag
/// 0 is index of shader source part
/// include.glsl is tag for shader source part
/// Tags for program parts are separated by ;
///
/// To link shader source part to physical file use
/// l:path/to/file.glsl
/// the path is relative to workspace root. Use glDebugMessageInsert to set workspace root
pub export fn glObjectLabel(identifier: gl.GLenum, name: gl.GLuint, length: gl.GLsizei, label: ?CString) void {
    if (label == null) {
        // Then the tag is meant to be removed.
        switch (identifier) {
            gl.PROGRAM => shaders.Programs.removeTagForIndex(name, 0) catch |err| {
                log.warn("Failed to remove tag for program {x}: {any}", .{ name, err });
            },
            gl.SHADER => shaders.Shaders.removeAllTags(name) catch |err| {
                log.warn("Failed to remove all tags for shader {x}: {any}", .{ name, err });
            },
            else => {}, // TODO support other objects?
        }
    } else {
        var real_length: usize = undefined;
        if (length < 0) {
            // Then label is null-terminated and length is ignored.
            real_length = std.mem.len(label.?);
        } else {
            real_length = @intCast(length);
        }
        switch (identifier) {
            gl.SHADER => {
                if (std.mem.indexOfScalar(u8, label.?[0..128], ':') != null) {
                    var it = std.mem.splitScalar(u8, label.?[0..real_length], ';');
                    while (it.next()) |current| {
                        var it2 = std.mem.splitScalar(u8, current, ':');
                        const index = std.fmt.parseUnsigned(usize, it2.first(), 10) catch std.math.maxInt(usize);
                        const tag = it2.next();
                        if (tag == null or index == std.math.maxInt(usize)) {
                            log.err("Failed to parse tag {s} for shader {x}", .{ current, name });
                            continue;
                        }
                        shaders.Shaders.assignTag(@intCast(name), index, tag.?, .Overwrite) catch |err| objLabErr(label.?[0..real_length], name, index, err);
                        //TODO specify if-exists
                    }
                } else {
                    shaders.Shaders.assignTag(@intCast(name), 0, label.?[0..real_length], .Overwrite) catch |err| objLabErr(label.?[0..real_length], name, 0, err);
                }
            },
            gl.PROGRAM => shaders.Programs.assignTag(@intCast(name), 0, label.?[0..real_length], .Overwrite) catch |err| objLabErr(label.?[0..real_length], name, 0, err),
            else => {}, // TODO support other objects?
        }
    }
}

/// use glDebugMessageInsert with these parameters to set workspace root
/// source = GL_DEBUG_SOURCE_OTHER
/// type = DEBUG_TYPE_OTHER
/// id = 0
pub export fn glDebugMessageInsert(source: gl.GLenum, _type: gl.GLenum, id: gl.GLuint, severity: gl.GLenum, length: gl.GLsizei, buf: [*c]const gl.GLchar) void {
    _ = severity;
    _ = length;
    _ = buf;

    if (source == gl.DEBUG_SOURCE_OTHER and _type == gl.DEBUG_TYPE_OTHER) {
        switch (id) {
            0 => {},
            else => {},
        }
    }
}
