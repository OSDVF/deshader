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
const positron = @import("positron");
const builtin = @import("builtin");
const common = @import("common");
const log = std.log.scoped(.wGUI);

const String = []const u8;
const ZString = [:0]const u8;
const C = @cImport({
    @cInclude("nfd.h");
    if (builtin.target.os.tag == .windows) {
        @cInclude("processthreadsapi.h");
    } else {
        @cInclude("unistd.h");
    }
});

pub const State = struct {
    view: *positron.View,
    terminate: std.Thread.Condition = .{},
    terminate_mutex: std.Thread.Mutex = .{},
    run_seq: ZString = "",
    /// Is the subprocess target running
    running: bool = false,
    /// SAFETY: will be assigned in `run()`
    target: std.process.Child = undefined,

    pub fn getWebView(self: *@This()) *positron.View {
        return self.view;
    }

    pub fn terminateTarget(self: *@This()) void {
        self.terminate_mutex.lock();
        defer self.terminate_mutex.unlock();
        self.terminate.broadcast();

        if (self.running) { // If the target is still running (termination was requested), kill it
            if (builtin.os.tag == .windows) {
                _ = self.target.kill() catch {};
            } else {
                std.posix.kill(-self.target.id, std.posix.SIG.TERM) catch |err| {
                    log.err("Failed to terminate target: {}", .{err});
                    return;
                }; // Kill the entire process group
                std.time.sleep(std.time.ns_per_ms * 200); // Wait for the target to exit
                std.posix.kill(-self.target.id, std.posix.SIG.KILL) catch {};
            }
        }
    }

    pub fn runRaw(self: *@This(), seq: ZString, req: ZString) void {
        self.run_seq = seq;
        const Args = struct { argv: []String, directory: String, env: std.json.ArrayHashMap(String) };

        const args = std.json.parseFromSlice([]const Args, common.allocator, req, .{ .ignore_unknown_fields = true }) catch |err| {
            log.err("Failed to parse JSON: {}", .{err});
            self.view.@"return"(seq, .{
                .failure = "\"Failed to parse JSON\"",
            });
            return;
        };
        defer args.deinit();

        // To wrap error handling
        run(self, args.value[0].argv, args.value[0].directory, args.value[0].env) catch |err| {
            log.err("Failed to run target: {}", .{err});
            self.view.@"return"(seq, .{
                .failure = "\"Failed to run target\"",
            });
        };
    }

    /// The returned subprocess wil be in State.target
    pub fn run(s: *State, argv: []String, directory: String, env: ?std.json.ArrayHashMap(String)) !void {
        var list = std.ArrayListUnmanaged(String){};
        defer list.deinit(common.allocator);

        // Append launcher exe as the first argument
        const launcher = try common.selfExePath();

        try list.append(common.allocator, launcher);

        for (argv) |arg| {
            try list.append(common.allocator, arg);
        }

        if (env) |e| {
            var env_it = e.map.iterator();
            while (env_it.next()) |entry| {
                common.env.set(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        const env_map = common.env.getMap();

        s.target = std.process.Child.init(list.items, common.allocator);
        s.target.env_map = env_map;
        if (directory.len > 0)
            s.target.cwd = directory;
        s.target.stderr_behavior = .Inherit;
        s.target.stdout_behavior = .Inherit;
        s.target.stdin_behavior = .Inherit;
        try s.target.spawn();
        s.running = true;

        if (builtin.os.tag != .windows) {
            _ = C.setpgid(s.target.id, 0); // Put the target in its own process group
        }
        log.info("Launched PID {d}, path {s}", .{ if (builtin.os.tag == .windows) C.GetProcessId(s.target.id) else s.target.id, list.items[1] });
        // TODO redirect stdout to a websocket

        var run_thread = try std.Thread.spawn(.{}, struct {
            fn r(st: *State) !void {
                _ = common.process.wailNoFailReport(&st.target);

                if (st.run_seq.len > 0) {
                    st.view.@"return"(st.run_seq, .{
                        .success = "",
                    });
                    st.run_seq = "";
                }
                st.running = false;
                st.terminate_mutex.lock();
                defer st.terminate_mutex.unlock();
                st.terminate.broadcast();
            }
        }.r, .{s});
        defer run_thread.detach();
    }

    pub fn injectFunctions(self: *@This()) void {
        self.view.bind("browseFile", browseFile, self);
        self.view.bind("browseDirectory", browseDirectory, self);
        self.view.bindRaw("run", self, runRaw);
        self.view.bind("terminate", terminateTarget, self);
    }
};

pub fn browseFile(_: *State, current: ZString) ?String {
    // SAFETY: assigned right after by NFD
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

pub fn browseDirectory(_: *State, current: ZString) ?String {
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
