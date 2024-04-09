const std = @import("std");
const decls = @import("../declarations/shaders.zig");

const log = @import("../log.zig").DeshaderLog;
const shaders = @import("shaders.zig");
const common = @import("../common.zig");

const String = []const u8;
const CString = [*:0]const u8;

const Shader = shaders.Shader;

/// # Deshader virtual storage
/// All detected shaders are stored here with their tags or refs.
/// This isn't an ordinary filesystem structure because a shader can have more tags.
/// Also tags can point to shaders which already have a different tag, so there is both M:N relationship between [Tag]-[Tag] and between [Tag]-[Stored].
/// This can lead to orphans, cycles or many other difficulties but this is not a real filesystem so we ignore the downsides for now.
///
/// `Stored` type must have fields
/// ```
///     tags: StringArrayHashMapUnmanaged(*Tag(Stored)) // will use this storage's allocator
///     stat: Stat
/// ```
/// `Nested` type is optional (can be void) and it is used for storing directories as the Stored objects (like in the case of programs)
/// Both the types must have property
/// ```
///    ref: usize
/// ```
pub fn Storage(comptime Stored: type, comptime Nested: type) type {
    return struct {
        pub const StoredDir = Dir(Stored);
        pub const StoredTag = Tag(Stored);
        // The capacity is 8 by default so it is no such a big deal to treat it as a hash-list hybrid
        /// Stores a list of untagged shader parts
        pub const RefMap = std.AutoHashMap(usize, std.ArrayList(Stored));
        /// programs / source parts mapped by tag
        tagged_root: StoredDir,
        /// programs / source parts list corresponding to the same shader. Mapped by ref
        all: RefMap,
        allocator: std.mem.Allocator,

        fn Const(comptime t: type) type {
            const info = @typeInfo(t);
            switch (info) {
                .Pointer => |p| return @Type(std.builtin.Type{ .Pointer = .{
                    .child = p.child,
                    .is_const = true,
                    .address_space = p.address_space,
                    .alignment = p.alignment,
                    .is_allowzero = p.is_allowzero,
                    .is_volatile = p.is_volatile,
                    .sentinel = p.sentinel,
                    .size = p.size,
                } }),
                else => return t,
            }
        }

        pub const TaggableMixin = struct {
            pub fn hasTag(self: Const(Stored)) bool {
                return self.tags.count() > 0;
            }
            pub fn firstTag(self: Const(Stored)) ?*Tag(Stored) {
                return if (self.hasTag()) self.tags.values()[0] else null;
            }
        };

        pub fn init(alloc: std.mem.Allocator) !@This() {
            return @This(){
                .allocator = alloc,
                .tagged_root = try StoredDir.init(alloc, null, ""),
                .all = RefMap.init(alloc),
            };
        }

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
                while (it.next()) |val_array| {
                    for (val_array.items) |*val| {
                        const deinit_fn = getInnerType(Stored).deinit;
                        const args_with_this = .{if (@typeInfo(Stored) == .Pointer) val.* else val} ++ args;
                        if (@typeInfo(@TypeOf(deinit_fn)).Fn.return_type == void) {
                            @call(.auto, deinit_fn, args_with_this);
                        } else {
                            @call(.auto, deinit_fn, args_with_this) catch {};
                        }
                    }
                    val_array.deinit();
                }
                self.all.deinit();
            }
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

        /// Lists existing tags or untagged files
        /// the returned paths are relative to `path`
        /// path = "/" => lists all tagged files
        /// path = null => do not include tagged files
        pub fn listTagged(self: *const @This(), allocator: std.mem.Allocator, path: ?String, recursive: bool, physical: bool) ![]CString {
            log.debug("Listing tagged {?s} recursive:{?}", .{ path, recursive });

            var result = std.StringArrayHashMapUnmanaged(void){};

            if (path) |sure_path| {
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
                const root = try @constCast(self).makePathRecursive(sure_path, false, false, true);
                //DFS print of directory tree
                try stack.append(allocator, .{ .dir = root.content.Dir, .prev_len = 0 });
                while (stack.popOrNull()) |current_dir| {
                    if (current_dir.dir.name.len > 0) {
                        current_path.shrinkRetainingCapacity(current_dir.prev_len);
                    }

                    log.debug("Expanding directory {s}", .{current_dir.dir.name});
                    if (stack.items.len > 1) {
                        try current_path.appendSlice(current_dir.dir.name); // add current directory, but not the requested root
                    }
                    try current_path.append('/');

                    var subdirs = current_dir.dir.dirs.iterator();
                    while (subdirs.next()) |subdir| {
                        log.debug("Pushing directory {s}", .{subdir.key_ptr.*});
                        if (recursive) {
                            try stack.append(allocator, .{ .dir = subdir.value_ptr, .prev_len = current_path.items.len });
                        } else {
                            // just print the directory
                            _ = try result.getOrPut(allocator, try std.fmt.allocPrint(allocator, "{s}{s}/", .{ current_path.items, subdir.key_ptr.* }));
                        }
                    }
                    var files = current_dir.dir.files.iterator();
                    while (files.next()) |file| {
                        if (Nested == void) { // Normal non-nested storage
                            var this_result = std.ArrayListUnmanaged(u8){};
                            try this_result.appendSlice(allocator, current_path.items);
                            try this_result.appendSlice(allocator, file.value_ptr.name);
                            log.debug("Tagged file {s}", .{this_result.items});
                            _ = try result.getOrPut(allocator, @ptrCast(try this_result.toOwnedSlice(allocator)));
                        } else {
                            const program_links: ?*Shader.Program = file.value_ptr.target; // programs should be always only one in a file (no symlinks)
                            if (program_links) |program| {
                                if (program.stages == null) {
                                    continue;
                                }
                                var shader_iter = program.listFiles();
                                if (shader_iter != null) {
                                    while (try shader_iter.?.nextAlloc(allocator)) |shaders_s| {
                                        defer allocator.free(shaders_s.name);
                                        _ = try result.getOrPut(allocator, try std.mem.concat(allocator, u8, &.{ current_path.items, file.value_ptr.name, "/", shaders_s.name }));
                                    }
                                }
                            }
                        }
                    }
                    if (physical) {
                        try current_dir.dir.listPhysical(allocator, &result, current_path.items, recursive);
                    }
                }
            }

            return try fileSetToSpan(&result, allocator);
        }

        /// if `refOrRoot` == O this function lists all untagged objects.
        /// else it lists nested objects under this untagged resource
        pub fn listUntagged(self: *const @This(), allocator: std.mem.Allocator, refOrRoot: usize) ![]CString {
            var result = try std.ArrayListUnmanaged(CString).initCapacity(allocator, self.all.count());
            if (refOrRoot == 0) {
                var iter = self.all.iterator();
                while (iter.next()) |items| {
                    for (items.value_ptr.items, 0..) |item, index| {
                        if (item.tags.count() > 0) { // skip tagged ones
                            continue;
                        }
                        try result.append(allocator, try std.fmt.allocPrintZ(allocator, if (Nested == void) "{x}" else "{x}/", .{combinedRef(item.ref, index)}));
                    }
                }
            } else {
                const item = self.all.get(refOrRoot) orelse return error.TargetNotFound;
                if (Nested != void) { //Specialization
                    if (item.items.len > 0) {
                        var iter2 = item.items[0].listFiles();
                        if (iter2) |*sure_iter| {
                            while (try sure_iter.nextAlloc(allocator)) |shader| {
                                defer allocator.free(shader.name);
                                try result.append(allocator, try allocator.dupeZ(u8, shader.name));
                            }
                        }
                    }
                } else {
                    for (item.items, 0..) |part, i| try result.append(allocator, try std.fmt.allocPrintZ(allocator, "{x}{s}", .{ combinedRef(refOrRoot, i), part.toExtension() }));
                }
            }
            return result.toOwnedSlice(allocator);
        }

        pub fn renameBasename(self: *@This(), path: String, new_name: String) !void {
            (try self.makePathRecursive(path, false, false, false)).Tag.name = new_name;
        }

        /// the content has to exist in the untagged storage
        pub fn assignTag(self: *@This(), ref: usize, index: usize, path: String, if_exists: decls.ExistsBehavior) !void {
            // check for all
            if (self.all.getEntry(ref)) |ptr| {
                var item: Stored = ptr.value_ptr.items[index];
                for (item.tags.values()) |tag| {
                    const p = try tag.fullPathAlloc(self.allocator, false);
                    defer self.allocator.free(p);
                    if (!std.mem.eql(u8, path, p)) {
                        log.err("Tried to put tag {s} to {x} but the pointer has already tag {s}", .{ path, combinedRef(ref, index), p });
                        return error.TagExists;
                    }
                }

                var target = try self.makePathRecursive(path, true, if_exists != .Error, false);

                if (target.content == .Dir) {
                    log.err("Tried to put tag {s} to {x} but the path is a directory", .{ path, combinedRef(ref, index) });
                    return error.DirExists;
                }
                target.content.Tag.target = &ptr.value_ptr.items[index];
                // assign "reverse pointer" (from the content to the tag)
                try ptr.value_ptr.items[index].tags.put(self.allocator, target.content.Tag.name, target.content.Tag);
            } else {
                log.err("Tried to put tag {s} to {x} but the pointer has no untagged content", .{ path, ref });
                return error.TargetNotFound;
            }
        }

        pub fn mkdir(self: *@This(), path: String) !Dir(Stored) {
            return try self.makePathRecursive(path, true, false, true).content.Dir;
        }

        /// Append to existing []Stored with same ref or create a new Stored
        /// The payload will be stored verbatim and will not be copied
        pub fn appendUntagged(self: *@This(), payload: Stored) !void {
            const maybe_ptr = try self.all.getOrPut(payload.ref);
            if (!maybe_ptr.found_existing) {
                maybe_ptr.value_ptr.* = std.ArrayList(Stored).init(self.allocator);
            }
            try maybe_ptr.value_ptr.append(payload);
        }

        pub fn createUntagged(self: *@This(), payloads: []Stored) !void {
            const maybe_ptr = try self.all.getOrPut(payloads[0].ref);
            if (!maybe_ptr.found_existing) {
                maybe_ptr.value_ptr.* = std.ArrayList(Stored).init(self.allocator);
            }
            try maybe_ptr.value_ptr.appendSlice(payloads);
        }

        /// Remove only from tagged storage
        fn removeTag(_: *@This(), tag: *Tag(Stored)) !void {
            if (tag.parent) |parent| {
                std.debug.assert(parent.files.remove(tag.name));
            }
        }

        /// dir => remove recursively
        /// does not erase tag content from the untagged storage
        pub fn untag(self: *@This(), path: String, dir: bool) !void {
            const ptr = try self.makePathRecursive(path, false, false, false); // also checks for existence
            switch (ptr.content) {
                .Dir => |content_dir| {
                    if (!dir) {
                        return error.DirExists;
                    }
                    var subdirs = content_dir.dirs.iterator();
                    while (subdirs.next()) |subdir| {
                        // remove content of subdirs
                        try self.untag(subdir.key_ptr.*, true);

                        // remove self
                        content_dir.deinit(); // removes subdirs and files references
                        // TODO convert to tail-recursion
                        if (content_dir.parent) |parent| {
                            std.debug.assert(parent.dirs.remove(content_dir.name));
                        }
                    }
                },
                .Tag => |content_tag| { // a single file
                    try self.removeTag(content_tag);
                },
            }
        }

        // From both tagged and untagged storage
        pub fn remove(self: *@This(), ref: usize) !void {
            // remove the content
            const removed_maybe = self.all.fetchRemove(ref);
            if (removed_maybe) |removed| {
                for (removed.value.items) |item| {
                    for (item.tags.values()) |tag| {
                        try self.removeTag(tag);
                    }
                }
            } else {
                return error.TargetNotFound;
            }
        }

        /// Remove only from tagged, kepp in untagged
        pub fn untagIndex(self: *@This(), ref: usize, index: usize) !void {
            const contents_maybe = self.all.get(ref);
            if (contents_maybe) |contents| {
                const tags = contents.items[index].tags;
                if (tags.count() >= 0) {
                    for (tags.values()) |tag| {
                        try self.removeTag(tag);
                    }
                } else {
                    return error.NotTagged;
                }
            } else {
                return error.TargetNotFound;
            }
        }

        pub fn untagAll(self: *@This(), ref: usize) !void {
            const contents_maybe = self.all.get(ref);
            if (contents_maybe) |contents| {
                for (contents.items) |item| {
                    if (item.tags.count() > 0) {
                        for (item.tags.values()) |tag| {
                            try self.removeTag(tag);
                        }
                    } else {
                        return error.NotTagged;
                    }
                }
            } else {
                return error.TargetNotFound;
            }
        }

        /// NOTE: incosistency: if you want to stat a shader under a program, use 'tagged' locator with the untagged source 'path'
        pub fn stat(self: *@This(), locator: Locator) !StatPayload {
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
                            .size = if (ptr.content.Nested.getSource()) |s| s.len else 0,
                        } else {
                            const now = Stat.now();
                            return StatPayload{
                                .type = @intFromEnum(FileType.File),
                                .accessed = now.accessed,
                                .created = now.created,
                                .modified = now.modified,
                                .size = if (ptr.content.Nested.getSource()) |s| s.len else 0,
                            };
                        };
                    }
                },
            }
        }

        pub const DirOrStored = if (Nested != void) struct {
            is_new: bool,
            content: union(enum) {
                Tag: *Tag(Stored),
                Nested: Nested,
                Dir: *Dir(Stored),
            },
        } else struct {
            is_new: bool,
            content: union(enum) {
                Tag: *Tag(Stored),
                Dir: *Dir(Stored),
            },
        };

        pub fn getStoredByLocator(self: *@This(), locator: Locator) !?*Stored {
            switch (locator) {
                .tagged => |path| return self.getStoredByPath(path),
                .untagged => |combined| return if (self.all.get(combined.ref)) |s| &s.items[combined.part] else null,
            }
        }

        pub const getNestedByLocator = if (Nested == void) undefined else struct {
            pub fn getNestedByLocator(self: *Storage(Stored, Nested), locator: Locator, nested: Locator) !?Nested {
                if (try self.getStoredByLocator(locator)) |outer| {
                    const ptr = try outer.getNested(nested);
                    switch (ptr.content) {
                        .Nested => |n| return n,
                        else => return error.DirExists,
                    }
                }
                return null;
            }
        }.getNestedByLocator;

        pub fn getStoredByPath(self: *@This(), path: String) !*Stored {
            const ptr = try self.makePathRecursive(path, false, false, false);
            switch (ptr.content) {
                .Tag => |tag| return tag.target,
                else => return error.DirExists,
            }
        }

        pub fn getDirByPath(self: *@This(), path: String) !?*Dir(Stored) {
            const ptr = try self.makePathRecursive(path, false, false, false);
            switch (ptr.content) {
                .Dir => |dir| return dir,
                else => return error.TagExists,
            }
        }

        /// Assume both the nested and the parent are tagged
        pub const getNestedByPath = if (Nested == void) undefined else struct {
            pub fn getNestedByPath(self: *Storage(Stored, Nested), path: String) !?Nested {
                const ptr = try self.makePathRecursive(path, false, false, false);
                switch (ptr.content) {
                    .Nested => |target| return target,
                    else => return error.DirExists,
                }
            }
        }.getNestedByPath;

        /// Gets an existing tag or directory, throws error is does not exist, or
        /// create_new => if the path pointer does not exist, create it (recursively).
        /// create_as_dir switches between creating a pointer for new Tag(payload) or Dir(payload)
        /// overwrite => return the path pointer even if it already exists and create_new is true (this means the function should always succeed).
        /// Caller should assign pointer from the content to the tag when the tag path pointer is created or changed.
        /// Makes this kind of a universal function.
        fn makePathRecursive(self: *@This(), path: String, create_new: bool, overwrite: bool, create_as_dir: bool) !DirOrStored {
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
                            var new_dir = try Dir(Stored).init(self.allocator, current_dir_entry.value_ptr, path_part);
                            const new_dir_ptr = try current_dir_entry.value_ptr.dirs.getOrPut(new_dir.name);
                            new_dir_ptr.value_ptr.* = new_dir;
                            current_dir_entry = .{ .value_ptr = new_dir_ptr.value_ptr, .key_ptr = &new_dir.name };
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
        ) !DirOrStored {
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
                    return existing_file.value_ptr.target.getNested(.{ .tagged = in_dir.subpath });
                }
                if (Nested == void or in_dir.subpath.len == 0) {
                    if (overwrite) {
                        if (create_as_dir) {
                            return error.TagExists;
                        }

                        // Remove old / overwrite
                        const old_ref = existing_file.value_ptr.target.*.ref;
                        if (!self.all.remove(old_ref)) {
                            log.err("Ref {x} not found in storage map", .{old_ref});
                            return error.NotTagged;
                        }
                        log.debug("Overwriting tag {s} from source {x} with {s}", .{ existing_file.value_ptr.name, old_ref, name });
                        // remove existing tag
                        if (!dir.files.remove(existing_file.value_ptr.name)) {
                            // should be a race condition
                            log.err("Tag {s} not found in parent directory", .{existing_file.value_ptr.name});
                            return error.NotTagged;
                        }
                        // overwrite tag and content
                        existing_file.value_ptr.name = try self.allocator.dupe(u8, name);
                        const time = std.time.milliTimestamp();
                        existing_file.value_ptr.target.*.stat.modified = time;
                        existing_file.value_ptr.target.*.stat.accessed = time;
                    } else if (create) {
                        return error.TagExists;
                    }
                    return .{
                        .is_new = false,
                        .content = .{ .Tag = existing_file.value_ptr },
                    };
                }
                // now _contains_folders is true and (in_dir.subpath.len == 0 or no targets found)
                return error.TargetNotFound;
            } else {
                // target does not exist as file. Maybe it exists as directory
                if (create) {
                    if (create_as_dir) {
                        if (dir.dirs.getEntry(name)) |existing_dir| {
                            if (!overwrite) {
                                return error.DirExists;
                            }

                            return .{
                                .is_new = false,
                                .content = .{ .Dir = existing_dir.value_ptr },
                            };
                        } else {
                            // create NEW directory
                            log.debug("Making new tag dir {s}", .{name});
                            const new_dir_content = try Dir(Stored).init(self.allocator, dir, name);
                            const new_dir = try dir.dirs.getOrPut(new_dir_content.name);
                            std.debug.assert(new_dir.found_existing == false);
                            new_dir.value_ptr.* = new_dir_content;
                            return .{
                                .is_new = true,
                                .content = .{ .Dir = new_dir.value_ptr },
                            };
                        }
                    }

                    log.debug("Making new tag file {s}", .{name});
                    const duplicated_name = try self.allocator.dupe(u8, name);
                    const new_file = try dir.files.getOrPut(duplicated_name);
                    std.debug.assert(new_file.found_existing == false);
                    new_file.value_ptr.* = StoredTag{
                        .name = duplicated_name,
                        .parent = dir,
                        .target = undefined,
                    };
                    // the caller should assign reverse pointer to the tag
                    return .{
                        .is_new = true,
                        .content = .{ .Tag = new_file.value_ptr },
                    };
                } else {
                    log.debug("Path {s} not found", .{name});
                    return error.TargetNotFound;
                }
            }
        }
    };
}

