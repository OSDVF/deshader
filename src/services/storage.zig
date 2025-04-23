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
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const decls = @import("../declarations/shaders.zig");

const shaders = @import("shaders.zig");
const common = @import("common");
const log = common.log;

const String = []const u8;
const CString = [*:0]const u8;
const ZString = [:0]const u8;

const Shader = shaders.Shader;
const root_name: String = "";
const storage = @This();

/// # Deshader virtual storage
/// All detected shaders are stored here with their tags or refs.
/// This isn't an ordinary filesystem structure because a shader can have more tags.
/// Also tags can point to shaders which already have a different tag, so there is both M:N relationship between [Tag]-[Tag] and between [Tag]-[Stored].
/// This can lead to orphans, cycles or many other difficulties but this is not a real filesystem so we ignore the downsides for now.
///
/// `Stored` type must be void or have these fields:
/// ```zig
///     pub const Ref = enum { _ }; // or `usize` or ...
///     tags: StringArrayHashMapUnmanaged(*Tag(Stored)) // will use this storage's allocator
///     stat: Stat
/// ```
/// `Nested` type is optional (can be void) and it is used for storing directories as the Stored objects (like in the case of programs)
/// Both the types must have property
/// ```zig
///     pub const Ref = enum { _ }; // or `usize` or ...
///     ref: Ref
/// ```
pub fn Storage(comptime Stored: type, comptime Nested: type, comptime Parted: bool) type {
    return struct {
        pub const Self = @This();
        pub const StoredDir = Dir(Stored);
        pub const StoredTag = Tag(Stored);
        /// Stores a list of untagged shader parts
        pub const StoredOrList = if (Parted) std.ArrayListUnmanaged(Stored) else Stored;
        pub const StoredPtrOrArray = if (Parted) []Stored else *Stored;
        pub const RefMap = std.AutoHashMapUnmanaged(Stored.Ref, *StoredOrList);
        pub const isParted = Parted;
        pub const Locator = if (Nested == void) storage.Locator(Stored) else storage.Locator(Stored).Nesting(Nested);
        /// programs / source parts mapped by tag
        tagged_root: StoredDir,
        /// programs / source parts list corresponding to the same shader. Mapped by ref
        all: RefMap = .empty,
        allocator: std.mem.Allocator,
        pool: if (Stored == void) void else std.heap.MemoryPool(StoredOrList), // for storing all the Stored objects
        bus: common.Bus(StoredTag.Event, false),
        nested_bus: if (Nested != void) *common.Bus(Tag(Nested).Event, false) else void,

        pub fn init(alloc: std.mem.Allocator, nested_bus: if (Nested == void) void else *common.Bus(Tag(Nested).Event, false)) @This() {
            return @This(){
                .allocator = alloc,
                .bus = common.Bus(StoredTag.Event, false).init(alloc),
                .nested_bus = nested_bus,
                .tagged_root = StoredDir{
                    .allocator = alloc,
                    .name = root_name,
                    .parent = null,
                    .stat = Stat.now(),
                },
                .pool = if (Stored == void) {} else std.heap.MemoryPool(StoredOrList).init(alloc),
            };
        }

        const parted = struct {
            const AppendUntaggedResult = struct { stored: *Stored, index: usize };

            /// Append to an existing parted []Stored with same ref or create a new Stored (parts list) with that ref
            pub fn appendUntagged(self: *Self, ref: Stored.Ref) !AppendUntaggedResult {
                if (Stored == void) {
                    @compileError("This storage stores void");
                }
                const maybe_ptr = try self.all.getOrPut(self.allocator, ref);
                if (!maybe_ptr.found_existing) {
                    const new = try self.pool.create();
                    new.* = std.ArrayListUnmanaged(Stored){};
                    maybe_ptr.value_ptr.* = new;
                }
                try maybe_ptr.value_ptr.*.append(self.allocator, undefined);
                const new_index = maybe_ptr.value_ptr.*.items.len - 1;
                return AppendUntaggedResult{ .stored = &maybe_ptr.value_ptr.*.items[new_index], .index = new_index };
            }
        };

        pub const appendUntagged = if (Parted) parted.appendUntagged;

        const not_nested = struct {
            pub fn list(self: *const Self, allocator: std.mem.Allocator, locator: Self.Locator, recursive: bool, physical: bool) ![]CString {
                return self.listLocator(allocator, locator, recursive, physical, null);
            }
        };

        const nested = struct {
            pub fn getNestedByLocator(self: *Self, locator: storage.Locator(Stored).Name, n: storage.Locator(Nested).Name) (std.mem.Allocator.Error || Error)!*Nested {
                switch (try self.getByLocator(locator, n)) {
                    .Nested => |ne| return ne.nested orelse Error.DirExists,
                    else => return Error.DirExists,
                }
            }

            pub fn getByLocator(self: *Self, locator: storage.Locator(Stored).Name, n: ?storage.Locator(Nested).Name) (std.mem.Allocator.Error || Error)!DirOrStored.Content {
                if (Stored == void) {
                    @compileError("This storage stores void");
                }
                switch (locator) {
                    .untagged => |combined| {
                        const var_or_list = self.all.get(combined.ref) orelse return Error.TargetNotFound;
                        const u = if (Parted) &var_or_list.items[combined.part] else var_or_list;
                        if (n) |ne| if (ne.isRoot()) {
                            return Error.InvalidPath;
                        } else {
                            return try u.getNested(ne);
                        } else return DirOrStored.Content{
                            .Nested = .{
                                .parent = var_or_list,
                            },
                        };
                    },
                    .tagged => |tagged| {
                        return (try self.makePathRecursive(tagged, false, false, false)).content;
                    },
                }
            }

            pub fn untagged(allocator: std.mem.Allocator, path: String) !CString {
                return try std.fs.path.joinZ(allocator, &.{ path, untagged_path[1..] ++ "/" });
            }

            pub fn list(self: *const Self, allocator: std.mem.Allocator, locator: Self.Locator, recursive: bool, physical: bool, nested_postfix: ?String) ![]CString {
                return self.listLocator(allocator, locator, recursive, physical, nested_postfix);
            }
        };

        pub const getNestedByLocator = if (Nested != void) nested.getNestedByLocator;
        pub const getByLocator = if (Nested != void) nested.getByLocator;
        pub const untagged = if (Nested != void) nested.untagged;
        pub const list = if (Nested == void) not_nested.list else nested.list;

        fn getInnerType(comptime t: type) type {
            var result = t;
            while (@as(?std.builtin.Type.Pointer, switch (@typeInfo(result)) {
                .pointer => |ptr| ptr,
                else => null,
            })) |ptr| {
                result = ptr.child;
            }
            return result;
        }

        /// Pass any args that the `Stored` wants for its `deinit` function
        pub fn deinit(self: *@This(), args: anytype) void {
            self.bus.deinit();
            self.tagged_root.deinit();
            {
                var it = self.all.valueIterator();
                while (it.next()) |val_or_list| {
                    if (Parted) {
                        for (val_or_list.*.items) |*val| {
                            const deinit_fn = getInnerType(Stored).deinit;
                            const args_with_this = .{val} ++ args;
                            if (@typeInfo(@TypeOf(deinit_fn)).@"fn".return_type == void) {
                                @call(.auto, deinit_fn, args_with_this);
                            } else {
                                @call(.auto, deinit_fn, args_with_this) catch {};
                            }
                        }
                        val_or_list.*.deinit(self.allocator);
                    } else {
                        const deinit_fn = getInnerType(Stored).deinit;
                        const args_with_this = .{val_or_list.*} ++ args;
                        if (@typeInfo(@TypeOf(deinit_fn)).@"fn".return_type == void) {
                            @call(.auto, deinit_fn, args_with_this);
                        } else {
                            @call(.auto, deinit_fn, args_with_this) catch {};
                        }
                    }
                }
                self.all.deinit(self.allocator);
            }
            if (Stored != void)
                self.pool.deinit();
        }

        /// Lists existing tags and directories
        /// the returned paths are relative to `path`
        pub fn listDir(self: *const @This(), allocator: std.mem.Allocator, path: String, recursive: bool, physical: bool, nested_postfix: ?String) !std.ArrayListUnmanaged(CString) {
            log.debug("Listing path {?s} recursive:{?}", .{ path, recursive });

            // print tagged
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            var fix_allocator = std.heap.FixedBufferAllocator.init(&buffer);
            // growing and shrinking path prefix for current directory
            var current_path = std.ArrayList(u8).init(fix_allocator.allocator());
            defer current_path.deinit();

            const DirStackItem = struct {
                content: DirOrStored.Content,
                prev_len: usize, // parent directory path length
            };
            var stack = std.ArrayListUnmanaged(DirStackItem){};
            defer stack.deinit(allocator);

            // when no overwrite and create flags are set, we can safely assume that `self` won't be modified
            const root = try @constCast(self).makePathRecursive(path, false, false, true);
            //DFS print of directory tree
            try stack.append(allocator, .{ .content = root.content, .prev_len = 0 });

            var result = std.ArrayListUnmanaged(CString){};
            while (stack.pop()) |current| {
                if (Nested != void and current.content == .Nested) {
                    const n = current.content.Nested;
                    if (n.nested) |_| {
                        return Error.DirectoryNotFound;
                    } else {
                        // list the untagged root
                        _ = try n.parent.listNested(allocator, current_path.items, nested_postfix, true, &result);
                    }
                } else if (current.content == .Dir) {
                    const dir = current.content.Dir;
                    if (dir.name.len > 0) {
                        current_path.shrinkRetainingCapacity(current.prev_len);
                    }

                    if (stack.items.len > 1) {
                        try current_path.appendSlice(dir.name); // add current directory, but not the requested root
                    }
                    try current_path.append('/');

                    var files = dir.files.iterator();
                    while (files.next()) |file| {
                        try result.append(allocator, try std.mem.concatWithSentinel(allocator, u8, &.{ current_path.items, file.value_ptr.name, if (Nested == void) "" else "/" }, 0));
                        if (Nested != void and recursive) {
                            try stack.append(allocator, .{ .content = .{ .Tag = file.value_ptr }, .prev_len = current_path.items.len });
                        }
                    }

                    var subdirs = dir.dirs.iterator();
                    while (subdirs.next()) |subdir| {
                        if (recursive) {
                            try stack.append(allocator, .{ .content = .{ .Dir = subdir.value_ptr }, .prev_len = current_path.items.len });
                        } else {
                            // just print the directory
                            try result.append(allocator, try std.fmt.allocPrintZ(allocator, "{s}{s}/", .{ current_path.items, subdir.key_ptr.* }));
                        }
                    }

                    if (physical) {
                        try dir.listPhysical(allocator, &result, current_path.items, recursive);
                    }
                } else if (current.content == .Tag) {
                    const tag = current.content.Tag;
                    if (Nested == void) {
                        return Error.DirectoryNotFound;
                    }
                    try current_path.appendSlice(tag.name);
                    try current_path.append('/');
                    const has_untagged = try tag.target.listNested(allocator, current_path.items, nested_postfix, if (recursive) null else false, &result);
                    if (has_untagged) {
                        // add untagged root
                        try result.append(allocator, try nested.untagged(allocator, current_path.items));
                    }
                }
            }

            return result;
        }

        fn listLocator(self: *const Self, allocator: std.mem.Allocator, locator: Self.Locator, recursive: bool, physical: bool, nested_postfix: ?String) ![]CString {
            switch (locator.name) {
                .tagged => |path| {
                    if (Nested != void and !locator.nested.isRoot()) {
                        return Error.DirectoryNotFound;
                    }
                    var result = try self.listDir(allocator, if (Nested == void) path else locator.fullPath, recursive, physical, nested_postfix);
                    if (path.len == 0 or std.mem.eql(u8, path, "/")) {
                        try result.append(allocator, try common.allocator.dupeZ(u8, storage.untagged_path ++ "/")); // add the virtual /untagged/ directory
                    }
                    return try result.toOwnedSlice(allocator);
                },
                .untagged => |ref| {
                    return self.listUntagged(allocator, ref.ref, nested_postfix, if (Nested == void) false else locator.nested.isUntagged());
                },
            }
        }

        /// If `ref_or_root == 0` this function lists all untagged objects.
        /// Otherwise it lists nested objects under this untagged resource.
        pub fn listUntagged(self: *const @This(), allocator: std.mem.Allocator, ref_or_root: Stored.Ref, nested_postfix: ?String, nested_untagged: ?bool) ![]CString {
            var result = try std.ArrayListUnmanaged(CString).initCapacity(allocator, self.all.count());
            if ((@hasField(Stored.Ref, "root") and ref_or_root == .root) or @intFromEnum(ref_or_root) == 0) {
                var iter = self.all.iterator();
                while (iter.next()) |items| {
                    if (Parted) {
                        for (items.value_ptr.*.items, 0..) |*item, index| {
                            if (item.tag != null) { // skip tagged ones
                                continue;
                            }
                            try result.append(allocator, try if (Nested == void) // Directories have trailing slash
                                std.fmt.allocPrintZ(allocator, "{}{s}", .{ storage.Locator(Stored).PartRef{ .ref = item.ref, .part = index }, item.toExtension() })
                            else
                                std.fmt.allocPrintZ(allocator, "{}/", .{storage.Locator(Stored).PartRef{ .ref = item.ref, .part = index }}));
                        }
                    } else {
                        const item = items.value_ptr.*;
                        if (item.tag != null) { // skip tagged ones
                            continue;
                        }
                        try result.append(allocator, try if (Nested == void) // Directories have trailing slash
                            std.fmt.allocPrintZ(allocator, "{}{s}", .{ storage.Locator(Stored).PartRef{ .ref = item.ref, .part = 0 }, item.toExtension() })
                        else
                            std.fmt.allocPrintZ(allocator, "{}/", .{storage.Locator(Stored).PartRef{ .ref = item.ref, .part = 0 }}));
                    }
                }
            } // 0 can be also a valid ref, so also list its sources

            if (Nested != void) { //Specialization
                const stored_parts = self.all.get(ref_or_root) orelse return Error.TargetNotFound;
                if (!Parted or stored_parts.items.len > 0) {
                    const stored = if (Parted) stored_parts.items[0] else stored_parts;
                    const has_untagged = try stored.listNested(allocator, "", nested_postfix, nested_untagged, &result);
                    if (has_untagged and nested_untagged != null and !nested_untagged.?) {
                        try result.append(allocator, try nested.untagged(allocator, ""));
                    }
                }
            } else {
                return error.DirectoryNotFound;
            }

            return result.toOwnedSlice(allocator);
        }

        pub fn renameByLocator(self: *Self, locator: storage.Locator(Stored).Name, to: String) !DirOrStored.Content {
            return switch (locator) {
                .tagged => |path| try self.renamePath(path, to),
                .untagged => |ref| .{ .Tag = try self.assignTag(ref.ref, ref.part, to, .Error) },
            };
        }

        fn protectedError(path: String) void {
            log.err("InvalidPath: Cannot rename {s}. It is protected.", .{path});
        }

        /// Rename a directory or a tagged file
        pub fn renamePath(self: *Self, from: String, to: String) !DirOrStored.Content {
            const existing = try self.makePathRecursive(from, false, false, false);
            std.debug.assert(existing.is_new == false);
            const target_dirname = std.fs.path.dirnamePosix(to);
            const target_basename = std.fs.path.basenamePosix(to);
            const rename_only_base = common.nullishEq(String, std.fs.path.dirnamePosix(from), target_dirname);
            if (Nested != void and existing.content == .Nested) { // renaming a shader under program can be done only on basename basis
                if (rename_only_base) {
                    const n = existing.content.Nested.nested orelse {
                        protectedError(from);
                        return Error.InvalidPath;
                    };
                    self.nested_bus.dispatchNoThrow(Tag(Nested).Event{ .action = .Remove, .tag = n.tag.? });
                    try n.tag.?.rename(target_basename);
                    self.nested_bus.dispatchNoThrow(Tag(Nested).Event{ .action = .Assign, .tag = n.tag.? });
                    return existing.content;
                } else {
                    return Error.InvalidPath;
                }
            } else switch (existing.content) {
                .Tag => |tag| if (rename_only_base) {
                    self.bus.dispatchNoThrow(StoredTag.Event{ .action = .Remove, .tag = tag });
                    try tag.rename(target_basename);
                    self.bus.dispatchNoThrow(StoredTag.Event{ .action = .Assign, .tag = tag });
                    return .{ .Tag = tag };
                } else {
                    const f = tag.fetchRemove();
                    self.bus.dispatchNoThrow(StoredTag.Event{ .action = .Remove, .tag = tag });
                    return .{ .Tag = try self.assignTagTo(f, to, .Error) };
                },
                else => |dir| {
                    if (rename_only_base) {
                        try dir.Dir.rename(target_basename);
                        return .{ .Dir = dir.Dir };
                    } else {
                        const from_parent = dir.Dir.parent orelse &self.tagged_root;
                        const old: StoredDir.DirMap.KV = from_parent.dirs.fetchRemove(dir.Dir.name).?;
                        self.allocator.free(old.value.name);

                        const target_parent = try self.makePathRecursive(target_dirname orelse "", true, false, true);
                        const target_dupe = try self.allocator.dupe(u8, target_basename);
                        const new = try target_parent.content.Dir.dirs.getOrPut(self.allocator, target_dupe);
                        new.value_ptr.* = old.value;
                        new.value_ptr.name = target_dupe;
                        return .{ .Dir = new.value_ptr };
                    }
                },
            }
        }

        /// the content has to exist in the untagged storage
        pub fn assignTag(self: *@This(), ref: Stored.Ref, index: usize, path: String, if_exists: decls.ExistsBehavior) (Error || std.mem.Allocator.Error)!*StoredTag {
            // check for all
            if (self.all.get(ref)) |ptr| {
                return self.assignTagTo(if (Parted) &ptr.items[index] else ptr, path, if_exists);
            } else {
                log.err("Tried to put tag {s} to {x} but the pointer has no untagged content", .{ path, ref });
                return Error.TargetNotFound;
            }
        }

        /// the content has to exist in the untagged storage
        pub fn assignTagTo(self: *@This(), stored: *Stored, path: String, if_exists: decls.ExistsBehavior) (Error || std.mem.Allocator.Error)!*StoredTag {
            if (if_exists == .Error) if (stored.tag) |tag| {
                log.err("Tried to put tag {s} to {x} but the pointer has already tag {}", .{ path, stored.ref, tag });
                return Error.TagExists;
            };

            var target = try self.makePathRecursive(path, true, if_exists != .Error, false);

            if (target.content == .Dir) {
                log.err("Tried to put tag {s} to {x} but the path is a directory", .{ path, stored.ref });
                return Error.DirExists;
            }
            if (Stored != void) {
                // assign "reverse pointer" (from the content to the tag)
                target.content.Tag.target = stored;
                if (stored.tag == null or if_exists == .Overwrite) {
                    stored.tag = target.content.Tag;
                    self.bus.dispatchNoThrow(StoredTag.Event{ .action = .Assign, .tag = target.content.Tag });
                } else if (if_exists == .Link) {
                    try target.content.Tag.backlinks.append(self.allocator, target.content.Tag);
                    // TODO: also dispatch event here?
                } else unreachable; // error should be already thrown at self.makePathRecursive
            }
            return target.content.Tag;
        }

        pub fn mkdir(self: *@This(), path: String) !*Dir(Stored) {
            return (try self.makePathRecursive(path, true, false, true)).content.Dir;
        }

        pub const createUntagged = if (Parted) struct {
            fn c(self: *Self, ref: Stored.Ref, count: usize) ![]Stored {
                return try self.createUntaggedImpl(ref, count);
            }
        }.c else struct {
            fn c(self: *Self, ref: Stored.Ref) !*Stored {
                return try self.createUntaggedImpl(ref, 1);
            }
        }.c;

        fn createUntaggedImpl(self: *@This(), ref: Stored.Ref, count: usize) !StoredPtrOrArray {
            if (Stored == void) {
                @compileError("This storage stores void");
            }
            const maybe_ptr = try self.all.getOrPut(self.allocator, ref);
            if (!maybe_ptr.found_existing) {
                const new = try self.pool.create();
                if (Parted) {
                    new.* = std.ArrayListUnmanaged(Stored){};
                }
                maybe_ptr.value_ptr.* = new;
            }
            if (Parted) {
                const prev_len = maybe_ptr.value_ptr.*.items.len;
                try maybe_ptr.value_ptr.*.appendNTimes(self.allocator, undefined, count);
                return maybe_ptr.value_ptr.*.items[prev_len..];
            } else return maybe_ptr.value_ptr.*;
        }

        /// `recursive` => if the path points to a directory, remove the contents recursively.
        /// Does not erase tag content from the untagged storage.
        pub fn untag(self: *Self, path: String, recursive: bool) (std.mem.Allocator.Error || Error)!void {
            const ptr = try self.makePathRecursive(path, false, false, false); // also checks for existence
            if (Nested != void and ptr.content == .Nested) {
                (ptr.content.Nested.nested orelse {
                    protectedError(path);
                    return Error.InvalidPath;
                }).tag.?.remove();
            } else switch (ptr.content) {
                .Dir => |content_dir| {
                    if (!recursive) {
                        return Error.DirExists;
                    }
                    var subdirs = content_dir.dirs.iterator();
                    while (subdirs.next()) |subdir| {
                        // remove content of subdirs
                        try untag(self, subdir.key_ptr.*, true);

                        // remove self
                        content_dir.deinit(); // removes subdirs and files references
                        // TODO convert to tail-recursion
                        if (content_dir.parent) |parent| {
                            std.debug.assert(parent.dirs.remove(content_dir.name));
                        }
                    }
                },
                else => |content_tag| { // a single file
                    self.bus.dispatchNoThrow(StoredTag.Event{ .action = .Remove, .tag = content_tag.Tag });
                    content_tag.Tag.remove();
                },
            }
        }

        /// Remove a `Stored` from both tagged and untagged storage.
        /// Use `untag` to remove only a record in the tagged storage.
        pub fn remove(self: *@This(), ref: Stored.Ref) !void {
            // remove the content
            const removed_maybe = self.all.fetchRemove(ref);
            if (removed_maybe) |removed| {
                if (Parted) {
                    for (removed.value.items) |item| {
                        // Remove all which pointed to this file
                        if (item.tag) |t| for (t.backlinks.items) |tag| {
                            tag.remove();
                        };
                    }
                } else {
                    if (removed.value.tag) |t| {
                        self.bus.dispatchNoThrow(StoredTag.Event{ .action = .Remove, .tag = t });
                        t.remove();
                    }
                }
            } else {
                return Error.TargetNotFound;
            }
        }

        /// Remove only from tagged, kepp in untagged
        pub fn untagIndex(self: *@This(), ref: Stored.Ref, index: usize) !void {
            const contents_maybe = self.all.get(ref);
            if (contents_maybe) |contents| {
                if (if (Parted) contents.items[index].tag else contents.tag) |tag| {
                    self.bus.dispatchNoThrow(StoredTag.Event{ .action = .Remove, .tag = tag });
                    tag.remove();
                } else {
                    return Error.NotTagged;
                }
            } else {
                return Error.TargetNotFound;
            }
        }

        /// Remove only from tagged, kepp in untagged
        pub fn untagAll(self: *@This(), ref: Stored.Ref) !void {
            const contents_maybe = self.all.get(ref);
            if (contents_maybe) |contents| {
                for (contents.items) |item| {
                    if (item.tag) |tag| {
                        self.bus.dispatchNoThrow(StoredTag.Event{ .action = .Remove, .tag = tag });
                        tag.remove();
                    } else {
                        return Error.NotTagged;
                    }
                }
            } else {
                return Error.TargetNotFound;
            }
        }

        pub fn stat(self: *@This(), locator: storage.Locator(Stored).Name) !StatPayload {
            if (Stored == void) {
                @compileError("Stat is not possible for void Storages");
            }
            switch (locator) {
                .untagged => |combined| {
                    const ptr = try self.all.get(combined.ref);
                    const s = ptr.items[combined.part].stat;
                    return StatPayload{
                        .type = @intFromEnum(FileType.File),
                        .accessed = s.accessed,
                        .created = s.created,
                        .modified = s.modified,
                        .size = if (ptr.items[combined.part].getSource()) |sr| sr.len else 0,
                    };
                },
                .tagged => |path| {
                    const ptr = try self.makePathRecursive(path, false, false, false);
                    if (ptr.content == .Dir) {
                        const dir = ptr.content.Dir;
                        return StatPayload{
                            .type = @intFromEnum(FileType.Directory),
                            .accessed = dir.stat.accessed,
                            .created = dir.stat.created,
                            .modified = dir.stat.modified,
                            .size = 0,
                        };
                    } else if (Nested == void) {
                        const s = ptr.content.Tag.target.?.*.stat;
                        return StatPayload{
                            .type = //TODO symlinks
                            @intFromEnum(FileType.File),
                            .accessed = s.accessed,
                            .created = s.created,
                            .modified = s.modified,
                            .size = if (ptr.content.Tag.target) |t| if (t.*.getSource()) |sr| sr.len else 0 else 0,
                        };
                    } else if (ptr.content == .Nested) {
                        if (ptr.content.Nested.nested) |n| {
                            return StatPayload{
                                .type = @intFromEnum(FileType.File),
                                .accessed = n.stat.accessed,
                                .created = n.stat.created,
                                .modified = n.stat.modified,
                                .size = if (n.getSource()) |s| s.len else 0,
                            };
                        } else {
                            const now = Stat.now();
                            return StatPayload{
                                .type = @intFromEnum(FileType.Directory),
                                .accessed = now.accessed,
                                .created = now.created,
                                .modified = now.modified,
                                .size = 0,
                            };
                        }
                    }
                },
            }
        }

        pub const DirOrStored = struct {
            pub const Content = if (Nested != void) union(enum) {
                Tag: *Tag(Stored),
                Nested: struct {
                    parent: *const Stored,
                    /// `null` => Nested untagged root
                    nested: ?*Nested = null,
                    part: usize = 0,
                },
                Dir: *Dir(Stored),
            } else union(enum) {
                Tag: *Tag(Stored),
                Dir: *Dir(Stored),
            };
            is_new: bool,
            content: Content,
        };

        pub fn getStoredByLocator(self: *@This(), locator: storage.Locator(Stored).Name) !*Stored {
            return switch (locator) {
                .tagged => |path| try self.getStoredByPath(path),
                .untagged => |combined| if (Parted) if (self.all.get(combined.ref)) |s| &s.items[combined.part] else Error.TargetNotFound else if (self.all.getPtr(combined.ref)) |s| s else Error.TargetNotFound,
            };
        }

        // Return a tagged Stored
        // TODO not create paths when only reading
        pub fn getStoredByPath(self: *@This(), path: String) !*Stored {
            if (Stored == void) {
                @compileError("This storage stores void");
            }
            const ptr = try self.makePathRecursive(path, false, false, false);
            switch (ptr.content) {
                .Tag => |tag| return tag.target,
                else => return Error.DirExists,
            }
        }

        pub fn getDirByPath(self: *@This(), path: String) !*Dir(Stored) {
            const ptr = try self.makePathRecursive(path, false, false, false);
            switch (ptr.content) {
                .Dir => |dir| return dir,
                else => return Error.TagExists,
            }
        }

        pub fn removeDir(self: *@This(), path: String) !void {
            // TODO really needed to create the path?
            const ptr = try self.makePathRecursive(path, false, false, false);
            if (ptr.content == .Dir) {
                ptr.content.Dir.deinit();
            } else {
                return Error.TagExists;
            }
        }

        /// Gets an existing tag or directory, throws error if it doesn't exist, or
        /// - `create_new` => if the path pointer does not exist, create it (recursively).
        /// - `create_as_dir` switches between creating a pointer for new Tag(payload) or Dir(payload)
        /// - `overwrite` => return the path pointer even if it already exists and create_new is true (this means the function should always succeed).
        /// Caller should assign pointer from the content to the tag when the tag path pointer is created or changed.
        /// Makes this kind of a universal function.
        pub fn makePathRecursive(self: *@This(), path: String, create_new: bool, overwrite: bool, create_as_dir: bool) (std.mem.Allocator.Error || Error)!DirOrStored {
            var path_iterator = std.mem.splitScalar(u8, if (path.len > 0 and path[0] == '/') path[1..] else path, '/');
            var root: String = "";
            var current_dir_entry: Dir(Stored).DirMap.Entry = .{ .value_ptr = &self.tagged_root, .key_ptr = &root };

            while (path_iterator.next()) |path_part| {
                // traverse directories
                if (current_dir_entry.value_ptr.dirs.getEntry(path_part)) |found| {
                    current_dir_entry = .{ .value_ptr = found.value_ptr, .key_ptr = found.key_ptr };
                } else {
                    if (path_iterator.peek()) |next_path_part| { // there is another path part (nested directory or file) pending
                        if (Nested != void) {
                            return self.makePathEntry(
                                .{ .dir = current_dir_entry.value_ptr, .subpath = next_path_part },
                                path_part,
                                create_new,
                                overwrite,
                                create_as_dir,
                            );
                        } else if (create_new) { // create recursive directory structure
                            log.debug("Recursively creating directory {s} in /{s}", .{ path_part, path_iterator.buffer[0 .. (path_iterator.index orelse (path_part.len + 1)) - path_part.len - 1] });
                            const new_dir = try StoredDir.createIn(self.allocator, current_dir_entry.value_ptr, path_part);
                            current_dir_entry = .{ .value_ptr = new_dir, .key_ptr = &new_dir.name };
                        } else {
                            return error.DirectoryNotFound;
                        }
                    } else {
                        return self.makePathEntry(
                            if (Nested != void) .{ .dir = current_dir_entry.value_ptr, .subpath = "" } else current_dir_entry.value_ptr,
                            path_part,
                            create_new,
                            overwrite,
                            create_as_dir,
                        );
                    }
                }
            }

            // at this point we have found a directory but not a file
            return .{
                .is_new = false,
                .content = .{ .Dir = current_dir_entry.value_ptr },
            };
        }

        /// Tag's `target` will be undefined if new
        fn makePathEntry(
            self: *@This(),
            in_dir: if (Nested != void) struct { dir: *Dir(Stored), subpath: String } else *Dir(Stored),
            name: String,
            create: bool,
            overwrite: bool,
            create_as_dir: bool,
        ) (std.mem.Allocator.Error || Error)!DirOrStored {
            const dir = if (Nested != void) in_dir.dir else in_dir;
            if (name.len == 0 and (Nested == void or in_dir.subpath.len == 0)) { //root
                return .{
                    .is_new = false,
                    .content = .{ .Dir = dir },
                };
            }
            // traverse files
            if (dir.files.getEntry(name)) |existing_file| {
                if (Nested != void and in_dir.subpath.len > 0) {
                    existing_file.value_ptr.target.touch();
                    const nested_locator = try storage.Locator(Nested).parse(in_dir.subpath);
                    return .{ .content = if (nested_locator.file()) |n|
                        try existing_file.value_ptr.target.getNested(n.name)
                    else
                        .{ .Nested = .{ .parent = existing_file.value_ptr.target } }, .is_new = false };
                } else {
                    dir.touch();
                }
                if (Nested == void or in_dir.subpath.len == 0) {
                    if (overwrite) {
                        if (create_as_dir) {
                            return Error.TagExists;
                        }

                        // Remove old / overwrite
                        const old_content = existing_file.value_ptr.target;
                        old_content.dirty();
                        log.debug("Overwriting tag {s} from source {x} with {s}", .{ existing_file.value_ptr.name, old_content.ref, name });
                        // remove existing tag
                        existing_file.value_ptr.remove();
                        // overwrite tag and content
                        const name_dupe = try self.allocator.dupe(u8, name);
                        const new_file = try dir.files.getOrPut(dir.allocator, name_dupe);
                        std.debug.assert(new_file.found_existing == false);
                        new_file.value_ptr.* = StoredTag{
                            .name = name_dupe,
                            .parent = dir,
                            .target = if (Stored == void) {} else old_content,
                        };
                    } else if (create) {
                        return Error.TagExists;
                    }
                    return .{
                        .is_new = false,
                        .content = .{ .Tag = existing_file.value_ptr },
                    };
                }
                // now _contains_folders is true and (in_dir.subpath.len == 0 or no targets found)
                return Error.TargetNotFound;
            } else {
                // target does not exist as file. Maybe it exists as directory
                if (create) {
                    if (create_as_dir) {
                        if (dir.dirs.getEntry(name)) |existing_dir| {
                            if (!overwrite) {
                                return Error.DirExists;
                            }

                            existing_dir.value_ptr.dirty();
                            return .{
                                .is_new = false,
                                .content = .{ .Dir = existing_dir.value_ptr },
                            };
                        } else {
                            // create NEW directory
                            log.debug("Making new tag dir {s}", .{name});
                            return .{
                                .is_new = true,
                                .content = .{ .Dir = try StoredDir.createIn(self.allocator, dir, name) },
                            };
                        }
                    }

                    log.debug("Making new tag file {s}", .{name});
                    const name_dupe = try self.allocator.dupe(u8, name);
                    const new_file = try dir.files.getOrPut(dir.allocator, name_dupe);
                    std.debug.assert(new_file.found_existing == false);
                    dir.touch();
                    new_file.value_ptr.* = StoredTag{
                        .name = name_dupe,
                        .parent = dir,
                        .target = if (Stored == void) {} else undefined,
                    };
                    // the caller should assign reverse pointer to the tag
                    return .{
                        .is_new = true,
                        .content = .{ .Tag = new_file.value_ptr },
                    };
                } else {
                    log.debug("Path {s} not found", .{name});
                    return Error.DirectoryNotFound;
                }
            }
        }
    };
}

