# Commands

All commands passed as URL-encoded query strings coming after the command name.
## Parameter types
- `false` the parameter is not present or has `false` value
- `true` the parameter is present or has `true` value
- `string` the parameter is present and has any value

Command               | Parameters             | Description
----------------------|------------------------|---------------------------------------------------------------------------
editorServerStart     |                        | Start serving VSCode editor at port `DESHADER_PORT` or default `8080`. Open with a web browser.
editorServerStop      |                        | Stop serving VSCode editor
editorWindowShow      |                        | Show embedded web browser viewing VSCode editor
editorWindowTerminate |                        |
listShaders           | annotated=`true/false` | List all shaders found in the application
version               |                        | Return Deshader version string