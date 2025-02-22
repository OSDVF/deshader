const std = @import("std");
const builtin = @import("builtin");
const DEBUG = builtin.mode == .Debug;
// Provider:
//
//                v---<-----<------O
// |-> idle -> drawing -> paused ->|
// O-----<----<---v
//

/// An agent that waits for a value to be requested, orders it from the producer (which waits when there are no requests), and returns it to the requester.
///
/// `T` should be an union of all possible message outputs
pub fn Waiter(comptime Request: type, comptime Response: type) type {
    return struct {
        eaten: std.Thread.Condition = .{},
        eaten_mutex: std.Thread.Mutex = .{},
        payload: union(enum) {
            Request: Request,
            Response: Response,
        } = .{ .Response = undefined },

        /// To be used by the producer when it wants to wait for a request
        requested: std.Thread.Condition = .{},
        requested_mutex: std.Thread.Mutex = .{},

        responded: std.Thread.Condition = .{},
        responded_mutex: std.Thread.Mutex = .{},

        responding: if (DEBUG) bool else void = if (DEBUG) false else {},

        const Self = @This();

        /// To be called by the requester.
        /// After the requester ended working with the requested resource, it should call `eatingDone()`
        pub fn request(self: *Self, req: Request) Response {
            {
                self.requested_mutex.lock();
                defer self.requested_mutex.unlock();
                self.payload = .{ .Request = req };
            }
            self.requested.signal();

            self.responded_mutex.lock();
            defer self.responded_mutex.unlock();
            self.responded.wait(&self.responded_mutex);
            // Now the payload is filled with the response
            return self.payload.Response;
        }

        /// To be called by the requester.
        pub fn eatingDone(self: *Self) void {
            self.eaten_mutex.lock();
            defer self.eaten_mutex.unlock();
            self.eaten.signal();
        }

        /// To be called by the producer
        pub fn respond(self: *Self, response: Response) void {
            {
                self.responded_mutex.lock();
                if (DEBUG) {
                    if (self.responding) {
                        std.debug.panic("Multiple respond handler called at the same time", .{});
                    }
                }
                defer if (DEBUG) {
                    self.responding = false;
                };
                defer self.responded_mutex.unlock();

                self.payload = .{ .Response = response };
            }
            self.responded.signal();
        }

        pub fn respondWaitEaten(self: *Self, response: Response) void {
            self.respond(response);

            self.eaten_mutex.lock();
            defer self.eaten_mutex.unlock();
            self.eaten.wait(&self.eaten_mutex);
        }

        /// To be called by the producer.
        /// Checks if there is any request awaiting a response.
        pub fn requests(self: *Self) ?Request {
            if (self.responded_mutex.tryLock()) {
                self.responded_mutex.unlock();
                return switch (self.payload) {
                    .Request => |req| req,
                    else => null,
                };
            } else if (DEBUG and self.responding) {
                std.debug.panic("Bad synchronization in calling `requests` and `respond` functions.", .{});
            } else {
                self.requested_mutex.lock();
                return self.payload.Request;
            }
        }
    };
}