pub const Error = std.fmt.ParseIntError || error{ NotUntagged, NotTagged, TagExists, DirExists, AlreadyTagged, DirectoryNotFound, TargetNotFound, InvalidPath };
pub const FileType = enum(usize) {
    Unknown = 0,
    File = 1,
    Directory = 2,
    SymbolicLink = 64,
};

fn StatMixin(comptime StatT: type) type {
    return struct {
        pub fn touch(mixin: *@This()) void {
            const self: *StatT = @alignCast(@fieldParentPtr("stat", mixin));
            self.accessed = std.time.milliTimestamp();
        }

        pub fn dirty(mixin: *@This()) void {
            const self: *StatT = @alignCast(@fieldParentPtr("stat", mixin));
            const time = std.time.milliTimestamp();
            if (self.created == 0) {
                self.created = time;
            }
            self.accessed = time;
            self.modified = time;
        }
    };
}

pub const Stat = struct {
    accessed: i64,
    created: i64,
    modified: i64,

    stat: StatMixin(@This()) = .{},

    pub fn now() @This() {
        const time = std.time.milliTimestamp();
        return @This(){ .accessed = time, .created = time, .modified = time };
    }
    pub fn toPayload(self: @This(), @"type": FileType, size: usize) !StatPayload {
        return StatPayload{
            .type = @intFromEnum(@"type"),
            .accessed = self.accessed,
            .created = self.created,
            .modified = self.modified,
            .size = size,
        };
    }

    pub fn newer(virtual: Stat, physical: anytype) Stat {
        return Stat{
            .accessed = @max(virtual.accessed, @divTrunc(physical.atime, 1000)),
            .created = @max(virtual.created, @divTrunc(physical.ctime, 1000)),
            .modified = @max(virtual.modified, @divTrunc(physical.mtime, 1000)),
        };
    }
};

