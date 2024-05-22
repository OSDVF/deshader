# Deshader Manual

Deshader exposes several basic user interfaces for controlling its behavior without any change to the host code:
- [GUI](GUI.md) - VSCode with Deshader extension
- [`#pragma` clauses in shaders](Shaders.md)
- [Remote commands server](Commands.md)

Additionally, Deshader can be controlled from the host code by:
- [Unobtrusive commands](C-API.md#unobtrusive-commands) using `glObjectLabel` and `glDebugMessageInsert`
- [C API](C-API.md#c-api) for more advanced control

Generally more than one interface can be used at the same time and they can control the same features.