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
const common = @import("common.zig");

pub const DeshaderLog = std.log.scoped(.Deshader);
pub var log_listener: ?*const fn (level: std.log.Level, scope: []const u8, message: []const u8) void = null;

pub fn logFn(comptime level: std.log.Level, comptime scope: @TypeOf(.EnumLiteral), comptime format: []const u8, args: anytype) void {
    if (log_listener != null) {
        if (std.fmt.allocPrint(common.allocator, format, args)) |message| {
            log_listener.?(level, @tagName(scope), message);
        } else |err| {
            _ = err catch {};
        }
    }
    std.log.defaultLog(level, scope, format, args);
}
pub const std_options = std.Options{
    .logFn = logFn,
};
