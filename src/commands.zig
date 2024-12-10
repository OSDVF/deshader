// Copyright (C) 2024  Ondřej Sabela
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const positron = @import("positron");
const serve = @import("serve");
const websocket = @import("websocket");

const common = @import("common");
const logging = common.logging;
const DeshaderLog = common.log;
const options = @import("options");
const storage = @import("services/storage.zig");
const dap = @import("services/debug.zig");
const shaders = @import("services/shaders.zig");
const analyzer = @import("glsl_analyzer");

const String = []const u8;
const CString = [*:0]const u8;
const Route = positron.Provider.Route;
const logParsing = false;

pub const setting_vars = struct {
    pub var logIntoResponses = false;
    /// Are shader parts automatically merged in glShaderSource? (so they will all belong to the same tag)
    pub var singleChunkShader: bool = true;
    pub var stackTraces: bool = false;
};

pub var instance: ?*MutliListener = null;

pub const MutliListener = struct {
    const ArgumentsMap = common.ArgumentsMap;
    pub const Config = struct {
        protocol: enum {
            WS,
            HTTP,
        },
        host: String,
        port: u16,
    };
    const json_options = std.json.StringifyOptions{ .whitespace = .minified, .emit_null_optional_fields = false };

    // various command providers
    http: ?*positron.Provider = null,
    ws: std.ArrayList(*websocket.Conn) = undefined,

    ws_configs: std.ArrayListUnmanaged(websocket.Config) = .{},

    provide_thread: ?std.Thread = null,
    websocket_thread: ?std.Thread = null,
    websocket_arena: std.heap.ArenaAllocator = undefined,
    provider_arena: std.heap.ArenaAllocator = undefined,
    secure: bool = false, //TODO use SSL
    break_mutex: std.Thread.Mutex = .{},
    resume_condition: std.Thread.Condition = .{},
    do_resume: bool = false,
    paused: bool = false,

    pub fn start(allocator: std.mem.Allocator, config: []const Config) !*@This() {
        const self = try allocator.create(@This());
        self.* = @This(){}; // zero out the struct
        errdefer allocator.destroy(self);
        self.ws = std.ArrayList(*websocket.Conn).init(allocator);
        errdefer self.ws.deinit();

        var http_configs = std.ArrayListUnmanaged(Config){};
        defer http_configs.deinit(allocator);

        self.provider_arena = std.heap.ArenaAllocator.init(allocator);

        // Filter configs
        for (config) |c| {
            try switch (c.protocol) {
                .WS => self.ws_configs.append(allocator, websocket.Config{
                    .address = c.host,
                    .port = c.port,
                }),
                .HTTP => http_configs.append(allocator, c),
            };
        }

        var addr_in_use = false;
        var some_started = false;

        // WS Command Listener
        for (self.ws_configs.items) |ws_config| {
            DeshaderLog.info("Starting websocket listener on {s}:{d} from {s}", .{ ws_config.address, ws_config.port, common.selfExePath() catch "?" });
            if (!try common.isPortFree(ws_config.address, ws_config.port)) {
                addr_in_use = true;
                DeshaderLog.err("Port {d} is already in use", .{ws_config.port});
            }
            some_started = true;

            self.websocket_thread = try std.Thread.spawn(
                .{ .allocator = common.allocator },
                struct {
                    fn listen(list: *MutliListener, conf: websocket.Config) void {
                        var alloc = common.GPA{};
                        defer _ = alloc.deinit();

                        var listener = websocket.Server(WSHandler).init(alloc.allocator(), conf) catch |err|
                            return DeshaderLog.err("Error while creating webscoket listener: {any}", .{err});

                        listener.listen(list) catch |err|
                            DeshaderLog.err("Error while listening for websocket commands: {any}", .{err});
                    }
                }.listen,
                .{ self, ws_config },
            );
            self.websocket_thread.?.setName("CmdListWS") catch {};
        }

        // HTTP Command listener
        for (http_configs.items) |http_config| { // TODO select interface to run on
            DeshaderLog.info("Starting HTTP listener on {s}:{d} from {s}", .{ http_config.host, http_config.port, common.selfExePath() catch "?" });

            self.http = try positron.Provider.create(self.provider_arena.allocator(), http_config.port);
            errdefer {
                self.http.?.destroy();
                self.http = null;
            }
            some_started = true;

            self.http.?.not_found_text = "Unknown command";

            inline for (@typeInfo(commands).Struct.decls) |function| {
                const command = @field(commands, function.name);
                _ = try self.addHTTPCommand("/" ++ function.name, command, if (@hasDecl(free_funcs, function.name)) @field(free_funcs, function.name) else null);
            }
            self.provide_thread = try std.Thread.spawn(.{ .allocator = common.allocator }, struct {
                fn wrapper(provider: *positron.Provider) void {
                    provider.run() catch |err| {
                        DeshaderLog.err("Error while providing HTTP commands: {any}", .{err});
                    };
                }
            }.wrapper, .{self.http.?});
            self.provide_thread.?.setName("CmdListHTTP") catch {};
        }

        if (!some_started) {
            DeshaderLog.warn("No listeners started", .{});
            if (addr_in_use) {
                return error.AddressInUse;
            }
        }

        return self;
    }

    pub fn stop(self: *@This()) void {
        if (self.http) |http| {
            http.destroy();
            self.provide_thread.?.join();
            self.provider_arena.deinit();
            self.provide_thread = null;
            self.http = null;
        }
        for (self.ws.items) |ws| {
            ws.writeText("432: Closing connection\n") catch {};
            ws.close(.{ .code = 1001, .reason = "server shutting down" }) catch {};
            // Close forcefully
            std.posix.shutdown(ws.stream.handle, .both) catch |e| {
                DeshaderLog.err("Error while shutting down websocket: {}", .{e});
            };
        }
        self.ws_configs.deinit(self.ws.allocator);
        if (self.hasClient()) {
            self.websocket_thread.?.join();
            self.websocket_thread = null;
            self.ws.clearAndFree();
        }
        self.provider_arena.deinit();
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

            fn wrapper(provider: *positron.Provider, _: *Route, context: *serve.HttpContext) Route.Error!void {
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
                        const url = try provider.allocator.dupe(u8, context.request.url);
                        defer provider.allocator.free(url);
                        var args = try common.argsFromFullCommand(provider.allocator, url);
                        defer if (args) |*a| {
                            a.deinit(provider.allocator);
                        };
                        break :blk comm(args);
                    },
                    2 => blk: {
                        const url = try provider.allocator.dupe(u8, context.request.url);
                        defer provider.allocator.free(url);
                        var args = try common.argsFromFullCommand(provider.allocator, url);
                        defer if (args) |*a| {
                            var it = a.valueIterator();
                            while (it.next()) |s| {
                                provider.allocator.free(s.*);
                            }
                            a.deinit(provider.allocator);
                        };
                        var reader = try context.request.reader();
                        defer reader.deinit();
                        const body = try reader.readAllAlloc(provider.allocator);
                        defer provider.allocator.free(body);
                        break :blk comm(args, body);
                    },
                    else => @compileError("Command " ++ @typeName(comm) ++ " has invalid number of arguments. First is state. Further only none, parameters and body are available."),
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

                    const result = try std.fmt.allocPrint(provider.allocator, "Error while executing command {s}: {} at\n{?}", .{ name, err, if (setting_vars.stackTraces) @errorReturnTrace() else &common.null_trace });
                    defer provider.allocator.free(result);
                    DeshaderLog.err("{s}", .{result});
                    try writer.writeAll(result);
                    try writer.writeByte('\n'); //Alwys add a newline to the end
                }
            }
        };
        command_route.comm = command;
        command_route.free = @alignCast(@ptrCast(freee));
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
        var command_array: [decls.len]struct { String, comInfo } = undefined;
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
        const map = std.StaticStringMap(@TypeOf(command_array[0][1])).initComptime(command_array);
        break :blk map;
    };

    const WSHandler = struct {
        conn: *websocket.Conn,
        context: *MutliListener,

        const Conn = websocket.Conn;
        const Message = websocket.Message;
        const Handshake = websocket.Handshake;

        pub fn init(h: Handshake, conn: *Conn, context: *MutliListener) !@This() {
            try context.ws.append(conn);
            _ = h;

            return @This(){
                .conn = conn,
                .context = context,
            };
        }

        fn writeAll(self: *@This(), opcode: websocket.OpCode, data: []const String) !void {
            var writer = self.conn.writeBuffer(common.allocator, opcode);
            defer writer.deinit();

            for (data) |line| {
                _ = try writer.write(line);
            }
            try writer.flush();
        }

        /// command_echo echoes either the input command or the "seq" parameter of the request. "seq" is not checked agains duplicates or anything.
        fn handleInner(self: *@This(), result_or_error: anytype, command_echo: String, free: ?*const fn (@TypeOf(result_or_error)) void) !void {
            defer if (free) |f| f(result_or_error);
            var http_code_buffer: [3]u8 = undefined;
            const accepted = "202: Accepted\n";
            if (result_or_error) |result| {
                switch (@TypeOf(result)) {
                    void => {
                        try self.writeAll(.text, &.{ accepted, command_echo, "\n" });
                    },
                    String => {
                        try self.writeAll(.text, &.{ accepted, command_echo, "\n", result, "\n" });
                    },
                    []const CString => {
                        const flattened = try common.joinInnerZ(common.allocator, "\n", result);
                        defer common.allocator.free(flattened);
                        try self.writeAll(.text, &.{ accepted, command_echo, "\n", flattened, "\n" });
                    },
                    []const String => {
                        const flattened = try std.mem.join(common.allocator, "\n", result);
                        defer common.allocator.free(flattened);
                        try self.writeAll(.text, &.{ accepted, command_echo, "\n", flattened, "\n" });
                    },
                    serve.HttpStatusCode => {
                        try self.writeAll(.text, &.{
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
            } else |err| { // TODO there are no stack traces and must be captured a in the function above
                const text = try std.fmt.allocPrint(common.allocator, "500: Internal Server Error\n{s}\n{} at\n{?}", .{ command_echo, err, if (setting_vars.stackTraces) @errorReturnTrace() else &common.null_trace });
                defer common.allocator.free(text);
                try self.conn.writeText(text);
            }
        }

        pub fn clientMessage(self: *@This(), message: String) !void {
            errdefer |err| {
                DeshaderLog.err("Error while handling websocket command: {any}", .{err});
                DeshaderLog.debug("Message: {any}", .{message});
                const err_mess = std.fmt.allocPrint(common.allocator, "Error: {any}\n", .{err}) catch "";
                defer if (err_mess.len > 0) common.allocator.free(err_mess);
                self.conn.writeText(err_mess) catch |er| DeshaderLog.err("Error while writing error: {any}", .{er});
            }
            var iterator = std.mem.splitScalar(u8, message, 0);
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
            const query_d = try common.allocator.dupe(u8, query);
            defer common.allocator.free(query_d);

            const target_command = ws_commands.get(command_name);
            if (target_command) |tc| {
                var parsed_args: ?ArgumentsMap = if (query.len > 0) try common.queryToArgsMap(common.allocator, query_d) else null;
                defer if (parsed_args) |*a| {
                    a.deinit(common.allocator);
                };
                if (parsed_args) |a| if (a.get("seq")) |seq| {
                    request = seq;
                };

                try switch (tc.r) {
                    .Void => switch (tc.a) {
                        0 => handleInner(self, @as(*const fn () anyerror!void, @alignCast(@ptrCast(tc.c)))(), request, @alignCast(@ptrCast(tc.free))),
                        1 => handleInner(self, @as(*const fn (?ArgumentsMap) anyerror!void, @alignCast(@ptrCast(tc.c)))(parsed_args), request, @alignCast(@ptrCast(tc.free))),
                        2 => handleInner(self, @as(*const fn (?ArgumentsMap, String) anyerror!void, @alignCast(@ptrCast(tc.c)))(parsed_args, body), request, @alignCast(@ptrCast(tc.free))),
                        else => unreachable,
                    },
                    .String => switch (tc.a) {
                        0 => handleInner(self, @as(*const fn () anyerror!String, @alignCast(@ptrCast(tc.c)))(), request, @alignCast(@ptrCast(tc.free))),
                        1 => handleInner(self, @as(*const fn (?ArgumentsMap) anyerror!String, @alignCast(@ptrCast(tc.c)))(parsed_args), request, @alignCast(@ptrCast(tc.free))),
                        2 => handleInner(self, @as(*const fn (?ArgumentsMap, String) anyerror!String, @alignCast(@ptrCast(tc.c)))(parsed_args, body), request, @alignCast(@ptrCast(tc.free))),
                        else => unreachable,
                    },
                    .CStringArray => switch (tc.a) {
                        0 => handleInner(self, @as(*const fn () anyerror![]const CString, @alignCast(@ptrCast(tc.c)))(), request, @alignCast(@ptrCast(tc.free))),
                        1 => handleInner(self, @as(*const fn (?ArgumentsMap) anyerror![]const CString, @alignCast(@ptrCast(tc.c)))(parsed_args), request, @alignCast(@ptrCast(tc.free))),
                        2 => handleInner(self, @as(*const fn (?ArgumentsMap, String) anyerror![]const CString, @alignCast(@ptrCast(tc.c)))(parsed_args, body), request, @alignCast(@ptrCast(tc.free))),
                        else => unreachable,
                    },
                    .StringArray => switch (tc.a) {
                        0 => handleInner(self, @as(*const fn () anyerror![]const String, @alignCast(@ptrCast(tc.c)))(), request, @alignCast(@ptrCast(tc.free))),
                        1 => handleInner(self, @as(*const fn (?ArgumentsMap) anyerror![]const String, @alignCast(@ptrCast(tc.c)))(parsed_args), request, @alignCast(@ptrCast(tc.free))),
                        2 => handleInner(self, @as(*const fn (?ArgumentsMap, String) anyerror![]const String, @alignCast(@ptrCast(tc.c)))(parsed_args, body), request, @alignCast(@ptrCast(tc.free))),
                        else => unreachable,
                    },
                    .HttpStatusCode => switch (tc.a) {
                        0 => handleInner(self, @as(*const fn () anyerror!serve.HttpStatusCode, @alignCast(@ptrCast(tc.c)))(), request, @alignCast(@ptrCast(tc.free))),
                        1 => handleInner(self, @as(*const fn (?ArgumentsMap) anyerror!serve.HttpStatusCode, @alignCast(@ptrCast(tc.c)))(parsed_args), request, @alignCast(@ptrCast(tc.free))),
                        2 => handleInner(self, @as(*const fn (?ArgumentsMap, String) anyerror!serve.HttpStatusCode, @alignCast(@ptrCast(tc.c)))(parsed_args, body), request, @alignCast(@ptrCast(tc.free))),
                        else => unreachable,
                    },
                };
            } else {
                DeshaderLog.warn("Command not found: {s}", .{command_name});
                try self.conn.writeText("404: Command not found\n");
                return;
            }
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
        stop,
        stopOnBreakpoint,
        stopOnDataBreakpoint,
        stopOnFunction,
        breakpoint,
        output,
        end,
    };

    pub fn sendEvent(self: *@This(), comptime event: Event, body: anytype) !void {
        const string = try std.json.stringifyAlloc(common.allocator, body, json_options);
        defer common.allocator.free(string);
        for (self.ws.items, 0..) |ws, i| {
            const content = try std.mem.concat(common.allocator, u8, &.{
                "600: Event\n",
                @tagName(event) ++ "\n",
                string,
            });
            defer common.allocator.free(content);
            ws.writeText(content) catch |err| {
                if (err == error.NotOpenForWriting) {
                    _ = self.ws.swapRemove(i);
                } else {
                    return err;
                }
            };
        }
        // TODO some HTTP way of sending events (probably persistent connection)
    }

    /// Suspends the thread that calls this function, but processes commands in the meantime
    pub fn eventBreak(self: *@This(), comptime event: Event, body: anytype) !void {
        self.paused = true;
        self.do_resume = false;
        var result = self.sendEvent(event, body);
        while (true) {
            self.break_mutex.lock();
            defer self.break_mutex.unlock();
            result catch { // retry sending the event
                result = self.sendEvent(event, body);
            };
            self.resume_condition.timedWait(&self.break_mutex, 700 * 1000 * 1000) catch if (self.do_resume) {
                self.do_resume = false;
                break;
            } else continue;
            break;
        }
        DeshaderLog.debug("Resuming after event {s}", .{@tagName(event)});
        self.paused = false;
    }

    fn unPause(self: *@This()) void {
        self.break_mutex.lock();
        self.do_resume = true;
        self.resume_condition.broadcast();
        self.break_mutex.unlock();
    }

    pub fn hasClient(self: @This()) bool {
        return self.ws.items.len > 0;
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

                .Array, .Pointer => {
                    if (logParsing) {
                        DeshaderLog.debug("Parsing array/pointer {x}: {s}", .{ @intFromPtr(v.ptr), v });
                    }
                    if (std.meta.Child(inner.type) == u8) {
                        // Probably string
                        return v;
                    } else {
                        const parsed = try std.json.parseFromSlice(inner.type, common.allocator, v, .{});
                        return parsed.value;
                    }
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

    fn parseArgs(comptime result: type, args: ?ArgumentsMap) !result {
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

    pub const commands = struct {
        /// Continues to the next breakpoint
        pub fn @"continue"(args: ?ArgumentsMap) !void {
            shaders.user_action = true;
            const in_params = try parseArgs(dap.ContinueArguments, args);
            const locator: *shaders.ShaderLocator = @ptrFromInt(in_params.threadId);
            try locator.service.@"continue"(locator.shader);

            instance.?.unPause();
        }

        pub fn terminate(args: ?ArgumentsMap) !void {
            shaders.user_action = true;
            const in_params = try parseArgs(dap.TerminateRequest, args);
            if (in_params.restart) |r| {
                if (r) {
                    try noDebug();
                }
            } else {
                try abort(); // TODO better way
            }
        }

        pub fn clearDataBreakpoints(_: ?ArgumentsMap) !void {
            shaders.user_action = true;
            shaders.clearDataBreakpoints();
        }

        pub fn clearBreakpoints(args: ?ArgumentsMap) !void {
            shaders.user_action = true;
            if (args) |sure_args| {
                if (sure_args.get("path")) |path| {
                    const context = try shaders.ContextLocator.parse(path);
                    if (context.service) |s| {
                        if (context.resource) |r| {
                            switch (r) {
                                .programs => |locator| if (try s.Programs.getNestedByLocator((locator.sub orelse return error.TargetNotFound).name, locator.nested)) |shader| return shader.clearBreakpoints(),
                                .sources => |locator| if (try s.Shaders.getStoredByLocator((locator orelse return error.TargetNotFound).name)) |shader| return shader.*.clearBreakpoints(),
                            }
                        }
                    }
                    return error.InvalidPath;
                } else {
                    return error.ParameterMissing;
                }
            } else {
                return error.WrongParameters;
            }
        }

        pub fn completion(_: ?ArgumentsMap) !void {
            //TODO
        }

        pub fn dataBreakpointInfo(_: ?ArgumentsMap) !void {
            //TODO
        }

        pub fn abort() !void {
            std.process.abort();
        }

        fn getUnsentBreakpoints(s: *shaders, breakpoints_to_send: *std.ArrayListUnmanaged(dap.Breakpoint)) !void {
            for (s.breakpoints_to_send.items) |bp| {
                if (s.Shaders.all.get(bp[0])) |shader| {
                    if (shader.items.len > bp[1]) {
                        const part = &shader.items[bp[1]];
                        const stops = try part.possibleSteps();
                        const local_stop = stops.items(.pos)[bp[2]];
                        const dap_bp = dap.Breakpoint{
                            .id = bp[2],
                            .line = local_stop.line,
                            .column = local_stop.character,
                            .verified = true,
                            .path = try s.fullPath(common.allocator, part, null, bp[1]),
                        };
                        try breakpoints_to_send.append(common.allocator, dap_bp);
                    }
                }
            }
        }

        pub fn debug(_: ?ArgumentsMap) !String {
            shaders.user_action = true;

            var breakpoints_to_send = std.ArrayListUnmanaged(dap.Breakpoint){};
            shaders.debugging = true;
            for (shaders.services.values()) |*s| {
                try getUnsentBreakpoints(s, &breakpoints_to_send);
            }
            defer {
                for (breakpoints_to_send.items) |bp| {
                    common.allocator.free(bp.path);
                }
                breakpoints_to_send.deinit(common.allocator);
            }

            return std.json.stringifyAlloc(common.allocator, breakpoints_to_send.items, json_options);
        }

        pub fn noDebug() !void {
            shaders.user_action = true;
            shaders.debugging = false;
            for (shaders.services.values()) |*s| {
                s.revert_requested = true;
            }
            instance.?.unPause();
        }

        pub fn evaluate(args: ?ArgumentsMap) !String {
            const in_args = try parseArgs(dap.EvaluateArguments, args);
            return std.json.stringifyAlloc(common.allocator, dap.EvaluateResponse{
                .result = in_args.expression,
                .type = "TODO",
            }, json_options);
        }

        fn getPossibleBreakpointsAlloc(positions: []const analyzer.lsp.Position, params: dap.BreakpointLocationArguments) ![]dap.BreakpointLocation {
            var result = std.ArrayListUnmanaged(dap.BreakpointLocation){};
            // for (ranges) |range| {
            //     if (range.start.line < params.line) {
            //         continue;
            //     }

            //     if (params.endLine) |el| if (range.start.line > el) {
            //         break;
            //     };
            //     if (params.column == null and params.endLine == null and params.endColumn == null) {
            //         if (range.start.line > params.line) {
            //             break;
            //         }
            //     }
            //     try result.append(common.allocator, dap.BreakpointLocation{
            //         .line = range.start.line,
            //         .column = range.start.character,
            //         .endLine = range.end.line,
            //         .endColumn = range.end.character,
            //     });
            // }
            for (positions) |pos| {
                if (pos.line < params.line) {
                    continue;
                }
                if (params.endLine) |el| if (pos.line > el) {
                    break;
                };
                if (params.column == null and params.endLine == null and params.endColumn == null) {
                    if (pos.line > params.line) {
                        break;
                    }
                }
                try result.append(common.allocator, dap.BreakpointLocation{
                    .line = pos.line,
                    .column = pos.character,
                });
            }
            return try result.toOwnedSlice(common.allocator);
        }

        pub fn pauseMode(args: ?ArgumentsMap) !void {
            const in_params = try parseArgs(struct { single: bool }, args);
            if (shaders.single_pause_mode != in_params.single) {
                shaders.single_pause_mode = in_params.single;
                for (shaders.services.values()) |*s| {
                    s.invalidate();
                }
            }
        }

        pub fn possibleBreakpoints(args: ?ArgumentsMap) !String {
            //var result = std.ArrayList(debug.BreakpointLocation).init(common.allocator);
            const in_params = try parseArgs(dap.BreakpointLocationArguments, args);
            // bounded by source, lines and cols in params
            var positions: []const analyzer.lsp.Position = undefined;
            const context = try shaders.ContextLocator.parse(in_params.path);
            if (context.service) |s| {
                if (context.resource) |r| {
                    switch (r) {
                        .programs => |locator| if (try s.Programs.getNestedByLocator((locator.sub orelse return error.TargetNotFound).name, locator.nested orelse return error.TargetNotFound)) |shader| {
                            positions = (try shader.possibleSteps()).items(.pos);
                        },
                        .sources => |locator| if (try s.Shaders.getStoredByLocator((locator orelse return error.TargetNotFound).name)) |shader| {
                            positions = (try shader.*.possibleSteps()).items(.pos);
                        },
                    }
                } else return error.InvalidPath;
            } else return error.InvalidPath;

            const result = try getPossibleBreakpointsAlloc(positions, in_params);
            defer common.allocator.free(result);
            return std.json.stringifyAlloc(common.allocator, dap.BreakpointLocationsResponse{
                .breakpoints = result,
            }, json_options);
        }

        pub fn getStepInTargets(_: ?ArgumentsMap) !void {
            //TODO
        }

        /// Go to next program step. Enables program stepping when needed.
        pub fn next(args: ?ArgumentsMap) !void {
            shaders.user_action = true;
            const in_params = try parseArgs(dap.NextArguments, args);
            const locator: *shaders.ShaderLocator = @ptrFromInt(in_params.threadId);
            try locator.service.advanceStepping(locator.shader, null);
            instance.?.unPause();
        }

        pub fn readMemory(_: ?ArgumentsMap) !void {
            //TODO
        }

        pub fn scopes(_: ?ArgumentsMap) !void {
            //TODO
        }

        pub fn addBreakpoint(args: ?ArgumentsMap) !String {
            shaders.user_action = true;
            const breakpoint = try parseArgs(struct {
                path: String,
                line: usize,
                column: usize,
            }, args);
            const new = dap.SourceBreakpoint{
                .line = breakpoint.line,
                .column = breakpoint.column,
            };
            const context = try shaders.ContextLocator.parse(breakpoint.path);
            const s = context.service orelse return error.InvalidPath;
            const r = context.resource orelse return error.InvalidPath;
            const result = try s.addBreakpointAlloc(r, new, common.allocator);
            defer common.allocator.free(result.path);

            return std.json.stringifyAlloc(common.allocator, result, json_options);
        }

        pub fn selectThread(args: ?ArgumentsMap) !void {
            shaders.user_action = true;
            const in_params = try parseArgs(struct { shader: usize, thread: []usize, group: ?[]usize }, args);
            try shaders.selectThread(in_params.shader, in_params.thread, in_params.group);
        }

        pub fn setBreakpoints(args: ?ArgumentsMap) !String {
            shaders.user_action = true;
            const in_params = try parseArgs(dap.SetBreakpointsArguments, args);
            const context = try shaders.ContextLocator.parse(in_params.path);
            const s = context.service orelse return error.InvalidPath;
            const r = context.resource orelse return error.InvalidPath;

            var result = std.ArrayListUnmanaged(dap.Breakpoint){};
            defer {
                for (result.items) |bp| {
                    common.allocator.free(bp.path);
                }
                result.deinit(common.allocator);
            }
            const target = try s.getResourcesByLocator(r);
            const shader = (target.shader orelse return error.TargetNotFound).source;
            const i_state = s.state.getPtr(shader.ref);

            var remaining = std.AutoHashMapUnmanaged(usize, void){};
            defer remaining.deinit(common.allocator);
            {
                var it = shader.breakpoints.keyIterator();
                while (it.next()) |i| {
                    _ = try remaining.getOrPut(common.allocator, i.*);
                }
            }

            if (in_params.breakpoints) |bps| {
                for (bps) |bp| {
                    var bp_result = try shader.addBreakpoint(bp);
                    if (bp_result.id) |id| {
                        if (!remaining.remove(id)) { // this is a new breakpoint
                            if (i_state) |st| {
                                st.dirty = true;
                                shader.dirty = true;
                            }
                        }
                    }
                    bp_result.path = try s.fullPath(common.allocator, shader, target.program, target.shader.?.part);
                    try result.append(common.allocator, bp_result);
                }
                var it = remaining.keyIterator();
                while (it.next()) |i| {
                    try shader.removeBreakpoint(i.*);
                    if (i_state) |st| {
                        st.dirty = true;
                        shader.dirty = true;
                    }
                }
            } else {
                shader.clearBreakpoints();
                if (i_state) |st| {
                    st.dirty = true;
                    shader.dirty = true;
                }
            }

            return std.json.stringifyAlloc(common.allocator, result.items, json_options);
        }

        pub fn setDataBreakpoint(args: ?ArgumentsMap) !String {
            shaders.user_action = true;
            const d_breakpoint = try parseArgs(dap.DataBreakpoint, args);
            const response_b = try shaders.setDataBreakpoint(d_breakpoint);
            return std.json.stringifyAlloc(common.allocator, response_b, json_options);
        }

        pub fn setExpression(_: ?ArgumentsMap) !void {
            //TODO
        }

        pub fn setFunctionBreakpoint(_: ?ArgumentsMap) !void {
            //TODO
        }

        pub fn setVariable(_: ?ArgumentsMap) !void {
            //TODO
        }

        pub fn stackTrace(args: ?ArgumentsMap) !String {
            // Get program and shader ref
            const parsed_args = try parseArgs(dap.StackTraceArguments, args);
            const trace = try shaders.stackTrace(common.allocator, parsed_args);
            defer {
                for (trace.stackFrames) |fr| {
                    common.allocator.free(fr.path);
                }
                common.allocator.free(trace.stackFrames);
            }
            return try std.json.stringifyAlloc(common.allocator, trace, json_options);
        }

        pub fn stepIn(_: ?ArgumentsMap) !void {
            //TODO
        }

        pub fn stepOut(_: ?ArgumentsMap) !void {
            //TODO
        }

        /// The full state of the debugger
        pub fn state() !String {
            var breakpoints_to_send = std.ArrayListUnmanaged(dap.Breakpoint){};
            defer {
                for (breakpoints_to_send.items) |bp| {
                    common.allocator.free(bp.path);
                }
                breakpoints_to_send.deinit(common.allocator);
            }
            var running_to_send = std.ArrayListUnmanaged(shaders.RunningShader){};
            for (shaders.services.values()) |*s| {
                try getUnsentBreakpoints(s, &breakpoints_to_send);
                try s.runningShaders(common.allocator, &running_to_send);
            }
            defer {
                for (running_to_send.items) |runnning| {
                    runnning.deinit(common.allocator);
                }
                running_to_send.deinit(common.allocator);
            }
            return std.json.stringifyAlloc(common.allocator, .{
                .breakpoints = breakpoints_to_send.items,
                .debugging = shaders.debugging,
                .paused = instance.?.paused,
                .runningShaders = running_to_send.items,
                .singlePauseMode = shaders.single_pause_mode,
            }, json_options);
        }

        pub fn runningShaders() !String {
            var threads_list = std.ArrayListUnmanaged(shaders.RunningShader){};
            for (shaders.services.values()) |*s| {
                try s.runningShaders(common.allocator, &threads_list);
            }
            defer {
                for (threads_list.items) |thread| {
                    thread.deinit(common.allocator);
                }
                threads_list.deinit(common.allocator);
            }
            return std.json.stringifyAlloc(common.allocator, threads_list.items, json_options);
        }

        pub fn variables(_: ?ArgumentsMap) !void {
            //TODO
        }

        pub fn writeMemory(_: ?ArgumentsMap) !void {
            //TODO
        }

        const ListArgs = struct { path: String, recursive: ?bool, physical: ?bool };
        fn listStorage(stor: anytype, locator: ?storage.Locator, args: ListArgs, postfix: ?String) ![]CString {
            switch ((locator orelse storage.Locator{ .name = .{ .untagged = .{ .ref = 0, .part = 0 } } }).name) {
                .tagged => |path| {
                    var result = try stor.listTagged(common.allocator, path, args.recursive orelse false, args.physical orelse true, postfix);
                    if (path.len == 0 or std.mem.eql(u8, path, "/")) {
                        result = try common.allocator.realloc(result, result.len + 1);
                        result[result.len - 1] = try common.allocator.dupeZ(u8, storage.untagged_path ++ "/"); // add the virtual /untagged/ directory
                    }
                    return result;
                },
                .untagged => |ref| {
                    return try stor.listUntagged(common.allocator, ref.ref, ">");
                },
            }
        }

        //
        // Virtual filesystem commands
        //
        /// The path must start with `/sources/` or `/programs/`
        /// path: String, recursive: bool[false]
        pub fn list(args: ?ArgumentsMap) !String {
            const in_args = try parseArgs(ListArgs, args);

            const context = try shaders.ContextLocator.parse(in_args.path);
            if (context.service) |service| {
                if (context.resource) |res| {
                    const lines = try switch (res) {
                        .programs => |locator| listStorage(&service.Programs, locator.sub, in_args, ">"), //indicate that sources under programs are "symlinks"
                        .sources => |locator| listStorage(&service.Shaders, locator, in_args, null),
                    };
                    defer {
                        for (lines) |line| {
                            common.allocator.free(std.mem.span(line));
                        }
                        common.allocator.free(lines);
                    }
                    return try common.joinInnerZ(common.allocator, "\n", lines);
                } else {
                    return try common.allocator.dupe(u8, "/sources/\n/programs/\n");
                }
            } else {
                const contexts = shaders.services.keys();
                const result = try common.allocator.alloc(String, contexts.len);
                for (contexts, result) |c, *r| {
                    r.* = try std.fmt.allocPrint(common.allocator, "/{x}/", .{@intFromPtr(c)});
                }
                defer {
                    for (result) |r| {
                        common.allocator.free(r);
                    }
                    common.allocator.free(result);
                }
                return std.mem.join(common.allocator, "\n", result);
            }
        }

        pub fn readFile(args: ?ArgumentsMap) !String {
            const args_result = try parseArgs(struct { path: String }, args);

            const context = try shaders.ContextLocator.parse(args_result.path);
            if (context.service) |service| {
                if (context.resource) |res| {
                    switch (res) {
                        .programs => |locator| if (try service.Programs.getNestedByLocator((locator.sub orelse return error.TargetNotFound).name, locator.nested orelse return error.TargetNotFound)) |shader| {
                            return shader.getSource() orelse "";
                        },
                        .sources => |locator| if (try service.Shaders.getStoredByLocator((locator orelse return error.TargetNotFound).name)) |shader| {
                            return shader.*.getSource() orelse "";
                        },
                    }
                }
            }
            return error.TargetNotFound;
        }
        const StatRequest = struct {
            path: String,
        };

        pub fn stat(args: ?ArgumentsMap) !String {
            const args_result = try parseArgs(StatRequest, args);

            const context = try shaders.ContextLocator.parse(args_result.path);
            const now = std.time.milliTimestamp();
            // Used for root
            const virtual = storage.StatPayload{
                .type = @intFromEnum(storage.FileType.Directory),
                .accessed = now,
                .created = 0,
                .modified = now,
                .size = 0,
            };
            return std.json.stringifyAlloc(common.allocator, if (context.service) |s|
                if (context.resource) |locator|
                    try s.stat(locator)
                else
                    virtual
            else
                virtual, json_options);
        }

        /// Returns the currently set breakpoints
        /// ### Arguments (not required)
        /// `path`: String
        pub fn listBreakpoints(args: ?ArgumentsMap) ![]const String {
            var result = std.ArrayList(String).init(common.allocator);
            if (args) |sure_args| {
                if (sure_args.get("path")) |path| {
                    const context = try shaders.ContextLocator.parse(path);
                    const s = context.service orelse return error.InvalidPath;
                    const locator = context.resource orelse return error.InvalidPath;
                    const shader = ((try s.getResourcesByLocator(locator)).shader orelse return error.TargetNotFound).source;
                    const steps = try shader.*.possibleSteps();
                    const steps_pos = steps.items(.pos);
                    var it = shader.*.breakpoints.keyIterator();
                    while (it.next()) |bp| {
                        try result.append(try std.fmt.allocPrint(common.allocator, "{?d},{?d}", .{ steps_pos[bp.*].line, steps_pos[bp.*].character }));
                    }
                    return result.toOwnedSlice();
                }
            }
            // From all files
            for (shaders.services.values()) |*s| {
                var it = s.Shaders.all.valueIterator();
                while (it.next()) |sh| {
                    for (sh.*.items) |*part| {
                        var it2 = part.breakpoints.keyIterator();
                        const steps = try part.possibleSteps();
                        while (it2.next()) |bp| {
                            const pos = steps.items(.pos)[bp.*];
                            try result.append(try std.fmt.allocPrint(common.allocator, "{?d},{?d}", .{ pos.line, pos.character }));
                        }
                    }
                }
            }
            return result.toOwnedSlice();
        }

        var help_out: [
            blk: { // Compute the number of functions
                var count = 0;
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

        pub fn settings(args: ?ArgumentsMap) (error{ UnknownSettingName, OutOfMemory } || std.fmt.ParseIntError)![]const String {
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
                        shaders.user_action = true;
                        // switch on setting name
                        inline for (settings_decls) |decl| {
                            if (std.ascii.eqlIgnoreCase(decl.name, name)) {
                                const field = @field(setting_vars, decl.name);
                                switch (@TypeOf(field)) {
                                    bool => return setBool(decl.name, target_val),
                                    u16 => return setInt(decl.name, u16, target_val),
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

        const addBreakpoint = stringReturning;
        const list = stringReturning;
        const setBreakpoints = stringReturning;
        const stat = stringReturning;
        const state = stringReturning;
        //const completion = stringReturning;
        const debug = stringReturning;
        const dataBreakpointInfo = stringReturning;
        const evaluate = stringReturning;
        const possibleBreakpoints = stringReturning;
        const getStepInTargets = stringReturning;
        const readMemory = stringReturning;
        const runningShaders = stringReturning;
        //const scopes = stringReturning;
        const setDataBreakpoint = stringReturning;
        // const setExpression = stringReturning;
        //const setFunctionBreakpoint = stringReturning;
        //const setVariable = stringReturning;
        const stackTrace = stringReturning;
        //const stepIn = stringReturning;
        //const stepOut = stringReturning;
        // const variables = stringReturning;
        // const writeMemory = stringReturning;
    };
};
