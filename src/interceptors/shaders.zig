const std = @import("std");
const builtin = @import("builtin");
const gl = @import("gl");
const decls = @import("../declarations/shaders.zig");
const shaders = @import("../services/shaders.zig");
const log = @import("../log.zig").DeshaderLog;
const common = @import("../common.zig");
const args = @import("args");
const main = @import("../main.zig");
const ids = @cImport(@cInclude("commands.h"));

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
        .language = decls.LanguageType.GLSL,
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
        .language = decls.LanguageType.GLSL,
    }) catch |err| {
        log.warn("Failed to add shader source {x} cache: {any}", .{ new_platform_sources[0], err });
    };

    return new_platform_program;
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
    shaders.sourceReplaceUntagged(decls.SourcesPayload{
        .ref = @intCast(shader),
        .count = @intCast(count),
        .sources = sources,
        .lengths = lengths_wide,
        .language = decls.LanguageType.GLSL,
    }) catch |err| {
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
                    const arg_iter = ArgsIterator{ .s = line, .i = pragma_found + pragma_text.len };
                    if (args.parseWithVerb(
                        struct {},
                        union(enum) {
                            breakpoint: void,
                            workspace: void,
                            @"workspace-overwrite": void,
                            source: void,
                            @"source-link": void,
                            @"source-purge-previous": void,
                        },
                        @constCast(&arg_iter),
                        common.allocator,
                        .print,
                    )) |options| {
                        defer options.deinit();
                        if (options.verb) |v| {
                            switch (v) {
                                // Workspace include
                                .workspace => {
                                    shaders.addWorkspacePath(options.positionals[0], options.positionals[1]) catch |err| failedWorkspacePath(options.positionals[0], err);
                                },
                                .@"workspace-overwrite" => {
                                    if (shaders.workspace_paths.getPtr(options.positionals[0])) |w_paths| {
                                        w_paths.clearAndFree();
                                    }
                                    shaders.addWorkspacePath(options.positionals[0], options.positionals[1]) catch |err| failedWorkspacePath(options.positionals[0], err);
                                },
                                .source => {
                                    shaders.Shaders.assignTag(@intCast(shader), source_i, options.positionals[0], .Error) catch |err| objLabErr(options.positionals[0], shader, source_i, err);
                                },
                                .@"source-link" => {
                                    shaders.Shaders.assignTag(@intCast(shader), source_i, options.positionals[0], .Link) catch |err| objLabErr(options.positionals[0], shader, source_i, err);
                                },
                                .@"source-purge-previous" => {
                                    shaders.Shaders.assignTag(@intCast(shader), source_i, options.positionals[0], .PurgePrevious) catch |err| objLabErr(options.positionals[0], shader, source_i, err);
                                },
                                .breakpoint => {
                                    if (shaders.Shaders.all.get(@intCast(shader))) |stored| {
                                        if (stored.items.len > source_i) {
                                            if (stored.items[source_i].breakpoints.append(.{ line_i, 0 })) {
                                                log.debug("Shader {d} source {d}: breakpoint at line {d}", .{ shader, source_i, line_i });
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
                } else {
                    log.debug("Ignoring pragma in shader source: {s}, because is at {d} and comment at {d}, block: {any}", .{ line, pragma_found, comment_found, in_block_comment });
                }
            }
        }
    }
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
            gl.PROGRAM => shaders.Programs.removeTagForIndex(name, 0) catch |err| {
                log.warn("Failed to remove tag for program {x}: {any}", .{ name, err });
            },
            gl.SHADER => shaders.Shaders.removeAllTags(name) catch |err| {
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
                                behavior = .PurgePrevious;
                            },
                            else => {},
                        }
                        const index = std.fmt.parseUnsigned(usize, first, 10) catch std.math.maxInt(usize);
                        const tag = it2.next();
                        if (tag == null or index == std.math.maxInt(usize)) {
                            log.err("Failed to parse tag {s} for shader {x}", .{ current, name });
                            continue;
                        }
                        shaders.Shaders.assignTag(@intCast(name), index, tag.?, behavior) catch |err| objLabErr(label.?[0..real_length], name, index, err);
                    }
                } else {
                    shaders.Shaders.assignTag(@intCast(name), 0, label.?[0..real_length], .Error) catch |err| objLabErr(label.?[0..real_length], name, 0, err);
                }
            },
            gl.PROGRAM => shaders.Programs.assignTag(@intCast(name), 0, label.?[0..real_length], .Error) catch |err| objLabErr(label.?[0..real_length], name, 0, err),
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
                            shaders.addWorkspacePath(real_path, virtual_path) catch |err| failedWorkspacePath(buf.?[0..real_length], err);
                        } else failedWorkspacePath(buf.?[0..real_length], error.@"No virtual path specified");
                    } else failedWorkspacePath(buf.?[0..real_length], error.@"No real path specified");
                }
            },
            ids.COMMAND_WORKSPACE_REMOVE => if (buf == null) { //Remove all
                shaders.workspace_paths.clearRetainingCapacity();
            } else { //Remove
                const real_length = realLength(length, buf);
                var it = std.mem.split(u8, buf.?[0..real_length], "<-");
                if (it.next()) |real_path| {
                    if (it.next()) |virtual_path| {
                        if (shaders.workspace_paths.getPtr(real_path)) |w_paths| {
                            if (!w_paths.remove(virtual_path)) {
                                failedRemoveWorkspacePath(buf.?[0..real_length], error.@"No such virtual path in workspace");
                            }
                        }
                    } else {
                        if (!shaders.workspace_paths.remove(real_path)) {
                            failedRemoveWorkspacePath(buf.?[0..real_length], error.@"No such real path in workspace");
                        }
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
