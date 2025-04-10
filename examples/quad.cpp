#include <iostream>
#include <array>
#include <vector>
#include <cstring>
#include <GL/glew.h>
#include <GLFW/glfw3.h>
#if defined(__MINGW32__) || defined(WIN32)
#include <windows.h>
#include "resources.h"

// https://stackoverflow.com/questions/2933295/embed-text-file-in-a-resource-in-a-native-windows-application
void LoadFileInResource(int name, int type, DWORD& size, const char*& data)
{
    HMODULE handle = ::GetModuleHandle(NULL);
    HRSRC rc = ::FindResource(handle, MAKEINTRESOURCE(name),
        MAKEINTRESOURCE(type));
    HGLOBAL rcData = ::LoadResource(handle, rc);
    size = ::SizeofResource(handle, rc);
    data = static_cast<const char*>(::LockResource(rcData));
}
#elif __linux__
#include <execinfo.h>
#include <unistd.h>
#elif __APPLE__
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#endif

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

    #ifdef _POSIX_VERSION
    void *array[10];
    size_t size = backtrace(array, 10);
    backtrace_symbols_fd(array, size, STDERR_FILENO);
    #endif
}

GLFWwindow* createWindow() {
    return glfwCreateWindow(640, 480, "GLFW with C++ and Deshader", nullptr, nullptr);
}

int main(int argc, char** argv) {
    std::cout << "Showing Quad window from C++" << std::endl;

    if (!glfwInit()) {
        std::cerr << "Failed to initialize GLFW" << std::endl;
        return 1;
    }

    // Set opengl version
    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 4);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 1);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
    GLFWwindow* window = createWindow();
    if (!window) {
        // Try software renderer
        glfwWindowHint(GLFW_CONTEXT_RENDERER, GLFW_SOFTWARE_RENDERER);
        window = createWindow();
    }
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

    // Print renderer information
    std::cout << "Renderer: " << glGetString(GL_RENDERER) << std::endl;
    std::cout << "OpenGL version supported " << glGetString(GL_VERSION) << std::endl;

    if (GLEW_KHR_debug) {
        glEnable(GL_DEBUG_OUTPUT);
        glEnable(GL_DEBUG_OUTPUT_SYNCHRONOUS);
        glDebugMessageCallback(MessageCallback, 0);
    }

    // Initialize programs and shaders
    std::vector<float> vertex_data = {
        -1, -1,
        1, -1,
        -1, 1,
        1,  1,
    };
    #if defined(__MINGW32__) || defined(WIN32)
    DWORD vert_size = 0;
    DWORD frag_size = 0;
    const char* vertex_vert_start = NULL;
    const char* fragment_frag_start = NULL;
    LoadFileInResource(VERTEX_VERT, TEXTFILE, vert_size, vertex_vert_start);
    LoadFileInResource(FRAGMENT_FRAG, TEXTFILE, frag_size, fragment_frag_start);
    const GLint vert_size_int = static_cast<GLint>(vert_size);
    const GLint frag_size_int = static_cast<GLint>(frag_size);
    #elif __linux__
    extern const char vertex_vert_start[] asm("_binary_vertex_vert_start");//created by ld --relocatable --format=binary --output=vertex.vert.o vertex.vert
    extern const char vertex_vert_end[]   asm("_binary_vertex_vert_end");
    extern const char fragment_frag_start[] asm("_binary_fragment_frag_start");
    extern const char fragment_frag_end[]   asm("_binary_fragment_frag_end");
    const GLint vert_size_int = static_cast<GLint>(vertex_vert_end - vertex_vert_start);
    const GLint frag_size_int = static_cast<GLint>(fragment_frag_end - fragment_frag_start);
    #else
    size_t vert_size = 0;
    const GLchar* vertex_vert_start = reinterpret_cast<const GLchar*>(getsectiondata(
        &_mh_execute_header, "binary", "vertex.vert", &vert_size));
    size_t frag_size = 0;
    const GLchar* fragment_frag_start = reinterpret_cast<const GLchar*>(getsectiondata(
        &_mh_execute_header, "binary", "fragment.frag", &frag_size));
    const GLint vert_size_int = static_cast<GLint>(vert_size);
    const GLint frag_size_int = static_cast<GLint>(frag_size);
    #endif

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
    glGenBuffers(1, &vertex_buffer);
    glBindBuffer(GL_ARRAY_BUFFER, vertex_buffer);
    glBufferData(GL_ARRAY_BUFFER, vertex_data.size() * sizeof(float), vertex_data.data(), GL_STATIC_DRAW);

    GLuint vao;
    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, 0);

    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);


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
