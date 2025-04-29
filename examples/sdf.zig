const std = @import("std");
const glfw = @import("zig_glfw");
const gl = @import("gl");
const engine = @import("engine.zig");

const vertex_source = @embedFile("vertex.vert");
const fragment_source = @embedFile("sdf.frag");

const vertex_data = [_]f32{
    -1, -1, //
    1, -1, //
    -1, 1, //
    1,  1,
};

var w: gl.int = 640;
var h: gl.int = 480;

pub fn onResize(window: glfw.Window, width: u32, height: u32) void {
    _ = window;
    w = @intCast(width);
    h = @intCast(height);
    gl.Viewport(0, 0, w * 2, h * 2);
}

// Procedure table that will hold OpenGL functions loaded at runtime.
// SAFETY: assigned after the context is created
var procs: gl.ProcTable = undefined;
// count of seconds from the start of the program
var iTime: f32 = 0;

pub fn main() !void {
    const start_time = std.time.milliTimestamp();
    const env = try std.process.getEnvMap(std.heap.page_allocator);
    const powerSave = try std.fmt.parseInt(usize, env.get("POWER_SAVE") orelse "0", 0);
    engine.log.info("Showing a SDF window with GLFW and OpenGL", .{});
    // Initialize GLFW
    glfw.setErrorCallback(engine.errorCallback);
    if (!glfw.init(.{})) {
        engine.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    // Create our window
    const window = glfw.Window.create(
        @intCast(w),
        @intCast(h),
        "SDF",
        null,
        null,
        .{ .opengl_profile = .opengl_core_profile, .context_version_major = 4, .context_version_minor = 0, .context_debug = true },
    ) orelse {
        engine.log.err("failed to create GLFW window: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    };
    defer window.destroy();

    glfw.makeContextCurrent(window);

    if (!procs.init(glfw.getProcAddress)) {
        engine.log.err("failed to load some OpenGL functions", .{});
    }
    gl.makeProcTableCurrent(&procs);
    defer gl.makeProcTableCurrent(null);

    gl.DebugMessageCallback(engine.glDebugMessageCallback, null);

    window.setFramebufferSizeCallback(onResize);
    const initial_size = window.getFramebufferSize();
    onResize(window, initial_size.width, initial_size.height);

    const program = gl.CreateProgram();
    defer gl.DeleteProgram(program);
    const vertex = engine.createShader(vertex_source, gl.VERTEX_SHADER);
    const fragment = engine.createShader(fragment_source, gl.FRAGMENT_SHADER);
    //gl.ObjectLabel(gl.SHADER, vertex, -1, "myvertex.vert");
    //gl.ObjectLabel(gl.SHADER, fragment, -1, "myfragment.frag");
    gl.AttachShader(program, vertex);
    gl.AttachShader(program, fragment);
    engine.linkProgram(program);
    gl.DeleteShader(vertex);
    gl.DeleteShader(fragment);

    // SAFETY: assigned right after by OpenGL
    var vertex_buffer: gl.uint = undefined;
    gl.CreateBuffers(1, &vertex_buffer);
    defer gl.DeleteBuffers(1, (&vertex_buffer)[0..1]);
    gl.NamedBufferData(vertex_buffer, vertex_data.len * @sizeOf(f32), &vertex_data, gl.STATIC_DRAW);

    // SAFETY: assigned right after by OpenGL
    var vao: gl.uint = undefined;
    gl.CreateVertexArrays(1, &vao);
    defer gl.DeleteVertexArrays(1, (&vao)[0..1]);
    gl.BindVertexArray(vao);
    gl.EnableVertexAttribArray(0);
    gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 0, 0);
    gl.VertexArrayVertexBuffer(vao, 0, vertex_buffer, 0, 2 * @sizeOf(f32));

    const iResolution = gl.GetUniformLocation(program, "iResolution");
    const iTimeLoc = gl.GetUniformLocation(program, "iTime");

    gl.Disable(gl.CULL_FACE);

    // Wait for the user to close the window.
    while (!window.shouldClose()) {
        glfw.pollEvents();

        gl.ClearColor(1, 0, 1, 1);
        gl.Clear(gl.COLOR_BUFFER_BIT);
        gl.UseProgram(program);
        gl.BindVertexArray(vao);
        gl.Uniform2f(iResolution, @floatFromInt(w), @floatFromInt(h));
        iTime = @as(f32, @floatFromInt(std.time.milliTimestamp() - start_time)) / 1000.0;
        gl.Uniform1f(iTimeLoc, iTime);
        gl.DrawArrays(gl.TRIANGLE_STRIP, 0, 4);

        window.swapBuffers();
        if (powerSave > 0) {
            std.time.sleep(powerSave * 1000000); //to miliseconds
        }
    }
}
