#include <iostream>
#include <deshader/deshader.hpp>

int main(int argc, char** argv) {
    std::cerr << "Show Deshader Library version from C++ code" << std::endl;
    std::cout << deshaderVersion() << std::endl;
    return 0;
}
