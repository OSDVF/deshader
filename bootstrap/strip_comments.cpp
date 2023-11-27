#include <iostream>
#include <fstream>
#include <string>

// Function to remove single-line comments from a string
std::string removeSingleLineComments(const std::string& line) {
    std::string result;
    bool inString = false;
    bool inComment = false;

    for (size_t i = 0; i < line.size(); ++i) {
        if (!inComment && !inString && line[i] == '/' && i + 1 < line.size() && line[i + 1] == '/') {
            break; // Found single-line comment, ignore rest of the line
        }
        else if (!inComment && !inString && line[i] == '/' && i + 1 < line.size() && line[i + 1] == '*') {
            inComment = true; // Start of multi-line comment
            ++i; // Skip the next character '*'
        }
        else if (!inComment && !inString && line[i] == '"') {
            inString = true; // Start of string literal
            result += line[i];
        }
        else if (inString && line[i] == '"' && (i == 0 || line[i - 1] != '\\')) {
            inString = false; // End of string literal
            result += line[i];
        }
        else if (!inComment && inString) {
            result += line[i]; // Inside string literal, keep characters
        }
        else if (inComment && line[i] == '*' && i + 1 < line.size() && line[i + 1] == '/') {
            inComment = false; // End of multi-line comment
            ++i; // Skip the next character '/'
        }
        else if (!inComment) {
            result += line[i]; // Add non-comment characters to result
        }
    }

    return result;
}

// Function to remove comments from a file
void removeCommentsFromFile(const std::string& inputFile, const std::string& outputFile) {
    std::ifstream inFile(inputFile);
    std::ofstream outFile(outputFile);

    if (!inFile.is_open()) {
        std::cerr << "Error opening input file!" << std::endl;
        return;
    }

    if (!outFile.is_open()) {
        std::cerr << "Error opening output file!" << std::endl;
        inFile.close();
        return;
    }

    std::string line;
    while (std::getline(inFile, line)) {
        std::string lineWithoutComments = removeSingleLineComments(line);
        outFile << lineWithoutComments << '\n';
    }

    inFile.close();
    outFile.close();
}

int main(int argc, const char *argv[]) {
    if(argc < 3) {
        std::cerr << "Expected 2 arguments (source and destination)";
        return 1;
    }
    std::string inputFile = argv[1];
    std::string outputFile = argv[2];

    removeCommentsFromFile(inputFile, outputFile);

    std::cout << "Comments removed successfully. Output written to '" << outputFile << "'" << std::endl;

    return 0;
}
