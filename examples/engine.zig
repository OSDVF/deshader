const std = @import("std");
const gl = @import("gl");
const glfw = @import("zig_glfw");
pub const log = std.log.scoped(.Engine);

const gl_stack_trace = false;
const gl_severity: Severity = .low;
const Severity = enum(usize) {
    notification = 0,
    low = 1,
    medium = 2,
    high = 3,
};

/// Default GLFW error handling callback
pub fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    log.err("quad: {}: {s}\n", .{ error_code, description });
}

pub fn createShader(source: []const u8, typ: gl.@"enum") c_uint {
    const shader = gl.CreateShader(typ);
    gl.ShaderSource(shader, 1, @ptrCast(&source.ptr), @ptrCast(&source.len));
    gl.CompileShader(shader);

    var status: gl.int = undefined;
    gl.GetShaderiv(shader, gl.COMPILE_STATUS, &status);

    var info_length: gl.sizei = undefined;
    gl.GetShaderiv(shader, gl.INFO_LOG_LENGTH, &info_length);
    if (std.heap.page_allocator.allocSentinel(u8, @intCast(info_length), 0)) |info_log| {
        defer std.heap.page_allocator.free(info_log);
        gl.GetShaderInfoLog(shader, info_length, &info_length, info_log.ptr);
        if (info_length > 0) {
            if (status == gl.FALSE) {
                log.err("shader compilation failed: {s}", .{info_log});
            } else {
                log.info("shader compilation: {s}", .{info_log});
            }
        }
    } else |err| {
        log.err("failed to allocate memory for shader info log: {}", .{err});
        return 0;
    }
    if (status == gl.FALSE) {
        gl.DeleteShader(shader);
        return 0;
    }
    return shader;
}

pub fn linkProgram(program: gl.uint) void {
    gl.LinkProgram(program);

    var status: gl.int = undefined;
    gl.GetProgramiv(program, gl.LINK_STATUS, &status);

    var info_length: gl.sizei = undefined;
    gl.GetProgramiv(program, gl.INFO_LOG_LENGTH, &info_length);
    if (std.heap.page_allocator.allocSentinel(u8, @intCast(info_length), 0)) |info_log| {
        defer std.heap.page_allocator.free(info_log);
        gl.GetProgramInfoLog(program, info_length, &info_length, info_log.ptr);
        if (info_length > 0) {
            if (status == gl.FALSE) {
                log.err("program link failed: {s}", .{info_log});
            } else {
                log.info("program link: {s}", .{info_log});
            }
        }
    } else |err| {
        log.err("failed to allocate memory for program info log: {}", .{err});
    }

    if (status == gl.FALSE) {
        log.err("program link failed", .{});
        gl.DeleteProgram(program);
    }
}

pub fn glDebugMessageCallback(source: gl.@"enum", typ: gl.@"enum", id: gl.uint, severity: gl.@"enum", length: gl.sizei, message: [*:0]const gl.char, userParam: ?*const anyopaque) callconv(gl.APIENTRY) void {
    _ = userParam;
    _ = length;
    const source_string = switch (source) {
        gl.DEBUG_SOURCE_API => "API",
        gl.DEBUG_SOURCE_WINDOW_SYSTEM => "Window System",
        gl.DEBUG_SOURCE_SHADER_COMPILER => "Shader Compiler",
        gl.DEBUG_SOURCE_THIRD_PARTY => "Third Party",
        gl.DEBUG_SOURCE_APPLICATION => "Application",
        gl.DEBUG_SOURCE_OTHER => "Other",
        else => unreachable,
    };
    const typ_string = switch (typ) {
        gl.DEBUG_TYPE_ERROR => "Error",
        gl.DEBUG_TYPE_DEPRECATED_BEHAVIOR => "Deprecated Behavior",
        gl.DEBUG_TYPE_UNDEFINED_BEHAVIOR => "Undefined Behavior",
        gl.DEBUG_TYPE_PORTABILITY => "Portability",
        gl.DEBUG_TYPE_PERFORMANCE => "Performance",
        gl.DEBUG_TYPE_MARKER => "Marker",
        gl.DEBUG_TYPE_PUSH_GROUP => "Push Group",
        gl.DEBUG_TYPE_POP_GROUP => "Pop Group",
        gl.DEBUG_TYPE_OTHER => "Other",
        else => unreachable,
    };
    const severity_string = switch (severity) {
        gl.DEBUG_SEVERITY_HIGH => "High",
        gl.DEBUG_SEVERITY_MEDIUM => if (@intFromEnum(Severity.medium) >= @intFromEnum(gl_severity)) "Medium" else return,
        gl.DEBUG_SEVERITY_LOW => if (@intFromEnum(Severity.low) >= @intFromEnum(gl_severity)) "Low" else return,
        gl.DEBUG_SEVERITY_NOTIFICATION => if (@intFromEnum(Severity.notification) >= @intFromEnum(gl_severity)) "Notification" else return,
        else => unreachable,
    };
    log.debug("{d}: {s} {s} {s} {s}\n", .{ id, source_string, typ_string, severity_string, message }); // TODO use debug build of OpenGL
    if (gl_stack_trace) {
        std.debug.dumpCurrentStackTrace(null);
    }
}
