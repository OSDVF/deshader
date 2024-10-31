#version 400
//#pragma deshader source "glfw/vertex.vert"
in vec2 vPosition;
out vec3 vColor;

void main() {
    vColor = vec3(gl_VertexID == 0, gl_VertexID == 1, gl_VertexID == 2);
    gl_Position = vec4(vPosition, 0, 1);
}
