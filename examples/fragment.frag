#version 400
#pragma deshader source "glfw/fragment.frag"
in vec3 vColor;
out vec4 fColor;
uint test;
void main() {
#pragma deshader breakpoint
    fColor = vec4(vColor, 1);
    test = 1;
    if(test == 1) {
        test = 2;
    }
}
