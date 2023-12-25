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
    GLFWwindow* offscreen_window = glfwCreateWindow(640, 480, "", nullptr, nullptr);
    if (!offscreen_window) {
        std::cerr << "Failed to create GLFW window" << std::endl;
        glfwTerminate();
        return 1;
    }
    glfwMakeContextCurrent(offscreen_window);

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
