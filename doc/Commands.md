# Commands

All commands are passed URL-encoded with arguments as query parameters.
- If the command name does not exist, 404 error is returned
- If the command was *called* successully, 202 is returned
- Each command can have a different way of telling if it was *executed* successfully
- With WebSocket provider the commands return HTTP status codes as the first line in their response
- Response payloads can be `void`, `string`, `string[]` (multiple lines) or `JSON`
- Each response ends with a newline character `\n`

## Parameter types
- `false` the parameter is not present or has `false` value
- `true` the parameter is present or has `true` value
- `string` the parameter is present and has any value

Command               | Parameters             | Returns/Description
----------------------|------------------------|---------------------------------------------------------------------------
editorServerStart     |                        | \[`void`\] Start serving VSCode editor at port `DESHADER_PORT` or default `8080`. Open with a web browser.
editorServerStop      |                        | \[`void`\] Stop serving VSCode editor
editorWindowShow      |                        | \[`void`\] Show embedded web browser viewing VSCode editor
editorWindowTerminate |                        |
listShaders           | tagged=`true/false`[^1] | \[`string[]`\] List all shaders found in the application
version               |                        | \[`string`\] Deshader library version

[^1]: Include all detected shaders or only tagged ones (with `deshaderTag...(...)`)