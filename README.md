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
- [Visual Studio Code for Web distribution](https://github.com/Felx-B/vscode-web) (MIT)
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
- GNU Make and .NET Core for generating OpenGL bindings
- [VCPKG](https://vcpkg.io) (MIT)
- C libraries
    - Linux
        - gtk-3 (LGPL-2.1) and webkit2gtk (BSD, LGPL-2.1)
    - Windows
        - [Edge Dev Channel](https://www.microsoftedgeinsider.com/download)
        - WebView2 runtime
        - Bun under WSL
    - *Cross-compilation* under Linux
        - for Windows
            - add VCPKG path to `~/.local/share/vcpkg/vcpkg.path.txt` (e.g. `echo $(which vcpkg) > ~/.local/share/vcpkg/vcpkg.path.txt`)
            - [Edge Dev Channel](https://www.microsoftedgeinsider.com/download) installed by offline installer
            - WebView2 runtime must be installed by [standalone installer](https://developer.microsoft.com/en-us/microsoft-edge/webview2#download) (not bootstraper) under Wine
            - **NOTES**
                - Cross compiled Launcher is not compatible with Deshader compiled on Windows because there are inconsistencies between library names (`[lib]wolfssl`) 
                - DLL interception does not work for OpenGL under Wine. Intercept on host side instead (however this does not really work for now)
- For using CMake to compile C++ examples
    - `pkg-config`
    - `ld` from `binutils` package

## How to
After you install all the required frameworks, clone this repository with submodules, open terminal in its folder and create a debug build by
```sh
git clone --recurse-submodules https://github.com/OSDVF/deshader
cd deshader
zig build deshader
```
If that does not output any errors, it will autmatically
- Install Node.js dependencies
    - `bun install` inside `/editor/` and `/editor/deshader-vscode/`
- Compile Deshader VSCode Extension
    - `bun compile-dev` or `bun compile-prod` inside `/editor/deshader-vscode/`
- <details>
    <summary>Install VCPKG managed libraries (when target is Windows, or they are not present or system) and correct ther names (`.dll.a` -> `.lib`)</summary>

    GLEW, GLSLang, GLFW, WolfSSL, nativefiledialog
  </details>

- Build Deshader library

for you. If there weren't any errors, then you can then
```sh
# Build
zig build **launcher**

# Use Launcher tool
./zig-out/bin/deshader-run your_application

# Or display Launcher GUI
./zig-out/bin/deshader-run

# Or run & build all the provided examples one-by-one
zig build examples-run
```
If the Launcher is not able to find Deshader library, you can specify it
```sh
DESHADER_LIB=zig-out/lib/libdeshader.so
```

`zig build` will only download Zig-managed dependencies (specified in `build.zig.zon`).

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
    - `examples`
- `lib/`
    - (lib)deshader.[a|so|dll|lib|dylib]
    - (dependencies)
    - `wolfssl.dll`
    - `glslang.dll`

- `include/`
    - `deshader`
        - `commands.h`
        - `macros.h`
        - `deshader.h`
        - `deshader.hpp`
        - `deshader.zig`
        - `deshader_prefixed.zig`

The files inside `include/` are API definitions for use in your application.

### Without Launcher
#### Linux
```sh
DESHADER_LIB=your/lib/dir/libdeshader.so /your/app/dir/app # Loads Deshader into your application
```
#### Windows
```bat
copy path\to\deshader.dll your\app\dir\opengl32.dll
copy path\to\libwolfssl.dll your\app\dir
your\app\dir\app.exe
```

#### Mac OS
```sh
DYLD_INSERT_LIBRARIES=./zig-out/lib/libdeshader.dylib your_application
```

## Build Options
Specify options as `-Doption=value` to `zig build` commands. See also `zig build --help`.  
Boolean options can be set to true using `-Doption=true` or `-Doption`.

**NOTE**: Options must be specified when compiling both Deshader (`deshader-lib`/`deshader`) and Launcher (`Launcher`).
Name           | Values                        | Description
---------------|-------------------------------|--------------------------------------------------------------------------------------------------
`linkage`      | `Static`, `Dynamic` (default) | Select type of for Deshader library
`wolfSSL`      | `true`, `false` (default)     | Link with system or VCPKG provided WolfSSL instead of compiling it from source
`logIntercept` | `true`, `false` (default)     | Enable logging of intercepted GL (not on Mac) procedure requests
`editor`       | `true` (default), `false`     | Embed VSCode into Deshader. Otherwise external editor must be used. Can save 4MB in release=small.
`glAddLoader`  | any string                    | Specify a single additional function name that will be exported and intercepted
 
### Production Build
- Add `--release` to `zig build` commands
    - `--release=small` will disable debug and info meassages
    - `--release=safe` will will enable info meassages
    - `--release=off` (default) will include debug, info, warning and error meassages. **Editor GUI will not be embedded into Deshader but loaded from the source tree at runtime**

## Frequently Seen Errors
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


# Settings
## Environment variables
Runtime settings can be specified by environment variables.
All names start with DESHADER_ prefix e.g. `DESHADER_PORT`
### Deshader Launcher
Name      | Default                                                   | Description
----------|-----------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------
LIB_ROOT  | `/usr/lib` / `C:\Windows\System32`                        | Override the default path to the folder where the original libraries are located
LIB       | \[app work dir\]/`libdeshader.so`/`.dylib`/`deshader.dll` | Directory/complete path to Deshader library. If the laucher does not succeed in finding the library and it was started with the GUI, it will show an open dialog to select the library
HOOK_LIBS | value of `GL_LIBS`                                        | Set to comma separated list of **additional** libraries to replace with Deshader library (defaults always included)
### Deshader library
Name              | Default                                 | Description
------------------|-----------------------------------------|---------------------------------------------------------------------------------------------------------------------------
LIB_ROOT          | `/usr/lib` / `C:\Windows\System32`      | **REQUIRED** and automatically set by the Launcher. Path to the folder where the original libraries are located
GUI               | none                                    | Pass `true` or `1` to show the editor window on startup
PORT              | 8080                                    | Port for the web editor at `http://localhost:DESHADER_PORT/index.html`
START_SERVER      | none                                    | Pass `true` or `1` to start the editor server on startup	2300325930 / 2010
COMMANDS_HTTP     | none                                    | Port for HTTP server listening to Deshader commands
COMMANDS_WS       | 8082                                    | Port for WebSocket server listening to Deshader commands (disabled by default)
LSP               | none                                    | Port for GLSL Language Server (based on [glsl_analyzer](https://github.com/nolanderc/glsl_analyzer/)) WebSocket
GL_LIBS           | `libGLX.so, libEGL.so` / `opengl32.dll` | Path to libraries from which the original GL functions will be loaded
GL_PROC_LOADERS   | none                                    | Specify additional lodader functions that will be called to retrieve GL function pointers[^1]
SUBSTITUTE_LOADER | `false`                                 | Specify `1`, `yes` or `true` for calling `DESHADER_GL_PROC_LOADERS` instead of standard GL loader functions internally[^2]
HOOKED            | reserved                                | Do not set this variable. IT is used by Deshader internally as a flag of already hooked app
EDITOR_URL        | reserved                                | Used internally as a startup URL for embedded Editor
EDITOR_SHOWN      | reserved                                |
IGNORE_PROCESS    | none                                    | Comma separated list of process name postfixes that won't be intercepted. You may need to ignore `gdb,sh,bash,zsh,code,llvm-symbolizer`
PROCESS           | none                                    | Comma separated list of process name postfixes that will be intercepted. If set, `DESHADER_IGNORE_PROCESS` is ignored.

[^1]: Should be a comma separated list. The first found function will be used.
[^2]: In this case `DESHADER_GL_PROC_LOADERS` must be a single function. Does not work on Mac OS.

If Deshader saved some of your time, you can leave a comment in the [discussions](https://github.com/OSDVF/deshader/discussions) or [star](https://github.com/OSDVF/deshader/star) the repo.

# License
Deshader is licensed under the [GPL-3.0](https://www.gnu.org/licenses/gpl-3.0.html) license. See [LICENSE](LICENSE) for more information.