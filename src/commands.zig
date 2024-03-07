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
const storage = @import("services/storage.zig");
const debug = @import("services/debug.zig");
const shaders = @import("services/shaders.zig");

const String = []const u8;
const CString = [*:0]const u8;
const Tuple = std.meta.Tuple;
const Route = positron.Provider.Route;
const logParsing = false;

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
                _ = try self.addHTTPCommand("/" ++ function.name, command, if (@hasDecl(commands.free_funcs, function.name)) @field(commands.free_funcs, function.name) else null);
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

    fn argsFromQuery(allocator: std.mem.Allocator, query: String) !ArgumentsList {
        var list = ArgumentsList.init(allocator);
        var iterator = std.mem.splitScalar(u8, query, '&');
        while (iterator.next()) |arg| {
            var arg_iterator = std.mem.splitScalar(u8, arg, '=');
            const key = arg_iterator.first();
            const value = arg_iterator.rest();
            try list.put(key, try std.Uri.unescapeString(allocator, value));
        }
        return list;
    }

    //
    // Implement various command backends
    //
    pub fn addHTTPCommand(self: *@This(), comptime name: String, command: anytype, freee: ?*const anyopaque) !*@This() {
        const route = try self.http.?.addRoute(name);
        const command_route = struct {
            var comm: *const @TypeOf(command) = undefined;
            var free: ?*const fn (@typeInfo(@TypeOf(command)).Fn.return_type.?) void = null;
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

            fn argsFromFullCommand(allocator: std.mem.Allocator, uri: String) !?ArgumentsList {
                const command_query = std.mem.splitScalar(u8, uri, '?');
                const query = command_query.rest();
                return if (query.len > 0) try argsFromQuery(allocator, query) else null;
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

                const result_or_err = switch (@typeInfo(@TypeOf(command)).Fn.params.len) {
                    0 => comm(),
                    1 => blk: {
                        var args = try argsFromFullCommand(provider.allocator, context.request.url);
                        defer if (args) |*a| {
                            var it = a.valueIterator();
                            while (it.next()) |s| {
                                provider.allocator.free(s.*);
                            }
                            a.deinit();
                        };
                        break :blk comm(args);
                    },
                    2 => blk: {
                        var args = try argsFromFullCommand(provider.allocator, context.request.url);
                        defer if (args) |*a| {
                            var it = a.valueIterator();
                            while (it.next()) |s| {
                                provider.allocator.free(s.*);
                            }
                            a.deinit();
                        };
                        var reader = try context.request.reader();
                        defer reader.deinit();
                        const body = try reader.readAllAlloc(provider.allocator);
                        defer provider.allocator.free(body);
                        break :blk comm(args, body);
                    },
                    else => @compileError("Command " ++ @typeName(comm) ++ " has invalid number of arguments. Only none, parameters and body are available."),
                };

                defer if (free) |f| f(result_or_err);
                if (result_or_err) |result| { //swith on result of running the command
                    switch (error_union.payload) {
                        void => {},
                        String => {
                            if (!setting_vars.log_into_responses) {
                                try context.response.setStatusCode(.accepted);
                                writer = try context.response.writer();
                            }
                            try writer.writeAll(result);
                            try writer.writeByte('\n'); //Alwys add a newline to the end
                        },
                        []const String => {
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
                        else => unreachable,
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
        command_route.free = @ptrCast(freee);
        route.handler = command_route.wrapper;
        errdefer route.deinit();
        return self;
    }

    const ws_commands = blk: {
        const CommandReturnType = enum { Void, String, CStringArray, StringArray, HttpStatusCode };
        const decls = @typeInfo(commands.simple).Struct.decls;
        const comInfo = struct { r: CommandReturnType, a: usize, c: *const anyopaque, free: ?*const anyopaque };
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
                .free = if (@hasDecl(commands.free_funcs, function.name)) &@field(commands.free_funcs, function.name) else null,
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

        fn handleInner(self: *@This(), result_or_error: anytype, command_echo: String, free: ?*const fn (@TypeOf(result_or_error)) void) !void {
            defer if (free) |f| f(result_or_error);
            var http_code_buffer: [3]u8 = undefined;
            const accepted = "202: Accepted\n";
            if (result_or_error) |result| {
                switch (@TypeOf(result)) {
                    void => try self.conn.writeAllFrame(.text, &.{ accepted, command_echo, "\n" }),
                    String => {
                        try self.conn.writeAllFrame(.text, &.{ accepted, command_echo, "\n", result, "\n" });
                    },
                    []const CString => {
                        const flattened = try common.joinInnerZ(common.allocator, "\n", result);
                        defer common.allocator.free(flattened);
                        try self.conn.writeAllFrame(.text, &.{ accepted, command_echo, "\n", flattened, "\n" });
                    },
                    []const String => {
                        const flattened = try std.mem.join(common.allocator, "\n", result);
                        defer common.allocator.free(flattened);
                        try self.conn.writeAllFrame(.text, &.{ accepted, command_echo, "\n", flattened, "\n" });
                    },
                    serve.HttpStatusCode => {
                        try self.conn.writeAllFrame(.text, &.{
                            try std.fmt.bufPrint(&http_code_buffer, "{d}", .{@as(serve.HttpStatusCode, result)}),
                            ": ",
                            @tagName(result),
                            "\n",
                            command_echo,
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
            if (target_command) |tc| {
                if (logParsing) {
                    DeshaderLog.debug("query: {s}", .{query});
                }
                var parsed_args: ?ArgumentsList = if (query.len > 0) try argsFromQuery(common.allocator, query) else null;
                defer if (parsed_args) |*a| {
                    var it = a.valueIterator();
                    while (it.next()) |s| {
                        common.allocator.free(s.*);
                    }
                    a.deinit();
                };

                try switch (tc.r) {
                    .Void => switch (tc.a) {
                        0 => handleInner(self, @as(*const fn () anyerror!void, @ptrCast(tc.c))(), args, @ptrCast(tc.free)),
                        1 => handleInner(self, @as(*const fn (?ArgumentsList) anyerror!void, @ptrCast(tc.c))(parsed_args), args, @ptrCast(tc.free)),
                        2 => handleInner(self, @as(*const fn (?ArgumentsList, String) anyerror!void, @ptrCast(tc.c))(parsed_args, body), args, @ptrCast(tc.free)),
                        else => unreachable,
                    },
                    .String => switch (tc.a) {
                        0 => handleInner(self, @as(*const fn () anyerror!String, @ptrCast(tc.c))(), args, @ptrCast(tc.free)),
                        1 => handleInner(self, @as(*const fn (?ArgumentsList) anyerror!String, @ptrCast(tc.c))(parsed_args), args, @ptrCast(tc.free)),
                        2 => handleInner(self, @as(*const fn (?ArgumentsList, String) anyerror!String, @ptrCast(tc.c))(parsed_args, body), args, @ptrCast(tc.free)),
                        else => unreachable,
                    },
                    .CStringArray => switch (tc.a) {
                        0 => handleInner(self, @as(*const fn () anyerror![]const CString, @ptrCast(tc.c))(), args, @ptrCast(tc.free)),
                        1 => handleInner(self, @as(*const fn (?ArgumentsList) anyerror![]const CString, @ptrCast(tc.c))(parsed_args), args, @ptrCast(tc.free)),
                        2 => handleInner(self, @as(*const fn (?ArgumentsList, String) anyerror![]const CString, @ptrCast(tc.c))(parsed_args, body), args, @ptrCast(tc.free)),
                        else => unreachable,
                    },
                    .StringArray => switch (tc.a) {
                        0 => handleInner(self, @as(*const fn () anyerror![]const String, @ptrCast(tc.c))(), args, @ptrCast(tc.free)),
                        1 => handleInner(self, @as(*const fn (?ArgumentsList) anyerror![]const String, @ptrCast(tc.c))(parsed_args), args, @ptrCast(tc.free)),
                        2 => handleInner(self, @as(*const fn (?ArgumentsList, String) anyerror![]const String, @ptrCast(tc.c))(parsed_args, body), args, @ptrCast(tc.free)),
                        else => unreachable,
                    },
                    .HttpStatusCode => switch (tc.a) {
                        0 => handleInner(self, @as(*const fn () anyerror!serve.HttpStatusCode, @ptrCast(tc.c))(), args, @ptrCast(tc.free)),
                        1 => handleInner(self, @as(*const fn (?ArgumentsList) anyerror!serve.HttpStatusCode, @ptrCast(tc.c))(parsed_args), args, @ptrCast(tc.free)),
                        2 => handleInner(self, @as(*const fn (?ArgumentsList, String) anyerror!serve.HttpStatusCode, @ptrCast(tc.c))(parsed_args, body), args, @ptrCast(tc.free)),
                        else => unreachable,
                    },
                };
            } else {
                try self.conn.writeText("404: Command not found\n");
                return;
            }
        }

        // optional hooks
        pub fn afterInit(_: *WSHandler) !void {}
        pub fn close(self: *WSHandler) void {
            self.context.ws = null;
        }
    };

    fn stringToBool(val: ?String) bool {
        return val != null and (std.ascii.eqlIgnoreCase(val.?, "true") or (val.?.len == 1 and val.?[0] == '1'));
    }

    fn parseValue(comptime t: type, value: ?String) !t {
        const nullable = @typeInfo(t) == .Optional;
        const inner = blk: {
            switch (@typeInfo(t)) {
                .Optional => |opt| {
                    if (logParsing) {
                        DeshaderLog.debug("Parsing optional", .{});
                    }
                    break :blk opt.child;
                },
                else => break :blk t,
            }
        };
        if (value) |v| {
            return switch (@typeInfo(inner)) {
                .Bool => std.ascii.eqlIgnoreCase(v, "true") or
                    std.ascii.eqlIgnoreCase(v, "on") or
                    std.mem.eql(v, "1"),

                .Float => std.fmt.parseFloat(inner, v),

                .Int => std.fmt.parseInt(inner, v, 0),

                .Array, .Pointer => {
                    if (logParsing) {
                        DeshaderLog.debug("Parsing array/pointer {x}: {s}", .{ @intFromPtr(v.ptr), v });
                    }
                    return v;
                }, // Probably string

                // JSON
                .Struct => std.json.parseFromSlice(inner, common.allocator, v, .{ .ignore_unknown_fields = true }),
                else => @compileError("Unsupported type for command parameter " ++ @typeName(inner)),
            };
        } else {
            if (nullable) {
                return null;
            } else {
                DeshaderLog.err("Missing parameter of type {}", .{t});
                return error.ParameterMissing;
            }
        }
    }

    fn parseArgs(comptime result: type, args: ?ArgumentsList) !result {
        if (args) |sure_args| {
            var result_payload: result = undefined;
            inline for (@typeInfo(result).Struct.fields) |field| {
                if (logParsing) {
                    DeshaderLog.debug("Parsing field: {s}", .{field.name});
                }
                @field(result_payload, field.name) = try parseValue(field.type, sure_args.get(field.name));
            }
            return result_payload;
        }
        return error.WrongParameters;
    }

    pub const commands = struct {
        const simple = struct {
            pub fn clearAllBreakpoints(args: ?ArgumentsList) !void {
                if (args) |sure_args| {
                    if (sure_args.get("path")) |path| {
                        if (try shaders.Shaders.getTagByPath(path)) |shader| {
                            shader.breakpoints.clearRetainingCapacity();
                        }
                    } else {
                        return error.ParameterMissing;
                    }
                } else {
                    return error.WrongParameters;
                }
            }

            pub fn setBreakpoint(args: ?ArgumentsList) !String {
                const breakpoint = try parseArgs(struct {
                    path: String,
                    line: usize,
                    column: usize,
                }, args);
                if (try shaders.Shaders.getTagByPath(breakpoint.path)) |shader| {
                    var new = shaders.Breakpoint.init();
                    new.line = breakpoint.line;
                    new.column = breakpoint.column;
                    try shader.breakpoints.append(new);
                    return std.json.stringifyAlloc(common.allocator, .{
                        .id = new.id,
                        .verified = true,
                        .message = null,
                        .source = .{
                            .name = std.fs.path.basename(breakpoint.path),
                            .path = breakpoint.path,
                        },
                        .line = new.line,
                        .column = new.column,
                        .endLine = null,
                        .endColumn = null,
                    }, .{});
                } else {
                    return error.FileNotFound;
                }
            }

            const StatRequest = struct {
                path: String,
            };
            pub fn statSource(args: ?ArgumentsList) !String {
                const args_result = try parseArgs(StatRequest, args);

                const s = try std.json.stringifyAlloc(common.allocator, try shaders.Shaders.stat(args_result.path), .{});
                DeshaderLog.debug("Stat source {s}: {s}", .{ args_result.path, s });
                return s;
            }
            pub fn statProgram(args: ?ArgumentsList) !String {
                const args_result = try parseArgs(StatRequest, args);

                const s = try std.json.stringifyAlloc(common.allocator, try shaders.Programs.stat(args_result.path), .{});
                DeshaderLog.debug("Stat program {s}: {s}", .{ args_result.path, s });
                return s;
            }
            pub fn stat(args: ?ArgumentsList) !String {
                const args_result = try parseArgs(StatRequest, args);

                const s = try std.json.stringifyAlloc(common.allocator, try (shaders.Shaders.stat(args_result.path) catch shaders.Programs.stat(args_result.path)), .{});
                DeshaderLog.debug("Stat {s}: {s}", .{ args_result.path, s });
                return s;
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

            fn getListArgs(args: ?ArgumentsList) struct { untagged: bool, path: String, recursive: bool } {
                var untagged = false;
                var recursive = false;
                var path: String = "";
                if (args) |sure_args| {
                    if (sure_args.get("untagged")) |wants_untagged| {
                        untagged = stringToBool(wants_untagged);
                    }
                    if (sure_args.get("recursive")) |wants_recursive| {
                        recursive = stringToBool(wants_recursive);
                    }
                    if (sure_args.get("path")) |wants_path| {
                        path = wants_path;
                    }
                }
                return .{ .untagged = untagged, .path = path, .recursive = recursive };
            }
            /// path: String
            pub fn listBreakpoints(args: ?ArgumentsList) ![]const String {
                if (args) |sure_args| {
                    if (sure_args.get("path")) |path| {
                        if (try shaders.Shaders.getTagByPath(path)) |shader| {
                            var result = std.ArrayList(String).init(common.allocator);
                            for (shader.breakpoints.items) |bp| {
                                try result.append(try std.fmt.allocPrint(common.allocator, "{?d},{?d}", .{ bp.line, bp.column }));
                            }
                            return result.toOwnedSlice();
                        }
                    }
                }
                return error.FileNotFound;
            }

            var help_out: [
                blk: { // Compute the number of functions
                    comptime var count = 0;
                    for (@typeInfo(commands.simple).Struct.decls) |decl_info| {
                        const decl = @field(commands.simple, decl_info.name);
                        if (@typeInfo(@TypeOf(decl)) == .Fn) {
                            count += 1;
                        }
                    }
                    break :blk count;
                }
            ]String = undefined;
            pub fn help() ![]const String {
                var i: usize = 0;
                inline for (@typeInfo(commands.simple).Struct.decls) |decl_info| {
                    const decl = @field(commands.simple, decl_info.name);
                    if (@typeInfo(@TypeOf(decl)) == .Fn) {
                        defer i += 1;
                        help_out[i] = decl_info.name;
                    }
                }
                return &help_out;
            }
            /// untagged: bool[false], recursive: bool[false], path: String
            pub fn listSources(args: ?ArgumentsList) ![]const CString {
                const args_result = getListArgs(args);
                const result = try shaders.Shaders.listAlloc(args_result.untagged, args_result.path, args_result.recursive);
                return result;
            }

            /// untagged: bool[false], recursive: bool[false], path: String
            pub fn listPrograms(args: ?ArgumentsList) ![]const CString {
                const args_result = getListArgs(args);
                return try shaders.Programs.listAlloc(args_result.untagged, args_result.path, args_result.recursive);
            }

            /// path: String, recursive: bool[false]
            /// TODO
            pub fn listWorkspace(args: ?ArgumentsList) ![]const CString {
                const args_result = getListArgs(args);
                return try shaders.Programs.listAlloc(args_result.untagged, args_result.path, args_result.recursive);
            }

            pub fn readFile(args: ?ArgumentsList) !String {
                const args_result = try parseArgs(struct { path: String }, args);
                const result = try shaders.Shaders.getTagByPath(args_result.path);
                if (result) |shader| {
                    if (shader.getSource()) |source| {
                        return source;
                    } else {
                        return error.SourceNotAvailable;
                    }
                } else {
                    return error.FileNotFound;
                }
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

            pub fn version() !String {
                return options.version;
            }
        };
        const free_funcs = struct {
            fn settings(result: anyerror![]const String) void {
                const r = result catch return;
                for (r) |line| {
                    common.allocator.free(line);
                }
                common.allocator.free(r);
            }
            fn listPrograms(result: anyerror![]const CString) void {
                const r = result catch return;
                for (r) |line| {
                    common.allocator.free(std.mem.span(line));
                }
                common.allocator.free(r);
            }
            const listSources = listPrograms;
            const listWorkspace = listPrograms;

            fn stringReturing(result: anyerror!String) void {
                const r = result catch return;
                common.allocator.free(r);
            }

            const setBreakpoint = stringReturing;
            const statSource = stringReturing;
            const statProgram = stringReturing;
            const stat = stringReturing;
        };
    };
};
