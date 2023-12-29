#version 400
#pragma deshader source "glfw/fragment.frag"
in vec3 vColor;
layout(location = 0) out vec4 fColor;
void main() {
#pragma deshader breakpoint
    fColor = vec4(vColor, 1);
}
