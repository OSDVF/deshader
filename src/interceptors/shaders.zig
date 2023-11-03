const gl = @import("gl");

pub fn createShader(shaderType: gl.GLenum) gl.GLuint {
    return gl.createShader(shaderType);
}
