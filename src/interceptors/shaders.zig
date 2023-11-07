const gl = @import("gl");
const decls = @import("../declarations/shaders.zig");
const shaders = @import("../services/shaders.zig");
const log = @import("../log.zig").DeshaderLog;

pub fn glCreateShader(shaderType: gl.GLenum) gl.GLuint {
    const new_platform_source = gl.createShader(shaderType);

    shaders.Sources.addUntagged(@ptrFromInt(new_platform_source), null) catch |err| {
        log.warn("Failed to add shader source {x} to virtual filesystem: {any}", .{ new_platform_source, err });
    };

    return new_platform_source;
}