pub const Permission = enum(u8) {
    ReadWrite = 0,
    ReadOnly = 1,
};

pub const StatPayload = struct {
    type: usize,
    accessed: i64,
    created: i64,
    modified: i64,
    size: usize,
    permission: Permission = .ReadWrite,

    stat: StatMixin(@This()) = .{},

    pub const empty_readonly = @This(){
        .type = @intFromEnum(FileType.Unknown),
        .accessed = 0,
        .created = 0,
        .modified = 0,
        .size = 0,
        .permission = .ReadOnly,
    };

    pub fn fromPhysical(physical: anytype, file_type: FileType) @This() {
        return StatPayload{
            .accessed = @intCast(@divTrunc(physical.atime, 1000)),
            .modified = @intCast(@divTrunc(physical.mtime, 1000)),
            .created = @intCast(@divTrunc(physical.ctime, 1000)),
            .permission = if ((physical.mode & 0o222) == 0) Permission.ReadOnly else Permission.ReadWrite,
            .type = @intFromEnum(file_type),
            .size = @intCast(physical.size),
        };
    }
};

pub fn Dir(comptime Taggable: type) type {
    return struct {
        const DirMap = std.StringHashMapUnmanaged(Dir(Taggable));
        const FileMap = std.StringHashMapUnmanaged(Tag(Taggable));
        allocator: std.mem.Allocator,
        dirs: DirMap = .empty,
        files: FileMap = .empty,
        /// owned by the Dir
        name: String,
        stat: Stat,
        /// `null` for `tagged_root`. Should be set otherwise.
        parent: ?*@This(),
        /// is owned by services/shaders module
        physical: ?String = null,

        fn createIn(allocator: std.mem.Allocator, parent: *@This(), name: String) !*@This() {
            const name_dupe = try allocator.dupe(u8, name);
            const result = try parent.dirs.getOrPut(parent.allocator, name_dupe);
            parent.stat.stat.touch();
            result.value_ptr.* = @This(){
                .allocator = allocator,
                .name = name_dupe,
                .parent = parent,
                .stat = Stat.now(),
            };
            return result.value_ptr;
        }

        fn deinit(self: *@This()) void {
            var it = self.dirs.valueIterator();
            while (it.next()) |dir| {
                dir.deinit();
            }
            self.dirs.deinit(self.allocator);

            var it_f = self.files.valueIterator();
            while (it_f.next()) |file| {
                file.deinit();
            }
            self.files.deinit(self.allocator);
            self.allocator.free(self.name);
        }

        pub fn listPhysical(self: *@This(), allocator: std.mem.Allocator, result: *std.ArrayListUnmanaged(CString), subpath: String, recursive: bool) !void {
            if (Taggable != void)
                self.stat.accessed = std.time.milliTimestamp();

            var already = std.StringHashMapUnmanaged(void){};
            defer already.deinit(allocator);

            if (self.physical) |path| {
                var physical_dir = try std.fs.openDirAbsolute(path, .{});
                defer physical_dir.close();
                const dir = try physical_dir.openDir(subpath, .{});
                var stack = try std.ArrayListUnmanaged(std.fs.Dir).initCapacity(allocator, 2);
                defer stack.deinit(allocator);
                var current_path = std.ArrayListUnmanaged(u8){};
                defer current_path.deinit(allocator);

                stack.appendAssumeCapacity(dir);
                while (stack.pop()) |current| {
                    defer @constCast(&current).close();
                    var current_it = current.iterate();
                    while (try current_it.next()) |dir_entry| {
                        const item_path: ?ZString = blk: {
                            switch (dir_entry.kind) {
                                .directory => {
                                    if (recursive)
                                        try stack.append(allocator, try current.openDir(dir_entry.name, .{}));
                                    break :blk try std.mem.concatWithSentinel(allocator, u8, &.{ current_path.items, "/", dir_entry.name, "/" }, 0);
                                },
                                .file, .sym_link, .named_pipe, .character_device, .block_device, .unknown => {
                                    break :blk try std.mem.concatWithSentinel(allocator, u8, &.{ current_path.items, "/", dir_entry.name }, 0);
                                },
                                else => break :blk null,
                            }
                        };
                        if (item_path) |p| {
                            const has = try already.getOrPut(allocator, p);
                            if (has.found_existing) {
                                continue;
                            }
                            try result.append(allocator, p.ptr);
                        }
                    }
                }
            }
        }

        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            if (self.parent) |parent| {
                try writer.print("{}/", .{parent});
            }
            try writer.writeAll(self.name);
        }

        pub fn rename(self: *@This(), new_name: String) !void {
            if (self.parent) |p| {
                const new_name_dupe = try p.allocator.dupe(u8, new_name);
                const old_name = self.name;
                const result = try p.dirs.getOrPut(p.allocator, new_name_dupe);
                result.value_ptr.* = self.*;
                self.allocator.free(self.name);
                result.value_ptr.name = new_name_dupe;
                // TODO: all refs freed?
                std.debug.assert(p.dirs.remove(old_name));
            } else {
                return error.InvalidPath; // root cannot be renamed (root is the only dir without parent)
            }
        }

        pub fn touch(self: *@This()) void {
            self.stat.stat.touch();
            if (self.parent) |p| p.touch();
        }

        pub fn dirty(self: *@This()) void {
            self.stat.stat.dirty();
            if (self.parent) |p| p.dirty();
        }
    };
}

