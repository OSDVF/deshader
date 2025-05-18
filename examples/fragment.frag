#version 400
#pragma deshader source "glfw/fragment.frag"
in vec3 vColor;
layout(location=0) out lowp vec4 fColor;
out uint dummy[2];
layout(location=2) out uint test;
void main() {
    fColor = vec4(vColor, 1);
    test = 1;
    dummy[1] = 3;
    if(test == 1, test == 2) {
        #pragma deshader breakpoint
        test = 2;
    } else if (test == 2) {
        test = 3;
        dummy[0] = 2;
    } else {
        test = 4;
        dummy[0] = 3;
    }
}
