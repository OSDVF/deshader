const std = @import("std");
const log = @import("log.zig").DeshaderLog;

pub fn Bus(comptime Event: type, comptime Async: bool) type {
    return struct {
        allocator: std.mem.Allocator,
        listeners: std.ArrayListUnmanaged(struct { listener: *const Listener, context: ?*anyopaque }) = .{},
        queue: if (Async) std.ArrayListUnmanaged(struct { event: Event, arena: std.heap.ArenaAllocator }) else void = if (Async) .{},

        const Self = @This();
        pub const Listener = fn (context: ?*anyopaque, event: Event, allocator: std.mem.Allocator) anyerror!void;

        pub fn addListener(self: *@This(), listener: *const Listener, context: ?*anyopaque) !void {
            try self.listeners.append(self.allocator, .{ .listener = listener, .context = context });
        }

        const sync_only = struct {
            pub fn dispatch(self: *Self, event: Event) !void {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                for (self.listeners.items) |listener| {
                    try listener.listener(listener.context, event, arena.allocator());
                }
            }

            pub fn dispatchNoThrow(self: *Self, event: Event) void {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                for (self.listeners.items) |listener| {
                    listener.listener(listener.context, event, arena.allocator()) catch |err| {
                        log.err("Error dispatching event {any}: {}\n", .{ event, err });
                    };
                }
            }
        };

        const async_only = struct {
            pub fn dispatchAsync(self: *Self, event: Event, arena: std.heap.ArenaAllocator) !void {
                try self.queue.append(self.allocator, .{ .event = event, .arena = arena });
            }

            pub fn processQueue(self: *Self) !void {
                while (self.queue.popOrNull()) |event| {
                    defer event.arena.deinit();
                    for (self.listeners.items) |listener| {
                        try listener.listener(listener.context, event.event, event.arena.allocator());
                    }
                }
            }

            pub fn processQueueNoThrow(self: *Self) void {
                for (self.queue.items) |*event| {
                    defer event.arena.deinit();
                    for (self.listeners.items) |listener| {
                        listener.listener(listener.context, event.event, event.arena.allocator()) catch |err| {
                            log.err("Error dispatching async event {any}: {}\n", .{ event, err });
                        };
                    }
                }
                self.queue.clearAndFree(self.allocator);
            }
        };

        pub usingnamespace if (Async) async_only else sync_only;

        pub fn init(allocator: std.mem.Allocator) @This() {
            return @This(){
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.listeners.deinit(self.allocator);
            if (Async) self.queue.deinit(self.allocator);
        }
    };
}
