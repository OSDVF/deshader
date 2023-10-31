# Deshader 🔦
Shaders are often shiny but sometimes also shady, fishy and stinky!
> What if I could just step-debug that shader as I do with my CPU programs?

Now you can!
Deshader intercepts OpenGL calls and adds instrumentation code to your shaders so you don't need to create your own debug visualizations to output shader execution process.
You can also:
# Features
- Track variable values for different output primitives and pixels
- Incrementally visualise primitive and pixel output (so you can fix that weird vertex!)
- Use inbuilt editor (VSCode for Web in an embedded window or at `http://localhost:8080/index.html` by default)
- Run it on Linux and Windows

# Goals
- Compatibility between OpenGL vendor implementations (ICDs)
- Broader API support than [GLIntercept](https://github.com/dtrebilco/glintercept), different features than [ApiTrace](https://github.com/apitrace/apitrace)

## Non-goals
And also some dead ends that have been encountered.
- Debugging other languages than GLSL (feel free to fork and add your own language)
- Using vendor-specific GPU APIs and instructions
- Assembly level debugging
- Profiling
- Mac OS CGL Support
- [Custom WebView profile data directory](https://github.com/webview/webview/issues/719)

Feel free to fork and add your own goals or even better, break the non-goals!

Deshader aims to assist researchers who want to leverage the edge features of graphical APIs to explore and create new software technologies. There is no development effort given into features like debugging of third party applications. If Deshader saved some of your time, you can leave a comment in the [discussions](https://github.com/OSDVF/deshader/discussions) or [star](https://github.com/OSDVF/deshader/star) the repo.

# Build
## Components

Deshader consists of several (mostly third party; mostly forked) components that require different dev stacks and frameworks. Some of them are installed as git submodules or as Zig dependencies.

- Deshader runner
    - [/src/tools/run.zig](/src/tools/run.zig)
- Deshader library
    - [/src/](/src/)
    - Written in **Zig**
    - [Graphical API bindings](https://github.com/MasterQ32/zig-opengl)
        - Code generator written in **C#** [/libs/zig-opengl/](/libs/zig-opengl/)
    - [Web View (WebKit2Gtk)](https://github.com/ziglibs/positron) [/libs/positron/](/libs/positron/)
    - Example applications
        - [/examples/](/examples/)
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
- C libraries
    - Linux
        - gtk-3 and webkit2gtk
    - Windows
        - [Edge Dev Channel](https://www.microsoftedgeinsider.com/download)

## How to
After you install all the required frameworks, clone this repository with submodules, open terminal in its folder and create a debug build by
```sh
git clone --recurse-submmodules https://github.com/OSDVF/deshader
cd deshader
zig build dependencies
```
If that does not output any errors, it will autmatically
- Generate OpenGL bindings
    - `make` inside `/libs/zig-opengl/`
- Install Node.js dependencies
    - `bun install` inside `/editor/` and `/editor/deshader-vscode/`
- Compile Deshader VSCode Extension
    - `bun compile-web` inside `/editor/deshader-vscode/`

for you. If there weren't any errors, then you can then
```sh
# Build
zig build runner

# Use Runner wrapper
DESHADER_LIB_ROOT=zig-out/lib ./zig-out/bin/deshader-run your_application

# Or run & build the provided examples sequentially
zig build examples-run -DwolfSSL=true -DlogIntercept=true  # -DwolfSSL=true only if you have WolfSSL installed
```
btw. `zig build` only downloads dependencies specified in `build.zig.zon`.

Output files will be placed at `./zig-out/`:
- `bin/`
    - `deshader-run`
    - (internal tools)
        - `generate_header`
        - `generate_stubs`
        - `symbol_enumerator`
    - `example/`
        - `glfw`
        - `editor`
    - `examples`
- `lib/`
    - (lib)deshader.[a|so|dll|lib|dylib]
- `include/`
    - `deshader.h`
    - `deshader.hpp`
    - `deshader.zig`

The files inside `include/` are bindings for your application.

### Without runner
#### Linux
```sh
DESHADER_LIB_ROOT=zig-out/lib DESHADER_REPLACE_ROOT=/your/app/dir ./zig-out/bin/deshader-run # Symlinks Deshader as libGLX.so, libEGL.so... etc. into DESHADER_REPLACE_ROOT
LD_LIBRARY_PATH=/your/app/dir /your/app/dir/app
```
#### Windows
```bat
set DESHADER_REPLACE_ROOT=your\app\dir
set DESHADER_LIB_ROOT=zig-out\lib
rem Symlink Deshader as opengl32.dll, vulkan-1.dll... etc. into DESHADER_REPLACE_ROOT
zig-out\bin\deshader-run.exe
your\app\dir\app.exe
```

#### Mac OS
```sh
DYLD_INSERT_LIBRARIES=./zig-out/lib/libdeshader.dylib your_application
```

## Build Options
Specify options as `-Doption=value` to `zig build deshader` commands. See also `zig build --help`
Name                  | Values                        | Description
----------------------|-------------------------------|---------------------------------------------------------------------------------------
`linkage`             | `Static`, `Dynamic` (default) | Select type of for Deshader library
`wolfSSL`             | `true`, `false` (default)     | Link with system-provided WolfSSL instead of deshader included one
`logIntercept`        | `true`, `false` (default)     | Enable logging of intercepted VK ang GL (not on Mac) procedure requests 
`glAddLoader`         | any string                    | Specify a single additional function name that will be exported and intercepted
`vkAddDeviceLoader`   | any string                    | Export additional intercepted function that will call device procedure addresss loader
`vkAddInstanceLoader` | any string                    | Same as `vkAddDeviceLoader` but for instance procedure addresses
 
### Production build
- Add `-Doptimize` to `zig build` commands
    - `-Doptimize=ReleaseSmall` will disable debug and info meassages
    - `-Doptimize=ReleaseSafe` will will enable info meassages
    - `-Doptimize=Debug` (default) will include debug, info, warning and error meassages

## Frequently Seen Errors
- Cannot compile
    - Something with `struct_XSTAT` inside WolfSSL
        - fix by `./fix_wolfssl.sh`  
        **CAUTION**: The script searches the whole `zls` global cache and deletes lines with `struct_XSTAT` so be careful.
- Editor window is blank
    - This is a known issue between WebKit and vendor GL drivers
    - Disable GPU acceleration
        - Set environment variable `WEBKIT_DISABLE_COMPOSITING_MODE=1`
    - Or select a different GPU
        - by setting `__GLX_VENDOR_LIBRARY_NAME=nvidia __NV_PRIME_RENDER_OFFLOAD=1 __VK_LAYER_NV_optimus=NVIDIA_only`
        - or `DRI_PRIME=1`


# Settings
## Environment variables
Runtime settings can be specified by environment variables.
All names start with DESHADER_ prefix e.g. `DESHADER_PORT`
### Deshader runner
Name         | Default                                                             | Description
-------------|---------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------
LIB_ROOT     | `/usr/lib` / `C:\Windows\System32`                                  | Override the default path to the folder where the original libraries are located
REPLACE_ROOT | current working directory                                           | Location for Deshader replacement libraries (should be the working directory of debugged app)
HOOK_LIBS    | `opengl32.dll, vulkan-1.dll, libvulkan.dylib, libGLX.so, libEGL.so` | Comma separated list of **additional** library files that will be replaced with Deshader library (defaults will be always included)
### Deshader library
Name                | Default                                            | Description
--------------------|----------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------
LIB_ROOT            | `/usr/lib` / `C:\Windows\System32`                 | **REQUIRED** and automatically set by the Runner. Path to the folder where the original libraries are located
PORT                | 8080                                               | Port for the web editor at `http://localhost:DESHADER_PORT/index.html`
SHOW                | none                                               | Pass `true` or `1` to show the editor window on startup
GL_LIBS             | `libGLX.so, libEGL.so` / `opengl32.dll`            | Path to libraries from which the original GL functions will be loaded
GL_PROC_LOADERS     | none                                               | Specify additional lodader functions that will be called to retrieve GL function pointers[^1]
SUBSTITUTE_LOADER   | `false`                                            | Specify `1`, `yes` or `true` for calling `DESHADER_GL_PROC_LOADERS` instead of standard GL loader functions internally[^2]
VK_LIB              | `libvulkan.so` / `vulkan-1.dll`/ `libvulkan.dylib` | Path to library from which the original Vulkan functions will be loaded
VK_DEV_PROC_LOADER  | none                                               | Specify original device procedure address loader function for Vulkan
VK_INST_PROC_LOADER | none                                               | Specify original instance procedure address loader function for Vulkan

[^1]: Should be a comma separated list. The first found function will be used.
[^2]: In this case `DESHADER_GL_PROC_LOADERS` must be a single function. Does not work on Mac OS.