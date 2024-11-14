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

//! Edit-time analysis. Wraps glsl_analyzer library
const std = @import("std");
const analyzer = @import("glsl_analyzer");
const shaders = @import("shaders.zig").current;
const common = @import("../common.zig");

//
// Server control
//
pub const uri_scheme = "deshader";
var server_thread: ?std.Thread = null;
// Valid only withing running server thread
pub var state: analyzer.main.State = undefined;

pub fn serverStart(port: u16) !void {
    if (server_thread != null) return error.AlreadyRunning;
    server_thread = try std.Thread.spawn(.{
        .allocator = common.allocator,
    }, serverThread, .{port});
    server_thread.?.setName("LangSrv") catch {};
}

pub fn serverStop() !void {
    if (server_thread) |*t| {
        state.stop();
        // Do not wait for the thread to finish (because it could be still blocked on a request)
        t.join();
        server_thread = null;
    } else {
        return error.NotRunning;
    }
}

pub fn isRunning() bool {
    return server_thread != null;
}

pub fn serverThread(port: u16) !void {
    var server_arena = std.heap.ArenaAllocator.init(common.allocator);
    defer server_arena.deinit();
    // the return value of analyzer.main.run() does not contain any specific information in case of running as server
    _ = try analyzer.main.run(server_arena.allocator(), &state, .{
        .channel = .{ .ws = port },
        .scheme = uri_scheme ++ ":",
        .allow_reinit = true,
    });
}
