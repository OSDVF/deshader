# Settings
## Environment variables
Runtime settings can be specified by environment variables.
All names start with DESHADER_ prefix e.g. `DESHADER_PORT`
### Deshader Launcher
Name      | Default                                                   | Description
----------|-----------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
LIB_ROOT  | `/usr/lib` / `C:\Windows\System32`                        | Override the default path to the folder where the original libraries are located
LIB       | \[app work dir\]/`libdeshader.so`/`.dylib`/`deshader.dll` | Directory/complete path to Deshader library. If the laucher does not succeed in finding the library and it was started with the GUI, it will show an open dialog to select the library
HOOK_LIBS | none                                                      | Set to colon-separated list of **additional** libraries to replace with Deshader library (defaults always included)
LSP       | ws://127.0.0.1:8083                                       | Host and port for GLSL Language Server (based on [glsl_analyzer](https://github.com/nolanderc/glsl_analyzer/)) WebSocket. Pass empty string to disable.
GUI       | none                                                      | Pass `true` or `1` to show the editor window on startup. Pass `hidden` to only start the editor server
GUI_URL   | reserved                                                  | Used internally as a startup URL for embedded Editor
### Deshader library
Name              | Default                            | Description
------------------|------------------------------------|---------------------------------------------------------------------------------------------------------------------------
LIB_ROOT          | `/usr/lib` / `C:\Windows\System32` | **REQUIRED** and automatically set by the Launcher. Path to the folder where the original libraries are located
PORT              | 8080                               | Port for the web editor at `http://localhost:DESHADER_PORT/index.html`
START_SERVER      | none                               | Pass `true` or `1` to start the editor server on startup
COMMANDS          | ws://127.0.0.1:8082                | Protocol, host and port of the main command server (HTTP or WebSocket)
COMMANDS_HTTP     | none                               | Host and port for secondary HTTP commands server
COMMANDS_WS       | 127.0.0.1:8082                     | Host and port for secondary WebSocket commands server
GL_LIBS           | platform-specific                  | Paths to libraries from which the original GL functions will be loaded
GL_PROC_LOADERS   | none                               | Specify additional lodader functions that will be called to retrieve GL function pointers[^1][^2]
SUBSTITUTE_LOADER | `false`                            | Specify `1`, `yes` or `true` for calling `DESHADER_GL_PROC_LOADERS` instead of standard GL loader functions internally[^3]
HOOKED            | reserved                           | Do not set this variable. IT is used by Deshader internally as a flag of already hooked app
IGNORE_PROCESS    | none                               | Process name postfixes that won't be intercepted. For example `gdb,sh,bash,zsh,code,llvm-symbolizer`[^1]
PROCESS           | none                               | Process name postfixes that will be intercepted. If set, `DESHADER_IGNORE_PROCESS` is ignored.[^1]

[^1]: Should be a colon-separated list.
[^2]: The first found function will be used.
[^3]: In this case `DESHADER_GL_PROC_LOADERS` must be a single function. Does not work on Mac OS.

# Build Options
Specify options as `-Doption=value` to `zig build` commands. See also `zig build --help`.  
Boolean options can be set to true using `-Doption=true` or `-Doption`.

**NOTE**: Options must be specified when compiling both Deshader (`deshader-lib`/`deshader`) and Launcher (`Launcher`).
Name              | Values                                           | Description
------------------|--------------------------------------------------|-------------------------------------------------------------------------------------------------------
`target`, `cpu`   | See `zig targets`                                | Specify target architecture and CPU
`dynamic-linker`  |                                                  | Path to interpreter on the target system
`editor`          | `true` (default), `false`                        | Embed VSCode into Deshader. Otherwise external editor must be used. Can save 4MB in `--release=small`.
`glProfile`       | `core`, `compatibility`, `common`, `common_lite` |
`ignoreMissing`   | `true`, `false` (default)                        | Do not fail compilation when a graphics library is not found
`libDebug`        | `true`, `false`                                  | Include debug information in VCPKG libraries
`libAssert`       | `true`, `false`                                  | Include assertions in VCPKG libraries (implicit for debug and release safe)
`linkage`         | `Static`, `Dynamic` (default)                    | Select type of Deshader library
`logLevel`        | `err`, `warn`, `info`, `debug`, `default`        | Override log level
`logInterception` | `true`, `false` (default)                        | Enable logging of intercepted GL procedure requests
`memoryFrames`    | number (default 7)                               | Number of frames in memory analysis backtrace.
`ofmt`            | `Default`, `c`, `IR`, `BC`                       | Specify output format for Zig compiler
`sanitize`        | `true`, `false`                                  | Enable sanitizers (implicit for debug mode)
`sdk`             |                                                  | SDK path (macOS only, defaults to the one selected by xcode-select)
`sGLSLang`        | `true`, `false`                                  | Force usage of system-supplied GLSLang library (VCPKG has priority otherwise)
`sGLFW3`          | `true`, `false`                                  | Force usage of system-supplied GLFW3 library (VCPKG has priority otherwise)
`sGLEW`           | `true`, `false`                                  | Force usage of system-supplied GLEW library (VCPKG has priority otherwise)
`sNFD`            | `true`, `false`                                  | Force usage of system-supplied native-file-dialogs library (VCPKG has priority otherwise)
`sWolfSSL`        | `true`, `false`                                  | Force usage of system-supplied WolfSSL library (VCPKG has priority otherwise)
`stackCheck`      | `true`, `false`                                  | Enable stack checking (implicit for debug mode, not supported for Windows, ARM)
`stackProtector`  | `true`, `false`                                  | Enable stack protector (implicit for debug mode)
`strip`           | `true`, `false`                                  | Strip debug symbols from the library (implicit for release fast and minimal mode)
`traces`          | `true`, `false`                                  | Enable error traces (implicit for debug mode)
`triplet`         | `true`, `false`                                  | VCPKG triplet to use for dependencies
`unwind`          | `true`, `false`                                  | Enable unwind tables (implicit for debug mode)
`valgrind`        | `true`, `false`                                  | Enable valgrind support (implicit for debug mode, not supported for macos, ARM, and msvc target)
 
## Production Build
- Add `--release` to `zig build` commands
    - `--release=small` will disable debug and info meassages
    - `--release=safe` will will enable info meassages
    - `--release=off` (default) will include debug, info, warning and error meassages. **Editor GUI will not be embedded into Deshader but loaded from the source tree at runtime**