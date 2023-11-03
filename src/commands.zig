const std = @import("std");
const positron = @import("positron");
const serve = @import("serve");

const common = @import("common.zig");
const logging = @import("log.zig");
const DeshaderLog = logging.DeshaderLog;
const main = @import("main.zig");
const editor = @import("tools/editor.zig");

const String = []const u8;
const Tuple = std.meta.Tuple;
const Route = positron.Provider.Route;

pub const CommandListener = struct {
    const settings = struct {
        var log_into_responses = false;
    };

    provider: *positron.Provider,

    pub fn start(allocator: std.mem.Allocator, port: u16) !*@This() {
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);

        self.provider = try positron.Provider.create(allocator, port);
        errdefer self.provider.destroy();
        self.provider.not_found_text = "Unknown command";

        inline for (@typeInfo(commands.simple).Struct.decls) |function| {
            const command = @field(commands.simple, function.name);
            const return_type = @typeInfo(@TypeOf(command)).Fn.return_type.?;
            const error_union = @typeInfo(return_type).ErrorUnion;
            _ = try self.simple(error_union.error_set, error_union.payload, .{ "/" ++ function.name, command });
        }
        const provide_thread = try std.Thread.spawn(.{}, positron.Provider.run, .{self.provider});
        try provide_thread.setName("CommandListener");
        provide_thread.detach();
        return self;
    }

    const RouteInfo = struct {
        provider: positron.Provider,
        route: Route,
        context: *serve.HttpContext,
    };

    //
    // Add various types of commands
    //
    pub fn informed(self: *@This(), comptime errtype: type, command: Tuple(&.{
        String,
        *const fn (RouteInfo) errtype!void,
    })) !*@This() {
        const route = try self.provider.addRoute(command[0]);
        route.handler = struct {
            fn wrapper(provider: *positron.Provider, route2: *Route, context: *serve.HttpContext) Route.Error!void {
                command[1](.{
                    .provider = provider,
                    .route = route2,
                    .context = context,
                });
            }
        }.wrapper;
        errdefer route.deinit();
        return self;
    }

    // A command that returns a string or a generic type that will be JSON-strinigified
    pub fn simple(self: *@This(), comptime errtype: type, comptime returntype: type, command: Tuple(&.{
        String,
        *const fn () errtype!returntype,
    })) !*@This() {
        const route = try self.provider.addRoute(command[0]);
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
