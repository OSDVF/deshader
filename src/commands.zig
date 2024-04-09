const std = @import("std");
const positron = @import("positron");
const serve = @import("serve");
const websocket = @import("websocket");

const common = @import("common.zig");
const logging = @import("log.zig");
const DeshaderLog = logging.DeshaderLog;
const options = @import("options");
const editor = if (options.embedEditor) @import("tools/editor.zig") else null;
const storage = @import("services/storage.zig");
const dap = @import("services/debug.zig");
const shaders = @import("services/shaders.zig");
const analysis = @import("services/analysis.zig");
const analyzer = @import("glsl_analyzer");

const String = []const u8;
const CString = [*:0]const u8;
const Route = positron.Provider.Route;
const logParsing = false;

pub const CommandListener = struct {
    pub const ArgumentsList = std.StringHashMap(String);
    pub const setting_vars = struct {
        pub var logIntoResponses = false;
        pub var languageServerPort: u16 = std.fmt.parseInt(u16, common.default_lsp_port, 10) catch 8083;
        // TODO recreate providers on port change
        pub var commandsHttpPort: u16 = std.fmt.parseInt(u16, common.default_http_port, 10) catch 8080;
        pub var commandsWsPort: u16 = std.fmt.parseInt(u16, common.default_ws_port, 10) catch 8081;
    };
    const json_options = std.json.StringifyOptions{ .whitespace = .minified, .emit_null_optional_fields = false };

    // various command providers
    http: ?*positron.Provider = null,
    ws: ?*websocket.Conn = null,
    ws_server: std.net.StreamServer = undefined,
    ws_config: ?websocket.Config.Server = null,
    provide_thread: ?std.Thread = null,
    websocket_thread: ?std.Thread = null,
    server_arena: std.heap.ArenaAllocator = undefined,
    provider_allocator: std.mem.Allocator = undefined,
    secure: bool = false, //TODO use SSL
    break_mutex: std.Thread.Mutex = .{},
    resume_condition: std.Thread.Condition = .{},

    pub fn start(allocator: std.mem.Allocator, http_port: ?u16, ws_port: ?u16, lsp_port: ?u16) !*@This() {
        const self = try allocator.create(@This());
        self.* = @This(){}; // zero out the struct
        errdefer allocator.destroy(self);

        self.server_arena = std.heap.ArenaAllocator.init(allocator);
        // WS Command Listener
        if (ws_port) |port| {
            setting_vars.commandsWsPort = port;
            if (!try common.isPortFree(null, port)) {
                return error.AddressInUse;
            }

            self.ws_config = .{
                .port = port,
                .max_headers = 10,
                .address = "127.0.0.1",
            };
            self.websocket_thread = try std.Thread.spawn(
                .{},
                struct {
                    fn listen(list: *CommandListener, alloc: std.mem.Allocator, conf: websocket.Config.Server, out_listener: *std.net.StreamServer) void {
                        websocket.listen(WSHandler, alloc, list, conf, out_listener) catch |err| {
                            DeshaderLog.err("Error while listening for websocket commands: {any}", .{err});
                        };
                    }
                }.listen,
                .{ self, self.server_arena.allocator(), self.ws_config.?, &self.ws_server },
            );
            try self.websocket_thread.?.setName("CmdListWS");
        }

        // HTTP Command listener
        if (http_port) |port| {
            setting_vars.commandsHttpPort = port;
            self.provider_allocator = self.server_arena.allocator();
            self.http = try positron.Provider.create(self.provider_allocator, port);
            errdefer {
                self.http.?.destroy();
                self.http = null;
            }
            self.http.?.not_found_text = "Unknown command";

            inline for (@typeInfo(commands).Struct.decls) |function| {
                const command = @field(commands, function.name);
                _ = try self.addHTTPCommand("/" ++ function.name, command, if (@hasDecl(free_funcs, function.name)) @field(free_funcs, function.name) else null);
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

        // Language Server
        if (lsp_port) |port| {
            setting_vars.languageServerPort = port;
            if (try common.isPortFree(null, port)) {
                try analysis.serverStart(port);
            } else {
                return error.AddressInUse;
            }
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
            self.ws_server.close();
            self.websocket_thread.?.detach();
            self.ws = null;
            self.websocket_thread = null;
        }
        self.server_arena.deinit();
        analysis.serverStop() catch {};
    }

    fn queryArgsMap(allocator: std.mem.Allocator, query: String) !ArgumentsList {
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
                return if (query.len > 0) try queryArgsMap(allocator, query) else null;
            }

            fn wrapper(provider: *positron.Provider, route2: *Route, context: *serve.HttpContext) Route.Error!void {
                _ = route2;

                if (setting_vars.logIntoResponses) {
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
                            if (!setting_vars.logIntoResponses) {
                                try context.response.setStatusCode(.accepted);
                                writer = try context.response.writer();
                            }
                            try writer.writeAll(result);
                            try writer.writeByte('\n'); //Alwys add a newline to the end
                        },
                        []const String => {
                            if (!setting_vars.logIntoResponses) {
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
                    if (!setting_vars.logIntoResponses) {
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
        const CommandReturnType = enum {
            Void,
            String,
            CStringArray,
            StringArray,
            HttpStatusCode,
        };
        const decls = @typeInfo(commands).Struct.decls;
        const comInfo = struct { r: CommandReturnType, a: usize, c: *const anyopaque, free: ?*const anyopaque };
        comptime var command_array: [decls.len]struct { String, comInfo } = undefined;
        for (decls, 0..) |function, i| {
            const command = @field(commands, function.name);
            const return_type = @typeInfo(@TypeOf(command)).Fn.return_type.?;
            const error_union = @typeInfo(return_type).ErrorUnion;
            command_array[i] = .{ function.name, comInfo{
                .r = switch (error_union.payload) {
                    void => CommandReturnType.Void,
                    String => CommandReturnType.String,
                    []const String => CommandReturnType.StringArray,
                    []const CString => CommandReturnType.CStringArray,
                    serve.HttpStatusCode => CommandReturnType.HttpStatusCode,
                    else => @compileError("Command " ++ function.name ++ " has invalid return type. Only void, string, string array, string set, and http status code are available."),
                },
                .a = @typeInfo(@TypeOf(command)).Fn.params.len,
                .c = &command,
                .free = if (@hasDecl(free_funcs, function.name)) &@field(free_funcs, function.name) else null,
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

        /// command_echo echoes either the input command or the "seq" parameter of the request. "seq" is not checked agains duplicates or anything.
        fn handleInner(self: *@This(), result_or_error: anytype, command_echo: String, free: ?*const fn (@TypeOf(result_or_error)) void) !void {
            defer if (free) |f| f(result_or_error);
            var http_code_buffer: [3]u8 = undefined;
            const accepted = "202: Accepted\n";
            if (result_or_error) |result| {
                switch (@TypeOf(result)) {
                    void => {
                        DeshaderLog.debug("WS Command {s} => void", .{command_echo});
                        try self.conn.writeAllFrame(.text, &.{ accepted, command_echo, "\n" });
                    },
                    String => {
                        DeshaderLog.debug("WS Command {s} => {s}", .{ command_echo, result });
                        try self.conn.writeAllFrame(.text, &.{ accepted, command_echo, "\n", result, "\n" });
                    },
                    []const CString => {
                        const flattened = try common.joinInnerZ(common.allocator, "\n", result);
                        defer common.allocator.free(flattened);
                        DeshaderLog.debug("WS Command {s} => {s}", .{ command_echo, flattened });
                        try self.conn.writeAllFrame(.text, &.{ accepted, command_echo, "\n", flattened, "\n" });
                    },
                    []const String => {
                        const flattened = try std.mem.join(common.allocator, "\n", result);
                        defer common.allocator.free(flattened);
                        DeshaderLog.debug("WS Command {s} => {s}", .{ command_echo, flattened });
                        try self.conn.writeAllFrame(.text, &.{ accepted, command_echo, "\n", flattened, "\n" });
                    },
                    serve.HttpStatusCode => {
                        DeshaderLog.debug("WS Command {s} => {d}", .{ command_echo, result });
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
                const text = try std.fmt.allocPrint(common.allocator, "500: Internal Server Error\n{s}\n{any}", .{ command_echo, err });
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
            var request = iterator.first();
            if (request.len == 0) {
                try self.conn.writeText("400: Bad request\n");
                return;
            }
            if (request[request.len - 1] == '\n') {
                request = request[0 .. request.len - 1];
            }
            const body = iterator.rest();

            var command_query = std.mem.splitScalar(u8, request, '?');
            const command_name = command_query.first();
            const query = command_query.rest();

            const target_command = ws_commands.get(command_name);
            if (target_command) |tc| {
                var parsed_args: ?ArgumentsList = if (query.len > 0) try queryArgsMap(common.allocator, query) else null;
                defer if (parsed_args) |*a| {
                    var it = a.valueIterator();
                    while (it.next()) |s| {
                        common.allocator.free(s.*);
                    }
                    a.deinit();
                };
                if (parsed_args) |a| if (a.get("seq")) |seq| {
                    request = seq;
                };

                try switch (tc.r) {
                    .Void => switch (tc.a) {
                        0 => handleInner(self, @as(*const fn () anyerror!void, @ptrCast(tc.c))(), request, @ptrCast(tc.free)),
                        1 => handleInner(self, @as(*const fn (?ArgumentsList) anyerror!void, @ptrCast(tc.c))(parsed_args), request, @ptrCast(tc.free)),
                        2 => handleInner(self, @as(*const fn (?ArgumentsList, String) anyerror!void, @ptrCast(tc.c))(parsed_args, body), request, @ptrCast(tc.free)),
                        else => unreachable,
                    },
                    .String => switch (tc.a) {
                        0 => handleInner(self, @as(*const fn () anyerror!String, @ptrCast(tc.c))(), request, @ptrCast(tc.free)),
                        1 => handleInner(self, @as(*const fn (?ArgumentsList) anyerror!String, @ptrCast(tc.c))(parsed_args), request, @ptrCast(tc.free)),
                        2 => handleInner(self, @as(*const fn (?ArgumentsList, String) anyerror!String, @ptrCast(tc.c))(parsed_args, body), request, @ptrCast(tc.free)),
                        else => unreachable,
                    },
                    .CStringArray => switch (tc.a) {
                        0 => handleInner(self, @as(*const fn () anyerror![]const CString, @ptrCast(tc.c))(), request, @ptrCast(tc.free)),
                        1 => handleInner(self, @as(*const fn (?ArgumentsList) anyerror![]const CString, @ptrCast(tc.c))(parsed_args), request, @ptrCast(tc.free)),
                        2 => handleInner(self, @as(*const fn (?ArgumentsList, String) anyerror![]const CString, @ptrCast(tc.c))(parsed_args, body), request, @ptrCast(tc.free)),
                        else => unreachable,
                    },
                    .StringArray => switch (tc.a) {
                        0 => handleInner(self, @as(*const fn () anyerror![]const String, @ptrCast(tc.c))(), request, @ptrCast(tc.free)),
                        1 => handleInner(self, @as(*const fn (?ArgumentsList) anyerror![]const String, @ptrCast(tc.c))(parsed_args), request, @ptrCast(tc.free)),
                        2 => handleInner(self, @as(*const fn (?ArgumentsList, String) anyerror![]const String, @ptrCast(tc.c))(parsed_args, body), request, @ptrCast(tc.free)),
                        else => unreachable,
                    },
                    .HttpStatusCode => switch (tc.a) {
                        0 => handleInner(self, @as(*const fn () anyerror!serve.HttpStatusCode, @ptrCast(tc.c))(), request, @ptrCast(tc.free)),
                        1 => handleInner(self, @as(*const fn (?ArgumentsList) anyerror!serve.HttpStatusCode, @ptrCast(tc.c))(parsed_args), request, @ptrCast(tc.free)),
                        2 => handleInner(self, @as(*const fn (?ArgumentsList, String) anyerror!serve.HttpStatusCode, @ptrCast(tc.c))(parsed_args, body), request, @ptrCast(tc.free)),
                        else => unreachable,
                    },
                };
            } else {
                DeshaderLog.warn("Command not found: {s}", .{command_name});
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

    fn getInnerType(comptime t: type) struct { type: type, isOptional: bool } {
        return switch (@typeInfo(t)) {
            .Optional => |opt| .{ .type = opt.child, .isOptional = true },
            else => .{ .type = t, .isOptional = false },
        };
    }

    pub const Event = enum {
        connected,
        message,
        @"error",
        close,
        invalidated,
        stopOnEntry,
        stopOnStep,
        stopOnBreakpoint,
        stopOnDataBreakpoint,
        stopOnFunction,
        breakpoint,
        output,
        end,
    };

    pub fn sendEvent(self: *const @This(), comptime event: Event, body: anytype) !void {
        const string = try std.json.stringifyAlloc(common.allocator, body, json_options);
        defer common.allocator.free(string);
        if (self.ws) |ws| {
            try ws.writeAllFrame(.text, &.{
                "600: Event\n",
                @tagName(event) ++ "\n",
                string,
            });
        }
        // TODO some HTTP way of sending events (probably persistent connection)
    }

    /// Suspends the thread that calls this function, but processes commands in the meantime
    pub fn eventBreak(self: *@This(), comptime event: Event, body: anytype) !void {
        try self.sendEvent(event, body);
        while (true) {
            self.break_mutex.lock();
            defer self.break_mutex.unlock();
            self.resume_condition.timedWait(&self.break_mutex, 700 * 1000 * 1000) catch continue;

            break;
        }
    }

    pub fn hasClient(self: @This()) bool {
        return self.ws != null;
    }

    /// Parse single parameter value
    fn parseValue(comptime t: type, value: ?String) !t {
        const inner = getInnerType(t);
        if (value) |v| {
            return switch (@typeInfo(inner.type)) {
                .Bool => std.ascii.eqlIgnoreCase(v, "true") or
                    std.ascii.eqlIgnoreCase(v, "on") or
                    std.mem.eql(u8, v, "1"),

                .Float => std.fmt.parseFloat(inner.type, v),

                .Int => try std.fmt.parseInt(inner.type, v, 0),

                .Array, .Pointer => { // Probably string
                    if (logParsing) {
                        DeshaderLog.debug("Parsing array/pointer {x}: {s}", .{ @intFromPtr(v.ptr), v });
                    }
                    return v;
                },
                .Enum => if (std.meta.stringToEnum(inner.type, v)) |e| e else return error.InvalidEnumValue,

                // JSON
                .Struct => if (std.json.parseFromSlice(inner.type, common.allocator, v, .{ .ignore_unknown_fields = true })) |p|
                    p.value
                else |err|
                    err,
                else => @compileError("Unsupported type for command parameter " ++ @typeName(inner.type)),
            };
        } else {
            if (inner.isOptional) {
                return null;
            } else {
                DeshaderLog.err("Missing parameter of type {}", .{t});
                return error.ParameterMissing;
            }
        }
    }

    fn parseArgs(comptime result: type, args: ?ArgumentsList) !result {
        const result_type = getInnerType(result);
        if (args) |sure_args| {
            var result_payload: result_type.type = undefined;
            if (sure_args.count() == 0) {
                if (result_type.isOptional) {
                    return null;
                } else {
                    return error.WrongParameters;
                }
            }
            inline for (@typeInfo(result_type.type).Struct.fields) |field| {
                if (logParsing) {
                    DeshaderLog.debug("Parsing field: {s}", .{field.name});
                }
                @field(result_payload, field.name) = try parseValue(field.type, sure_args.get(field.name));
            }
            return result_payload;
        } else if (result_type.isOptional) {
            return null;
        }
        return error.WrongParameters;
    }

    fn processDAPArgs(comptime InT: type, comptime OutT: type, args: ?ArgumentsList, out: *OutT) !InT {
        const in = try parseArgs(InT, args);
        out.seq = in.seq;
        out.type = dap.MessageType.response;
        return in;
    }

    pub const commands = struct {
        pub fn @"continue"() !void {
            common.command_listener.?.break_mutex.lock();
            common.command_listener.?.break_mutex.unlock();
            common.command_listener.?.resume_condition.broadcast();
        }

        pub fn cancel(_: ?ArgumentsList) !void {
            //TODO
        }

        pub fn clearDataBreakpoints(_: ?ArgumentsList) !void {
            shaders.instance.clearDataBreakpoints();
        }

        pub fn clearBreakpoints(args: ?ArgumentsList) !void {
            if (args) |sure_args| {
                if (sure_args.get("path")) |path| {
                    const source = try shaders.GenericLocator.parse(path);
                    switch (source) {
                        .programs => |locator| if (try shaders.instance.Programs.getNestedByLocator(locator.program orelse return error.TargetNotFound, locator.source orelse return error.TargetNotFound)) |shader| shader.clearBreakpoints(),
                        .sources => |locator| if (try shaders.instance.Shaders.getStoredByLocator(locator orelse return error.TargetNotFound)) |shader| shader.*.clearBreakpoints(),
                    }
                } else {
                    return error.ParameterMissing;
                }
            } else {
                return error.WrongParameters;
            }
        }

        pub fn completion(_: ?ArgumentsList) !void {
            //TODO
        }

        pub fn dataBreakpointInfo(_: ?ArgumentsList) !void {
            //TODO
        }

        pub fn abort() !void {
            std.process.abort();
        }

        fn getUnsentBreakpoints() !std.ArrayListUnmanaged(dap.Breakpoint) {
            var breakpoints_to_send = try std.ArrayListUnmanaged(dap.Breakpoint).initCapacity(common.allocator, shaders.instance.breakpoints_to_send.items.len);
            for (shaders.instance.breakpoints_to_send.items) |bp| {
                if (shaders.instance.Shaders.all.get(bp[0])) |shader| {
                    if (shader.items.len > bp[1]) {
                        if (shader.items[bp[1]].breakpoints.items[bp[2]]) |yes_bp| {
                            const dap_bp = try yes_bp.toDAPAlloc(common.allocator, null, bp[1]);
                            try breakpoints_to_send.append(common.allocator, dap_bp);
                        }
                    }
                }
            }
            return breakpoints_to_send;
        }

        pub fn debug() !String {
            shaders.instance.debugging = true;
            var breakpoints_to_send = try getUnsentBreakpoints();
            defer {
                for (breakpoints_to_send.items) |bp| {
                    common.allocator.free(bp.path);
                }
                breakpoints_to_send.deinit(common.allocator);
            }

            return std.json.stringifyAlloc(common.allocator, breakpoints_to_send.items, json_options);
        }

        pub fn noDebug() !void {
            try @"continue"();
            shaders.instance.revert_requested = true;
        }

        pub fn evaluate(_: ?ArgumentsList) !void {
            //TODO
        }

        fn getPossibleBreakpointsAlloc(tree: *const analyzer.parse.Tree, params: dap.BreakpointLocationArguments, source: String) ![]dap.BreakpointLocation {
            var result = std.ArrayListUnmanaged(dap.BreakpointLocation){};
            // find all statements
            for (tree.nodes.items(.tag), 0..) |tag, node| {
                if (tag == .statement) {
                    const range = tree.nodeSpan(@intCast(node)).range(source);
                    if (range.start.line < params.line) {
                        continue;
                    }

                    if (params.endLine) |el| if (range.start.line > el) {
                        break;
                    };
                    if (params.column == null and params.endLine == null and params.endColumn == null) {
                        if (range.start.line > params.line) {
                            break;
                        }
                    }
                    try result.append(common.allocator, dap.BreakpointLocation{
                        .line = range.start.line,
                        .column = range.start.character,
                        .endLine = range.end.line,
                        .endColumn = range.end.character,
                    });
                }
            }
            return try result.toOwnedSlice(common.allocator);
        }

        pub fn possibleBreakpoints(args: ?ArgumentsList) !String {
            //var result = std.ArrayList(debug.BreakpointLocation).init(common.allocator);
            const in_params = try parseArgs(dap.BreakpointLocationArguments, args);
            // bounded by source, lines and cols in params
            var tree: *const analyzer.parse.Tree = undefined;
            var source: String = undefined;

            if (try analysis.state.workspace.getDocument(.{ .uri = in_params.path })) |document| {
                source = document.source();
                tree = &(try document.parseTree()).tree;
            } else switch (try shaders.GenericLocator.parse(in_params.path)) {
                .programs => |locator| if (try shaders.instance.Programs.getNestedByLocator(locator.program orelse return error.TargetNotFound, locator.source orelse return error.TargetNotFound)) |shader| {
                    source = shader.getSource() orelse return error.NoSource;
                    tree = try shader.parseTree();
                },
                .sources => |locator| if (try shaders.instance.Shaders.getStoredByLocator(locator orelse return error.TargetNotFound)) |shader| {
                    source = shader.*.getSource() orelse return error.NoSource;
                    tree = try shader.*.parseTree();
                },
            }

            const result = try getPossibleBreakpointsAlloc(tree, in_params, source);
            defer common.allocator.free(result);
            return std.json.stringifyAlloc(common.allocator, dap.BreakpointLocationsResponse{
                .breakpoints = result,
            }, json_options);
        }

        pub fn getStepInTargets(_: ?ArgumentsList) !void {
            //TODO
        }

        pub fn readMemory(_: ?ArgumentsList) !void {
            //TODO
        }

        pub fn scopes(_: ?ArgumentsList) !void {
            //TODO
        }

        fn getPartOr0(locator: storage.Locator) usize {
            return switch (locator) {
                .untagged => |combined| combined.part,
                else => 0,
            };
        }

        pub fn setBreakpoint(args: ?ArgumentsList) !String {
            const breakpoint = try parseArgs(struct {
                path: String,
                line: usize,
                column: usize,
            }, args);
            const new = shaders.Breakpoint{
                .line = breakpoint.line,
                .column = breakpoint.column,
            };
            const result = blk: {
                const source = try shaders.GenericLocator.parse(breakpoint.path);
                break :blk switch (source) {
                    .programs => |locator| if (try shaders.instance.Programs.getNestedByLocator(locator.program orelse return error.TargetNotFound, locator.source orelse return error.TargetNotFound)) |shader| //
                        try shader.addBreakpoint(
                            new,
                            common.allocator,
                            try shaders.instance.Programs.getStoredByLocator(locator.program.?),
                            getPartOr0(locator.source orelse return error.TargetNotFound),
                        )
                    else
                        return error.TargetNotFound,
                    .sources => |locator| if (try shaders.instance.Shaders.getStoredByLocator(locator orelse return error.TargetNotFound)) |shader| try shader.*.addBreakpoint(
                        new,
                        common.allocator,
                        null,
                        getPartOr0(locator.?),
                    ) else return error.TargetNotFound,
                };
            };
            defer common.allocator.free(result.path);
            return std.json.stringifyAlloc(common.allocator, result, .{});
        }

        pub fn setDataBreakpoint(args: ?ArgumentsList) !String {
            const d_breakpoint = try parseArgs(dap.DataBreakpoint, args);
            const response_b = try shaders.instance.setDataBreakpoint(d_breakpoint);
            return std.json.stringifyAlloc(common.allocator, response_b, .{});
        }

        pub fn setExpression(_: ?ArgumentsList) !void {
            //TODO
        }

        pub fn setFunctionBreakpoint(_: ?ArgumentsList) !void {
            //TODO
        }

        pub fn setVariable(_: ?ArgumentsList) !void {
            //TODO
        }

        pub fn stackTrace(_: ?ArgumentsList) !void {
            //TODO
        }

        pub fn stepIn(_: ?ArgumentsList) !void {
            //TODO
        }

        pub fn stepLine(_: ?ArgumentsList) !void {
            //TODO
        }

        pub fn stepOut(_: ?ArgumentsList) !void {
            //TODO
        }

        pub fn stepStatement(_: ?ArgumentsList) !void {
            //TODO
        }

        pub fn state() !String {
            var breakpoints_to_send = try getUnsentBreakpoints();
            defer {
                for (breakpoints_to_send.items) |bp| {
                    common.allocator.free(bp.path);
                }
                breakpoints_to_send.deinit(common.allocator);
            }
            const threads_to_send = try shaders.instance.listThreads(common.allocator);
            defer {
                for (threads_to_send) |thread| {
                    thread.deinit(common.allocator);
                }
                common.allocator.free(threads_to_send);
            }
            return std.json.stringifyAlloc(common.allocator, .{
                .threads = threads_to_send,
                .breakpoints = breakpoints_to_send.items,
                .lsp = if (analysis.isRunning()) setting_vars.languageServerPort else null,
            }, .{});
        }

        pub fn threads() !String {
            const threads_list = try shaders.instance.listThreads(common.allocator);
            defer {
                for (threads_list) |thread| {
                    thread.deinit(common.allocator);
                }
                common.allocator.free(threads_list);
            }
            return std.json.stringifyAlloc(common.allocator, threads_list, .{});
        }

        pub fn variables(_: ?ArgumentsList) !void {
            //TODO
        }

        pub fn writeMemory(_: ?ArgumentsList) !void {
            //TODO
        }

        const ListArgs = struct { path: String, recursive: ?bool, physical: ?bool };
        fn listStorage(stor: anytype, locator: ?storage.Locator, args: ListArgs) !String {
            switch (locator orelse storage.Locator{ .untagged = .{ .ref = 0, .part = 0 } }) {
                .tagged => |path| {
                    var result = try stor.listTagged(common.allocator, path, args.recursive orelse false, args.physical orelse true);
                    if (path.len == 0 or std.mem.eql(u8, path, "/")) {
                        result = try common.allocator.realloc(result, result.len + 1);
                        result[result.len - 1] = try common.allocator.dupeZ(u8, storage.untagged_path ++ "/"); // add vthe irtual untagged directory
                    }
                    defer {
                        for (result) |p| {
                            common.allocator.free(std.mem.span(p));
                        }
                        common.allocator.free(result);
                    }
                    return try common.joinInnerZ(common.allocator, "\n", result);
                },
                .untagged => |ref| {
                    const result = try stor.listUntagged(common.allocator, ref.ref);
                    defer {
                        for (result) |path| {
                            common.allocator.free(std.mem.span(path));
                        }
                        common.allocator.free(result);
                    }
                    return try common.joinInnerZ(common.allocator, "\n", result);
                },
            }
        }

        //
        // Virtual filesystem commands
        //
        /// The path must start with `/sources/` or `/programs/`
        /// path: String, recursive: bool[false]
        pub fn list(args: ?ArgumentsList) !String {
            const args_result = try parseArgs(ListArgs, args);

            return switch (try shaders.GenericLocator.parse(args_result.path)) {
                .programs => |locator| listStorage(shaders.instance.Programs, locator.program, args_result),
                .sources => |locator| listStorage(shaders.instance.Shaders, locator, args_result),
            };
        }

        pub fn readFile(args: ?ArgumentsList) !String {
            const args_result = try parseArgs(struct { path: String }, args);

            switch (try shaders.GenericLocator.parse(args_result.path)) {
                .programs => |locator| if (try shaders.instance.Programs.getNestedByLocator(locator.program orelse return error.TargetNotFound, locator.source orelse return error.TargetNotFound)) |shader| {
                    const source = shader.getSource();
                    if (source) |s| {
                        return s;
                    } else {
                        return error.NoSource;
                    }
                } else {
                    return error.TargetNotFound;
                },
                .sources => |locator| if (try shaders.instance.Shaders.getStoredByLocator(locator orelse return error.TargetNotFound)) |shader| {
                    const source = shader.*.getSource();
                    if (source) |s| {
                        return s;
                    } else {
                        return error.NoSource;
                    }
                } else {
                    return error.TargetNotFound;
                },
            }
        }
        const StatRequest = struct {
            path: String,
        };

        pub fn stat(args: ?ArgumentsList) !String { // TODO more effective than iterating through all mappings
            const args_result = try parseArgs(StatRequest, args);

            return std.json.stringifyAlloc(common.allocator, try shaders.instance.stat(try shaders.GenericLocator.parse(args_result.path)), json_options);
        }

        //
        // Services control commands
        //
        pub fn editorWindowShow() !void {
            if (options.embedEditor) {
                return editor.windowShow(common.command_listener);
            }
        }

        pub fn editorWindowTerminate() !void {
            if (options.embedEditor) {
                return editor.windowTerminate();
            }
        }

        pub fn editorServerStart() !void {
            if (options.embedEditor) {
                return editor.serverStart(common.command_listener);
            }
        }

        pub fn editorServerStop() !void {
            if (options.embedEditor) {
                return editor.serverStop();
            }
        }

        /// port: ?u16. 1st fallback: settings_vars.language_server_port, 2nd fallback: common.default_lsp_port
        pub fn languageServerStart(args: ?ArgumentsList) !String {
            const parsed = try parseArgs(?struct { port: ?u16 }, args);
            const port = (if (parsed) |p| p.port else null) orelse setting_vars.languageServerPort;
            try analysis.serverStart(port);
            return std.fmt.allocPrint(common.allocator, "{d}", .{port});
        }

        pub fn languageServerStop() !void {
            return analysis.serverStop();
        }

        /// path: String
        pub fn listBreakpoints(args: ?ArgumentsList) ![]const String {
            if (args) |sure_args| {
                if (sure_args.get("path")) |path| {
                    const shader = try shaders.instance.Shaders.getStoredByPath(path);
                    var result = std.ArrayList(String).init(common.allocator);
                    for (shader.*.breakpoints.items) |maybe_bp| {
                        if (maybe_bp) |bp| {
                            try result.append(try std.fmt.allocPrint(common.allocator, "{?d},{?d}", .{ bp.line, bp.column }));
                        }
                    }
                    return result.toOwnedSlice();
                }
            }
            return error.FileNotFound;
        }

        var help_out: [
            blk: { // Compute the number of functions
                comptime var count = 0;
                for (@typeInfo(commands).Struct.decls) |decl_info| {
                    const decl = @field(commands, decl_info.name);
                    if (@typeInfo(@TypeOf(decl)) == .Fn) {
                        count += 1;
                    }
                }
                break :blk count;
            }
        ]String = undefined;
        pub fn help() ![]const String {
            var i: usize = 0;
            inline for (@typeInfo(commands).Struct.decls) |decl_info| {
                const decl = @field(commands, decl_info.name);
                if (@typeInfo(@TypeOf(decl)) == .Fn) {
                    defer i += 1;
                    help_out[i] = decl_info.name;
                }
            }
            return &help_out;
        }

        pub fn settings(args: ?ArgumentsList) (error{ UnknownSettingName, OutOfMemory } || std.fmt.ParseIntError)![]const String {
            const settings_decls = @typeInfo(setting_vars).Struct.decls;
            if (args == null) {
                var values = try common.allocator.alloc(String, settings_decls.len);
                inline for (settings_decls, 0..) |decl, i| {
                    values[i] = try std.json.stringifyAlloc(common.allocator, @field(setting_vars, decl.name), json_options);
                }
                return values;
            }
            var iter = args.?.keyIterator();
            var results = std.ArrayList(String).init(common.allocator);
            // For each setting name in the request
            while (iter.next()) |key| {
                const value = args.?.get(key.*);

                try struct {
                    fn setBool(comptime name: String, target_val: ?String) void {
                        @field(setting_vars, name) = stringToBool(target_val);
                    }

                    fn setInt(comptime name: String, comptime T: type, target_val: ?String) !void {
                        @field(setting_vars, name) = try std.fmt.parseInt(T, target_val orelse "", 0);
                    }

                    fn setAny(name: String, target_val: ?String) !void {
                        // switch on setting name
                        inline for (settings_decls) |decl| {
                            if (std.ascii.eqlIgnoreCase(decl.name, name)) {
                                const field = @field(setting_vars, decl.name);
                                switch (@TypeOf(field)) {
                                    bool => setBool(decl.name, target_val),
                                    u16 => try setInt(decl.name, u16, target_val),
                                    else => |t| DeshaderLog.err("Unknown setting datatype: {}", .{t}),
                                }
                            }
                        }
                        DeshaderLog.err("Unknown setting name: {s}", .{name});
                        return error.UnknownSettingName;
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
        pub fn settings(result: anyerror![]const String) void {
            const r = result catch return;
            for (r) |line| {
                common.allocator.free(line);
            }
            common.allocator.free(r);
        }

        fn stringReturning(result: anyerror!String) void {
            const r = result catch return;
            common.allocator.free(r);
        }

        const list = stringReturning;
        const setBreakpoint = stringReturning;
        const stat = stringReturning;
        const state = stringReturning;
        const cancel = stringReturning;
        const completion = stringReturning;
        const debug = stringReturning;
        const dataBreakpointInfo = stringReturning;
        const evaluate = stringReturning;
        const possibleBreakpoints = stringReturning;
        const getStepInTargets = stringReturning;
        const languageServerStart = stringReturning;
        const readMemory = stringReturning;
        const scopes = stringReturning;
        const setDataBreakpoint = stringReturning;
        const setExpression = stringReturning;
        const setFunctionBreakpoint = stringReturning;
        const setVariable = stringReturning;
        const stackTrace = stringReturning;
        const stepIn = stringReturning;
        const stepLine = stringReturning;
        const stepOut = stringReturning;
        const stepStatement = stringReturning;
        const threads = stringReturning;
        const variables = stringReturning;
        const writeMemory = stringReturning;
    };
};
