const std = @import("std");
const positron = @import("positron");
const serve = @import("serve");
const websocket = @import("websocket");

const common = @import("common.zig");
const logging = @import("log.zig");
const DeshaderLog = logging.DeshaderLog;
const main = @import("main.zig");
const options = @import("options");
const editor = if (options.embedEditor) @import("tools/editor.zig") else null;
const shaders = @import("services/shaders.zig");

const String = []const u8;
const CString = [*:0]const u8;
const Tuple = std.meta.Tuple;
const Route = positron.Provider.Route;

pub const CommandListener = struct {
    pub const ArgumentsList = std.StringHashMap(String);
    pub const setting_vars = struct {
        pub var log_into_responses = false;
    };

    // various command providers
    http: ?*positron.Provider = null,
    ws: ?*websocket.Conn = null,
    ws_config: ?websocket.Config.Server = null,
    provide_thread: ?std.Thread = null,
    websocket_thread: ?std.Thread = null,
    server_arena: std.heap.ArenaAllocator = undefined,
    provider_allocator: std.mem.Allocator = undefined,
    secure: bool = false, //TODO use SSL

    pub fn start(allocator: std.mem.Allocator, http_port: ?u16, ws_port: ?u16) !*@This() {
        const self = try allocator.create(@This());
        self.* = @This(){}; // zero out the struct
        errdefer allocator.destroy(self);

        self.server_arena = std.heap.ArenaAllocator.init(allocator);
        // WS Listener
        if (ws_port != null) {
            if (!try common.isPortFree(null, ws_port.?)) {
                return error.AddressInUse;
            }

            self.ws_config = .{
                .port = ws_port.?,
                .max_headers = 10,
                .address = "127.0.0.1",
            };
            self.websocket_thread = try std.Thread.spawn(
                .{},
                struct {
                    fn listen(list: *CommandListener, alloc: std.mem.Allocator, conf: websocket.Config.Server) void {
                        websocket.listen(WSHandler, alloc, list, conf) catch |err| {
                            DeshaderLog.err("Error while listening for websocket commands: {any}", .{err});
                        };
                    }
                }.listen,
                .{ self, self.server_arena.allocator(), self.ws_config.? },
            );
            try self.websocket_thread.?.setName("CmdListWS");
        }

        // HTTP listener
        if (http_port != null) {
            self.provider_allocator = self.server_arena.allocator();
            self.http = try positron.Provider.create(self.provider_allocator, http_port.?);
            errdefer {
                self.http.?.destroy();
                self.http = null;
            }
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
            self.provide_thread = null;
            self.http = null;
        }
        if (self.ws != null) {
            self.ws.?.writeText("432: Closing connection\n") catch {};
            self.ws.?.writeClose() catch {};
            self.ws.?.close();
            self.websocket_thread.?.detach();
            self.ws = null;
            self.websocket_thread = null;
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
        const CommandReturnType = enum { Void, String, CStringArray, StringArray, HttpStatusCode };
        const decls = @typeInfo(commands.simple).Struct.decls;
        const comInfo = struct { r: CommandReturnType, a: usize, c: *const anyopaque };
        comptime var command_array: [decls.len]std.meta.Tuple(&.{ String, comInfo }) = undefined;
        for (decls, 0..) |function, i| {
            const command = @field(commands.simple, function.name);
            const return_type = @typeInfo(@TypeOf(command)).Fn.return_type.?;
            const error_union = @typeInfo(return_type).ErrorUnion;
            command_array[i] = .{ function.name, comInfo{
                .r = switch (error_union.payload) {
                    void => CommandReturnType.Void,
                    String => CommandReturnType.String,
                    []const String => CommandReturnType.StringArray,
                    []const CString => CommandReturnType.CStringArray,
                    serve.HttpStatusCode => CommandReturnType.HttpStatusCode,
                    else => @compileError("Command " ++ function.name ++ " has invalid return type. Only void, string, string array and http status code are available."),
                },
                .a = @typeInfo(@TypeOf(command)).Fn.params.len,
                .c = &command,
            } };
        }
        const map = std.ComptimeStringMap(@TypeOf(command_array[0][1]), command_array);
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

        fn handleInner(self: *@This(), result_or_error: anytype, command_name: String) !void {
            var http_code_buffer: [3]u8 = undefined;
            const accepted = "202: Accepted\n";
            if (result_or_error) |result| {
                switch (@TypeOf(result)) {
                    void => try self.conn.writeAllFrame(.text, &.{ accepted, command_name, "\n" }),
                    String => {
                        defer common.allocator.free(result);
                        try self.conn.writeAllFrame(.text, &.{ accepted, command_name, "\n", result, "\n" });
                    },
                    []const CString => {
                        defer {
                            for (result) |line| common.allocator.free(std.mem.span(line));
                            common.allocator.free(result);
                        }
                        const flattened = try common.joinInnerZ(common.allocator, "\n", result);
                        defer common.allocator.free(flattened);
                        try self.conn.writeAllFrame(.text, &.{ accepted, command_name, "\n", flattened, "\n" });
                    },
                    []const String => {
                        defer for (result) |line| common.allocator.free(line);
                        defer common.allocator.free(result);
                        const flattened = try std.mem.join(common.allocator, "\n", result);
                        defer common.allocator.free(flattened);
                        try self.conn.writeAllFrame(.text, &.{ accepted, command_name, "\n", flattened, "\n" });
                    },
                    serve.HttpStatusCode => {
                        try self.conn.writeAllFrame(.text, &.{
                            try std.fmt.bufPrint(&http_code_buffer, "{d}", .{@as(serve.HttpStatusCode, result)}),
                            ": ",
                            @tagName(result),
                            "\n",
                            command_name,
                            "\n",
                        });
                    },
                    else => unreachable,
                }
            } else |err| {
                const text = try std.fmt.allocPrint(common.allocator, "Error: {any}\n", .{err});
                defer common.allocator.free(text);
                try self.conn.writeText(text);
            }
        }

        pub fn handle(self: *@This(), message: Message) !void {
            errdefer |err| {
                DeshaderLog.err("Error while handling websocket command: {any}", .{err});
                DeshaderLog.debug("Message: {any}", .{message.data});
                const err_mess = std.fmt.allocPrint(common.allocator, "Error: {any}\n", .{err}) catch "";
                defer if (err_mess.len > 0) common.allocator.free(err_mess);
                self.conn.writeText(err_mess) catch |er| DeshaderLog.err("Error while writing error: {any}", .{er});
            }
            var iterator = std.mem.splitScalar(u8, message.data, 0);
            var args = iterator.first();
            if (args.len == 0) {
                try self.conn.writeText("400: Bad request\n");
                return;
            }
            if (args[args.len - 1] == '\n') {
                args = args[0 .. args.len - 1];
            }
            const body = iterator.rest();

            var command_query = std.mem.splitScalar(u8, args, '?');
            const command_name = command_query.first();
            const query = command_query.rest();

            const target_command = ws_commands.get(command_name);
            if (target_command == null) {
                try self.conn.writeText("404: Command not found\n");
                return;
            }

            var parsed_args: ?ArgumentsList = if (query.len > 0) try argsFromUri(common.allocator, query) else null;
            defer if (parsed_args != null) parsed_args.?.deinit();

            try switch (target_command.?.r) {
                .Void => switch (target_command.?.a) {
                    0 => handleInner(self, @as(*const fn () anyerror!void, @ptrCast(target_command.?.c))(), command_name),
                    1 => handleInner(self, @as(*const fn (?ArgumentsList) anyerror!void, @ptrCast(target_command.?.c))(parsed_args), command_name),
                    2 => handleInner(self, @as(*const fn (?ArgumentsList, String) anyerror!void, @ptrCast(target_command.?.c))(parsed_args, body), command_name),
                    else => unreachable,
                },
                .String => switch (target_command.?.a) {
                    0 => handleInner(self, @as(*const fn () anyerror!String, @ptrCast(target_command.?.c))(), command_name),
                    1 => handleInner(self, @as(*const fn (?ArgumentsList) anyerror!String, @ptrCast(target_command.?.c))(parsed_args), command_name),
                    2 => handleInner(self, @as(*const fn (?ArgumentsList, String) anyerror!String, @ptrCast(target_command.?.c))(parsed_args, body), command_name),
                    else => unreachable,
                },
                .CStringArray => switch (target_command.?.a) {
                    0 => handleInner(self, @as(*const fn () anyerror![]const CString, @ptrCast(target_command.?.c))(), command_name),
                    1 => handleInner(self, @as(*const fn (?ArgumentsList) anyerror![]const CString, @ptrCast(target_command.?.c))(parsed_args), command_name),
                    2 => handleInner(self, @as(*const fn (?ArgumentsList, String) anyerror![]const CString, @ptrCast(target_command.?.c))(parsed_args, body), command_name),
                    else => unreachable,
                },
                .StringArray => switch (target_command.?.a) {
                    0 => handleInner(self, @as(*const fn () anyerror![]const String, @ptrCast(target_command.?.c))(), command_name),
                    1 => handleInner(self, @as(*const fn (?ArgumentsList) anyerror![]const String, @ptrCast(target_command.?.c))(parsed_args), command_name),
                    2 => handleInner(self, @as(*const fn (?ArgumentsList, String) anyerror![]const String, @ptrCast(target_command.?.c))(parsed_args, body), command_name),
                    else => unreachable,
                },
                .HttpStatusCode => switch (target_command.?.a) {
                    0 => handleInner(self, @as(*const fn () anyerror!serve.HttpStatusCode, @ptrCast(target_command.?.c))(), command_name),
                    1 => handleInner(self, @as(*const fn (?ArgumentsList) anyerror!serve.HttpStatusCode, @ptrCast(target_command.?.c))(parsed_args), command_name),
                    2 => handleInner(self, @as(*const fn (?ArgumentsList, String) anyerror!serve.HttpStatusCode, @ptrCast(target_command.?.c))(parsed_args, body), command_name),
                    else => unreachable,
                },
            };
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
                if (options.embedEditor) {
                    return editor.windowShow(main.command_listener);
                }
            }

            pub fn editorWindowTerminate() !void {
                if (options.embedEditor) {
                    return editor.windowTerminate();
                }
            }

            pub fn editorServerStart() !void {
                if (options.embedEditor) {
                    return editor.serverStart(main.command_listener);
                }
            }

            pub fn editorServerStop() !void {
                if (options.embedEditor) {
                    return editor.serverStop();
                }
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
                        for (settings_decls, 0..) |decl, i| {
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
