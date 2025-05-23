# Deshader 🔦
Shaders are often shiny but sometimes also shady, fishy and stinky!
> What if I could just step-debug that shader as I do with my CPU programs?

Now you can, and in your favorite code editor[^1]!
Deshader intercepts OpenGL calls and adds instrumentation code to your shaders (so you don't need to write your own visualizations to debug shader execution process anymore).

[^1]: VSCode derivatives and the standalone Deshader Editor is supported for now.

# (Un)Implemented Features
- [x] Step through the shader execution (...breakpoints, logging, conditional bps...)
- [x] Arrange shaders in a virtual filesystem
- [x] Support for named strings / `#include` header files
- [x] Open the integrated editor (VSCode in a separate window or in your browser - at `localhost:8080/index.html` by default)
- [ ] Track variable values for different output primitives and pixels
- [x] Runs on Linux, Windows and MacOS

# Goals
- Compatibility between OpenGL vendor implementations (ICDs)
- Flexibility
- Broader API support than [GLIntercept](https://github.com/dtrebilco/glintercept), different features than [ApiTrace](https://github.com/apitrace/apitrace)

## Non-goals
...and some dead ends, which have been encountered.
- Debugging other languages than GLSL (feel free to fork and add your own language)
- Vendor API/ISA level debugging
- Assembly (ISA) or pseudo-assembly (SPIR-V) level debugging
- Profiling
- [Custom WebView profile data directory](https://github.com/webview/webview/issues/719)
- Cross compilation for macOS

## Possible future goals
- View assembly
    - SPIR-V (compile by GLSLang)
    - ISA level ([nvdisasm](https://developer.download.nvidia.com/compute/cuda/redist/cuda_nvdisasm/), [nvcachetools](https://github.com/therontarigo/nvcachetools), [envytools](https://github.com/envytools/envytools/))
- Vulkan support
- Profiling
- Validation
- Modular instrumentation API

Feel free to fork and add your own goals or even better, break the non-goals!

# Installation
### Prebuilt packages
[![packages](https://github.com/OSDVF/deshader/actions/workflows/packages.yml/badge.svg?event=push)](https://github.com/OSDVF/deshader/actions/workflows/packages.yml)
[Packages for macOS, Debian-like, Arch Linux and Windows are in the releases section.](https://github.com/OSDVF/deshader/releases)

### Arch Linux (AUR)
Download and install using an AUR helper. 
Zig 0.14 is not currently available in the Arch Linux repositories, so it must be also installed from the AUR before. For example:
```bash
yay -S zig-bin deshader-git
```
or
```bash
pamac build zig-bin deshader-git
```
### Build and packaging scripts
[Build scripts for Debian-like and Arch Linux reside in a separate repository](https://github.com/OSDVF/deshader-build).

## Usage
Display the Launcher GUI:
```bash
deshader-run
```
Advanced instructions are contained in [Deshader Manual](./guide/README.md).

# Build
## Components

Deshader consists of several (mostly third party; mostly forked) components that require different dev stacks and frameworks. Some of them are installed as git submodules or as Zig dependencies.

- Deshader Launcher
    - [/src/launcher/launcher.zig](/src/launcher/launcher.zig)
- Deshader library
    - [/src/](/src/)
    - [Web View (WebKit2Gtk)](https://github.com/ziglibs/positron) at [/libs/positron/](/libs/positron/) (MIT)
    - Example applications
        - [/examples/](/examples/)
    - Fork of [GLSL Analyzer](https://github.com/nolanderc/glsl_analyzer) at [/libs/glsl_analyzer/](/libs/glsl_analyzer/) (GPL-3.0)
- Deshader VSCode extension
    - [/editor/deshader-vscode/](/editor/deshader-vscode/) (MIT)
    - With node.js packages
    - Managed by **Bun**
- A distribution of [Visual Studio Code for web](https://github.com/Felx-B/vscode-web) (MIT)
    - [/editor/](/editor/)
    - With node.js packages
    - Managed by **Bun**

## Requirements
- [Zig 0.14](https://ziglang.org/) (MIT)
- Bun 1.2.8 [Install](https://github.com/oven-sh/bun#install) (MIT)
- [VCPKG](https://vcpkg.io) (MIT)
    - Make sure you are [using the latest version](https://github.com/microsoft/vcpkg/issues/15417)
    - VCPKG may download another dependencies, such as `pwsh` on Windows, `cmake`... 
- C libraries
    - Linux
        - gtk-3 (LGPL-2.1) and webkit2gtk 4.0-4.1 (BSD, LGPL-2.1)
    - Windows
        - [Edge Dev Channel](https://www.microsoftedgeinsider.com/download)
        - WebView2 runtime
    - *Cross-compilation* under Linux
        - for Windows
            - install Wine
            - add VCPKG path to `~/.local/share/vcpkg/vcpkg.path.txt` (e.g. `echo $(which vcpkg) > ~/.local/share/vcpkg/vcpkg.path.txt`)
            - [Edge Dev Channel](https://www.microsoftedgeinsider.com/download) installed by offline installer
            - WebView2 runtime must be installed by [standalone installer](https://developer.microsoft.com/en-us/microsoft-edge/webview2#download) (not bootstraper) under Wine
            - `zig build deshader -fwine -Dtarget=x86_64-windows`
            - **NOTES**
                - DLL interception does not work for OpenGL under Wine. Intercept on host side instead (however this does not really work for now)

- Building __examples__ requires [Vulkan SDK](https://vulkan.lunarg.com/sdk/home) ([mixed licenses...](https://vulkan.lunarg.com/license/)) (for GLFW)
- for Linux and macOS:
    - `pkg-config`
    - `ld` from `binutils` package
- for Windows (installable by [Visual Studio Installer](https://visualstudio.microsoft.com/downloads/)):
    - Build Tools
- Examples on macOS require `gcc`

## Building from source
After you install all the required frameworks, clone this repository with submodules, open terminal in its folder and create a debug build by
```sh
git clone --recurse-submodules https://github.com/OSDVF/deshader # git submodule update --init --recursive # if you cloned non-recursively
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
If Launcher is not able to find Deshader library, you can specify it in environment variable:
```sh
DESHADER_LIB=zig-out/lib/libdeshader.so deshader-run
```

Deshader and its build process support some [configuraiton options](guide/Settings.md).

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
```sh
DYLD_INSERT_LIBRARIES=./zig-out/lib/libdeshader.dylib your_application
```

## Frequently Seen Build Errors
- Cannot compile
    - Something with `struct_XSTAT` inside WolfSSL
        - fix by `powershell .\fix_c_import.sh` or `./fix_c_import.ps1` and build again
        **CAUTION**: The script searches the whole `zls` global cache in `~/.cache/zls` and deletes lines with `struct_XSTAT` so be careful.
- Segmentation fault at when starting application from Launcher GUI
    - Check if Launcher is build with the same tracing and release options as Deshader
- Editor window is blank
    - This is a known issue between WebKit and vendor GL drivers
    - Disable GPU acceleration
        - Set environment variable `WEBKIT_DISABLE_COMPOSITING_MODE=1`
    - Or select a different GPU
        - by setting `__GLX_VENDOR_LIBRARY_NAME=nvidia __NV_PRIME_RENDER_OFFLOAD=1`
        - or `DRI_PRIME=1`

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

  - `vcpkg install --triplet=x(86/64)-[os](-zig) --x-install-root=build/vcpkg_installed`
  - Rename `.dll.a` -> `.lib` in `build/vcpkg_installed/*/lib`

### Zig dependencies
Some of the dependencies are managed as git submodules, other are specified in `build.zig.zon`. `zig build` without additonal target name will only download Zig-managed dependencies.

### Build Outputs

Output files will be placed at `./zig-out/`:
- `bin/`
    - `deshader-run`
    - (internal tools)
        - `generate_headers`
        - `generate_stubs`
    - `deshader-examples-all`
    - `deshader-examples/`
        - `quad`
        - `editor`
        - `quad_cpp`
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

### Development Environment
#### VSCode
- Follow extension recommendations in `.vscode/extensions.json`.
- Add this to your `keybindings.json` to automate [ZLint](https://github.com/DonIsaac/zlint):
```json
{
    "command": "runCommands",
    "key": "ctrl+s", 
    "args": {
      "commands": [
        "workbench.action.files.save",
        "zig.zlint.lint"
      ]
    },
    "when": "resourceLangId == zig"
  }
```
# License
Deshader is licensed under the [GPL-3.0](https://www.gnu.org/licenses/gpl-3.0.html) license. See [LICENSE](LICENSE.md) for more information.  
This repository also contains third-party software, which is licensed under their respective licenses. See [NOTICES](NOTICES.md) for more information.

If Deshader saved some of your time, you can leave a comment in the [discussions](https://github.com/OSDVF/deshader/discussions) or [star](https://github.com/OSDVF/deshader/star) the repo.

And promise me you won't use the time saved by using Deshader to do more work, but to do more living instead.