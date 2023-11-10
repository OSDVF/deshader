const std = @import("std");
const positron = @import("positron");
const serve = @import("serve");
const websocket = @import("websocket");

const common = @import("common.zig");
const logging = @import("log.zig");
const DeshaderLog = logging.DeshaderLog;
const main = @import("main.zig");
const editor = @import("tools/editor.zig");
const shaders = @import("services/shaders.zig");

const String = []const u8;
const CString = [*:0]const u8;
const Tuple = std.meta.Tuple;
const Route = positron.Provider.Route;

pub const CommandListener = struct {
    const ArgumentsList = std.StringHashMap(String);
    pub const setting_vars = struct {
        pub var log_into_responses = false;
    };

    // various command providers
    http: ?*positron.Provider = null,
    ws: ?*websocket.Conn = null,
    provide_thread: ?std.Thread = null,
    websocket_thread: ?std.Thread = null,
    server_arena: std.heap.ArenaAllocator = undefined,
    provider_allocator: std.mem.Allocator = undefined,

    pub fn start(allocator: std.mem.Allocator, http_port: ?u16, ws_port: ?u16) !*@This() {
        const self = try allocator.create(@This());
        self.* = @This(){}; // zero out the struct
        errdefer allocator.destroy(self);

        self.server_arena = std.heap.ArenaAllocator.init(allocator);
        if (ws_port != null) {
            self.websocket_thread = try std.Thread.spawn(
                .{},
                struct {
                    fn listen(list: *CommandListener, alloc: std.mem.Allocator, port: u16) void {
                        websocket.listen(WSHandler, alloc, list, .{
                            .port = port,
                            .max_headers = 10,
                            .address = "127.0.0.1",
                        }) catch |err| {
                            DeshaderLog.err("Error while listening for websocket commands: {any}", .{err});
                        };
                    }
                }.listen,
                .{ self, self.server_arena.allocator(), ws_port.? },
            );
            try self.websocket_thread.?.setName("CmdListWS");
        }

        if (http_port != null) {
            self.provider_allocator = self.server_arena.allocator();
            self.http = try positron.Provider.create(self.provider_allocator, http_port.?);
            errdefer self.http.?.destroy();
            self.http.?.not_found_text = "Unknown command";

            inline for (@typeInfo(commands.simple).Struct.decls) |function| {
                const command = @field(commands.simple, function.name);
                _ = try self.addHTTPCommand("/" ++ function.name, command);
            }
            self.provide_thread = try std.Thread.spawn(.{}, struct {
                fn wrapper(provider: *positron.Provider) void {
                    provider.run() catch |err| {
                        DeshaderLog.err("Error while providing HTTP commands: {any}", .{err});
                    };
                }
            }.wrapper, .{self.http.?});
            try self.provide_thread.?.setName("CmdListHTTP");
        }
        return self;
    }

    pub fn stop(self: *@This()) void {
        if (self.http != null) {
            self.http.?.destroy();
            self.provide_thread.?.join();
            self.provider_allocator.destroy(self.http.?);
        }
        if (self.ws != null) {
            self.ws.?.writeText("432: Closing connection\n") catch {};
            self.ws.?.writeClose() catch {};
            self.ws.?.close();
            self.websocket_thread.?.detach();
        }
        self.server_arena.deinit();
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
    pub fn addHTTPCommand(self: *@This(), comptime name: String, command: anytype) !*@This() {
        const route = try self.http.?.addRoute(name);
        const command_route = struct {
            var comm: *const @TypeOf(command) = undefined;
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

            fn parseArgs(allocator: std.mem.Allocator, uri: String) !?ArgumentsList {
                const command_query = std.mem.splitScalar(u8, uri, '?');
                const query = command_query.rest();
                return if (query.len > 0) try argsFromUri(allocator, query) else null;
            }

            fn wrapper(provider: *positron.Provider, route2: *Route, context: *serve.HttpContext) Route.Error!void {
                _ = route2;

                if (setting_vars.log_into_responses) {
                    writer = try context.response.writer();
                    logging.log_listener = log;
                } else {
                    logging.log_listener = null;
                }
                const return_type = @typeInfo(@TypeOf(command)).Fn.return_type.?;
                const error_union = @typeInfo(return_type).ErrorUnion;

                if (switch (@typeInfo(@TypeOf(command)).Fn.params.len) {
                    0 => comm(),
                    1 => blk: {
                        var args = try parseArgs(provider.allocator, context.request.url);
                        defer if (args != null) args.?.deinit();
                        break :blk comm(args);
                    },
                    2 => blk: {
                        var args = try parseArgs(provider.allocator, context.request.url);
                        defer if (args != null) args.?.deinit();
                        var reader = try context.request.reader();
                        defer reader.deinit();
                        const body = try reader.readAllAlloc(provider.allocator);
                        defer provider.allocator.free(body);
                        break :blk comm(args, body);
                    },
                    else => @compileError("Command " ++ @typeName(comm) ++ " has invalid number of arguments. Only none, parameters and body are available."),
                }) |result| { //swith on result of running the command
                    switch (error_union.payload) {
                        void => {},
                        String => {
                            defer common.allocator.free(result);
                            if (!setting_vars.log_into_responses) {
                                try context.response.setStatusCode(.accepted);
                                writer = try context.response.writer();
                            }
                            try writer.writeAll(result);
                            try writer.writeByte('\n'); //Alwys add a newline to the end
                        },
                        []const String => {
                            defer for (result) |line| common.allocator.free(line);
                            defer common.allocator.free(result);
                            if (!setting_vars.log_into_responses) {
                                try context.response.setStatusCode(.accepted);
                                writer = try context.response.writer();
                            }

                            for (result) |line| {
                                try writer.writeAll(line);
                                try writer.writeByte('\n'); //Alwys add a newline to the end
                            }
                        },
                        serve.HttpStatusCode => try context.response.setStatusCode(result),
                        else => {
                            defer if (@typeInfo(@TypeOf(result)) == .Pointer) common.allocator.free(result);
                            if (!setting_vars.log_into_responses) {
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
                    if (!setting_vars.log_into_responses) {
                        try context.response.setStatusCode(.internal_server_error);
                        writer = try context.response.writer();
                    }

                    const result = try std.fmt.allocPrint(provider.allocator, "Error while executing command {s}: {any}", .{ name, err });
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
                                    2 => inner(args, body),
                                    else => @compileError("Command " ++ @typeName(inner) ++ " has invalid number of arguments. Only none, parameters and body are available."),
                                }) |result| {
                                    switch (@TypeOf(result)) {
                                        void => try self.conn.writeText(accepted),
                                        String => {
                                            defer common.allocator.free(result);
                                            try self.conn.writeAllFrame(.text, &.{ accepted, result, "\n" });
                                        },
                                        []const CString => {
                                            defer {
                                                for (result) |line| common.allocator.free(std.mem.span(line));
                                                common.allocator.free(result);
                                            }
                                            var flattened = try common.joinInnerZ(common.allocator, "\n", result);
                                            defer common.allocator.free(flattened);
                                            try self.conn.writeAllFrame(.text, &.{ accepted, flattened, "\n" });
                                        },
                                        []const String => {
                                            defer for (result) |line| common.allocator.free(line);
                                            defer common.allocator.free(result);
                                            var flattened = try std.mem.join(common.allocator, "\n", result);
                                            defer common.allocator.free(flattened);
                                            try self.conn.writeAllFrame(.text, &.{ accepted, flattened, "\n" });
                                        },
                                        serve.HttpStatusCode => |code| {
                                            try self.conn.writeAllFrame(.text, &.{ try std.fmt.bufPrint(http_code_buffer, "{d}", .{code}), ": ", @tagName(result), "\n" });
                                        },
                                        else => {
                                            defer if (@typeInfo(@TypeOf(result)) == .Pointer) common.allocator.free(result);
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
        context: *CommandListener,

        const Conn = websocket.Conn;
        const Message = websocket.Message;
        const Handshake = websocket.Handshake;

        pub fn init(h: Handshake, conn: *Conn, context: *CommandListener) !@This() {
            context.ws = conn;
            _ = h;

            return @This(){
                .conn = conn,
                .context = context,
            };
        }

        pub fn handle(self: *@This(), message: Message) !void {
            errdefer |err| {
                DeshaderLog.err("Error while handling websocket command: {any}", .{err});
                DeshaderLog.debug("Message: {any}", .{message.data});
                const err_mess = std.fmt.allocPrint(common.allocator, "Error: {any}", .{err}) catch "";
                defer if (err_mess.len > 0) common.allocator.free(err_mess);
                self.conn.writeText(err_mess) catch |er| DeshaderLog.err("Error while writing error: {any}", .{er});
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
        pub fn close(self: *WSHandler) void {
            self.context.ws = null;
        }
    };

    fn stringToBool(val: ?String) bool {
        return val != null and (std.mem.eql(u8, val.?, "true") or (val.?.len == 1 and val.?[0] == '1'));
    }

    pub const commands = struct {
        const simple = struct {
            pub fn version() !String {
                return try common.allocator.dupe(u8, "dev");
            }

            pub fn editorWindowShow() !void {
                return editor.windowShow();
            }

            pub fn editorWindowTerminate() !void {
                return editor.windowTerminate();
            }

            pub fn editorServerStart() !void {
                return editor.serverStart();
            }

            pub fn editorServerStop() !void {
                return editor.serverStop();
            }

            fn getListArgs(args: ?ArgumentsList) struct { untagged: bool, path: String } {
                var untagged = true;
                var path: String = "/";
                if (args) |sure_args| {
                    if (sure_args.get("untagged")) |wants_untagged| {
                        untagged = stringToBool(wants_untagged);
                    }
                    if (sure_args.get("path")) |wants_path| {
                        path = wants_path;
                    }
                }
                return .{ .untagged = untagged, .path = path };
            }

            /// untagged: bool, path: String
            pub fn listSources(args: ?ArgumentsList) ![]const CString {
                const args_result = getListArgs(args);
                return try shaders.Shaders.list(args_result.untagged, args_result.path);
            }

            /// untagged: bool, path: String
            pub fn listPrograms(args: ?ArgumentsList) ![]const CString {
                const args_result = getListArgs(args);
                return try shaders.Programs.list(args_result.untagged, args_result.path);
            }

            pub fn settings(args: ?ArgumentsList) error{ UnknownSettingName, OutOfMemory }![]const String {
                const settings_decls = @typeInfo(setting_vars).Struct.decls;
                if (args == null) {
                    var values = try common.allocator.alloc(String, settings_decls.len);
                    inline for (settings_decls, 0..) |decl, i| {
                        values[i] = try std.json.stringifyAlloc(common.allocator, @field(setting_vars, decl.name), .{ .whitespace = .minified });
                    }
                    return values;
                }
                var iter = args.?.keyIterator();
                var results = std.ArrayList(String).init(common.allocator);
                while (iter.next()) |key| {
                    const value = args.?.get(key.*);

                    comptime var settings_enum_fields: [settings_decls.len]std.builtin.Type.EnumField = undefined;

                    comptime {
                        inline for (settings_decls, 0..) |decl, i| {
                            settings_enum_fields[i] = .{
                                .name = decl.name,
                                .value = i,
                            };
                        }
                    }

                    const settings_enum = @Type(.{ .Enum = .{
                        .decls = &[_]std.builtin.Type.Declaration{},
                        .tag_type = usize,
                        .fields = &settings_enum_fields,
                        .is_exhaustive = true,
                    } });

                    try struct {
                        fn setBool(comptime name: String, target_val: ?String) void {
                            @field(setting_vars, name) = stringToBool(target_val);
                        }

                        fn setAny(name: String, target_val: ?String) !void {
                            // switch on setting name
                            const setting_name = std.meta.stringToEnum(settings_enum, name);
                            if (setting_name == null) {
                                DeshaderLog.err("Unknown setting name: {s}", .{name});
                                return error.UnknownSettingName;
                            } else switch (setting_name.?) {
                                .log_into_responses => {
                                    setBool(@tagName(.log_into_responses), target_val);
                                },
                            }
                        }
                    }.setAny(key.*, value);
                    try results.append(try std.fmt.allocPrint(common.allocator, "{s} = {?s}", .{ key.*, value }));
                }
                return results.items;
            }
        };
    };
};
