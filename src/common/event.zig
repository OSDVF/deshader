const std = @import("std");
const log = @import("log.zig").DeshaderLog;

pub fn Bus(comptime Event: type, comptime Async: bool) type {
    return struct {
        allocator: std.mem.Allocator,
        listeners: std.ArrayListUnmanaged(struct { listener: *const GenericListener, context: ?*anyopaque }) = .empty,
        queue: if (Async) std.ArrayListUnmanaged(struct { event: Event, arena: std.heap.ArenaAllocator }) else void = if (Async) .empty,

        const Self = @This();
        pub const GenericListener = Listener(?*anyopaque);
        pub fn Listener(comptime Context: type) type {
            return fn (context: Context, event: Event, allocator: std.mem.Allocator) anyerror!void;
        }

        /// `context` must be a pointer. Pass `null` for no context. The listener then must have the first argument as `_: ?*const anyopaque`.
        pub fn addListener(self: *@This(), context: anytype, listener: *const Listener(PointerOrNull(@TypeOf(context)))) !void {
            try self.listeners.append(self.allocator, .{ .listener = @ptrCast(listener), .context = if (@TypeOf(context) == @TypeOf(null)) null else @ptrCast(context) });
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
                    log.debug("Dispatch sync {} with context {x}.", .{ event, @intFromPtr(listener.context) });
                    listener.listener(listener.context, event, arena.allocator()) catch |err| {
                        log.err("Error dispatching event {any}: {}\n", .{ event, err });
                    };
                }
            }
        };

        const async_only = struct {
            /// The arena will be freed after the queue is emptied
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
                for (self.queue.items) |*queued| {
                    defer queued.arena.deinit();
                    for (self.listeners.items) |listener| {
                        log.debug("Processing event {} with context {x}", .{ queued.event, @intFromPtr(listener.context) });
                        listener.listener(listener.context, queued.event, queued.arena.allocator()) catch |err| {
                            log.err("Error dispatching async listener {}: {}\n", .{ queued, err });
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

fn PointerOrNull(comptime T: type) type {
    return if (T == @TypeOf(null)) ?*const anyopaque else T;
}
