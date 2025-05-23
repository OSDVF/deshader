// Copyright (C) 2025  Ondřej Sabela
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
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const builtin = @import("builtin");
const positron = @import("positron");
const serve = @import("serve");
const websocket = @import("websocket");

const analyzer = @import("glsl_analyzer");
const common = @import("common");
const logging = common.logging;
const DeshaderLog = common.log;
const options = @import("options");
const storage = @import("services/storage.zig");
const dap = @import("services/debug.zig");
const shaders = @import("services/shaders.zig");
const instruments = @import("services/instruments.zig");

const String = []const u8;
const CString = [*:0]const u8;
const Route = positron.Provider.Route;
const logParsing = false;

pub const setting_vars = struct {
    pub var logIntoResponses = false;
    /// Are shader parts automatically merged in glShaderSource? (so they will all belong to the same tag)
    pub var singleChunkShader: bool = true;
    pub var stackTraces: bool = false;
    pub var forceSupport: bool = false;
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
    // TODO make this array safe with mutex
    // SAFETY: private variable assigned in the `start()` function
    ws: std.ArrayList(*websocket.Conn) = undefined,

    ws_configs: std.ArrayListUnmanaged(websocket.Config) = .{},

    provide_thread: ?std.Thread = null,
    websocket_thread: ?std.Thread = null,
    // SAFETY: private variable assigned in the `start()` function
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
                    .address = try allocator.dupe(u8, c.host),
                    .port = c.port,
                }),
                .HTTP => http_configs.append(allocator, c),
            };
        }

        var addr_in_use = false;
        var some_started = false;

        // WS Command Listener
        for (self.ws_configs.items) |ws_config| {
            DeshaderLog.info(
                "Starting websocket listener on {s}:{d} from {s}",
                .{ ws_config.address, ws_config.port, common.selfExePath() catch "?" },
            );
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

            inline for (@typeInfo(commands).@"struct".decls) |function| {
                const command = @field(commands, function.name);
                _ = try self.addHTTPCommand("/" ++ function.name, command, if (@hasDecl(free_funcs, function.name))
                    @field(free_funcs, function.name)
                else
                    null);
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
        var shutdown = false;
        for (self.ws.items) |ws| {
            ws.writeText("432: Closing connection\n") catch {};
            ws.close(.{ .code = 1001, .reason = "server shutting down" }) catch {};
            if (builtin.os.tag == .windows or std.posix.system.fcntl(ws.stream.handle, std.posix.F.GETFD) != -1) {
                // Close forcefully
                if (std.posix.shutdown(ws.stream.handle, .both)) {
                    shutdown = true;
                } else |e| {
                    DeshaderLog.err("Error while shutting down websocket: {}", .{e});
                }
            }
        }
        for (self.ws_configs.items) |c| {
            self.ws.allocator.free(c.address);
        }
        self.ws_configs.deinit(self.ws.allocator);
        if (self.hasClient()) {
            if (shutdown) self.websocket_thread.?.join() else self.websocket_thread.?.detach();
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
            // SAFETY: must be initialized in the outer `addHTTPCommand()` function
            var comm: *const @TypeOf(command) = undefined;
            var free: ?*const fn (@typeInfo(@TypeOf(command)).@"fn".return_type.?) void = null;
            // SAFETY: assigned in `wrapper()`
            var writer: serve.http.Response.Writer = undefined;
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

            fn wrapper(provider: *positron.Provider, _: *Route, context: *serve.http.Context) Route.Error!void {
                if (setting_vars.logIntoResponses) {
                    writer = try context.response.writer();
                    logging.log_listener = log;
                } else {
                    logging.log_listener = null;
                }
                const return_type = @typeInfo(@TypeOf(command)).@"fn".return_type.?;
                const error_union = @typeInfo(return_type).error_union;

                const result_or_err = switch (@typeInfo(@TypeOf(command)).@"fn".params.len) {
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
                            a.deinit(provider.allocator);
                        };
                        var reader = try context.request.reader();
                        const body = reader.readAllAlloc(provider.allocator, 10_000_000) catch |err| switch (err) {
                            error.StreamTooLong => return Route.Error.OutOfMemory,
                            error.ConnectionTimedOut => return Route.Error.InputOutput,
                            error.SocketNotBound => return Route.Error.InputOutput,
                            else => |e| return e,
                        };
                        defer provider.allocator.free(body);
                        break :blk comm(args, body);
                    },
                    else => @compileError("Command " ++ @typeName(comm) ++
                        " has invalid number of arguments. First is state. Further only none, parameters and body are available."),
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
                        serve.http.StatusCode => try context.response.setStatusCode(result),
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

                    const fmt = "Error while executing command {s}: {} at\n{?}";
                    const stack = if (setting_vars.stackTraces) blk: {
                        const s = @errorReturnTrace();
                        DeshaderLog.err(fmt, .{ name, err, s });
                        break :blk s;
                    } else &common.null_trace;

                    const result = try std.fmt.allocPrint(provider.allocator, fmt, .{ name, err, stack });
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
            StatusCode,
        };
        const decls = @typeInfo(commands).@"struct".decls;
        const comInfo = struct { r: CommandReturnType, a: usize, c: *const anyopaque, free: ?*const anyopaque };
        var command_array: [decls.len]struct { String, comInfo } = undefined;
        for (decls, 0..) |function, i| {
            const command = @field(commands, function.name);
            const return_type = @typeInfo(@TypeOf(command)).@"fn".return_type.?;
            const error_union = @typeInfo(return_type).error_union;
            command_array[i] = .{ function.name, comInfo{
                .r = switch (error_union.payload) {
                    void => CommandReturnType.Void,
                    String => CommandReturnType.String,
                    []const String => CommandReturnType.StringArray,
                    []const CString => CommandReturnType.CStringArray,
                    serve.http.StatusCode => CommandReturnType.StatusCode,
                    else => @compileError("Command " ++ function.name ++
                        " has invalid return type. Only void, string, string array, string set, and http status code are available."),
                },
                .a = @typeInfo(@TypeOf(command)).@"fn".params.len,
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
                        try self.writeAll(
                            if (std.unicode.utf8ValidateSlice(result)) .text else .binary,
                            &.{ accepted, command_echo, "\n", result, "\n" },
                        );
                    },
                    []const CString => {
                        const flattened = try common.joinInnerZ(common.allocator, "\n", result);
                        defer common.allocator.free(flattened);
                        try self.writeAll(
                            if (std.unicode.utf8ValidateSlice(flattened)) .text else .binary,
                            &.{ accepted, command_echo, "\n", flattened, "\n" },
                        );
                    },
                    []const String => {
                        const flattened = try std.mem.join(common.allocator, "\n", result);
                        defer common.allocator.free(flattened);
                        try self.writeAll(
                            if (std.unicode.utf8ValidateSlice(flattened)) .text else .binary,
                            &.{ accepted, command_echo, "\n", flattened, "\n" },
                        );
                    },
                    serve.http.StatusCode => {
                        try self.writeAll(.text, &.{
                            try std.fmt.bufPrint(&http_code_buffer, "{d}", .{@as(serve.http.StatusCode, result)}),
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
                const text = try std.fmt.allocPrint(common.allocator, "500: Internal Server Error\n{s}\n{} at\n{?}", .{
                    command_echo,
                    err,
                    if (setting_vars.stackTraces) @errorReturnTrace() else &common.null_trace,
                });
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
            if (request.len == 0 or blk: {
                if (request[request.len - 1] == '\n') {
                    request = request[0 .. request.len - 1];
                    if (request.len == 0) {
                        break :blk true;
                    } else if (request[request.len - 1] == '\r') {
                        request = request[0 .. request.len - 1];
                    }
                }
                break :blk request.len == 0;
            }) {
                try self.conn.writeText("400: Bad request\n");
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
                        0 => handleInner(
                            self,
                            @as(*const fn () anyerror!void, @alignCast(@ptrCast(tc.c)))(),
                            request,
                            @alignCast(@ptrCast(tc.free)),
                        ),
                        1 => handleInner(
                            self,
                            @as(*const fn (?ArgumentsMap) anyerror!void, @alignCast(@ptrCast(tc.c)))(parsed_args),
                            request,
                            @alignCast(@ptrCast(tc.free)),
                        ),
                        2 => handleInner(
                            self,
                            @as(*const fn (?ArgumentsMap, String) anyerror!void, @alignCast(@ptrCast(tc.c)))(parsed_args, body),
                            request,
                            @alignCast(@ptrCast(tc.free)),
                        ),
                        else => unreachable,
                    },
                    .String => switch (tc.a) {
                        0 => handleInner(
                            self,
                            @as(*const fn () anyerror!String, @alignCast(@ptrCast(tc.c)))(),
                            request,
                            @alignCast(@ptrCast(tc.free)),
                        ),
                        1 => handleInner(
                            self,
                            @as(*const fn (?ArgumentsMap) anyerror!String, @alignCast(@ptrCast(tc.c)))(parsed_args),
                            request,
                            @alignCast(@ptrCast(tc.free)),
                        ),
                        2 => handleInner(
                            self,
                            @as(*const fn (?ArgumentsMap, String) anyerror!String, @alignCast(@ptrCast(tc.c)))(parsed_args, body),
                            request,
                            @alignCast(@ptrCast(tc.free)),
                        ),
                        else => unreachable,
                    },
                    .CStringArray => switch (tc.a) {
                        0 => handleInner(
                            self,
                            @as(*const fn () anyerror![]const CString, @alignCast(@ptrCast(tc.c)))(),
                            request,
                            @alignCast(@ptrCast(tc.free)),
                        ),
                        1 => handleInner(
                            self,
                            @as(*const fn (?ArgumentsMap) anyerror![]const CString, @alignCast(@ptrCast(tc.c)))(parsed_args),
                            request,
                            @alignCast(@ptrCast(tc.free)),
                        ),
                        2 => handleInner(
                            self,
                            @as(*const fn (?ArgumentsMap, String) anyerror![]const CString, @alignCast(@ptrCast(tc.c)))(parsed_args, body),
                            request,
                            @alignCast(@ptrCast(tc.free)),
                        ),
                        else => unreachable,
                    },
                    .StringArray => switch (tc.a) {
                        0 => handleInner(
                            self,
                            @as(*const fn () anyerror![]const String, @alignCast(@ptrCast(tc.c)))(),
                            request,
                            @alignCast(@ptrCast(tc.free)),
                        ),
                        1 => handleInner(
                            self,
                            @as(*const fn (?ArgumentsMap) anyerror![]const String, @alignCast(@ptrCast(tc.c)))(parsed_args),
                            request,
                            @alignCast(@ptrCast(tc.free)),
                        ),
                        2 => handleInner(
                            self,
                            @as(*const fn (?ArgumentsMap, String) anyerror![]const String, @alignCast(@ptrCast(tc.c)))(parsed_args, body),
                            request,
                            @alignCast(@ptrCast(tc.free)),
                        ),
                        else => unreachable,
                    },
                    .StatusCode => switch (tc.a) {
                        0 => handleInner(
                            self,
                            @as(*const fn () anyerror!serve.http.StatusCode, @alignCast(@ptrCast(tc.c)))(),
                            request,
                            @alignCast(@ptrCast(tc.free)),
                        ),
                        1 => handleInner(
                            self,
                            @as(*const fn (?ArgumentsMap) anyerror!serve.http.StatusCode, @alignCast(@ptrCast(tc.c)))(parsed_args),
                            request,
                            @alignCast(@ptrCast(tc.free)),
                        ),
                        2 => handleInner(
                            self,
                            @as(*const fn (?ArgumentsMap, String) anyerror!serve.http.StatusCode, @alignCast(@ptrCast(tc.c)))(parsed_args, body),
                            request,
                            @alignCast(@ptrCast(tc.free)),
                        ),
                        else => unreachable,
                    },
                };
            } else {
                DeshaderLog.warn("Command not found: {s}", .{command_name});
                try self.conn.writeText("404: Command not found\n");
                return;
            }
        }

        pub fn clientClose(self: *@This(), _: []u8) !void {
            if (self.context.ws.items.len <= 1) {
                DeshaderLog.info("Unpausing shaders, because the last websocket connection was closed", .{});
                self.context.do_resume = true;
            }
        }

        pub fn close(self: *@This()) void {
            for (self.context.ws.items, 0..) |ws, i| {
                if (ws == self.conn) {
                    _ = self.context.ws.swapRemove(i);
                    break;
                }
            }
        }
    };

    fn stringToBool(val: ?String) bool {
        return val != null and (std.ascii.eqlIgnoreCase(val.?, "true") or (val.?.len == 1 and val.?[0] == '1'));
    }

    fn getInnerType(comptime t: type) struct { type: type, isOptional: bool } {
        return switch (@typeInfo(t)) {
            .optional => |opt| .{ .type = opt.child, .isOptional = true },
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
        var to_remove = std.ArrayListUnmanaged(usize){};
        defer to_remove.deinit(common.allocator);
        var i: usize = self.ws.items.len;
        while (i > 0) {
            i -= 1;
            const content = try std.mem.concat(common.allocator, u8, &.{
                "600: Event\n",
                @tagName(event) ++ "\n",
                string,
            });
            defer common.allocator.free(content);
            const ws = self.ws.items[i];
            ws.writeText(content) catch |err| {
                if (err == error.NotOpenForWriting) {
                    _ = self.ws.orderedRemove(i);
                } else {
                    return err;
                }
            };
        }
        // TODO some HTTP way of sending events (probably persistent connection)
    }

    // TODO type checking on event payload
    /// Suspends the thread that calls this function, but processes commands and `meantime` in the meantime
    pub fn eventBreak(self: *@This(), comptime event: Event, body: anytype, meantime: anytype) !void {
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
            } else {
                self.break_mutex.unlock(); // hack to allow do_resume to be set again
                defer self.break_mutex.lock();
                if (@TypeOf(meantime) != @TypeOf(null)) {
                    meantime();
                }
                continue;
            };
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
    fn parseValue(comptime T: type, value: ?String, allocator: std.mem.Allocator) !T {
        const inner = getInnerType(T);
        if (value) |v| {
            return switch (@typeInfo(inner.type)) {
                .bool => std.ascii.eqlIgnoreCase(v, "true") or
                    std.ascii.eqlIgnoreCase(v, "on") or
                    std.mem.eql(u8, v, "1"),

                .float => std.fmt.parseFloat(inner.type, v),

                .int => try std.fmt.parseInt(inner.type, v, 0),

                .array, .pointer => {
                    if (logParsing) {
                        DeshaderLog.debug("Parsing array/pointer {x}: {s}", .{ @intFromPtr(v.ptr), v });
                    }
                    if (std.meta.Child(inner.type) == u8) {
                        // Probably string
                        return v;
                    } else {
                        return try std.json.parseFromSliceLeaky(inner.type, allocator, v, .{});
                    }
                },
                .@"enum" => if (std.meta.stringToEnum(inner.type, v)) |e| e else return error.InvalidEnumValue,

                // JSON
                .@"struct" => try std.json.parseFromSliceLeaky(inner.type, allocator, v, .{ .ignore_unknown_fields = true }),
                else => @compileError("Unsupported type for command parameter " ++ @typeName(inner.type)),
            };
        } else {
            if (inner.isOptional) {
                return null;
            } else {
                DeshaderLog.err("Missing parameter of type {}", .{T});
                return error.ParameterMissing;
            }
        }
    }

    fn Result(comptime T: type) type {
        return struct {
            value: T,
            arena: std.heap.ArenaAllocator,
        };
    }
    fn parseArgs(comptime R: type, args: ?ArgumentsMap) !Result(R) {
        var arena = std.heap.ArenaAllocator.init(common.allocator);
        const result_type = getInnerType(R);
        if (args) |sure_args| {
            // SAFETY: will be filled in the inline for loop
            var result_payload: result_type.type = undefined;
            if (sure_args.count() == 0) {
                if (result_type.isOptional) {
                    return null;
                } else {
                    return error.WrongParameters;
                }
            }
            inline for (@typeInfo(result_type.type).@"struct".fields) |field| {
                if (logParsing) {
                    DeshaderLog.debug("Parsing field: {s}", .{field.name});
                }
                @field(result_payload, field.name) = try parseValue(field.type, sure_args.get(field.name), arena.allocator());
            }
            return .{ .value = result_payload, .arena = arena };
        } else if (result_type.isOptional) {
            return null;
        }
        return error.WrongParameters;
    }

    // TODO: rewrite to sysfs-like interface
    pub const commands = struct {
        /// Continues to the next breakpoint
        pub fn @"continue"(args: ?ArgumentsMap) !void {
            shaders.user_action = true;
            const in_params = try parseArgs(dap.ContinueArguments, args);
            const locator = shaders.Running.Locator.parse(in_params.value.threadId);
            try instruments.Step.@"continue"(try locator.service(), locator.stage());

            instance.?.unPause();
        }

        pub fn terminate(args: ?ArgumentsMap) !void {
            shaders.user_action = true;
            const in_params = try parseArgs(dap.TerminateRequest, args);
            if (in_params.value.restart) |r| {
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
                    if (try shaders.ServiceLocator.parse(path)) |context| {
                        if (context.resource) |r| {
                            context.service.clearBreakpoints(r) catch |err| {
                                return switch (err) {
                                    storage.Error.InvalidPath => shaders.ResourceLocator.Error.Protected, // Convert error to a more specific one
                                    else => err,
                                };
                            };
                        }
                    }
                    return storage.Error.InvalidPath;
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

        pub fn clients() ![]const String {
            const c = try common.allocator.alloc(String, instance.?.ws.items.len);
            for (instance.?.ws.items, 0..) |ws, i| {
                c[i] = try std.fmt.allocPrint(common.allocator, "{}", .{ws.address});
            }
            return c;
        }

        fn getUnsentBreakpoints(s: *const shaders, breakpoints_to_send: *std.ArrayListUnmanaged(dap.Breakpoint)) !void {
            for (s.dirty_breakpoints.items) |bp| {
                if (s.Shaders.all.get(bp[0])) |stage| {
                    if (stage.parts.items.len > bp[1]) {
                        const part = &stage.parts.items[bp[1]];
                        const stops = try part.possibleSteps();
                        const local_stop = stops.items(.pos)[bp[2]];
                        const dap_bp = dap.Breakpoint{
                            .id = bp[2],
                            .line = local_stop.line,
                            .column = local_stop.character,
                            .verified = true,
                            .path = try s.fullPath(common.allocator, part, false, bp[1]),
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
            for (shaders.allServices()) |s| {
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
            shaders.user_action = false;
            shaders.debugging = false;
            for (shaders.allServices()) |s| {
                s.revert_requested = true;
            }
            instance.?.unPause();
        }

        pub fn evaluate(args: ?ArgumentsMap) !String {
            const in_args = try parseArgs(dap.EvaluateArguments, args);
            return std.json.stringifyAlloc(common.allocator, dap.EvaluateResponse{
                .result = in_args.value.expression,
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

        pub fn pause(args: ?ArgumentsMap) !void {
            const in_params = try parseArgs(dap.PauseArguments, args);
            const running = shaders.Running.Locator.parse(in_params.value.threadId);
            try instruments.Step.pause(try running.service(), running.stage());

            instance.?.unPause();
        }

        pub fn pauseMode(args: ?ArgumentsMap) !void {
            const in_params = try parseArgs(struct { single: bool }, args);
            if (shaders.single_pause_mode != in_params.value.single) {
                shaders.single_pause_mode = in_params.value.single;
                for (shaders.allServices()) |s| {
                    s.invalidate();
                }
            }
        }

        pub fn possibleBreakpoints(args: ?ArgumentsMap) !String {
            //var result = std.ArrayList(debug.BreakpointLocation).init(common.allocator);
            const in_params = try parseArgs(dap.BreakpointLocationArguments, args);
            // bounded by source, lines and cols in params
            const positions: []const analyzer.lsp.Position = blk: {
                if (try shaders.ServiceLocator.parse(in_params.value.path)) |context| {
                    if (context.resource) |r| {
                        switch (r) {
                            .programs => |locator| {
                                const shader = try context.service.Programs.getNestedByLocator(locator.name, locator.nested.name);
                                break :blk (try shader.possibleSteps()).items(.pos);
                            },
                            .sources => |locator| {
                                const shader = try context.service.Shaders.getStoredByLocator(locator.name);
                                break :blk (try shader.*.possibleSteps()).items(.pos);
                            },
                            else => return shaders.ResourceLocator.Error.Protected,
                        }
                    } else return storage.Error.InvalidPath;
                } else return storage.Error.InvalidPath;
            };

            const result = try getPossibleBreakpointsAlloc(positions, in_params.value);
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
            const locator = shaders.Running.Locator.parse(in_params.value.threadId);
            try instruments.Step.advanceStepping(try locator.service(), locator.stage());
            instance.?.unPause();
        }

        pub fn readMemory(_: ?ArgumentsMap) !void {
            //TODO
        }

        /// Revert all instrumentation state and restart debugging
        pub fn restart(_: ?ArgumentsMap) !void {
            DeshaderLog.info("Restarting debugging", .{});
            for (shaders.allServices()) |s| {
                s.revert_requested = true;
            }
            shaders.debugging = true;

            instance.?.unPause();
        }

        pub fn scopes(_: ?ArgumentsMap) !void {
            //TODO
        }

        pub fn addBreakpoint(args: ?ArgumentsMap) !String {
            shaders.user_action = true;
            const in_params = try parseArgs(struct {
                path: String,
                line: usize,
                column: usize,
            }, args);
            const new = dap.SourceBreakpoint{
                .line = in_params.value.line,
                .column = in_params.value.column,
            };
            const context = try shaders.ServiceLocator.parse(in_params.value.path) orelse return error.InvalidPath;
            const s = context.service;
            const r = context.resource orelse return error.InvalidPath;
            const result = try s.addBreakpointAlloc(r, new, common.allocator);
            defer common.allocator.free(result.path);

            return std.json.stringifyAlloc(common.allocator, result, json_options);
        }

        pub fn selectThread(args: ?ArgumentsMap) !void {
            shaders.user_action = true;
            const in_params = try parseArgs(struct { shader: usize, thread: []usize, group: ?[]usize }, args);
            try shaders.selectThread(in_params.value.shader, in_params.value.thread, in_params.value.group);
        }

        pub fn setBreakpoints(args: ?ArgumentsMap) !String {
            shaders.user_action = true;
            const in_params = try parseArgs(dap.SetBreakpointsArguments, args);
            defer in_params.arena.deinit();
            const context = try shaders.ServiceLocator.parse(in_params.value.path) orelse return error.InvalidPath;
            const s = context.service;
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

            var remaining = std.AutoHashMapUnmanaged(usize, void){};
            defer remaining.deinit(common.allocator);
            {
                var it = shader.breakpoints.keyIterator();
                while (it.next()) |i| {
                    _ = try remaining.getOrPut(common.allocator, i.*);
                }
            }
            const p_state = if (shader.stage.program) |p| if (p.state) |*st| st else null else null;

            if (in_params.value.breakpoints) |bps| {
                for (bps) |bp| {
                    var bp_result = try shader.addBreakpoint(bp);
                    if (bp_result.verified) {
                        if (p_state) |st| {
                            if (!remaining.remove(bp_result.id)) { // this is a new breakpoint
                                st.dirty = true;
                            }
                            st.uniforms_dirty = true;
                        }
                    }
                    bp_result.path = try s.fullPath(common.allocator, shader, false, target.shader.?.part);
                    try result.append(common.allocator, bp_result.toDAP());
                }
                var it = remaining.keyIterator();
                while (it.next()) |i| {
                    try shader.removeBreakpoint(i.*);
                    if (p_state) |st| {
                        st.dirty = true;
                        st.uniforms_dirty = true; // TODO really need to do this when the shader will be reinstrumented anyways?
                    }
                }
            } else {
                shader.clearBreakpoints();
                if (p_state) |st| {
                    st.dirty = true;
                    st.uniforms_dirty = true;
                }
            }

            return std.json.stringifyAlloc(common.allocator, result.items, json_options);
        }

        pub fn setDataBreakpoint(args: ?ArgumentsMap) !String {
            shaders.user_action = true;
            const in_params = try parseArgs(dap.DataBreakpoint, args);
            const response_b = try shaders.setDataBreakpoint(in_params.value);
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
            const in_params = try parseArgs(dap.StackTraceArguments, args);
            const trace = try instruments.StackTrace.stackTrace(common.allocator, in_params.value);
            defer {
                for (trace.stackFrames) |fr| {
                    common.allocator.free(fr.path);
                }
                common.allocator.free(trace.stackFrames);
            }
            return try std.json.stringifyAlloc(common.allocator, trace, json_options);
        }

        pub fn stepIn(args: ?ArgumentsMap) !void {
            //TODO
            return next(args);
        }

        pub fn stepOut(args: ?ArgumentsMap) !void {
            //TODO
            return next(args);
        }

        /// The full state of the debugger
        pub fn state() !String {
            var breakpoints_to_send = std.ArrayListUnmanaged(dap.Breakpoint).empty;
            defer {
                for (breakpoints_to_send.items) |bp| {
                    common.allocator.free(bp.path);
                }
                breakpoints_to_send.deinit(common.allocator);
            }
            var running_to_send = std.ArrayListUnmanaged(shaders.Running).empty;
            for (shaders.allServices()) |s| {
                try getUnsentBreakpoints(s, &breakpoints_to_send);
                try s.runningShaders(common.allocator, &running_to_send);
            }
            defer {
                for (running_to_send.items) |runnning| {
                    runnning.deinit(common.allocator);
                }
                running_to_send.deinit(common.allocator);
            }
            var result = std.ArrayListUnmanaged(u8).empty;
            const w = result.writer(common.allocator);
            // Must be called instead of stringifyAlloc which would corrupt the stack (because of the array-lists being on stack)
            try std.json.stringify(.{
                .breakpoints = breakpoints_to_send.items,
                .debugging = shaders.debugging,
                .paused = instance.?.paused,
                .runningShaders = running_to_send.items,
                .singlePauseMode = shaders.single_pause_mode,
            }, json_options, w);
            return result.toOwnedSlice(common.allocator);
        }

        pub fn runningShaders() !String {
            var threads_list = std.ArrayListUnmanaged(shaders.Running).empty;
            for (shaders.allServices()) |s| {
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

        const ListArgs = struct { path: String, recursive: ?bool, physical: ?bool, meta: ?bool };

        //
        // Virtual filesystem commands
        //
        /// The path must start with `/sources/` or `/programs/`
        /// path: String, recursive: bool[false]
        pub fn list(args: ?ArgumentsMap) !String {
            const in_params = try parseArgs(ListArgs, args);

            if (try shaders.ServiceLocator.parse(in_params.value.path)) |context| {
                if (context.resource) |res| {
                    const lines = try switch (res) {
                        .programs => |locator| context.service.Programs.list(
                            common.allocator,
                            locator,
                            in_params.value.recursive orelse false,
                            in_params.value.physical orelse true,
                            in_params.value.meta orelse false,
                            ">",
                        ), //indicate that sources under programs are "symlinks"
                        .sources => |locator| context.service.Shaders.list(
                            common.allocator,
                            locator,
                            in_params.value.recursive orelse false,
                            in_params.value.physical orelse true,
                            in_params.value.meta orelse false,
                        ),
                        else => return storage.Error.InvalidPath,
                    };
                    defer {
                        for (lines) |line| {
                            common.allocator.free(std.mem.span(line));
                        }
                        common.allocator.free(lines);
                    }
                    return try common.joinInnerZ(common.allocator, "\n", lines);
                } else { // listing files for this service
                    // TODO recursive
                    const basic_virtual = shaders.ResourceLocator.programs_path ++ "/\n" ++
                        shaders.ResourceLocator.sources_path ++ "/\n" ++
                        shaders.ResourceLocator.capabilities_path ++ ".md\n"; // Only the "human-readable" MD version of the capabilities file

                    return common.allocator.dupe(u8, if (in_params.value.meta) |m| if (m) basic_virtual ++
                        shaders.ResourceLocator.capabilities_path ++ ".json\n" // also the JSON version of the capabilities file
                    else basic_virtual else basic_virtual);
                }
            } else {
                shaders.lockServices();
                var it = shaders.serviceNames();
                const c = shaders.servicesCount();
                var result = std.ArrayListUnmanaged(u8){};
                var i: usize = 0;
                while (it.next()) |n| {
                    try result.appendSlice(common.allocator, n.*);
                    try result.append(common.allocator, '/'); //Add / to the end of each line to indicate a directory
                    if (i < c - 1) {
                        try result.append(common.allocator, '\n');
                    }
                    i += 1;
                }
                shaders.unlockServices();
                return result.toOwnedSlice(common.allocator);
            }
        }

        pub fn mkdir(args: ?ArgumentsMap) !void {
            const in_params = try parseArgs(struct { path: String }, args);
            const locator = try shaders.ServiceLocator.parse(in_params.value.path) orelse return shaders.ResourceLocator.Error.Protected;
            switch (locator.resource orelse return shaders.ResourceLocator.Error.Protected) {
                .programs => |p| {
                    if (!p.nested.isRoot()) { // Nested should be "root" >= no nested
                        return storage.Error.InvalidPath;
                    }
                    _ = try locator.service.Programs.mkdir(p.name.taggedOrNull() orelse return shaders.ResourceLocator.Error.Protected);
                },
                .sources => |s| {
                    _ = try locator.service.Shaders.mkdir(s.name.taggedOrNull() orelse return shaders.ResourceLocator.Error.Protected);
                },
                else => return shaders.ResourceLocator.Error.Protected,
            }
        }

        pub fn readFile(args: ?ArgumentsMap) !String {
            const in_params = try parseArgs(struct { path: String }, args);

            if (try shaders.ServiceLocator.parse(in_params.value.path)) |context| {
                if (context.resource) |res| {
                    switch (res) {
                        .capabilities => |fmt| return switch (fmt) {
                            inline else => |f| std.fmt.allocPrint(common.allocator, "{" ++ @tagName(f) ++ "}", .{context.service.support}),
                        },
                        else => {
                            const shader = try context.service.getSourceByRLocator(res);
                            return if (res.isInstrumented())
                                try shader.instrumentedSource(context.service) orelse shaders.Error.NoInstrumentation
                            else
                                shader.getSource() orelse "";
                        },
                    }
                }
            }
            return error.TargetNotFound;
        }

        const WriteArgs = struct { path: String, compile: ?bool, link: ?bool };
        pub fn saveVirtual(args: ?ArgumentsMap, content: String) !void {
            const in_params = try parseArgs(WriteArgs, args);

            const locator = try shaders.ServiceLocator.parse(in_params.value.path) orelse return storage.Error.InvalidPath;
            try locator.service.setSourceByLocator2(
                locator.resource orelse return shaders.ResourceLocator.Error.Protected,
                content,
                in_params.value.compile orelse true,
                in_params.value.link orelse true,
            );
        }

        pub fn savePhysical(args: ?ArgumentsMap, content: String) !void {
            const in_params = try parseArgs(WriteArgs, args);

            const locator = try shaders.ServiceLocator.parse(in_params.value.path) orelse return storage.Error.InvalidPath;
            try locator.service.saveSource(
                locator.resource orelse return shaders.ResourceLocator.Error.Protected,
                content,
                in_params.value.compile orelse true,
                in_params.value.link orelse true,
            );
        }

        pub fn save(args: ?ArgumentsMap, content: String) !void {
            return savePhysical(args, content) catch |err| {
                if (err != error.NotPhysical)
                    DeshaderLog.err("Encountered {} when saving to physical storage. Trying to save to virtual storage.", .{err});

                try saveVirtual(args, content);
            };
        }

        /// Rename a file or directory.
        ///
        /// Sources under program directories can be renamed only by basename (no moving outside the program or between them).
        /// When untagged file is renamed, it becomes a tagged file.
        ///
        /// Returns the new full path for the file. This can be different than the `to` parameter (e.g. when renaming untagged file).
        pub fn rename(args: ?ArgumentsMap) !String {
            const in_params = try parseArgs(struct { from: String, to: String }, args);
            const to_unslash = common.noTrailingSlash(in_params.value.to);
            const basename_only = common.nullishEq(
                String,
                std.fs.path.dirname(common.noTrailingSlash(in_params.value.from)),
                std.fs.path.dirname(to_unslash),
            );

            const from = try shaders.ServiceLocator.parse(in_params.value.from) orelse return error.InvalidPath;
            const from_res = from.resource orelse return error.InvalidPath;
            const from_untagged = basename_only and !from_res.isTagged();

            const to = if (from_untagged) blk: {
                var tagged = from;
                tagged.resource = try tagged.resource.?.toTagged(common.allocator, std.fs.path.basename(to_unslash));
                break :blk tagged;
            } else try shaders.ServiceLocator.parse(in_params.value.to) orelse return error.InvalidPath;
            defer if (from_untagged) switch (to.resource.?) {
                .programs => |p| common.allocator.free(p.fullPath),
                else => {},
            };

            const to_res = to.resource orelse return error.InvalidPath;
            if (from.service != to.service) {
                return error.ContextMismatch;
            } else if (@intFromEnum(from_res) != @intFromEnum(to_res)) { //Compare tags
                return error.TypeMismatch;
            }
            switch (from_res) {
                .sources => |source| {
                    _ = try from.service.Shaders.renameByLocator(source.name, to_res.sources.name.taggedOrNull() orelse
                        return shaders.ResourceLocator.Error.Protected);
                },
                .programs => |program| {
                    const p = program.name.file() orelse return shaders.ResourceLocator.Error.Protected;
                    if (program.nested.isRoot()) {
                        _ = try from.service.Programs.renameByLocator(p, to_res.programs.name.taggedOrNull() orelse
                            return shaders.ResourceLocator.Error.Protected);
                    } else {
                        if (basename_only) {
                            const s = try from.service.Programs.getNestedByLocator(p, program.nested.name);
                            const name = to_res.programs.nested.name.taggedOrNull() orelse return shaders.ResourceLocator.Error.Protected;
                            if (s.tag) |t| {
                                try t.rename(name);
                            } else {
                                _ = try from.service.Shaders.assignTagTo(s, name, .Error);
                            }
                        } else {
                            return error.TypeMismatch;
                        }
                    }
                },
                else => return shaders.ResourceLocator.Error.Protected,
            }
            return std.fmt.allocPrint(common.allocator, "{}", .{to});
        }

        // Remove a tag record of a file or a directory
        pub fn untag(args: ?ArgumentsMap) !void {
            const in_params = try parseArgs(struct { path: String }, args);
            const locator = try shaders.ServiceLocator.parse(in_params.value.path) orelse return error.InvalidPath;
            try locator.service.untag(locator.resource orelse return error.InvalidPath);
        }

        const StatRequest = struct {
            path: String,
        };

        pub fn stat(args: ?ArgumentsMap) !String {
            const in_params = try parseArgs(StatRequest, args);

            // TODO: supress the long stack trace when targeting invalid path?
            const context = try shaders.ServiceLocator.parse(in_params.value.path);
            const now = std.time.milliTimestamp();
            // Used for root
            const virtual = storage.StatPayload{
                .type = @intFromEnum(storage.FileType.Directory),
                .accessed = now,
                .created = 0,
                .modified = now,
                .size = 0,
            };
            return std.json.stringifyAlloc(common.allocator, if (context) |c|
                if (c.resource) |locator|
                    try c.service.stat(locator)
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
                    const context = try shaders.ServiceLocator.parse(path) orelse return error.InvalidPath;
                    const s = context.service;
                    const locator = context.resource orelse return error.InvalidPath;
                    const shader = ((try s.getResourcesByLocator(locator)).shader orelse return error.TargetNotFound).source;
                    const steps = try shader.*.possibleSteps();
                    const steps_pos = steps.items(.pos);
                    var it = shader.*.breakpoints.keyIterator();
                    while (it.next()) |bp| {
                        try result.append(
                            try std.fmt.allocPrint(common.allocator, "{?d},{?d}", .{ steps_pos[bp.*].line, steps_pos[bp.*].character }),
                        );
                    }
                    return result.toOwnedSlice();
                }
            }
            // From all files
            for (shaders.allServices()) |s| {
                var it = s.Shaders.all.valueIterator();
                while (it.next()) |stage| {
                    for (stage.*.parts.items) |*part| {
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
                for (@typeInfo(commands).@"struct".decls) |decl_info| {
                    const decl = @field(commands, decl_info.name);
                    if (@typeInfo(@TypeOf(decl)) == .@"fn") {
                        count += 1;
                    }
                }
                break :blk count;
            }
        ]String = undefined;
        pub fn help() ![]const String {
            var i: usize = 0;
            inline for (@typeInfo(commands).@"struct".decls) |decl_info| {
                const decl = @field(commands, decl_info.name);
                if (@typeInfo(@TypeOf(decl)) == .@"fn") {
                    defer i += 1;
                    help_out[i] = decl_info.name;
                }
            }
            return &help_out;
        }

        pub fn settings(args: ?ArgumentsMap) (error{ UnknownSettingName, OutOfMemory } || std.fmt.ParseIntError)![]const String {
            const settings_decls = @typeInfo(setting_vars).@"struct".decls;
            if (args == null) {
                var values = try common.allocator.alloc(String, settings_decls.len);
                inline for (settings_decls, 0..) |decl, i| {
                    values[i] = try std.json.stringifyAlloc(common.allocator, @field(setting_vars, decl.name), json_options);
                }
                return values;
            }
            var iter = args.?.keyIterator();
            var results = std.ArrayListUnmanaged(String){};
            // For each setting name in the request
            while (iter.next()) |key| {
                const value = args.?.get(key.*);

                try struct {
                    fn setBool(comptime name: String, target_val: ?String) void {
                        const b_val = stringToBool(target_val);
                        if (std.mem.eql(u8, name, "forceSupport")) {
                            for (shaders.allServices()) |s| {
                                s.setForceSupport(b_val);
                            }
                        }
                        @field(setting_vars, name) = b_val;
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
                try results.append(common.allocator, try std.fmt.allocPrint(common.allocator, "{s} = {?s}", .{ key.*, value }));
            }
            return results.toOwnedSlice(common.allocator);
        }

        pub fn version() !String {
            return options.version;
        }
    };
    const free_funcs = struct {
        fn stringArray(result: anyerror![]const String) void {
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
        const clients = stringArray;
        const debug = stringReturning;
        const dataBreakpointInfo = stringReturning;
        const evaluate = stringReturning;
        const possibleBreakpoints = stringReturning;
        const getStepInTargets = stringReturning;
        const readMemory = stringReturning;
        const rename = stringReturning;
        const runningShaders = stringReturning;
        //const scopes = stringReturning;
        const setDataBreakpoint = stringReturning;
        // const setExpression = stringReturning;
        //const setFunctionBreakpoint = stringReturning;
        //const setVariable = stringReturning;
        const stackTrace = stringReturning;
        const settings = stringArray;
        //const stepIn = stringReturning;
        //const stepOut = stringReturning;
        // const variables = stringReturning;
        // const writeMemory = stringReturning;
    };
};