pub fn Tag(comptime Taggable: type) type {
    return struct {
        /// Owned by the tag.
        /// Name cannot contain '/' and '>'.
        name: String,
        parent: *Dir(Taggable),
        target: if (Taggable == void) void else *Taggable,
        /// Reverse symlinks (other paths that point to this path).
        /// This is used to remove all references to a file when it is removed.
        ///
        /// Owned by the tag.
        backlinks: std.ArrayListUnmanaged(*Tag(Taggable)) = .{},

        /// Fired when an action is performed on the tag
        pub const Event = struct {
            action: Action,
            tag: *Tag(Taggable),
        };

        pub fn deinit(self: *@This()) void {
            const parent = self.parent;
            const name = self.name;
            self.backlinks.deinit(parent.allocator);
            std.debug.assert(parent.files.remove(name));
            parent.allocator.free(name);
        }

        pub fn fullPathAlloc(self: *@This(), allocator: std.mem.Allocator, comptime sentinel: bool) !if (sentinel) [:0]const u8 else String {
            if (Taggable != void)
                self.target.*.stat.accessed = std.time.milliTimestamp();
            var path_stack = std.ArrayListUnmanaged(u8){};
            var dir_stack = std.ArrayListUnmanaged(String){};
            defer dir_stack.deinit(allocator);
            var root: ?*Dir(Taggable) = self.parent;
            while (root != null) {
                try dir_stack.append(allocator, root.?.name);
                root = root.?.parent;
            }
            for (0..dir_stack.items.len) |i| {
                try path_stack.appendSlice(allocator, dir_stack.items[dir_stack.items.len - i - 1]);
                try path_stack.append(allocator, '/');
            }
            try path_stack.appendSlice(allocator, self.name);
            if (sentinel) {
                try path_stack.append(allocator, 0);
            }
            return if (sentinel) try path_stack.toOwnedSliceSentinel(allocator, 0) else try path_stack.toOwnedSlice(allocator);
        }

        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            if (Taggable != void)
                self.target.*.stat.accessed = std.time.milliTimestamp();

            try writer.print("{}/", .{self.parent});
            try writer.writeAll(self.name);
        }

        /// Remove a record from the tagged storage
        pub fn remove(self: *@This()) void {
            self.removeAllThatBacklinks();
            self.deinit();
        }

        pub fn fetchRemove(self: *@This()) *Taggable {
            self.removeAllThatBacklinks();
            self.backlinks.deinit(self.parent.allocator);
            if (self.parent.files.fetchRemove(self.name)) |removed| {
                return removed.value.target;
            } else unreachable;
        }

        fn removeAllThatBacklinks(self: *@This()) void {
            for (self.backlinks.items) |tag| {
                tag.remove();
            }
        }

        pub fn rename(self: *@This(), new_name: String) !void {
            const new_name_dupe = try self.parent.allocator.dupe(u8, new_name);
            const old_name = self.name;
            const result = try self.parent.files.getOrPut(self.parent.allocator, new_name_dupe);
            result.value_ptr.* = self.*;
            result.value_ptr.name = new_name_dupe;

            self.removeAllThatBacklinks(); // TODO: want to keep the backlinks?
            std.debug.assert(self.parent.files.remove(self.name));
            result.value_ptr.parent.allocator.free(old_name);
        }
    };
}

