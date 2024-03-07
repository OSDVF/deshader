const std = @import("std");
const decls = @import("../declarations/shaders.zig");

const log = @import("../log.zig").DeshaderLog;
const shaders = @import("shaders.zig");

const String = []const u8;
const CString = [*:0]const u8;

const Shader = shaders.Shader;
const Program = shaders.Program;

const Shaders = shaders.Shaders;
const Programs = shaders.Programs;

/// Welcome to Deshader virtual shader tagging storage hell.
/// All detected shaders are stored here with their tags.
/// This is not standart filesystem structure because tags can point to more than one shader.
/// Also tags can point to shaders which already have a different tag, so there is both M:N relationship between [Tag]-[Tag] and between [Tag]-[Stored].
/// This can lead to orphans, cycles or many other difficulties but this is not a real filesystem so we ignore the downsides for now.
/// Stored type must have a .tag field of type ?*Tag(Stored) and a merge(Payload) method
/// Stored² type is optional (can be void) and it is used for storing multiple nested filesystems (like in the case of programs)
/// Both the types must have property
///    .ref: usize
pub fn Storage(comptime Stored: type, comptime Stored2: type) type {
    return struct {
        pub const StoredDir = Dir(Stored);
        pub const StoredTag = Tag(Stored);
        // The capacity is 8 by default so it is no such a big deal to treat it as a hash-list hybrid
        /// Stores a list of untagged shader parts
        pub const RefMap = std.AutoHashMap(usize, std.ArrayList(Stored));
        /// programs / source parts mapped by tag
        tagged_root: StoredDir,
        /// programs / source parts mapped by ref
        all: RefMap,
        allocator: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator) !@This() {
            return @This(){
                .allocator = alloc,
                .tagged_root = try StoredDir.init(alloc, null, ""),
                .all = RefMap.init(alloc),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.tagged_root.deinit();
            {
                var it = self.all.valueIterator();
                while (it.next()) |val_array| {
                    for (val_array.items) |*val| {
                        val.*.deinit();
                    }
                    val_array.deinit();
                }
                self.all.deinit();
            }
        }

        /// lists existing tags in various contaners
        /// path = "/" => lists all tagged files
        /// path = null => do not include tagged files
        pub fn listAlloc(self: *@This(), untagged: bool, path: ?String, recursive: ?bool) ![]CString {
            std.debug.assert(path != null or untagged);
            log.debug("Listing {?s} {?} {?}", .{ path, untagged, recursive });

            const recursive_decision = recursive orelse false;
            var result = std.ArrayList(CString).init(self.allocator);

            if (path) |sure_path| {
                // print tagged
                var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
                var allocator = std.heap.FixedBufferAllocator.init(&buffer);
                // growing and shrinking path prefix for current directory
                var current_path = std.ArrayList(u8).init(allocator.allocator());
                defer current_path.deinit();

                const DirStackItem = struct {
                    dir: *StoredDir,
                    prev_len: usize, // parent directory path length
                };
                var stack = std.ArrayList(DirStackItem).init(self.allocator);
                defer stack.deinit();

                const root = try self.makePathRecursive(sure_path, false, false, true);
                //DFS print of directory tree
                try stack.append(.{ .dir = root.content.Dir, .prev_len = 0 });
                while (stack.popOrNull()) |current_dir| {
                    if (current_dir.dir.name.len > 0) {
                        current_path.shrinkRetainingCapacity(current_dir.prev_len);
                    }

                    log.debug("Expanding directory {s}", .{current_dir.dir.name});
                    try current_path.appendSlice(current_dir.dir.name); // add current directory
                    try current_path.append('/');

                    var subdirs = current_dir.dir.dirs.iterator();
                    while (subdirs.next()) |subdir| {
                        log.debug("Pushing directory {s}", .{subdir.key_ptr.*});
                        if (recursive_decision) {
                            try stack.append(.{ .dir = subdir.value_ptr, .prev_len = current_path.items.len });
                        } else {
                            // just print the directory
                            try result.append(try std.fmt.allocPrintZ(self.allocator, "{s}{s}/", .{ current_path.items, subdir.key_ptr.* }));
                        }
                    }
                    var files = current_dir.dir.files.iterator();
                    while (files.next()) |file| {
                        if (Stored2 == void) { // Normal non-nested storage
                            var this_result = std.ArrayList(u8).init(self.allocator);
                            try this_result.appendSlice(current_path.items);
                            try this_result.appendSlice(file.value_ptr.name);
                            try this_result.append(0);
                            log.debug("Tagged file {s}", .{this_result.items});
                            try result.append(@ptrCast(try this_result.toOwnedSlice()));
                        } else {
                            const program_links: ?*Shader.Program = file.value_ptr.getFirstTarget(); // programs should be always only one in a file (no symlinks)
                            if (program_links) |program| {
                                if (program.shaders == null) {
                                    continue;
                                }
                                var shader_iter = program.listFiles();
                                if (shader_iter != null) {
                                    while (try shader_iter.?.nextAlloc(self.allocator)) |shaders_s| {
                                        defer self.allocator.free(shaders_s.name);
                                        try result.append(try std.mem.concatWithSentinel(self.allocator, u8, &.{ current_path.items, file.value_ptr.name, "/", shaders_s.name }, 0));
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if (untagged) {
                // print untagged
                var iter = self.all.iterator();
                while (iter.next()) |items| {
                    for (items.value_ptr.items, 0..) |item, index| {
                        if (item.tag != null) { // skip tagged ones
                            continue;
                        }
                        if (Stored2 != void) { //Specialization
                            var iter2 = item.listFiles();
                            if (iter2) |*sure_iter| {
                                while (try sure_iter.nextAlloc(self.allocator)) |shader| {
                                    defer self.allocator.free(shader.name);
                                    try result.append(try std.fmt.allocPrintZ(self.allocator, "/untagged/{d}/{s}", .{ item.ref, shader.name }));
                                }
                            }
                        } else {
                            try result.append(try std.fmt.allocPrintZ(self.allocator, "/untagged/{d}_{d}{s}", .{ item.ref, index, item.toExtension() }));
                        }
                    }
                }
            }
            return try result.toOwnedSlice();
        }

        pub fn renameBasename(self: *@This(), path: String, new_name: String) !void {
            (try self.makePathRecursive(path, false, false, false)).Tag.name = new_name;
        }

        /// the content has to exist in the untagged storage
        pub fn assignTag(self: *@This(), ref: usize, index: usize, path: String, if_exists: decls.ExistsBehavior) !void {
            // check for all
            if (self.all.getEntry(ref)) |ptr| {
                var item: Stored = ptr.value_ptr.items[index];
                if (item.tag != null) {
                    const p = try item.tag.?.getPathAlloc(self.allocator);
                    defer self.allocator.free(p);
                    if (!std.mem.eql(u8, path, p)) {
                        log.err("Tried to put tag {s} to {x}_{d} but the pointer has already tag {s}", .{ path, ref, index, p });
                        return error.TagExists;
                    }
                }

                var target = try self.makePathRecursive(path, true, if_exists != .Error, false);

                if (target.content == .Dir) {
                    log.err("Tried to put tag {s} to {x}_{d} but the path is a directory", .{ path, ref, index });
                    return error.DirExists;
                }
                // assign "reverse pointer" (from the content to the tag)
                ptr.value_ptr.items[index].tag = target.content.Tag;
                if (if_exists == .PurgePrevious) {
                    target.content.Tag.targets.clearAndFree();
                }
                try target.content.Tag.targets.put(&ptr.value_ptr.items[index], {});
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
            std.debug.assert(payload.tag == null);

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

        pub fn updateUntagged(self: *@This(), payload: Stored, index: usize, merge: bool) !void {
            std.debug.assert(payload.tag == null);

            const maybe_ptr = self.all.get(payload.ref);
            if (maybe_ptr) |ptr| {
                if (merge) {
                    merge(@TypeOf(ptr.items[index]), ptr.items[index], payload);
                } else {
                    ptr.items[index] = payload;
                }
            } else {
                return error.TargetNotFound;
            }
        }

        // Both from tagged and all
        fn removeTag(self: *@This(), tag: *Tag(Stored)) !void {
            if (tag.parent) |parent| {
                std.debug.assert(tag.targets.count() > 0);
                var it = tag.targets.keyIterator();
                while (it.next()) |item| {
                    var untagged = self.all.getPtr(item.*.*.ref);
                    var found = false;
                    for (untagged.?.items, 0..) |*untag, i| {
                        if (untag == item.*) {
                            _ = untagged.?.orderedRemove(i);
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        log.err("Tag {s} target {d} not found in untagged", .{ tag.name, item.*.*.ref });
                    }
                }
                std.debug.assert(parent.files.remove(tag.name));
            }
        }

        /// dir => remove recursively
        /// does not erase tag content from the untagged storage
        pub fn removePath(self: *@This(), path: String, dir: bool) !void {
            const ptr = try self.makePathRecursive(path, false, false, false); // also checks for existence
            switch (ptr.content) {
                .Dir => |content_dir| {
                    if (!dir) {
                        return error.DirExists;
                    }
                    var subdirs = content_dir.dirs.iterator();
                    while (subdirs.next()) |subdir| {
                        // remove content of subdirs
                        try self.removePath(subdir.key_ptr.*, true);

                        // remove self
                        content_dir.deinit(); // removes subdirs and files references
                        // TODO convert to tail-recursion
                        if (content_dir.parent) |parent| {
                            std.debug.assert(parent.dirs.remove(ptr.key));
                        }
                    }
                },
                .Tag => |content_tag| { // a single file
                    try self.removeTag(content_tag);
                },
            }
        }

        // From both tagged and all
        pub fn remove(self: *@This(), ref: usize) !void {
            // remove the content
            const removed_maybe = self.all.fetchRemove(ref);
            if (removed_maybe) |removed| {
                for (removed.value.items) |item| {
                    if (item.tag != null) {
                        // and the tag
                        try self.removeTag(item.*.tag.?);
                    }
                }
            } else {
                return error.TargetNotFound;
            }
        }

        /// Remove only from tagged, kepp in untagged
        pub fn removeTagForIndex(self: *@This(), ref: usize, index: usize) !void {
            const contents_maybe = self.all.get(ref);
            if (contents_maybe) |contents| {
                const tag = contents.items[index].tag;
                if (tag != null) {
                    try self.removeTag(tag.?);
                } else {
                    return error.NotTagged;
                }
            } else {
                return error.TargetNotFound;
            }
        }

        pub fn removeAllTags(self: *@This(), ref: usize) !void {
            const contents_maybe = self.all.get(ref);
            if (contents_maybe) |contents| {
                for (contents.items) |item| {
                    if (item.tag != null) {
                        try self.removeTag(item.tag.?);
                    } else {
                        return error.NotTagged;
                    }
                }
            } else {
                return error.TargetNotFound;
            }
        }

        pub fn stat(self: *@This(), path: String) !StatPayload {
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
            } else if (Stored2 == void) {
                const tag = ptr.content.Tag;
                return StatPayload{
                    .type = //TODO symlinks
                    @intFromEnum(FileType.File),
                    .accessed = tag.stat.accessed,
                    .created = tag.stat.created,
                    .modified = tag.stat.modified,
                    .size = if (ptr.content.Tag.getFirstTarget()) |t| if (t.*.getSource()) |s| s.len else 0 else 0,
                };
            } else if (ptr.content == .Nested) {
                const nested = ptr.content.Nested;
                return StatPayload{
                    .type = @intFromEnum(FileType.File), //TODO can be also directories nested?
                    .accessed = nested.stat.accessed,
                    .created = nested.stat.created,
                    .modified = nested.stat.modified,
                    .size = 0,
                };
            } else {
                const dir = ptr.content.Tag; // Self is a storage with nested Stored2 and this returned the Tag but it is a virtual filesystem
                return StatPayload{
                    .type = @intFromEnum(FileType.Directory),
                    .accessed = dir.stat.accessed,
                    .created = dir.stat.created,
                    .modified = dir.stat.modified,
                    .size = 0,
                };
            }
        }

        pub const DirOrFile = if (Stored2 != void) struct {
            is_new: bool,
            content: union(enum) {
                Tag: *Tag(Stored),
                /// Enclosed 'targets' map be freed by the caller
                Nested: Tag(Stored2),
                Dir: *Dir(Stored),
            },
            key: String,
        } else struct {
            is_new: bool,
            content: union(enum) {
                Tag: *Tag(Stored),
                Dir: *Dir(Stored),
            },
            key: String,
        };

        // untagged
        pub fn getStoredByPath(self: *@This(), path: String) !?Stored {
            const ptr = try self.makePathRecursive(path, false, false, false);
            switch (ptr.content) {
                .Tag => |tag| return if (tag.getFirstTarget()) |target| return target.* else null,
                else => return error.DirExists,
            }
        }

        /// Gets an existing tag or directory, throws error is does not exist, or
        /// create_new => if the path pointer does not exist, create it (recursively).
        /// create_as_dir switches between creating a pointer for new Tag(payload) or Dir(payload)
        /// overwrite => return the path pointer even if it already exists and create_new is true (this means the function should always succeed).
        /// Caller should assign pointer from the content to the tag when the tag path pointer is created or changed.
        /// Makes this kind of a universal function.
        fn makePathRecursive(self: *@This(), path: String, create_new: bool, overwrite: bool, create_as_dir: bool) !DirOrFile {
            var path_iterator = std.mem.splitScalar(u8, if (path.len > 0 and path[0] == '/') path[1..] else path, '/');
            var root: String = "";
            var current_dir_entry: Dir(Stored).DirMap.Entry = .{ .value_ptr = &self.tagged_root, .key_ptr = &root };

            while (path_iterator.next()) |path_part| {
                // traverse directories
                if (current_dir_entry.value_ptr.dirs.getEntry(path_part)) |found| {
                    current_dir_entry = .{ .value_ptr = found.value_ptr, .key_ptr = found.key_ptr };
                } else {
                    if (path_iterator.peek()) |next_path_part| { // there is another path part (nested directory or file) pending
                        if (Stored2 != void) {
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
                            if (Stored2 != void) .{ .dir = current_dir_entry.value_ptr, .subpath = "" } else current_dir_entry.value_ptr,
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
                .key = current_dir_entry.key_ptr.*,
            };
        }

        /// If Nested is returned, it must be freed by the caller
        fn makePathEntry(
            self: *@This(),
            in_dir: if (Stored2 != void) struct { dir: *Dir(Stored), subpath: String } else *Dir(Stored),
            name: String,
            create: bool,
            overwrite: bool,
            create_as_dir: bool,
        ) !DirOrFile {
            const dir = if (Stored2 != void) in_dir.dir else in_dir;
            if (name.len == 0 and (Stored2 == void or in_dir.subpath.len == 0)) { //root
                return .{
                    .is_new = false,
                    .content = .{ .Dir = dir },
                    .key = dir.name,
                };
            }
            // traverse files
            if (dir.files.getEntry(name)) |existing_file| {
                if (Stored2 != void and in_dir.subpath.len > 0) {
                    var targets = existing_file.value_ptr.targets.keyIterator();
                    if (targets.next()) |target| {
                        return target.*.makePathAlloc(in_dir.subpath, create, overwrite, create_as_dir, self.allocator);
                    }
                }
                if (Stored2 == void or in_dir.subpath.len == 0) {
                    if (overwrite) {
                        if (create_as_dir) {
                            return error.TagExists;
                        }

                        // Remove old / overwrite
                        const old_ref = existing_file.value_ptr.getFirstTarget().?.*.ref;
                        if (!self.all.remove(old_ref)) {
                            log.err("Tag {d} not found in all", .{old_ref});
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
                        existing_file.value_ptr.stat.modified = time;
                        existing_file.value_ptr.stat.accessed = time;
                    } else if (create) {
                        return error.TagExists;
                    }
                    return .{
                        .is_new = false,
                        .content = .{ .Tag = existing_file.value_ptr },
                        .key = existing_file.key_ptr.*,
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
                                .key = existing_dir.key_ptr.*,
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
                                .key = new_dir_content.name,
                            };
                        }
                    }

                    log.debug("Making new tag file {s}", .{name});
                    const duplicated_name = try self.allocator.dupe(u8, name);
                    const new_file = try dir.files.getOrPut(duplicated_name);
                    std.debug.assert(new_file.found_existing == false);
                    new_file.value_ptr.* = StoredTag{
                        .name = duplicated_name,
                        .stat = Stat.now(),
                        .parent = dir,
                        .targets = StoredTag.Targets.init(self.allocator),
                    };
                    // the caller should assign reverse pointer to the tag
                    return .{
                        .is_new = true,
                        .content = .{ .Tag = new_file.value_ptr },
                        .key = new_file.key_ptr.*,
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
};

pub const StatPayload = struct {
    type: usize,
    accessed: i64,
    created: i64,
    modified: i64,
    size: usize,
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
                file.targets.deinit();
            }
            self.allocator.free(self.name);
            self.files.deinit();
        }
    };
}
pub fn Tag(comptime taggable: type) type {
    return struct {
        pub const Targets = std.AutoHashMap(*taggable, void);
        /// name is duplicated when stored
        /// name cannot contain '/' and '>'
        name: String,
        parent: ?*Dir(taggable),
        stat: Stat,
        // TODO should ideally be an iterable continuously growing hash-set
        /// Reverse pointer to the tag from the content.
        /// the pointer is not owned.
        /// When more shaders are symlinked the hashmap will have more than one entry
        targets: Targets,

        pub fn getPathAlloc(self: *@This(), allocator: std.mem.Allocator) !String {
            self.stat.accessed = std.time.milliTimestamp();
            var path_stack = std.ArrayList(u8).init(allocator);
            var dir_stack = std.ArrayList(String).init(allocator);
            var root: ?*Dir(taggable) = self.parent;
            while (root != null) {
                try dir_stack.append(root.?.name);
                root = root.?.parent;
            }
            for (0..dir_stack.items.len) |i| {
                try path_stack.appendSlice(dir_stack.items[dir_stack.items.len - i - 1]);
                try path_stack.append('/');
            }
            return try path_stack.toOwnedSlice();
        }

        pub fn getFirstTarget(self: *@This()) ?*taggable {
            self.stat.accessed = std.time.milliTimestamp();
            var it = self.targets.keyIterator();
            return if (it.next()) |next| return next.* else null;
        }
    };
}
