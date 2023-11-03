const std = @import("std");
const positron = @import("positron");
const serve = @import("serve");
const websocket = @import("websocket");

const common = @import("common.zig");
const logging = @import("log.zig");
const DeshaderLog = logging.DeshaderLog;
const main = @import("main.zig");
const editor = @import("tools/editor.zig");

const String = []const u8;
const Tuple = std.meta.Tuple;
const Route = positron.Provider.Route;

pub const CommandListener = struct {
    const ArgumentsList = std.StringHashMap(String);
    const settings = struct {
        var log_into_responses = false;
    };

    // various command providers
    http: *positron.Provider,

    pub fn start(allocator: std.mem.Allocator, http_port: ?u16, ws_port: ?u16) !*@This() {
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);

        if (ws_port != null) {
            const websocket_thread = try std.Thread.spawn(
                .{},
                struct {
                    fn listen(alloc: std.mem.Allocator, port: u16) void {
                        websocket.listen(WSHandler, alloc, void, .{
                            .port = port,
                            .max_headers = 10,
                            .address = "127.0.0.1",
                        }) catch |err| {
                            DeshaderLog.err("Error while listening for websocket commands: {any}", .{err});
                        };
                    }
                }.listen,
                .{ allocator, ws_port.? },
            );
            try websocket_thread.setName("CmdListWS");
            websocket_thread.detach();
        }

        if (http_port != null) {
            self.http = try positron.Provider.create(allocator, http_port.?);
            errdefer self.http.destroy();
            self.http.not_found_text = "Unknown command";

            inline for (@typeInfo(commands.simple).Struct.decls) |function| {
                const command = @field(commands.simple, function.name);
                const return_type = @typeInfo(@TypeOf(command)).Fn.return_type.?;
                const error_union = @typeInfo(return_type).ErrorUnion;
                _ = try self.addHTTPCommand(error_union.error_set, error_union.payload, .{ "/" ++ function.name, command });
            }
            const provide_thread = try std.Thread.spawn(.{}, struct {
                fn wrapper(provider: *positron.Provider) void {
                    provider.run() catch |err| {
                        DeshaderLog.err("Error while providing HTTP commands: {any}", .{err});
                    };
                }
            }.wrapper, .{self.http});
            try provide_thread.setName("CmdListHTTP");
            provide_thread.detach();
        }
        return self;
    }

    fn argsFromUri(allocator: std.mem.Allocator, query: String) !ArgumentsList {
        var list = ArgumentsList.init(allocator);
        var iterator = std.mem.splitScalar(u8, query, '&');
        while (iterator.next()) |arg| {
            var arg_iterator = std.mem.splitScalar(u8, arg, '=');
            const key = arg_iterator.first();
            const value = arg_iterator.rest();
            try list.put(key, value);
        }
        return list;
    }

    //
    // Implement various command backends
    //

    // A command that returns a string or a generic type that will be JSON-strinigified
    pub fn addHTTPCommand(self: *@This(), comptime errtype: type, comptime returntype: type, command: anytype) !*@This() {
        const parameter_wise = Tuple(&.{
            String,
            *const fn (?ArgumentsList, String) errtype!returntype,
        });
        _ = parameter_wise;
        const route = try self.http.addRoute(command[0]);
        const command_route = struct {
            var comm: @TypeOf(command) = undefined;
            var writer: serve.HttpResponse.Writer = undefined;
            fn log(level: std.log.Level, scope: String, message: String) void {
                const result = std.fmt.allocPrint(common.allocator, "{s} ({s}): {s}", .{ scope, @tagName(level), message }) catch return;
                defer common.allocator.free(result);
                writer.writeAll(result) catch |err| {
                    var listener_was_set = false;
                    if (logging.log_listener == log) {
                        logging.log_listener = null;
                        listener_was_set = true;
                    }
                    defer if (listener_was_set) {
                        logging.log_listener = log;
                    };
                    DeshaderLog.err("Error while logging into response: {any}", .{err});
                };
            }

            fn wrapper(provider: *positron.Provider, route2: *Route, context: *serve.HttpContext) Route.Error!void {
                _ = route2;

                if (settings.log_into_responses) {
                    writer = try context.response.writer();
                    logging.log_listener = log;
                } else {
                    logging.log_listener = null;
                }
                if (comm[1]()) |result| {
                    switch (returntype) {
                        void => {},
                        String => {
                            if (!settings.log_into_responses) {
                                try context.response.setStatusCode(.accepted);
                                writer = try context.response.writer();
                            }
                            try writer.writeAll(result);
                            try writer.writeByte('\n'); //Alwys add a newline to the end
                        },
                        serve.HttpStatusCode => try context.response.setStatusCode(result),
                        else => {
                            if (!settings.log_into_responses) {
                                try context.response.setStatusCode(.accepted);
                                writer = try context.response.writer();
                            }
                            const json = try std.json.stringifyAlloc(provider.allocator, result, .{ .whitespace = .minified });
                            defer provider.allocator.free(json);
                            try writer.writeAll(json);
                            try writer.writeByte('\n'); //Alwys add a newline to the end
                        },
                    }
                } else |err| {
                    if (@TypeOf(err) == Route.Error) { // TODO: does this really check if the error is one of the target union?
                        return err;
                    }
                    if (!settings.log_into_responses) {
                        try context.response.setStatusCode(.internal_server_error);
                        writer = try context.response.writer();
                    }

                    const result = try std.fmt.allocPrint(provider.allocator, "Error while executing command {s}: {any}", .{ comm[0], err });
                    defer provider.allocator.free(result);
                    DeshaderLog.err("{s}", .{result});
                    try writer.writeAll(result);
                    try writer.writeByte('\n'); //Alwys add a newline to the end
                }
            }
        };
        command_route.comm = command;
        route.handler = command_route.wrapper;
        errdefer route.deinit();
        return self;
    }

    const ws_commands = blk: {
        const decls = @typeInfo(commands.simple).Struct.decls;
        comptime var command_array: [decls.len]std.meta.Tuple(&.{ String, *const fn (self: *WSHandler, args: ?ArgumentsList, body: String) anyerror!void }) = undefined;
        inline for (decls, 0..) |function, i| {
            const command = @field(commands.simple, function.name);
            //const error_union = @typeInfo(return_type).ErrorUnion;
            command_array[i] = .{
                function.name,
                &struct {
                    var http_code_buffer: [3]u8 = undefined;
                    fn wrap(comptime inner: anytype) type {
                        return struct {
                            fn wrapped(self: *WSHandler, args: ?ArgumentsList, body: String) !void {
                                const accepted = "202: Accepted\n";
                                const arguments = @typeInfo(@TypeOf(inner)).Fn.params;
                                if (switch (arguments.len) {
                                    0 => inner(),
                                    1 => inner(args),
                                    else => inner(args, body),
                                }) |result| {
                                    switch (@TypeOf(result)) {
                                        void => try self.conn.writeText(accepted),
                                        String => {
                                            try self.conn.writeAllFrame(.text, &.{ accepted, result, "\n" });
                                        },
                                        serve.HttpStatusCode => |code| {
                                            try self.conn.writeAllFrame(.text, &.{ try std.fmt.bufPrint(http_code_buffer, "{d}", .{code}), ": ", @tagName(result), "\n" });
                                        },
                                        else => {
                                            const json = try std.json.stringifyAlloc(common.allocator, result, .{ .whitespace = .minified });
                                            defer common.allocator.free(json);
                                            try self.conn.writeAllFrame(.text, &.{ accepted, json, "\n" });
                                        },
                                    }
                                } else |err| {
                                    try self.conn.writeText(try std.fmt.allocPrint(common.allocator, "Error: {any}", .{err}));
                                }
                            }
                        };
                    }
                }.wrap(command).wrapped,
            };
        }
        var map = std.ComptimeStringMap(@TypeOf(command_array[0][1]), command_array);
        break :blk map;
    };

    const WSHandler = struct {
        conn: *websocket.Conn,

        const Conn = websocket.Conn;
        const Message = websocket.Message;
        const Handshake = websocket.Handshake;

        pub fn init(h: Handshake, conn: *Conn, comptime _: type) !@This() {
            // the last parameter is a `context` which we don't need
            // `h` contains the initial websocket "handshake" request
            // It can be used to apply application-specific logic to verify / allow
            // the connection (e.g. valid url, query string parameters, or headers)

            _ = h; // we're not using this in our simple case

            return @This(){
                .conn = conn,
            };
        }

        pub fn handle(self: *@This(), message: Message) !void {
            errdefer |err| {
                DeshaderLog.err("Error while handling websocket command: {any}", .{err});
                DeshaderLog.debug("Message: {any}", .{message.data});
                self.conn.writeText(std.fmt.allocPrint(common.allocator, "Error: {any}", .{err}) catch "Error") catch |er| DeshaderLog.err("Error while writing error: {any}", .{er});
            }
            var iterator = std.mem.splitScalar(u8, message.data, 0);
            var args = iterator.first();
            if (args[args.len - 1] == '\n') {
                args = args[0 .. args.len - 1];
            }
            const body = iterator.rest();

            var command_query = std.mem.splitScalar(u8, args, '?');
            const command = command_query.first();
            const query = command_query.rest();
            var parsed_args: ?ArgumentsList = if (query.len > 0) try argsFromUri(common.allocator, query) else null;
            defer if (parsed_args != null) parsed_args.?.deinit();

            const target_command = ws_commands.get(command);
            if (target_command == null) {
                try self.conn.writeText("404: Command not found\n");
                return;
            }
            try target_command.?(self, parsed_args, body);
        }

        // optional hooks
        pub fn afterInit(_: *WSHandler) !void {}
        pub fn close(_: *WSHandler) void {}
    };
};

pub const commands = struct {
    const simple = struct {
        pub fn version() !String {
            return "dev";
        }

        pub fn editorWindowShow() !u8 {
            return main.editorWindowShow();
        }

        pub fn editorWindowTerminate() !u8 {
            return main.editorWindowTerminate();
        }

        pub fn editorServerStart() !void {
            return editor.editorServerStart();
        }

        pub fn editorServerStop() !void {
            return editor.editorServerStop();
        }
    };
};
