#include <iostream>
#include <deshader/deshader.hpp>

int main(int argc, char** argv) {
    std::cerr << "Show Deshader Library version from C++ code" << std::endl;
    unsigned char* version;
    deshaderVersion(&version);
    std::cout << version << std::endl;
    return 0;
}
