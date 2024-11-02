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
const CString = []const u8;
const C = @cImport(@cInclude("nfd.h"));

pub const State = struct {
    view: *positron.View,
    run: *const fn (target_argv: []const String, working_dir: ?String, env: ?std.StringHashMapUnmanaged(String)) anyerror!void,

    pub fn getWebView(self: *@This()) *positron.View {
        return self.view;
    }
    pub fn injectFunctions(self: *@This()) void {
        self.view.bind("browseFile", browseFile, self);
        self.view.bind("browseDirectory", browseDirectory, self);
        self.view.bind("run", runFromUi, self);
    }
};

fn browseFile(_: *State, current: CString) ?String {
    var out_path: [*:0]C.nfdchar_t = undefined;
    const result: C.nfdresult_t = C.NFD_OpenDialog(null, current.ptr, @ptrCast(&out_path));
    switch (result) {
        C.NFD_OKAY => return std.mem.span(out_path),
        C.NFD_CANCEL => return null,
        else => {
            log.err("NFD error: {s}", .{std.mem.span(C.NFD_GetError())});
            return null;
        },
    }
}

fn browseDirectory(_: *State, current: CString) ?String {
    var out_path: ?[*:0]C.nfdchar_t = null;
    const result: C.nfdresult_t = C.NFD_PickFolder(current.ptr, @ptrCast(&out_path));
    switch (result) {
        C.NFD_OKAY => return std.mem.span(out_path.?),
        C.NFD_CANCEL => return null,
        else => {
            log.err("NFD error: {s}", .{std.mem.span(C.NFD_GetError())});
            return null;
        },
    }
}

pub fn runFromUi(state: *State, program: CString, directory: CString, args: CString, env: CString) !void {
    var list = std.ArrayListUnmanaged(String){};
    defer list.deinit(common.allocator);

    try list.append(common.allocator, program);

    var it = common.CliArgsIterator{ .s = args };
    while (it.next()) |arg| {
        try list.append(common.allocator, arg);
    }

    var env_map = std.StringHashMapUnmanaged(String){};
    defer env_map.deinit(common.allocator);
    var env_it = std.mem.splitScalar(u8, env, '\n');
    while (env_it.next()) |item| {
        var env_parts = std.mem.splitScalar(u8, item, '=');
        try env_map.put(common.allocator, env_parts.first(), env_parts.rest());
    }

    try state.run(list.items, directory, env_map);
}
