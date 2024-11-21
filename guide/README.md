# Deshader Manual

Installation and build process are [covered in the main README](../README.md).

Deshader exposes several basic user interfaces for using it, without any modifications to host application code:
- [GUI](GUI.md) - VSCode with Deshader extension
- [Remote commands server](Commands.md)

Additionally, Deshader can be controlled from the host application code by:
- [`#pragma` clauses in shaders](Shaders.md)
- [Unobtrusive commands](API.md#unobtrusive-commands) using `glObjectLabel` and `glDebugMessageInsert`
- [C API](API.md#c-api) for more advanced control
- [Zig API](API.md#zig-api)

Generally more than one interface can be used at the same time and they can control the same features.

Low-level features are controlled by setting [environment variables](Settings.md).