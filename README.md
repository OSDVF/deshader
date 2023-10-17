# Deshader
Shaders are often shiny bud also shady, fishy and stinky!
> What if I could just step-debug that shader as I do with my CPU programs?

Now you can!
You can also:
# Features
- Track variable values for different output primitives and pixels
- Incrementally visualise primitive and pixel output (so you can fix that weird vertex!)
- Linux and Windows support

## Goals
- Be better than GLIntercept

## Non-goals
- Debugging other languages than GLSL

# Build
## Components

Deshader consists of several components that require different dev stacks and frameworks. Some of them are installed as git submodules or as Zig dependencies.

- Deshader library
    - [/src/](/src/)
    - Written in **Zig**
    - [Graphical API bindings](https://github.com/MasterQ32/zig-opengl)
        - Code generator written in **C#** [/libs/zig-opengl/](/libs/zig-opengl/)
    - [Web View (WebKit2Gtk)](https://github.com/ziglibs/positron) [/libs/positron/](/libs/positron/)
    - Example application
        - [/example/](/example/)
    - [GLSL Analyzer](https://github.com/nolanderc/glsl_analyzer) [/libs/positron/](/libs/positron/)
- [Visual Studio Code for Web distribution](https://github.com/Felx-B/vscode-web)
    - [/editor/](/editor/)
    - With node.js packages
    - Managed by **Bun**
- VSCode extension
    - [/editor/deshader-vscode/](/editor/deshader-vscode/)
    - With node.js packages
    - Managed by **Bun** and bundled by Webpack

## Requirements
- Zig [Installation](https://github.com/ziglang/zig#installation) (developed against 0.12.0-dev.899+027aabf49)
- Bun 1.0.6 [Install](https://github.com/oven-sh/bun#install)
- Dotnet

## How to
After you install all the required frameworks, you can
```sh
zig build dependencies
```
If that does not output any errors, it will autmatically
- Generate OpenGL bindings
    - `make` inside `/libs/zig-opengl/`
- Install Node.js dependencies
    - `bun install` inside `/editor/` and `/editor/deshader-vscode/`
- Compile Deshader VSCode Extension
    - `bun compile-web` inside `/editor/deshader-vscode/`

for you. If there weren't any errors, then you can
```sh
zig build deshader
```
## Frequently Seen Errors
- Cannot compile
    - Something with `struct_XSTAT` inside WolfSSL
        - fix by `./fix_wolfssl.sh`  
        **CAUTION**: The script searches the whole `zls` global cache and deletes lines with `struct_XSTAT` so be careful.
- Editor window is blank
    - Set environment variable `WEBKIT_DISABLE_COMPOSITING_MODE=1`
    - This is an issue with WebKit2Gtk
    
and finally get your Deshader library files from `./zig-out/`:

- lib
    - (lib)deshader.[a|so|dll|lib|dylib]
- include
    - deshader.h
    - deshader.hpp
    - deshader.zig

The files inside `include/` are bindings for your application.

### Example
```sh
zig build example # Builds example application
./zig-out/bin/example # Runs example application
```