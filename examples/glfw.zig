const std = @import("std");
const glfw = @import("zig_glfw");
const gl = @import("gl");
const c = @cImport(@cInclude("GLFW/glfw3.h"));

const log = std.log.scoped(.Engine);
const gl_stack_trace = false;
const gl_severity: Severity = .low;
const Severity = enum(usize) {
    notification = 0,
    low = 1,
    medium = 2,
    high = 3,
};

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

pub fn createShader(source: []const u8, typ: gl.@"enum") c_uint {
    const shader = gl.CreateShader(typ);
    gl.ShaderSource(shader, 1, @ptrCast(&source.ptr), @ptrCast(&source.len));
    gl.CompileShader(shader);

    var info_length: gl.sizei = undefined;
    gl.GetShaderiv(shader, gl.INFO_LOG_LENGTH, &info_length);
    if (std.heap.page_allocator.allocSentinel(u8, @intCast(info_length), 0)) |info_log| {
        defer std.heap.page_allocator.free(info_log);
        gl.GetShaderInfoLog(shader, info_length, &info_length, info_log.ptr);
        if (info_length > 0) {
            log.err("shader compilation failed: {s}", .{info_log});
            gl.DeleteShader(shader);
            return 0;
        }
        return shader;
    } else |err| {
        log.err("failed to allocate memory for shader info log: {}", .{err});
        return 0;
    }
}

pub fn linkProgram(program: gl.uint) void {
    gl.LinkProgram(program);

    var info_length: gl.sizei = undefined;
    gl.GetProgramiv(program, gl.INFO_LOG_LENGTH, &info_length);
    if (std.heap.page_allocator.allocSentinel(u8, @intCast(info_length), 0)) |info_log| {
        defer std.heap.page_allocator.free(info_log);
        gl.GetProgramInfoLog(program, info_length, &info_length, info_log.ptr);
        if (info_length > 0) {
            log.err("program link failed: {s}", .{info_log});
            gl.DeleteShader(program);
        }
    } else |err| {
        log.err("failed to allocate memory for program info log: {}", .{err});
    }
}

pub fn onResize(window: glfw.Window, width: u32, height: u32) void {
    _ = window;
    const w: gl.int = @intCast(width);
    const h: gl.int = @intCast(height);
    gl.Viewport(0, 0, w * 2, h * 2);
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

// Procedure table that will hold OpenGL functions loaded at runtime.
var procs: gl.ProcTable = undefined;
fn createWindow() ?glfw.Window {
    return glfw.Window.create(640, 480, "zig-glfw + zig-opengl", null, null, .{
        .opengl_profile = .opengl_core_profile,
        .context_version_major = 4,
        .context_version_minor = 1,
        .context_debug = true,
    });
}

pub fn main() !void {
    const env = try std.process.getEnvMap(std.heap.page_allocator);
    const powerSave = try std.fmt.parseInt(usize, env.get("POWER_SAVE") orelse "0", 0);
    log.info("Showing a window with GLFW and OpenGL", .{});
    // Initialize GLFW
    glfw.setErrorCallback(errorCallback);
    if (!glfw.init(.{})) {
        log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    // Create our window
    const window = createWindow() orelse soft: {
        c.glfwWindowHint(c.GLFW_CONTEXT_RENDERER, c.GLFW_SOFTWARE_RENDERER);
        break :soft createWindow();
    } orelse {
        log.err("failed to create GLFW window: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    };
    defer window.destroy();

    glfw.makeContextCurrent(window);

    if (!procs.init(glfw.getProcAddress)) {
        log.err("failed to load some OpenGL functions", .{});
    }
    gl.makeProcTableCurrent(&procs);
    defer gl.makeProcTableCurrent(null);

    // Print renderer information
    const renderer = gl.GetString(gl.RENDERER);
    const version = gl.GetString(gl.VERSION);
    log.info("Renderer: {?s} version {?s}", .{ renderer, version });

    if (@intFromPtr(procs.DebugMessageCallback) != 0) {
        gl.DebugMessageCallback(glDebugMessageCallback, null);
        gl.Enable(gl.DEBUG_OUTPUT);
        gl.Enable(gl.DEBUG_OUTPUT_SYNCHRONOUS);
    }

    window.setFramebufferSizeCallback(onResize);
    const initial_size = window.getFramebufferSize();
    onResize(window, initial_size.width, initial_size.height);

    const program = gl.CreateProgram();
    defer gl.DeleteProgram(program);
    const vertex = createShader(vertex_source, gl.VERTEX_SHADER);
    const fragment = createShader(fragment_source, gl.FRAGMENT_SHADER);
    //gl.ObjectLabel(gl.SHADER, vertex, -1, "myvertex.vert");
    //gl.ObjectLabel(gl.SHADER, fragment, -1, "myfragment.frag");
    gl.AttachShader(program, vertex);
    gl.AttachShader(program, fragment);
    linkProgram(program);
    gl.DeleteShader(vertex);
    gl.DeleteShader(fragment);

    var vertex_buffer: gl.uint = undefined;
    gl.GenBuffers(1, (&vertex_buffer)[0..1]);
    defer gl.DeleteBuffers(1, (&vertex_buffer)[0..1]);
    gl.BindBuffer(gl.ARRAY_BUFFER, vertex_buffer);
    gl.BufferData(gl.ARRAY_BUFFER, vertex_data.len * @sizeOf(f32), &vertex_data, gl.STATIC_DRAW);

    var vao: gl.uint = undefined;
    gl.GenVertexArrays(1, (&vao)[0..1]);
    defer gl.DeleteVertexArrays(1, (&vao)[0..1]);
    gl.BindVertexArray(vao);
    gl.EnableVertexAttribArray(0);
    gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 0, 0);

    gl.Disable(gl.CULL_FACE);

    // Wait for the user to close the window.
    while (!window.shouldClose()) {
        glfw.pollEvents();

        gl.ClearColor(1, 0, 1, 1);
        gl.Clear(gl.COLOR_BUFFER_BIT);
        gl.UseProgram(program);
        gl.BindVertexArray(vao);
        gl.DrawArrays(gl.TRIANGLE_STRIP, 0, 4);

        window.swapBuffers();
        if (powerSave > 0) {
            std.time.sleep(powerSave * 1000000); //to miliseconds
        }
    }
}
