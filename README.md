# Deshader 🔦
Shaders are often shiny but sometimes also shady, fishy and stinky!
> What if I could just step-debug that shader as I do with my CPU programs?

Now you can!
Deshader intercepts OpenGL calls and adds instrumentation code to your shaders (so you don't need to write your own visualizations to debug shader execution process anymore).
You can also:
# Features
- Step through the shader execution (...breakpoints, logging, conditional bps...)
- Arrange shaders in a virtual filesystem (`#include` friendly!)
- Track variable values for different output primitives and pixels
- Incrementally visualise primitive and pixel output (so you can fix that weird vertex!)
- Open the integrated editor (VSCode in a separate window or in your browser - at `localhost:8080/index.html` by default)
- Run it on Linux and Windows
<!-- TODO check https://github.com/coder/code-server -->

# Goals
- Compatibility between OpenGL vendor implementations (ICDs)
- Flexibility
- Broader API support than [GLIntercept](https://github.com/dtrebilco/glintercept), different features than [ApiTrace](https://github.com/apitrace/apitrace)

## Non-goals
...and some dead ends, which have been encountered.
- Debugging other languages than GLSL (feel free to fork and add your own language)
- Using vendor-specific GPU APIs and instructions
- Assembly (ISA) or pseudo-assembly (SPIR-V) level debugging
- Profiling
- [Custom WebView profile data directory](https://github.com/webview/webview/issues/719)

## Possible future goals
- View assembly
    - SPIR-V (compile by GLSLang)
    - ISA level ([nvdisasm](https://developer.download.nvidia.com/compute/cuda/redist/cuda_nvdisasm/), [nvcachetools](https://github.com/therontarigo/nvcachetools), [envytools](https://github.com/envytools/envytools/))
- Mac OS CGL Support

Feel free to fork and add your own goals or even better, break the non-goals!

# Installation
### Prebuilt packages
[Packages for Debian-like, Arch Linux and Windows are in the releases section.](https://github.com/OSDVF/deshader/releases)

### Arch Linux (AUR)
Download and install using an AUR helper. For example, Yay:.
```bash
yay -S deshader-git
```
or
```bash
pamac build deshader-git
```
### Build and packaging scripts
[Build scripts for Debian-like and Arch Linux reside in a separate repository](https://github.com/OSDVF/deshader-build).

## Usage
Display the Launcher GUI:
```bash
deshader-run
```
Advanced instructions are written in [Deshader Manual](./guide/README.md).

# Build
## Components

Deshader consists of several (mostly third party; mostly forked) components that require different dev stacks and frameworks. Some of them are installed as git submodules or as Zig dependencies.

- Deshader Launcher
    - [/src/tools/run.zig](/src/tools/run.zig)
- Deshader library
    - [/src/](/src/)
    - Written in **Zig**
    - [Web View (WebKit2Gtk)](https://github.com/ziglibs/positron) at [/libs/positron/](/libs/positron/) (MIT)
    - Example applications
        - [/examples/](/examples/)
    - Fork of [GLSL Analyzer](https://github.com/nolanderc/glsl_analyzer) at [/libs/glsl_analyzer/](/libs/glsl_analyzer/) (GPL-3.0)
- A distribution of [Visual Studio Code for web](https://github.com/Felx-B/vscode-web) (MIT)
    - [/editor/](/editor/)
    - With node.js packages
    - Managed by **Bun**
- VSCode extension
    - [/editor/deshader-vscode/](/editor/deshader-vscode/) (MIT)
    - With node.js packages
    - Managed by **Bun** and bundled by Webpack

## Requirements
- [Zig 0.13](https://ziglang.org/) (MIT)
- Bun 1.1.34 [Install](https://github.com/oven-sh/bun#install) (MIT)
- [VCPKG](https://vcpkg.io) (MIT)
- C libraries
    - Linux
        - gtk-3 (LGPL-2.1) and webkit2gtk (BSD, LGPL-2.1)
    - Windows
        - [Edge Dev Channel](https://www.microsoftedgeinsider.com/download)
        - WebView2 runtime
    - *Cross-compilation* under Linux
        - for Windows
            - add VCPKG path to `~/.local/share/vcpkg/vcpkg.path.txt` (e.g. `echo $(which vcpkg) > ~/.local/share/vcpkg/vcpkg.path.txt`)
            - [Edge Dev Channel](https://www.microsoftedgeinsider.com/download) installed by offline installer
            - WebView2 runtime must be installed by [standalone installer](https://developer.microsoft.com/en-us/microsoft-edge/webview2#download) (not bootstraper) under Wine
            - **NOTES**
                - DLL interception does not work for OpenGL under Wine. Intercept on host side instead (however this does not really work for now)
- Building __examples__ requires [Vulkan SDK](https://vulkan.lunarg.com/sdk/home) ([mixed licenses...](https://vulkan.lunarg.com/license/)) (for GLFW)
- On Linux: for using CMake to compile C++ examples
    - `pkg-config`
    - `ld` from `binutils` package

## Building from source
After you install all the required frameworks, clone this repository with submodules, open terminal in its folder and create a debug build by
```sh
git clone --recurse-submodules https://github.com/OSDVF/deshader
cd deshader
zig build deshader
```
There are multiple ways how to [use Deshader](guide/README.md). For example, Deshader Launcher can be built and used like this:
```sh
# Build Launcher
zig build launcher

# Use Launcher as command line tool
./zig-out/bin/deshader-run your_application

# Or display Launcher GUI
./zig-out/bin/deshader-run

# Or run & build all the provided examples one-by-one
zig build examples-run
```
If the Launcher is not able to find Deshader library, you can specify it in env
```sh
DESHADER_LIB=zig-out/lib/libdeshader.so deshader-run
```

Deshader and its build process support many [configuraiton options](guide/Settings.md).

### Usage Without Launcher
#### Linux
```sh
DESHADER_LIB=your/lib/dir/libdeshader.so /your/app/dir/app # Loads Deshader into your application
```
#### Windows
```batch
copy path\to\deshader.dll your\app\dir\opengl32.dll
copy path\to\libwolfssl.dll path\to\glslang.dll path\to\WebView2Loader.dll your\app\dir
your\app\dir\app.exe
```

#### Mac OS
(Not tested)
```sh
DYLD_INSERT_LIBRARIES=./zig-out/lib/libdeshader.dylib your_application
```

## Build process
Deshader components are built with different build systems. They are being called inside the main build process (`zig build ...`). The notes here are just for reference:

### Editor
- Installing Node.js dependencies
    - `bun install` inside `/editor/` and `/editor/deshader-vscode/`
- Compiling Deshader VSCode Extension
    - `bun compile-dev` or `bun compile-prod` inside `/editor/deshader-vscode/`

### VCPKG Dependencies
- <details>
    <summary>Installing VCPKG managed libraries (when target is Windows, or they are not present or system) and correct ther names</summary>
    GLEW, GLSLang, GLFW, WolfSSL, nativefiledialog
  </details>

  - `vcpkg install --triplet=x[86/64]-os(-zig) --x-install-root=build/vcpkg_installed`
  - Rename `.dll.a` -> `.lib` in `build/vcpkg_installed/*/lib`

### Zig dependencies
Some of the dependencies are managed as git submodules, other are specified in `build.zig.zon`. `zig build` without additonal target name will only download Zig-managed dependencies.

Output files will be placed at `./zig-out/`:
- `bin/`
    - `deshader-run`
    - (internal tools)
        - `generate_headers`
        - `generate_stubs`
    - `deshader-examples-all`
    - `deshader-examples/`
        - `glfw`
        - `editor`
        - `glfw_cpp`
        - `editor_cpp`
- `lib/` (also `bin/` for Windows)
    - (lib)deshader.[a|so|dll|lib|dylib]
    - (dependencies for Windows version)
        - `libwolfssl.dll`
        - `glslang.dll`
        - `WebView2Loader.dll`

- `include/`
    - `deshader`
        - `commands.h`
        - `macros.h`
        - `deshader.h`
        - `deshader.hpp`
        - `deshader.zig`
        - `deshader_prefixed.zig`

The files inside `include/` are API definitions for use in your application.

# License
Deshader is licensed under the [GPL-3.0](https://www.gnu.org/licenses/gpl-3.0.html) license. See [LICENSE](LICENSE) for more information.

If Deshader saved some of your time, you can leave a comment in the [discussions](https://github.com/OSDVF/deshader/discussions) or [star](https://github.com/OSDVF/deshader/star) the repo.