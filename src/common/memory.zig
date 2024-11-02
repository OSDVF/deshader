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

pub fn dupeSliceOfSlices(alloc: std.mem.Allocator, comptime t: type, input: []const []const t) ![]const []const t {
    var result = try alloc.alloc([]const t, input.len);
    for (0..input.len) |i| {
        result[i] = try alloc.dupe(t, input[i]);
    }
    return result;
}

pub fn dupeHashMap(comptime H: type, alloc: std.mem.Allocator, input: H) !H {
    var result = H.init(alloc);
    var iter = input.iterator();
    while (iter.next()) |item| {
        try result.put(item.key_ptr.*, item.value_ptr.*);
    }
    return result;
}
