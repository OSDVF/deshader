# Debugging Shaders using GUI

## Launcher Tool
When Launcher is started without arguments, it will show Deshader Editor (based on VSCode), which can be used to connect to a running Deshader-injected program.
```sh
deshader-run
```
To inject Deshader into a program, do
```sh
deshader-run ./your-program
```
or use the (Renderdoc-like) GUI helper to select your application and show the Editor window automatically
```sh
deshader-run -g
```

### Launcher Features
- configuring Deshader Library before injecting into a program
- embedded Deshader Editor (VSCode)
- daemon mode (for viewing Deshader Editor in a web browser)

Refer to `deshader-run --help` for the most precise information.


## Using VSCode and the extension
You can install `deshader-vscode` extension to any VSCode instance to use Deshader features. 

The extension uses Deshader Launcher or at least the Deshader Library internally, so you need to have it installed. You can install them system-wide or specify the path to them in the extension settings (`deshader.launcher` and `deshader.path`).
