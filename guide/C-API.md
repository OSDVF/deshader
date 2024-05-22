# Deshader low-level API

## Unobtrusive Commands

`deshader/macros.h` wraps Deshader unobtrusive commands in a set of macros. The commands are implemented as `glObjectLabel` and `glDebugMessageInsert` calls. They can be used in any C or C++ code without any additional setup and do not require the deshader to be linked to the application.

## C API

`deshader/deshader.h` exposes a C API for more advanced control over Deshader. It includes all the commands from the [remote command interface](Commands.md).