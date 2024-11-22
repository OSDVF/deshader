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
const common = @import("../common.zig");
const log = @import("../log.zig").DeshaderLog;

const String = []const u8;
const CString = [*:0]const u8;
const ZString = [:0]const u8;
const C = @cImport(@cInclude("nfd.h"));

pub const State = struct {
    view: *positron.View,
    terminate: std.Thread.Condition = .{},
    terminate_mutex: std.Thread.Mutex = .{},
    run_seq: ZString = "",

    run: *const fn (target_argv: []const String, working_dir: ?String, env: ?*std.BufMap, terminate: *std.Thread.Condition, terminate_mutex: *std.Thread.Mutex) anyerror!void,

    pub fn getWebView(self: *@This()) *positron.View {
        return self.view;
    }

    pub fn terminateTarget(self: *@This()) void {
        self.terminate_mutex.lock();
        defer self.terminate_mutex.unlock();
        self.terminate.broadcast();
    }

    pub fn injectFunctions(self: *@This()) void {
        self.view.bind("browseFile", browseFile, self);
        self.view.bind("browseDirectory", browseDirectory, self);
        self.view.bindRaw("run", self, runFromUi);
        self.view.bind("terminate", terminateTarget, self);
    }
};

fn browseFile(_: *State, current: ZString) ?String {
    var out_path: ?[*:0]C.nfdchar_t = undefined;
    const result: C.nfdresult_t = C.NFD_OpenDialog(null, current.ptr, @ptrCast(&out_path));
    switch (result) {
        C.NFD_OKAY => return if (out_path) |o| std.mem.span(o) else null,
        C.NFD_CANCEL => return null,
        else => {
            log.err("NFD error: {s}", .{std.mem.span(C.NFD_GetError())});
            return null;
        },
    }
}

fn browseDirectory(_: *State, current: ZString) ?String {
    var out_path: ?[*:0]C.nfdchar_t = null;
    const result: C.nfdresult_t = C.NFD_PickFolder(current.ptr, @ptrCast(&out_path));
    switch (result) {
        C.NFD_OKAY => return if (out_path) |o| std.mem.span(o) else null,
        C.NFD_CANCEL => return null,
        else => {
            log.err("NFD error: {s}", .{std.mem.span(C.NFD_GetError())});
            return null;
        },
    }
}

pub fn runFromUi(state: *State, seq: ZString, req: ZString) void {
    state.run_seq = seq;
    log.debug("Run command from UI: {s}", .{seq});

    const Args = struct { program: String, directory: String, args: String, env: String };

    const args = std.json.parseFromSlice([]const Args, common.allocator, req, .{ .ignore_unknown_fields = true }) catch |err| {
        log.err("Failed to parse JSON: {}", .{err});
        state.view.@"return"(seq, .{
            .failure = "\"Failed to parse JSON\"",
        });
        return;
    };
    defer args.deinit();

    struct {
        fn run(a: Args, s: *State, command_s: ZString) !void {
            var list = std.ArrayListUnmanaged(String){};

            try list.append(common.allocator, try common.allocator.dupe(u8, a.program));

            var it = common.CliArgsIterator{ .s = a.args };
            while (it.next()) |arg| {
                try list.append(common.allocator, try common.allocator.dupe(u8, arg));
            }

            var env_map = try common.allocator.create(std.BufMap);
            env_map.* = std.BufMap.init(common.allocator);
            var env_it = std.mem.splitScalar(u8, a.env, '\n');
            while (env_it.next()) |item| {
                var env_parts = std.mem.splitScalar(u8, item, '=');
                const first = env_parts.first();
                if (std.mem.eql(u8, first, "\n")) continue;
                try env_map.put(first, env_parts.rest());
            }

            var run_thread = try std.Thread.spawn(.{}, struct {
                fn r(st: *State, ar: anytype, command_seq: ZString) !void {
                    defer common.allocator.free(command_seq);
                    try @call(.auto, st.run, ar);
                    if (st.run_seq.len > 0) {
                        st.view.@"return"(command_seq, .{
                            .success = "",
                        });
                        st.run_seq = "";
                    }
                    for (ar[0]) |arg| {
                        common.allocator.free(arg);
                    }
                    common.allocator.free(ar[0]);
                    ar[2].deinit();
                    common.allocator.destroy(ar[2]);
                }
            }.r, .{ s, .{ try list.toOwnedSlice(common.allocator), a.directory, env_map, &s.terminate, &s.terminate_mutex }, try common.allocator.dupeZ(u8, command_s) });
            defer run_thread.detach();
        }
    }.run(args.value[0], state, seq) catch |err| {
        log.err("Failed to run target: {}", .{err});
        state.view.@"return"(seq, .{
            .failure = "\"Failed to run target\"",
        });
    };
}
