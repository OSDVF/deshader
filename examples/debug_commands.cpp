#include <iostream>
#define DESHADER_DEBUG // not really necessary here, because DESHADER_DEBUG_ONLY is not defined
#include <deshader/macros.h>
#include <GL/glew.h>
#include <GLFW/glfw3.h>

int main(int argc, char** argv) {
    std::cout << "Maybe showing editor from C++ by debug commands" << std::endl;

    if (!glfwInit()) {
        std::cerr << "Failed to initialize GLFW" << std::endl;
        return 1;
    }

    glfwWindowHint(GLFW_VISIBLE, GLFW_FALSE);
    GLFWwindow* offscreen = glfwCreateWindow(640, 480, "", nullptr, nullptr);
    if (!offscreen) {
        // Try software renderer
        glfwWindowHint(GLFW_CONTEXT_RENDERER, GLFW_SOFTWARE_RENDERER);
        offscreen = glfwCreateWindow(640, 480, "", nullptr, nullptr);
    }    
    if (!offscreen) {
        std::cerr << "Failed to create GLFW offscreen window" << std::endl;
        glfwTerminate();
        return 1;
    }
    glfwMakeContextCurrent(offscreen);

    glewExperimental = GL_TRUE;
    if (glewInit() != GLEW_OK) {
        std::cerr << "Failed to initialize GLEW" << std::endl;
        glfwTerminate();
        return 1;
    }
    deshaderEditorWindowShow();
    deshaderEditorWindowWait();
    return 0;
}