pub const untagged_path = "/untagged";
/// `T` must have a `Ref` declaration
pub fn Locator(comptime T: type) type {
    return struct {
        /// Locates the instrumented version of the file
        instrumented: bool = false,
        name: Name,

        const INSTRUMENTED_EXT = ".instrumented";

        pub const Name = union(enum) {
            /// If zero length, it means tagged root
            tagged: String,
            untagged: PartRef,

            pub const untagged_root = Name{ .untagged = PartRef.root };
            pub const tagged_root = Name{ .tagged = "" };

            pub fn isRoot(self: @This()) bool {
                switch (self) {
                    .tagged => |s| {
                        return s.len == 0 or s[0] == '/';
                    },
                    .untagged => |ref| {
                        return ref.isRoot();
                    },
                }
            }

            pub fn isUntaggedRoot(self: @This()) bool {
                switch (self) {
                    .untagged => |ref| {
                        return ref.isRoot();
                    },
                    else => {},
                }
                return false;
            }

            /// Returns `null` if the `Name` represents a (un)tagged root instead of a file
            pub fn file(name: @This()) ?@This() {
                return if (name.isRoot()) null else name;
            }

            /// `combined` is a path under /untagged
            pub fn parseUntagged(path: String) !Name {
                var combined = path;
                if (path.len > 0 and path[0] == '/') {
                    // remove leading slash
                    combined = path[1..];
                }
                if (combined.len == 0) {
                    return Name{ .untagged = PartRef.root };
                }
                return Name{ .untagged = try PartRef.parse(combined) };
            }

            pub fn parse(path: String) !Name {
                if (std.mem.startsWith(u8, path, untagged_path)) {
                    if (path.len == untagged_path.len or (path[untagged_path.len] == '/' and path.len == untagged_path.len + 1)) {
                        return Name{ .untagged = PartRef.root };
                    }
                    const last_dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
                    return try Name.parseUntagged(path[untagged_path.len + 1 .. last_dot]);
                } else {
                    return Name{ .tagged = path };
                }
            }

            pub fn toTagged(self: @This(), name: String) !@This() {
                return switch (self) {
                    .tagged => |_| Error.AlreadyTagged,
                    .untagged => |_| {
                        return @This(){
                            .tagged = name,
                        };
                    },
                };
            }

            pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                switch (self) {
                    .tagged => |s| {
                        try writer.writeAll(s);
                    },
                    .untagged => |ref| {
                        try writer.print(untagged_path[1..] ++ "/{}", .{ref});
                    },
                }
            }
        };

        pub const PartRef = struct {
            const SEPARATOR = '_';
            // TODO Vulkan uses 64bit handles even on 32bit platforms
            /// If zero, it means untagged root
            ref: T.Ref,
            part: usize,

            pub const root = @This(){ .ref = if (@hasDecl(T.Ref, "root")) .root else @enumFromInt(0), .part = 0 };
            pub fn isRoot(self: @This()) bool {
                return self.part == root.part and self.ref == root.ref;
            }
            pub fn parse(combined: String) Error!PartRef {
                var parts = std.mem.splitScalar(u8, combined, SEPARATOR);
                return PartRef{
                    .ref = @enumFromInt(std.fmt.parseUnsigned(usize, parts.next() orelse return Error.InvalidPath, 16) catch |e| return if (e == std.fmt.ParseIntError.InvalidCharacter) Error.InvalidPath else e),
                    .part = std.fmt.parseUnsigned(usize, parts.next() orelse return Error.InvalidPath, 16) catch |e| return if (e == std.fmt.ParseIntError.InvalidCharacter) Error.InvalidPath else e,
                };
            }

            pub fn format(value: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                return writer.print("{x}_{x}", .{ @intFromEnum(value.ref), value.part });
            }
        };

        pub fn Nesting(comptime U: type) type {
            return struct {
                /// (un)tagged program / tagged dir / (un)tagged nested under tagged program / (un) tagged program roots.
                name: Name,
                /// Sources nested under (un)tagged program (or their roots).
                nested: Locator(U),
                /// Full path, including both the name and optional nested resource.
                fullPath: String,

                pub const untagged_root = @This(){ .name = Name.untagged_root, .nested = Locator.untagged_root };
                pub const tagged_root = @This(){ .name = Name.tagged_root, .nested = Locator.tagged_root };

                pub fn parse(path: String) !@This() {
                    var without_instr = path;
                    var instr = false;
                    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), INSTRUMENTED_EXT)) {
                        without_instr = path[0 .. path.len - INSTRUMENTED_EXT.len];
                        instr = true;
                    }

                    if (std.mem.lastIndexOf(u8, without_instr, untagged_path)) |nested_untagged| {
                        if (nested_untagged != 0) {
                            // Nested untagged under (un)tagged
                            return @This(){
                                .fullPath = without_instr,
                                .name = try Name.parse(without_instr[0..nested_untagged]),
                                .nested = Locator(U){
                                    .instrumented = instr,
                                    .name = try Locator(U).Name.parseUntagged(without_instr[nested_untagged + untagged_path.len .. std.mem.lastIndexOfScalar(
                                        u8,
                                        without_instr,
                                        '.',
                                    ) orelse without_instr.len]),
                                },
                            };
                        }
                    }

                    const last_slash = if (std.mem.lastIndexOfScalar(u8, without_instr, '/')) |last_slash| blk: {
                        if (last_slash < without_instr.len - 1) { // Not the very last character
                            // Nested tagged under (un) tagged
                            return @This(){
                                .fullPath = without_instr,
                                .name = try Name.parse(without_instr[0..last_slash]),
                                .nested = Locator(U){
                                    .instrumented = instr,
                                    .name = try Locator(U).Name.parse(without_instr[last_slash + 1 ..]),
                                },
                            };
                        }
                        break :blk last_slash;
                    } else null;

                    return @This(){
                        .fullPath = without_instr,
                        .name = try Name.parse(without_instr[0 .. last_slash orelse without_instr.len]),
                        .nested = Locator(U){
                            .instrumented = instr,
                            .name = try Locator(U).Name.parse(without_instr[last_slash orelse (without_instr.len) ..]), // tagged nested (or root)
                        },
                    };
                }

                pub fn toTagged(self: @This(), allocator: std.mem.Allocator, name: String) !@This() {
                    return if (self.nested.isRoot())
                        @This(){
                            .name = try self.name.toTagged(name),
                            .nested = Locator(U).tagged_root,
                            .fullPath = name,
                        }
                    else
                        @This(){
                            .name = self.name,
                            .nested = try self.nested.toTagged(name),
                            .fullPath = try std.fmt.allocPrint(allocator, "{}", .{self}),
                        };
                }

                pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                    try writer.print("{}/{}", .{ self.name, self.nested });
                }

                pub fn isUntagged(self: @This()) bool {
                    return self.name == .untagged;
                }
            };
        }

        pub const untagged_root = Locator(T){ .name = Name.untagged_root };
        pub const tagged_root = Locator(T){ .name = Name.tagged_root };

        pub fn parse(subpath: String) !Locator(T) {
            var without_instr = subpath;
            var instr = false;
            if (std.ascii.eqlIgnoreCase(std.fs.path.extension(subpath), INSTRUMENTED_EXT)) {
                without_instr = subpath[0 .. subpath.len - INSTRUMENTED_EXT.len];
                instr = true;
            }

            return Locator(T){
                .instrumented = instr,
                .name = try Name.parse(without_instr),
            };
        }

        /// Returns `null` if the `Locator` represents (un)tagged root instead of a file resource
        pub fn file(locator: @This()) ?@This() {
            return if (locator.name.isRoot()) null else locator;
        }

        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("{}", .{self.name});
            if (self.instrumented) {
                try writer.writeAll(INSTRUMENTED_EXT);
            }
        }

        pub fn isUntaggedRoot(locator: @This()) bool {
            return locator.name.isUntaggedRoot();
        }

        pub fn isRoot(locator: @This()) bool {
            return locator.name.isRoot();
        }

        pub fn isUntagged(locator: @This()) bool {
            return locator.name == .untagged;
        }

        pub fn toTagged(self: @This(), name: String) !@This() {
            return @This(){
                .instrumented = self.instrumented,
                .name = try self.name.toTagged(name),
            };
        }
    };
}
pub const Action = enum {
    /// After the tag is assigned to a file
    Assign,
    /// Before the tag is removed
    Remove,
};
