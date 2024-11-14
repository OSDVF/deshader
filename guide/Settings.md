# Settings
## Environment variables
Runtime settings can be specified by environment variables.
All names start with DESHADER_ prefix e.g. `DESHADER_PORT`
### Deshader Launcher
Name      | Default                                                   | Description
----------|-----------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
LIB_ROOT  | `/usr/lib` / `C:\Windows\System32`                        | Override the default path to the folder where the original libraries are located
LIB       | \[app work dir\]/`libdeshader.so`/`.dylib`/`deshader.dll` | Directory/complete path to Deshader library. If the laucher does not succeed in finding the library and it was started with the GUI, it will show an open dialog to select the library
HOOK_LIBS | none                                                      | Set to comma separated list of **additional** libraries to replace with Deshader library (defaults always included)
### Deshader library
Name              | Default                            | Description
------------------|------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------
LIB_ROOT          | `/usr/lib` / `C:\Windows\System32` | **REQUIRED** and automatically set by the Launcher. Path to the folder where the original libraries are located
GUI               | none                               | Pass `true` or `1` to show the editor window on startup
PORT              | 8080                               | Port for the web editor at `http://localhost:DESHADER_PORT/index.html`
START_SERVER      | none                               | Pass `true` or `1` to start the editor server on startup
COMMANDS_HTTP     | none                               | Port for HTTP server listening to Deshader commands
COMMANDS_WS       | 8082                               | Port for WebSocket server listening to Deshader commands (disabled by default)
LSP               | none                               | Port for GLSL Language Server (based on [glsl_analyzer](https://github.com/nolanderc/glsl_analyzer/)) WebSocket
GL_LIBS            | platform-specific                 | Paths to libraries from which the original GL functions will be loaded
GL_PROC_LOADERS   | none                               | Specify additional lodader functions that will be called to retrieve GL function pointers[^1]
SUBSTITUTE_LOADER | `false`                            | Specify `1`, `yes` or `true` for calling `DESHADER_GL_PROC_LOADERS` instead of standard GL loader functions internally[^2]
HOOKED            | reserved                           | Do not set this variable. IT is used by Deshader internally as a flag of already hooked app
EDITOR_URL        | reserved                           | Used internally as a startup URL for embedded Editor
EDITOR_SHOWN      | reserved                           |
IGNORE_PROCESS    | none                               | Comma separated list of process name postfixes that won't be intercepted. You may need to ignore `gdb,sh,bash,zsh,code,llvm-symbolizer`
PROCESS           | none                               | Comma separated list of process name postfixes that will be intercepted. If set, `DESHADER_IGNORE_PROCESS` is ignored.

[^1]: Should be a comma separated list. The first found function will be used.
[^2]: In this case `DESHADER_GL_PROC_LOADERS` must be a single function. Does not work on Mac OS.

# Build Options
Specify options as `-Doption=value` to `zig build` commands. See also `zig build --help`.  
Boolean options can be set to true using `-Doption=true` or `-Doption`.

**NOTE**: Options must be specified when compiling both Deshader (`deshader-lib`/`deshader`) and Launcher (`Launcher`).
Name           | Values                        | Description
---------------|-------------------------------|---------------------------------------------------------------------------------------------------
`linkage`      | `Static`, `Dynamic` (default) | Select type of for Deshader library
`wolfSSL`      | `true`, `false` (default)     | Link with system or VCPKG provided WolfSSL instead of compiling it from source
`logIntercept` | `true`, `false` (default)     | Enable logging of intercepted GL (not on Mac) procedure requests
`editor`       | `true` (default), `false`     | Embed VSCode into Deshader. Otherwise external editor must be used. Can save 4MB in release=small.
`glAddLoader`  | any string                    | Specify a single additional function name that will be exported and intercepted
 
## Production Build
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