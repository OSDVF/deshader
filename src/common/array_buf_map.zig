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
const StringArrayHashMap = std.StringArrayHashMap;
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;

/// Copies keys before they go into the map
pub fn ArrayBufMap(comptime Payload: type) type {
    return struct {
        hash_map: BufMapHashMap,

        const BufMapHashMap = StringArrayHashMap(Payload);

        /// Create a ArrayBufMap backed by a specific allocator.
        /// That allocator will be used for both backing allocations
        /// and string deduplication.
        pub fn init(allocator: Allocator) @This() {
            return .{ .hash_map = BufMapHashMap.init(allocator) };
        }

        /// Free the backing storage of the map, as well as all
        /// of the stored keys and values.
        pub fn deinit(self: *@This()) void {
            var it = self.hash_map.iterator();
            while (it.next()) |entry| {
                self.free(entry.key_ptr.*);
            }

            self.hash_map.deinit();
        }

        pub fn clearAndFree(self: *@This()) void {
            var it = self.hash_map.iterator();
            while (it.next()) |entry| {
                self.free(entry.key_ptr.*);
            }

            self.hash_map.clearAndFree();
        }

        pub fn clearRetainingCapacity(self: *@This()) void {
            var it = self.hash_map.iterator();
            while (it.next()) |entry| {
                self.free(entry.key_ptr.*);
            }

            self.hash_map.clearRetainingCapacity();
        }

        /// Same as `put` but the key and value become owned by the ArrayBufMap rather
        /// than being copied.
        /// If `putMove` fails, the ownership of key and value does not transfer.
        pub fn putMove(self: *@This(), key: []u8, value: Payload) !void {
            const get_or_put = try self.hash_map.getOrPut(key);
            if (get_or_put.found_existing) {
                self.free(get_or_put.key_ptr.*);
                get_or_put.key_ptr.* = key;
            }
            get_or_put.value_ptr.* = value;
        }

        /// `key` and `value` are copied into the ArrayBufMap.
        pub fn put(self: *@This(), key: []const u8, value: Payload) !void {
            _ = self.putGetEntry(key, value);
        }

        pub fn putGetEntry(self: *@This(), key: []const u8, value: Payload) !BufMapHashMap.Entry {
            const get_or_put = try self.hash_map.getOrPut(key);
            if (!get_or_put.found_existing) {
                get_or_put.key_ptr.* = self.copy(key) catch |err| {
                    _ = self.hash_map.swapRemove(key);
                    return err;
                };
            }
            get_or_put.value_ptr.* = value;
            return .{ .value_ptr = get_or_put.value_ptr, .key_ptr = get_or_put.key_ptr };
        }

        pub fn getOrPut(self: *@This(), key: []const u8) !BufMapHashMap.GetOrPutResult {
            const get_or_put = try self.hash_map.getOrPut(key);
            if (!get_or_put.found_existing) {
                get_or_put.key_ptr.* = self.copy(key) catch |err| {
                    _ = self.hash_map.swapRemove(key);
                    return err;
                };
            }
            return get_or_put;
        }

        /// Find the address of the value associated with a key.
        /// The returned pointer is invalidated if the map resizes.
        pub fn getPtr(self: @This(), key: []const u8) ?*Payload {
            return self.hash_map.getPtr(key);
        }

        /// Return the map's copy of the value associated with
        /// a key.  The returned string is invalidated if this
        /// key is removed from the map.
        pub fn get(self: @This(), key: []const u8) ?Payload {
            return self.hash_map.get(key);
        }

        pub fn getEntry(self: @This(), key: []const u8) ?BufMapHashMap.Entry {
            return self.hash_map.getEntry(key);
        }

        /// Removes the item from the map and frees its value.
        /// This invalidates the value returned by get() for this key.
        pub fn remove(self: *@This(), key: []const u8) bool {
            const kv = self.hash_map.fetchSwapRemove(key) orelse return false;
            self.free(kv.key);
            return true;
        }

        /// Returns the number of KV pairs stored in the map.
        pub fn count(self: @This()) BufMapHashMap.Size {
            return self.hash_map.count();
        }

        /// Returns an iterator over entries in the map.
        pub fn iterator(self: *const @This()) BufMapHashMap.Iterator {
            return self.hash_map.iterator();
        }

        fn free(self: @This(), value: []const u8) void {
            self.hash_map.allocator.free(value);
        }

        fn copy(self: @This(), value: []const u8) ![]u8 {
            return self.hash_map.allocator.dupe(u8, value);
        }
    };
}