pub const Error = error{ NotUntagged, NotTagged, TagExists, DirExists, AlreadyTagged, DirectoryNotFound, TargetNotFound };
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
};

pub const StatPayload = struct {
    type: usize,
    accessed: i64,
    created: i64,
    modified: i64,
    size: usize,

    pub fn fromPhysical(physical: anytype, file_type: FileType) @This() {
        return StatPayload{
            .accessed = @intCast(@divTrunc(physical.atime, 1000)),
            .modified = @intCast(@divTrunc(physical.mtime, 1000)),
            .created = @intCast(@divTrunc(physical.ctime, 1000)),
            .type = @intFromEnum(file_type),
            .size = @intCast(physical.size),
        };
    }
};

pub fn Dir(comptime Taggable: type) type {
    return struct {
        const DirMap = std.StringHashMap(Dir(Taggable));
        const FileMap = std.StringHashMap(Tag(Taggable));
        allocator: std.mem.Allocator,
        dirs: DirMap,
        files: FileMap,
        /// is owned by Dir instance
        name: String,
        stat: Stat,
        parent: ?*@This(),
        /// is owned by services/shaders module
        physical: ?String = null,

        fn init(allocator: std.mem.Allocator, parent: ?*@This(), name: String) !@This() {
            return Dir(Taggable){
                .allocator = allocator,
                .name = try allocator.dupe(u8, name),
                .dirs = DirMap.init(allocator),
                .files = FileMap.init(allocator),
                .parent = parent,
                .stat = Stat.now(),
            };
        }

        fn deinit(self: *@This()) void {
            var it = self.dirs.valueIterator();
            while (it.next()) |dir| {
                dir.deinit();
            }
            self.dirs.deinit();

            var it_f = self.files.valueIterator();
            while (it_f.next()) |file| {
                self.allocator.free(file.name);
            }
            self.allocator.free(self.name);
            self.files.deinit();
        }

        pub fn listPhysical(self: *@This(), allocator: std.mem.Allocator, result: *std.StringArrayHashMapUnmanaged(void), subpath: String, recursive: bool) !void {
            if (self.physical) |path| {
                const physical_dir = try std.fs.openDirAbsolute(path, .{});
                const dir = try physical_dir.openDir(subpath, .{});
                var stack = try std.ArrayListUnmanaged(std.fs.Dir).initCapacity(allocator, 2);
                defer stack.deinit(allocator);
                var current_path = std.ArrayListUnmanaged(u8){};
                defer current_path.deinit(allocator);

                stack.appendAssumeCapacity(dir);
                while (stack.items.len != 0) {
                    const current = stack.pop();
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
    };
}

pub fn Tag(comptime taggable: type) type {
    return struct {
        /// name is duplicated when stored
        /// name cannot contain '/' and '>'
        name: String,
        parent: ?*Dir(taggable),
        target: *taggable,

        pub fn fullPathAlloc(self: *@This(), allocator: std.mem.Allocator, comptime sentinel: bool) !if (sentinel) [:0]const u8 else String {
            self.target.*.stat.accessed = std.time.milliTimestamp();
            var path_stack = std.ArrayListUnmanaged(u8){};
            var dir_stack = std.ArrayListUnmanaged(String){};
            defer dir_stack.deinit(allocator);
            var root: ?*Dir(taggable) = self.parent;
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
    };
}

pub const DoubleUsize = @Type(std.builtin.Type{ .Int = .{ .bits = @bitSizeOf(usize) * 2, .signedness = .unsigned } });
pub fn combinedRef(ref: usize, part: usize) DoubleUsize {
    return @as(DoubleUsize, ref) << @bitSizeOf(usize) | part;
}

pub const untagged_path = "/untagged";
pub const Locator = union(enum) {
    pub const Ref = struct {
        ref: usize,
        part: usize,

        pub fn isRoot(self: @This()) bool {
            return self.part == 0 and self.ref == 0;
        }
    };
    tagged: String,
    /// ref
    untagged: Ref,

    pub fn untagged(combined: DoubleUsize) Locator {
        return Locator{ .untagged = .{
            .ref = @truncate(combined >> @bitSizeOf(usize)),
            .part = @truncate(combined),
        } };
    }

    /// returns null for untagged root
    pub fn parse(subpath: String) !?Locator {
        if (std.mem.startsWith(u8, subpath, untagged_path)) {
            if (subpath.len == untagged_path.len or (subpath[untagged_path.len] == '/' and subpath.len == untagged_path.len + 1)) {
                return null;
            }
            const last_dot = std.mem.lastIndexOfScalar(u8, subpath, '.') orelse subpath.len;
            const combined = try std.fmt.parseInt(DoubleUsize, subpath[untagged_path.len + 1 .. last_dot], 16);
            return Locator.untagged(combined);
        } else {
            return Locator{ .tagged = subpath };
        }
    }
};
