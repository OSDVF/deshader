# Debugging Shaders using GUI

## From VSCode


## Launcher Tool
When Launcher is started without arguments, it will show a GUI for starting an application with Deshader injected.
```sh
./zig-out/bin/deshader-run
```

### Integrated Editor
VSCode GUI can be shown by setting the `DESHADER_GUI` environment variable to `1` before running the application, or by sending the `editorWindowShow` command to the [command server](Commands.md). Alternatively `editorServerStart` can be used to start the GUI server and open the editor in a web browser (default port is `8080`).
