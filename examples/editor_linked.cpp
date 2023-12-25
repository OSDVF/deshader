#include <iostream>
#include <deshader.hpp>

int main(int argc, char** argv) {
    std::cout << "Showing editor from C++ code with linked Deshader library" << std::endl;
    deshaderEditorWindowShow();
    deshaderEditorWindowWait();
    return 0;
}
