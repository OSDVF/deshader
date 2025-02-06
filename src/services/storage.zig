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
const decls = @import("../declarations/shaders.zig");

const shaders = @import("shaders.zig");
const common = @import("common");
const log = common.log;

const String = []const u8;
const CString = [*:0]const u8;

const Shader = shaders.Shader;
const root_name: String = "";

/// # Deshader virtual storage
/// All detected shaders are stored here with their tags or refs.
/// This isn't an ordinary filesystem structure because a shader can have more tags.
/// Also tags can point to shaders which already have a different tag, so there is both M:N relationship between [Tag]-[Tag] and between [Tag]-[Stored].
/// This can lead to orphans, cycles or many other difficulties but this is not a real filesystem so we ignore the downsides for now.
///
/// `Stored` type must be void or have these fields:
/// ```
///     tags: StringArrayHashMapUnmanaged(*Tag(Stored)) // will use this storage's allocator
///     stat: Stat
/// ```
/// `Nested` type is optional (can be void) and it is used for storing directories as the Stored objects (like in the case of programs)
/// Both the types must have property
/// ```
///    ref: usize
/// ```
pub fn Storage(comptime Stored: type, comptime Nested: type, comptime parted: bool) type {
    return struct {
        pub const Self = @This();
        pub const StoredDir = Dir(Stored);
        pub const StoredTag = Tag(Stored);
        // The capacity is 8 by default so it is no such a big deal to treat it as a hash-list hybrid
        /// Stores a list of untagged shader parts
        pub const StoredOrList = if (parted) std.ArrayListUnmanaged(Stored) else Stored;
        pub const StoredPtrOrArray = if (parted) []Stored else *Stored;
        pub const RefMap = std.AutoHashMapUnmanaged(usize, *StoredOrList);
        pub const isParted = parted;
        /// programs / source parts mapped by tag
        tagged_root: StoredDir,
        /// programs / source parts list corresponding to the same shader. Mapped by ref
        all: RefMap = .{},
        allocator: std.mem.Allocator,
        pool: if (Stored == void) void else std.heap.MemoryPool(StoredOrList), // for storing all the Stored objects

        pub fn init(alloc: std.mem.Allocator) @This() {
            return @This(){
                .allocator = alloc,
                .tagged_root = StoredDir{
                    .allocator = alloc,
                    .name = root_name,
                    .parent = null,
                    .stat = Stat.now(),
                },
                .pool = if (Stored == void) {} else std.heap.MemoryPool(StoredOrList).init(alloc),
            };
        }

        const parted_only = struct {
            const AppendUntaggedResult = struct { stored: *Stored, index: usize };

            /// Append to an existing parted []Stored with same ref or create a new Stored (parts list) with that ref
            pub fn appendUntagged(self: *Self, ref: usize) !AppendUntaggedResult {
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

        const nested_only = struct {
            pub fn getNestedByLocator(self: *Self, locator: Locator.Name, nested: Locator.Name) (std.mem.Allocator.Error || Error)!*Nested {
                switch ((try self.getByLocator(locator, nested)).content) {
                    .Nested => |n| return n.nested,
                    else => return Error.DirExists,
                }
            }

            pub fn getByLocator(self: *Self, locator: Locator.Name, nested: ?Locator.Name) (std.mem.Allocator.Error || Error)!DirOrStored {
                if (Stored == void) {
                    @compileError("This storage stores void");
                }
                const ptr = blk: {
                    switch (locator) {
                        .untagged => |combined| {
                            const var_or_list = self.all.get(combined.ref) orelse return Error.TargetNotFound;
                            const untagged = if (parted) &var_or_list.items[combined.part] else var_or_list;
                            if (nested) |n| {
                                break :blk try untagged.getNested(n);
                            } else {
                                return Error.InvalidPath;
                            }
                        },
                        .tagged => |tagged| {
                            break :blk try self.makePathRecursive(tagged, false, false, false);
                        },
                    }
                };
                return ptr;
            }
        };

        pub usingnamespace if (parted) parted_only else struct {};
        pub usingnamespace if (Nested != void) nested_only else struct {};

        fn getInnerType(comptime t: type) type {
            var result = t;
            while (@as(?std.builtin.Type.Pointer, switch (@typeInfo(result)) {
                .Pointer => |ptr| ptr,
                else => null,
            })) |ptr| {
                result = ptr.child;
            }
            return result;
        }

        pub fn deinit(self: *@This(), args: anytype) void {
            self.tagged_root.deinit();
            {
                var it = self.all.valueIterator();
                while (it.next()) |val_or_list| {
                    if (parted) {
                        for (val_or_list.*.items) |*val| {
                            const deinit_fn = getInnerType(Stored).deinit;
                            const args_with_this = .{val} ++ args;
                            if (@typeInfo(@TypeOf(deinit_fn)).Fn.return_type == void) {
                                @call(.auto, deinit_fn, args_with_this);
                            } else {
                                @call(.auto, deinit_fn, args_with_this) catch {};
                            }
                        }
                        val_or_list.*.deinit(self.allocator);
                    } else {
                        const deinit_fn = getInnerType(Stored).deinit;
                        const args_with_this = .{val_or_list.*} ++ args;
                        if (@typeInfo(@TypeOf(deinit_fn)).Fn.return_type == void) {
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

        fn fileSetToSpan(set: *std.StringArrayHashMapUnmanaged(void), allocator: std.mem.Allocator) ![]CString {
            const result = try allocator.alloc(CString, set.count());
            for (set.keys(), 0..) |key, i| {
                result[i] = try allocator.dupeZ(u8, key);
                //self.allocator.free(key);
            }
            set.deinit(allocator);
            return result;
        }

        /// Lists existing tags and directories
        /// the returned paths are relative to `path`
        pub fn listTagged(self: *const @This(), allocator: std.mem.Allocator, path: String, recursive: bool, physical: bool, postfix: ?String) ![]CString {
            log.debug("Listing path {?s} recursive:{?}", .{ path, recursive });

            var result = std.StringArrayHashMapUnmanaged(void){};

            // print tagged
            var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            var fix_allocator = std.heap.FixedBufferAllocator.init(&buffer);
            // growing and shrinking path prefix for current directory
            var current_path = std.ArrayList(u8).init(fix_allocator.allocator());
            defer current_path.deinit();

            const DirStackItem = struct {
                dir: *StoredDir,
                prev_len: usize, // parent directory path length
            };
            var stack = std.ArrayListUnmanaged(DirStackItem){};
            defer stack.deinit(allocator);

            // when no overwrite and create flags are set, we can safely assume that `self` won't be modified
            const root = try @constCast(self).makePathRecursive(path, false, false, true);
            //DFS print of directory tree
            try stack.append(allocator, .{ .dir = root.content.Dir, .prev_len = 0 });
            while (stack.popOrNull()) |current_dir| {
                if (current_dir.dir.name.len > 0) {
                    current_path.shrinkRetainingCapacity(current_dir.prev_len);
                }

                if (stack.items.len > 1) {
                    try current_path.appendSlice(current_dir.dir.name); // add current directory, but not the requested root
                }
                try current_path.append('/');

                var subdirs = current_dir.dir.dirs.iterator();
                while (subdirs.next()) |subdir| {
                    if (recursive) {
                        try stack.append(allocator, .{ .dir = subdir.value_ptr, .prev_len = current_path.items.len });
                    } else {
                        // just print the directory
                        _ = try result.getOrPut(allocator, try std.fmt.allocPrint(allocator, "{s}{s}/{s}", .{ current_path.items, subdir.key_ptr.*, postfix orelse "" }));
                    }
                }
                var files = current_dir.dir.files.iterator();
                while (files.next()) |file| {
                    if (Nested == void) { // Normal non-nested storage
                        var this_result = std.ArrayListUnmanaged(u8){};
                        try this_result.appendSlice(allocator, current_path.items);
                        try this_result.appendSlice(allocator, file.value_ptr.name);
                        if (postfix) |p| {
                            try this_result.appendSlice(allocator, p);
                        }
                        _ = try result.getOrPut(allocator, @ptrCast(try this_result.toOwnedSlice(allocator)));
                    } else {
                        const program_links: ?*Shader.Program = file.value_ptr.target; // programs should be always only one in a file (no symlinks)
                        if (program_links) |program| {
                            if (program.stages.count() == 0) {
                                continue;
                            }
                            var shader_iter = program.listFiles();
                            while (shader_iter.next()) |part| {
                                if (part.source.tag) |_| {
                                    _ = try result.getOrPut(allocator, try std.fmt.allocPrint(allocator, "{s}{s}/{name}{s}", .{ current_path.items, file.value_ptr.name, part, postfix orelse "" }));
                                } else {
                                    _ = try result.getOrPut(allocator, try std.fmt.allocPrint(allocator, "{s}{s}" ++ untagged_path ++ "/{name}{s}", .{ current_path.items, file.value_ptr.name, part, postfix orelse "" }));
                                }
                            }
                        }
                    }
                }
                if (physical) {
                    try current_dir.dir.listPhysical(allocator, &result, current_path.items, recursive);
                }
            }

            return try fileSetToSpan(&result, allocator);
        }

        /// If `ref_or_root == 0` this function lists all untagged objects.
        /// Otherwise it lists nested objects under this untagged resource.
        pub fn listUntagged(self: *const @This(), allocator: std.mem.Allocator, ref_or_root: usize, nested_postfix: ?String) ![]CString {
            var result = try std.ArrayListUnmanaged(CString).initCapacity(allocator, self.all.count());
            if (ref_or_root == 0) {
                var iter = self.all.iterator();
                while (iter.next()) |items| {
                    if (parted) {
                        for (items.value_ptr.*.items, 0..) |*item, index| {
                            if (item.tag != null) { // skip tagged ones
                                continue;
                            }
                            try result.append(allocator, try if (Nested == void) // Directories have trailing slash
                                std.fmt.allocPrintZ(allocator, "{}{s}", .{ Locator.PartRef{ .ref = item.ref, .part = index }, item.toExtension() })
                            else
                                std.fmt.allocPrintZ(allocator, "{}/", .{Locator.PartRef{ .ref = item.ref, .part = index }}));
                        }
                    } else {
                        const item = items.value_ptr.*;
                        if (item.tag != null) { // skip tagged ones
                            continue;
                        }
                        try result.append(allocator, try if (Nested == void) // Directories have trailing slash
                            std.fmt.allocPrintZ(allocator, "{}{s}", .{ Locator.PartRef{ .ref = item.ref, .part = 0 }, item.toExtension() })
                        else
                            std.fmt.allocPrintZ(allocator, "{}/", .{Locator.PartRef{ .ref = item.ref, .part = 0 }}));
                    }
                }
            } else {
                const item = self.all.get(ref_or_root) orelse return Error.TargetNotFound;
                if (Nested != void) { //Specialization
                    if (!parted or item.len > 0) {
                        var iter2: shaders.Shader.Program.ShaderIterator = (if (parted) item.items[0] else item).listFiles();
                        while (iter2.next()) |shader| {
                            // Nested files should be always symlinks
                            if (shader.source.tag) |_| {
                                try result.append(allocator, try std.fmt.allocPrintZ(allocator, "{name}{s}", .{ shader, nested_postfix orelse "" }));
                            } else {
                                try result.append(allocator, try std.fmt.allocPrintZ(allocator, untagged_path[1..] ++ "/{name}{s}", .{ shader, nested_postfix orelse "" }));
                            }
                        }
                    }
                } else {
                    for (item.items, 0..) |part, i| try result.append(allocator, try std.fmt.allocPrintZ(allocator, "{}{s}{s}", .{ Locator.PartRef{ .ref = ref_or_root, .part = i }, part.toExtension(), nested_postfix orelse "" }));
                }
            }
            return result.toOwnedSlice(allocator);
        }

        pub fn renameByLocator(self: *Self, locator: Locator.Name, to: String) !DirOrStored.Content {
            return switch (locator) {
                .tagged => |path| try self.renamePath(path, to),
                .untagged => |ref| .{ .Tag = try self.assignTag(ref.ref, ref.part, to, .Error) },
            };
        }

        /// Rename a directory or a tagged file
        pub fn renamePath(self: *Self, from: String, to: String) !DirOrStored.Content {
            const existing = try self.makePathRecursive(from, false, false, false);
            std.debug.assert(existing.is_new == false);
            const target_dirname = std.fs.path.dirnamePosix(to);
            const target_basename = std.fs.path.basenamePosix(to);
            const rename_only_base = common.nullishEq(std.fs.path.dirnamePosix(from), target_dirname);
            if (Nested != void and existing.content == .Nested) { // renaming a shader under program can be done only on basename basis
                if (rename_only_base) {
                    try existing.content.Nested.nested.tag.?.rename(target_basename);
                    return existing.content;
                } else {
                    return Error.InvalidPath;
                }
            } else switch (existing.content) {
                .Tag => |tag| if (rename_only_base) {
                    try tag.rename(target_basename);
                    return .{ .Tag = tag };
                } else {
                    const f = tag.fetchRemove();
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
                        const new = try target_parent.content.Dir.dirs.getOrPut(self.allocator, target_basename);
                        new.value_ptr.* = old.value;
                        new.value_ptr.name = try self.allocator.dupe(u8, target_basename);
                        return .{ .Dir = new.value_ptr };
                    }
                },
            }
        }

        /// the content has to exist in the untagged storage
        pub fn assignTag(self: *@This(), ref: usize, index: usize, path: String, if_exists: decls.ExistsBehavior) (Error || std.mem.Allocator.Error)!*StoredTag {
            // check for all
            if (self.all.get(ref)) |ptr| {
                return self.assignTagTo(if (parted) &ptr.items[index] else ptr, path, if_exists);
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
                if (stored.tag == null or if_exists == .Overwrite) {
                    stored.tag = target.content.Tag;
                } else if (if_exists == .Link) {
                    try target.content.Tag.backlinks.append(self.allocator, target.content.Tag);
                } else unreachable; // error should be already thrown at self.makePathRecursive
                target.content.Tag.target = stored;
            }
            return target.content.Tag;
        }

        pub fn mkdir(self: *@This(), path: String) !*Dir(Stored) {
            return (try self.makePathRecursive(path, true, false, true)).content.Dir;
        }

        pub const createUntagged = if (parted) struct {
            fn c(self: *Self, ref: usize, count: usize) ![]Stored {
                return try self.createUntaggedImpl(ref, count);
            }
        }.c else struct {
            fn c(self: *Self, ref: usize) !*Stored {
                return try self.createUntaggedImpl(ref, 1);
            }
        }.c;

        fn createUntaggedImpl(self: *@This(), ref: usize, count: usize) !StoredPtrOrArray {
            if (Stored == void) {
                @compileError("This storage stores void");
            }
            const maybe_ptr = try self.all.getOrPut(self.allocator, ref);
            if (!maybe_ptr.found_existing) {
                const new = try self.pool.create();
                if (parted) {
                    new.* = std.ArrayListUnmanaged(Stored){};
                }
                maybe_ptr.value_ptr.* = new;
            }
            if (parted) {
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
                ptr.content.Nested.nested.tag.?.remove();
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
                    content_tag.Tag.remove();
                },
            }
        }

        /// Remove a `Stored` from both tagged and untagged storage.
        /// Use `untag` to remove only a record in the tagged storage.
        pub fn remove(self: *@This(), ref: usize) !void {
            // remove the content
            const removed_maybe = self.all.fetchRemove(ref);
            if (removed_maybe) |removed| {
                if (parted) {
                    for (removed.value.items) |item| {
                        // Remove all which pointed to this file
                        if (item.tag) |t| for (t.backlinks.items) |tag| {
                            tag.remove();
                        };
                    }
                } else {
                    if (removed.value.tag) |t| for (t.backlinks.items) |tag| {
                        tag.remove();
                    };
                }
            } else {
                return Error.TargetNotFound;
            }
        }

        /// Remove only from tagged, kepp in untagged
        pub fn untagIndex(self: *@This(), ref: usize, index: usize) !void {
            const contents_maybe = self.all.get(ref);
            if (contents_maybe) |contents| {
                if (if (parted) contents.items[index].tag else contents.tag) |tag| {
                    tag.remove();
                } else {
                    return Error.NotTagged;
                }
            } else {
                return Error.TargetNotFound;
            }
        }

        /// Remove only from tagged, kepp in untagged
        pub fn untagAll(self: *@This(), ref: usize) !void {
            const contents_maybe = self.all.get(ref);
            if (contents_maybe) |contents| {
                for (contents.items) |item| {
                    if (item.tag) |t| {
                        for (t.backlinks.items) |tag| {
                            tag.remove();
                        }
                    } else {
                        return Error.NotTagged;
                    }
                }
            } else {
                return Error.TargetNotFound;
            }
        }

        /// NOTE: incosistency: if you want to stat a shader under a program, use 'tagged' locator with the untagged source 'path'
        pub fn stat(self: *@This(), locator: Locator.Name) !StatPayload {
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
                        return if (ptr.content.Nested) |n| StatPayload{
                            .type = @intFromEnum(FileType.File),
                            .accessed = n.stat.accessed,
                            .created = n.stat.created,
                            .modified = n.stat.modified,
                            .size = if (ptr.content.Nested.nested.getSource()) |s| s.len else 0,
                        } else {
                            const now = Stat.now();
                            return StatPayload{
                                .type = @intFromEnum(FileType.File),
                                .accessed = now.accessed,
                                .created = now.created,
                                .modified = now.modified,
                                .size = if (ptr.content.Nested.nested.getSource()) |s| s.len else 0,
                            };
                        };
                    }
                },
            }
        }

        pub const DirOrStored = struct {
            pub const Content = if (Nested != void) union(enum) {
                Tag: *Tag(Stored),
                Nested: struct {
                    parent: *const Stored,
                    nested: *Nested,
                    part: usize,
                },
                Dir: *Dir(Stored),
            } else union(enum) {
                Tag: *Tag(Stored),
                Dir: *Dir(Stored),
            };
            is_new: bool,
            content: Content,
        };

        pub fn getStoredByLocator(self: *@This(), locator: Locator.Name) !*Stored {
            return switch (locator) {
                .tagged => |path| try self.getStoredByPath(path),
                .untagged => |combined| if (parted) if (self.all.get(combined.ref)) |s| &s.items[combined.part] else Error.TargetNotFound else if (self.all.getPtr(combined.ref)) |s| s else Error.TargetNotFound,
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

        /// Tag's target will be undefined if new
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
                dir.stat.access();
                if (Nested != void and in_dir.subpath.len > 0) {
                    existing_file.value_ptr.target.stat.access();
                    return existing_file.value_ptr.target.getNested((try Locator.parse(in_dir.subpath) orelse return Error.InvalidPath).name);
                }
                if (Nested == void or in_dir.subpath.len == 0) {
                    if (overwrite) {
                        if (create_as_dir) {
                            return Error.TagExists;
                        }
                        dir.stat.touch();

                        // Remove old / overwrite
                        const old_content = existing_file.value_ptr.target;
                        old_content.stat.touch();
                        log.debug("Overwriting tag {s} from source {x} with {s}", .{ existing_file.value_ptr.name, old_content.ref, name });
                        // remove existing tag
                        existing_file.value_ptr.remove();
                        // overwrite tag and content
                        const new_file = try dir.files.getOrPut(dir.allocator, name);
                        std.debug.assert(new_file.found_existing == false);
                        new_file.value_ptr.* = StoredTag{
                            .name = try self.allocator.dupe(u8, name),
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

                            existing_dir.value_ptr.stat.access();
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
                    const new_file = try dir.files.getOrPut(dir.allocator, name);
                    std.debug.assert(new_file.found_existing == false);
                    dir.stat.touch();
                    new_file.value_ptr.* = StoredTag{
                        .name = try self.allocator.dupe(u8, name),
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
pub const Stat = struct {
    accessed: i64,
    created: i64,
    modified: i64,
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

    pub fn access(self: *@This()) void {
        self.accessed = std.time.milliTimestamp();
    }

    pub fn touch(self: *@This()) void {
        const time = std.time.milliTimestamp();
        self.accessed = time;
        self.modified = time;
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
        dirs: DirMap = .{},
        files: FileMap = .{},
        /// owned by the Dir
        name: String,
        stat: Stat,
        /// `null` for `tagged_root`. Should be set otherwise.
        parent: ?*@This(),
        /// is owned by services/shaders module
        physical: ?String = null,

        fn createIn(allocator: std.mem.Allocator, parent: *@This(), name: String) !*@This() {
            const result = try parent.dirs.getOrPut(parent.allocator, name);
            parent.stat.touch();
            result.value_ptr.* = @This(){
                .allocator = allocator,
                .name = try allocator.dupe(u8, name),
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

        pub fn listPhysical(self: *@This(), allocator: std.mem.Allocator, result: *std.StringArrayHashMapUnmanaged(void), subpath: String, recursive: bool) !void {
            if (Taggable != void)
                self.stat.accessed = std.time.milliTimestamp();

            if (self.physical) |path| {
                var physical_dir = try std.fs.openDirAbsolute(path, .{});
                defer physical_dir.close();
                const dir = try physical_dir.openDir(subpath, .{});
                var stack = try std.ArrayListUnmanaged(std.fs.Dir).initCapacity(allocator, 2);
                defer stack.deinit(allocator);
                var current_path = std.ArrayListUnmanaged(u8){};
                defer current_path.deinit(allocator);

                stack.appendAssumeCapacity(dir);
                while (stack.items.len != 0) {
                    var current = stack.pop();
                    defer current.close();
                    var current_it = current.iterate();
                    while (try current_it.next()) |dir_entry| {
                        const item_path: ?String = blk: {
                            switch (dir_entry.kind) {
                                .directory => {
                                    if (recursive)
                                        try stack.append(allocator, try current.openDir(dir_entry.name, .{}));
                                    break :blk try std.mem.concat(allocator, u8, &.{ current_path.items, "/", dir_entry.name, "/" });
                                },
                                .file, .sym_link, .named_pipe, .character_device, .block_device, .unknown => {
                                    break :blk try std.mem.concat(allocator, u8, &.{ current_path.items, "/", dir_entry.name });
                                },
                                else => break :blk null,
                            }
                        };
                        if (item_path) |p| {
                            _ = try result.getOrPut(allocator, p); // effectivelly means 'put' for set-like hashmaps
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
                const old_name = self.name;
                const result = try p.dirs.getOrPut(p.allocator, new_name);
                result.value_ptr.* = self.*;
                self.allocator.free(self.name);
                result.value_ptr.name = try p.allocator.dupe(u8, new_name);
                // TODO: all refs freed?
                std.debug.assert(p.dirs.remove(old_name));
            } else {
                return error.InvalidPath; // root cannot be renamed (root is the only dir without parent)
            }
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

        pub fn deinit(self: *@This()) void {
            self.removeAllThatBacklinks();
            self.backlinks.deinit(self.parent.allocator);
            self.parent.allocator.free(self.name);
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
            std.debug.assert(self.parent.files.remove(self.name));
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
            const old_name = self.name;
            const result = try self.parent.files.getOrPut(self.parent.allocator, new_name);
            result.value_ptr.* = self.*; // TODO: may memory corruption
            self.parent.allocator.free(self.name);
            result.value_ptr.name = try self.parent.allocator.dupe(u8, new_name);

            self.removeAllThatBacklinks(); // TODO: want to keep the backlinks?
            std.debug.assert(self.parent.files.remove(old_name));
        }
    };
}

pub const untagged_path = "/untagged";
pub const Locator = struct {
    /// Return the instrumented version of the file
    instrumented: bool = false,
    name: Name,

    const INSTRUMENTED_EXT = ".instrumented";

    pub const Name = union(enum) {
        tagged: String,
        untagged: PartRef,

        /// `combined` is a path under /untagged
        pub fn parseUntagged(combined: String) !Name {
            return Name{ .untagged = try PartRef.parse(combined) };
        }
    };

    pub const PartRef = struct {
        const SEPARATOR = '_';
        // TODO Vulkan uses 64bit handles even on 32bit platforms
        ref: usize,
        part: usize,

        pub fn isRoot(self: @This()) bool {
            return self.part == 0 and self.ref == 0;
        }
        pub fn parse(combined: String) Error!PartRef {
            var parts = std.mem.splitScalar(u8, combined, SEPARATOR);
            return PartRef{
                .ref = try std.fmt.parseUnsigned(usize, parts.next() orelse return Error.InvalidPath, 16),
                .part = try std.fmt.parseUnsigned(usize, parts.next() orelse return Error.InvalidPath, 16),
            };
        }

        pub fn format(value: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            return writer.print("{x}_{x}", .{ value.ref, value.part });
        }
    };

    /// returns null for untagged root
    pub fn parse(subpath: String) !?Locator {
        var without_instr = subpath;
        var instr = false;
        if (std.ascii.eqlIgnoreCase(std.fs.path.extension(subpath), INSTRUMENTED_EXT)) {
            without_instr = subpath[0 .. subpath.len - INSTRUMENTED_EXT.len];
            instr = true;
        }

        const n = name: {
            if (std.mem.startsWith(u8, without_instr, untagged_path)) {
                if (without_instr.len == untagged_path.len or (without_instr[untagged_path.len] == '/' and without_instr.len == untagged_path.len + 1)) {
                    return null; //root
                }
                const last_dot = std.mem.lastIndexOfScalar(u8, without_instr, '.') orelse without_instr.len;
                break :name try Name.parseUntagged(subpath[untagged_path.len + 1 .. last_dot]);
            } else {
                break :name Name{ .tagged = subpath };
            }
        };
        return Locator{ .instrumented = instr, .name = n };
    }
};
