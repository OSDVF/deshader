# Commands
Deshader can be controlled from the host application code using the [API](API.md) or remotely.

## Remote control
When Deshader is injected into an application it exposes a side-channel for remote control. The commands can be sent over HTTP or WebSocket protocols.

`curl` and `websocat` utilities can be used to test the command servers.

### HTTP Command Server
Default port is `8081`.
```sh
curl http://127.0.0.1:8081/version
```
Should reply with the currently checked out commit or tag.

### Websocket Command Server
Default port is `8082`.
```sh
websocat --no-fixups ws://127.0.0.1:8082
```
will create a~persistent connection to the command server. Type each command on a~new line and press Enter.
```sh
version
```
Should reply with
```
202: Accepted
[current commit]
```

All commands are passed URL-encoded with arguments as query parameters (`?query=strig&after=the&url=path`).
- If the command name does not exist, 404 error is returned
- If the command was *called* successully, 202 is returned
- Each command can have a different way of telling if it was *executed* successfully
- With WebSocket provider the commands return HTTP status codes as the first line in their response
- Response payloads can be `void`, `string`, `string[]` (multiple lines) or `JSON`

## Parameter types
- `false` the parameter is not present or has `false` value
- `true` the parameter is present or has `true` value
- `string` the parameter is present and has any value

# Commands List

Command | Parameters                                                   | Returns/Description
--------|--------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------
help    |                                                              | List all possible command names
list    | path:`string`, recursive:`bool(true)`, physical:`bool(true)` | `string[]` List all tagged and untagged programs and shaders found in the application, all files in the mapped workspace
version |                                                              | `string` Deshader library version

[^1]: Include all detected shaders or only tagged ones (with `deshaderTag...(...)`)