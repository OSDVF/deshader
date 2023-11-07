const std = @import("std");
const glfw = @import("mach-glfw");
const gl = @import("gl");

const log = std.log.scoped(.Engine);

fn glGetProcAddress(p: glfw.GLProc, proc: [:0]const u8) ?gl.FunctionPointer {
    _ = p;
    return glfw.getProcAddress(proc);
}

/// Default GLFW error handling callback
fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    log.err("glfw: {}: {s}\n", .{ error_code, description });
}

const vertex_source = @embedFile("vertex.vert");
const fragment_source = @embedFile("fragment.frag");

const vertex_data = [_]f32{
    -1, -1, //
    1, -1, //
    -1, 1, //
    1,  1,
};

pub fn createShader(source: []const u8, typ: gl.GLenum) c_uint {
    const shader = gl.createShader(typ);
    gl.shaderSource(shader, 1, &@ptrCast(@alignCast(source)), @ptrCast(&source.len));
    gl.compileShader(shader);

    var info_length: gl.GLsizei = undefined;
    var info_log: [*:0]gl.GLchar = undefined;
    gl.getShaderInfoLog(shader, 0, &info_length, info_log);
    if (info_length > 0) {
        log.err("shader compilation failed: {s}", .{info_log});
        gl.deleteShader(shader);
        return 0;
    }
    return shader;
}

pub fn onResize(window: glfw.Window, width: u32, height: u32) void {
    _ = window;
    const w: gl.GLint = @intCast(width);
    const h: gl.GLint = @intCast(height);
    gl.viewport(0, 0, w * 2, h * 2);
}

pub fn glDebugMessageCallback(source: gl.GLenum, typ: gl.GLenum, id: gl.GLuint, severity: gl.GLenum, length: gl.GLsizei, message: [*:0]const gl.GLchar, userParam: ?*anyopaque) callconv(.C) void {
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
        gl.DEBUG_SEVERITY_MEDIUM => "Medium",
        gl.DEBUG_SEVERITY_LOW => "Low",
        gl.DEBUG_SEVERITY_NOTIFICATION => "Notification",
        else => unreachable,
    };
    log.debug("{d}: {s} {s} {s} {s}\n", .{ id, source_string, typ_string, severity_string, message });
}

pub fn main() !void {
    log.info("Showing a window with GLFW and OpenGL", .{});
    // Initialize GLFW
    glfw.setErrorCallback(errorCallback);
    if (!glfw.init(.{})) {
        log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    // Create our window
    const window = glfw.Window.create(640, 480, "mach-glfw + zig-opengl", null, null, .{ .opengl_profile = .opengl_core_profile, .context_version_major = 4, .context_version_minor = 0, .context_debug = true }) orelse {
        log.err("failed to create GLFW window: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    };
    defer window.destroy();

    glfw.makeContextCurrent(window);

    const proc: glfw.GLProc = undefined;
    try gl.load(proc, glGetProcAddress);

    gl.debugMessageCallback(glDebugMessageCallback, null);

    window.setFramebufferSizeCallback(onResize);
    const initial_size = window.getFramebufferSize();
    onResize(window, initial_size.width, initial_size.height);

    const program = gl.createProgram();
    defer gl.deleteProgram(program);
    const vertex = createShader(vertex_source, gl.VERTEX_SHADER);
    defer gl.deleteShader(vertex);
    const fragment = createShader(fragment_source, gl.FRAGMENT_SHADER);
    defer gl.deleteShader(fragment);
    gl.attachShader(program, vertex);
    gl.attachShader(program, fragment);
    gl.linkProgram(program);
    var info_length: gl.GLsizei = undefined;
    var info_log: [*:0]gl.GLchar = undefined;
    gl.getProgramInfoLog(program, 0, &info_length, info_log);
    if (info_length > 0) {
        log.err("program linking failed: {s}", .{info_log});
        gl.deleteProgram(program);
        return;
    }

    var vertex_buffer: gl.GLuint = undefined;
    gl.createBuffers(1, &vertex_buffer);
    defer gl.deleteBuffers(1, &vertex_buffer);
    gl.namedBufferData(vertex_buffer, vertex_data.len * @sizeOf(f32), &vertex_data, gl.STATIC_DRAW);

    var vao: gl.GLuint = undefined;
    gl.createVertexArrays(1, &vao);
    defer gl.deleteVertexArrays(1, &vao);
    gl.bindVertexArray(vao);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 0, null);
    gl.vertexArrayVertexBuffer(vao, 0, vertex_buffer, 0, 2 * @sizeOf(f32));

    gl.disable(gl.CULL_FACE);

    // Wait for the user to close the window.
    while (!window.shouldClose()) {
        glfw.pollEvents();

        gl.clearColor(1, 0, 1, 1);
        gl.clear(gl.COLOR_BUFFER_BIT);
        gl.useProgram(program);
        gl.bindVertexArray(vao);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);

        window.swapBuffers();
    }
}
