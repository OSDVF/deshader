#include <iostream>
#include <array>
#include <vector>
#include <cstring>
#include <GL/glew.h>
#include <GLFW/glfw3.h>

void GLAPIENTRY
MessageCallback(GLenum source,
    GLenum type,
    GLuint id,
    GLenum severity,
    GLsizei length,
    const GLchar* message,
    const void* userParam)
{
    switch (type) {
    case GL_DEBUG_TYPE_ERROR:
        std::cerr << "ERROR";
        break;
    case GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR:
        std::cerr << "DEPRECATED_BEHAVIOR";
        break;
    case GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR:
        std::cerr << "UNDEFINED_BEHAVIOR";
        break;
    case GL_DEBUG_TYPE_PORTABILITY:
        std::cerr << "PORTABILITY";
        break;
    case GL_DEBUG_TYPE_PERFORMANCE:
        std::cerr << "PERFORMANCE";
        break;
    case GL_DEBUG_TYPE_OTHER:
        std::cerr << "OTHER";
        break;
    }
    std::cerr << " (severity ";
    switch (severity) {
    case GL_DEBUG_SEVERITY_NOTIFICATION:
        std::cerr << "NOTIFICATION";
        break;
    case GL_DEBUG_SEVERITY_LOW:
        std::cerr << "LOW";
        break;
    case GL_DEBUG_SEVERITY_MEDIUM:
        std::cerr << "MEDIUM";
        break;
    case GL_DEBUG_SEVERITY_HIGH:
        std::cerr << "HIGH";
        break;
    }

    std::cerr << "): " << message << std::endl;
}

int main(int argc, char** argv) {
    std::cout << "Showing GLFW window from C++" << std::endl;

    if (!glfwInit()) {
        std::cerr << "Failed to initialize GLFW" << std::endl;
        return 1;
    }

    GLFWwindow* window = glfwCreateWindow(640, 480, "GLFW with C++ and Deshader", nullptr, nullptr);
    if (!window) {
        std::cerr << "Failed to create GLFW window" << std::endl;
        glfwTerminate();
        return 1;
    }

    glfwMakeContextCurrent(window);
    glewExperimental = GL_TRUE;
    if (glewInit() != GLEW_OK) {
        std::cerr << "Failed to initialize GLEW" << std::endl;
        glfwTerminate();
        return 1;
    }
    glEnable(GL_DEBUG_OUTPUT);
    glEnable(GL_DEBUG_OUTPUT_SYNCHRONOUS);
    glDebugMessageCallback(MessageCallback, 0);

    // Initialize programs and shaders
    std::vector<float> vertex_data = {
        -1, -1,
        1, -1,
        -1, 1,
        1,  1,
    };
    extern const char vertex_vert_start[] asm("_binary_vertex_vert_start");//created by LD --relocatable --format=binary --output=vertex.vert.o vertex.vert
    extern const char vertex_vert_end[]   asm("_binary_vertex_vert_end");
    extern const char fragment_frag_start[] asm("_binary_fragment_frag_start");
    extern const char fragment_frag_end[]   asm("_binary_fragment_frag_end");
    const GLint vert_size_int = static_cast<GLint>(vertex_vert_end - vertex_vert_start);
    const GLint frag_size_int = static_cast<GLint>(fragment_frag_end - fragment_frag_start);

    GLuint vertex_shader = glCreateShader(GL_VERTEX_SHADER);
    glShaderSource(vertex_shader, 1, std::array<const GLchar*, 1>({ vertex_vert_start }).data(), &vert_size_int);
    glCompileShader(vertex_shader);

    GLuint fragment_shader = glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(fragment_shader, 1, std::array<const GLchar*, 1>({ fragment_frag_start }).data(), &frag_size_int);
    glCompileShader(fragment_shader);

    GLuint program = glCreateProgram();
    glAttachShader(program, vertex_shader);
    glAttachShader(program, fragment_shader);
    glLinkProgram(program);

    GLuint vertex_buffer;
    glCreateBuffers(1, &vertex_buffer);
    glNamedBufferData(vertex_buffer, vertex_data.size() * sizeof(float), vertex_data.data(), GL_STATIC_DRAW);

    GLuint vao;
    glCreateVertexArrays(1, &vao);
    glVertexArrayVertexBuffer(vao, 0, vertex_buffer, 0, sizeof(float) * 2);
    glVertexArrayAttribFormat(vao, 0, 2, GL_FLOAT, GL_FALSE, 0);
    glVertexArrayAttribBinding(vao, 0, 0);
    glEnableVertexArrayAttrib(vao, 0);


    while (!glfwWindowShouldClose(window)) {
        glUseProgram(program);
        glBindVertexArray(vao);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

        glfwSwapBuffers(window);
        glfwPollEvents();
    }
    glfwTerminate();

    return 0;
}
