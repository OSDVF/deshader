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
/// Stored type must have a .tag field with the type ?*Tag(Stored) and a merge(Payload) method
/// Both the types must have
///    .ref: usize
/// Some code is specialized for Shader.Program or Shader.Source so it is not competely generic
pub fn Storage(comptime Stored: type) type {
    return struct {
        pub const TagMap = std.StringHashMap(Dir(Stored));
        // The capacity is 8 by default so it is no such a big deal to treat it as a hash-list hybrid
        pub const RefMap = std.AutoHashMap(usize, std.ArrayList(Stored));
        /// programs / source parts mapped by tag
        tagged: TagMap,
        /// programs / source parts mapped by ref
        all: RefMap,
        allocator: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator) !@This() {
            return @This(){
                .allocator = alloc,
                .tagged = TagMap.init(alloc),
                .all = RefMap.init(alloc),
            };
        }

        pub fn deinit(self: *@This()) void {
            {
                var it = self.tagged.valueIterator();
                while (it.next()) |val| {
                    val.*.deinit();
                }
                self.tagged.deinit();
            }
            {
                var it = self.all.valueIterator();
                while (it.next()) |val_array| {
                    for (val_array.items) |*val| {
                        if (val.tag == null) {
                            val.deinit();
                        }
                    }
                    val_array.deinit();
                }
                self.all.deinit();
            }
        }

        /// lists existing tags in various contaners
        /// path = "/" => lists all tagged files
        /// path = null => do not include tagged files
        pub fn list(self: *@This(), untagged: bool, path: ?String) ![]CString {
            var result = std.ArrayList(CString).init(self.allocator);

            if (path) |sure_path| {
                // print tagged
                var tag_iter = self.tagged.iterator();
                var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
                var allocator = std.heap.FixedBufferAllocator.init(&buffer);
                // growing and shrinking path prefix for current directory
                var current_path = std.ArrayList(u8).init(allocator.allocator());
                defer current_path.deinit();
                try current_path.appendSlice(sure_path);
                if (current_path.getLast() != '/') {
                    try current_path.append('/');
                }

                const DirStackItem = struct {
                    dir: *Dir(Stored),
                    prev_len: usize, // parent directory path length
                };
                var stack = std.ArrayList(DirStackItem).init(self.allocator);
                defer stack.deinit();
                while (tag_iter.next()) |dir| {
                    //DFS print of directory tree
                    try stack.append(.{ .dir = dir.value_ptr, .prev_len = 1 });
                    while (stack.popOrNull()) |current_dir| {
                        current_path.shrinkRetainingCapacity(current_dir.prev_len);

                        try current_path.appendSlice(dir.key_ptr.*); // add current directory
                        try current_path.append('/');

                        var subdirs = current_dir.dir.dirs.iterator();
                        while (subdirs.next()) |subdir| {
                            try stack.append(.{ .dir = subdir.value_ptr, .prev_len = current_path.items.len });
                        }
                        var files = current_dir.dir.files.iterator();
                        while (files.next()) |file| {
                            switch (Stored) { // specialization
                                Shader.Program => {
                                    const program_links: ?*Shader.Program = file.value_ptr.getFirstTarget(); // programs should be always only one in a file (no symlinks)
                                    if (program_links) |program| {
                                        if (program.shaders == null) {
                                            continue;
                                        }
                                        for (program.shaders.?.items) |shaders_s| {
                                            if (findMainShaderSource(shaders_s.value_ptr.items)) |shader| {
                                                try result.append(try std.mem.concatWithSentinel(self.allocator, u8, &.{ current_path.items, file.value_ptr.name, shader.toString() }, 0));
                                            }
                                        }
                                    }
                                },
                                else => {
                                    var this_result = std.ArrayList(u8).init(self.allocator);
                                    try this_result.appendSlice(current_path.items);
                                    try this_result.appendSlice(file.value_ptr.name);
                                    // resolve all symlinks
                                    var targets = file.value_ptr.targets.keyIterator();
                                    while (targets.next()) |target| {
                                        try this_result.append('_');
                                        try std.fmt.formatIntValue(target.*.ref, "d", .{}, this_result.writer());
                                    }
                                    try this_result.append(0);
                                    try result.append(@ptrCast(try this_result.toOwnedSlice()));
                                },
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
                        switch (Stored) { //Specialization
                            Shader.Program => {
                                if (item.shaders) |shaders_s| {
                                    for (shaders_s.items) |shader| {
                                        const shader_source = shader.value_ptr.items[0]; // untagged shader sources cannot be symlinked so we can just take the first one
                                        try result.append(try std.fmt.allocPrintZ(self.allocator, "/untagged/program{d}/{d}{s}", .{ item.ref, shader_source.ref, shader_source.toString() }));
                                    }
                                }
                            },
                            else => {
                                try result.append(try std.fmt.allocPrintZ(self.allocator, "/untagged/{x}_{d}{s}", .{ item.ref, index, item.toString() }));
                            },
                        }
                    }
                }
            }
            return try result.toOwnedSlice();
        }

        pub fn renameBasename(self: *@This(), path: String, new_name: String) !void {
            (try self.makePathPtr(path, false, false, false)).Tag.name = new_name;
        }

        /// the content has to exist in the untagged storage
        pub fn assignTag(self: *@This(), ref: usize, index: usize, path: String, if_exists: decls.ExistsBehavior) !void {
            // check for all
            const maybe_ptr = try self.all.getOrPut(ref);
            if (!maybe_ptr.found_existing) {
                log.err("Tried to put tag {s} to {x} but the pointer has no untagged content", .{ path, ref });
                return error.TargetNotFound;
            } else {
                var item = maybe_ptr.value_ptr.items[index];
                if (item.tag != null) {
                    const p = try item.tag.?.getPathAlloc(self.allocator);
                    defer self.allocator.free(p);
                    if (!std.mem.eql(u8, path, p)) {
                        log.err("Tried to put tag {s} to {x}_{d} but the pointer has already tag {s}", .{ path, ref, index, p });
                        return error.TagExists;
                    }
                }
            }

            var target = try self.makePathPtr(path, true, if_exists != .Error, false);

            if (target.content == .Dir) {
                log.err("Tried to put tag {s} to {x}_{d} but the path is a directory", .{ path, ref, index });
                return error.DirExists;
            }
            // assign "reverse pointer" (from the content to the tag)
            maybe_ptr.value_ptr.items[index].tag = target.content.Tag;
            if (if_exists == .Overwrite) {
                target.content.Tag.targets.clearAndFree();
            }
            try target.content.Tag.targets.put(&maybe_ptr.value_ptr.items[index], {});
        }

        pub fn mkdir(self: *@This(), path: String) !Dir(Stored) {
            return try self.makePathPtr(path, true, false, true).content.Dir;
        }

        /// Append to existing []Stored with same ref or create a new Stored
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

        fn removeTag(self: *@This(), tag: *Tag(Stored)) !void {
            std.debug.assert(tag.targets.count() > 0);
            var it = tag.targets.keyIterator();
            while (it.next()) |item| {
                var untagged = self.all.getPtr(item.*.ref);
                var found = false;
                for (untagged.?.items, 0..) |*untag, i| {
                    if (untag == item.*) {
                        _ = untagged.?.orderedRemove(i);
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    log.err("Tag {s} target {d} not found in untagged", .{ tag.name, item.*.ref });
                }
            }
            std.debug.assert(tag.parent.files.remove(tag.name));
        }

        /// dir => remove recursively
        /// does not erase tag content from the untagged storage
        pub fn removePath(self: *@This(), path: String, dir: bool) !void {
            const ptr = try self.makePathPtr(path, false, false, false); // also checks for existence
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
                            parent.dirs.removeByPtr(ptr.key);
                        }
                    }
                },
                .Tag => |content_tag| { // a single file
                    try self.removeTag(content_tag);
                },
            }
        }

        pub fn remove(self: *@This(), ref: usize) !void {
            // remove the content
            const removed_maybe = self.all.fetchRemove(ref);
            if (removed_maybe) |removed| {
                for (removed.value.items) |item| {
                    if (item.tag != null) {
                        // and the tag
                        try self.removeTag(item.tag.?);
                    }
                }
            } else {
                return error.TargetNotFound;
            }
        }

        pub fn removeIndex(self: *@This(), ref: usize, index: usize) !void {
            // remove the content
            const contents_maybe = self.all.get(ref);
            if (contents_maybe) |contents| {
                const tag = contents.items[index].value.tag;
                if (tag != null) {
                    try self.removeTag(tag.?);
                } else {
                    contents.items.orderedRemove(index);
                }
            } else {
                return error.TargetNotFound;
            }
        }

        const DirOrFile = struct {
            is_new: bool,
            content: union(enum) {
                Tag: *Tag(Stored),
                Dir: *Dir(Stored),
            },
            key: *String,
        };

        /// Gets an existing tag or directory, throws error is does not exist, or
        /// create_new => if the path pointer does not exist, create it.
        /// create_as_dir switches between creating a pointer for new Tag(payload) or Dir(payload)
        /// overwrite => return the path pointer even if it already exists and create_new is true (this means the function should always succeed).
        /// Caller should assign pointer from the content to the tag when the tag path pointer is created or changed.
        /// Makes this kind of a universal function.
        fn makePathPtr(self: *@This(), path: String, create_new: bool, overwrite: bool, create_as_dir: bool) !DirOrFile {
            var path_iterator = std.mem.splitScalar(u8, path, '/');
            var current_dir_entry = try self.tagged.getOrPut(path_iterator.first());
            if (!current_dir_entry.found_existing) {
                // create root-level directory if it does not exist
                current_dir_entry.value_ptr.* = try Dir(Stored).init(self.allocator, null, path_iterator.first());
            }
            var current_dir: *Dir(Stored) = current_dir_entry.value_ptr;

            var no_further_dirs = false;
            while (path_iterator.next()) |path_part| {
                if (no_further_dirs) {
                    // we are at the last part of the path (the basename)
                    // there was already the last directory match found
                    if (path_iterator.peek() != null) { // there is another path part (directory) pending
                        if (create_new) { // create_new creates recursive directory structure
                            log.debug("Recursively creating directory {s}", .{path_part});
                            const new_dir = try Dir(Stored).init(self.allocator, current_dir, path_part);
                            const new_dir_ptr = try current_dir.dirs.getOrPut(path_part);
                            new_dir_ptr.value_ptr.* = new_dir;
                            current_dir = new_dir_ptr.value_ptr;
                        } else {
                            return error.DirectoryNotFound;
                        }
                    } else {
                        // traverse files
                        const existing_file = try current_dir.files.getOrPut(path_part);
                        if (existing_file.found_existing) {
                            if (overwrite) {
                                if (create_as_dir) {
                                    return error.TagExists;
                                }

                                // Remove old / overwrite
                                const old_ref = existing_file.value_ptr.getFirstTarget().?.ref;
                                if (!self.all.remove(old_ref)) {
                                    log.err("Tag {d} not found in all", .{old_ref});
                                    return error.NotTagged;
                                }
                                log.debug("Overwriting tag {s} from source {x} with {s}", .{ existing_file.value_ptr.name, old_ref, path_part });
                                // remove existing tag
                                if (!current_dir.files.remove(existing_file.value_ptr.name)) {
                                    // should be a race condition
                                    log.err("Tag {s} not found in parent directory", .{existing_file.value_ptr.name});
                                    return error.NotTagged;
                                }
                                // overwrite tag and content
                                existing_file.value_ptr.name = try self.allocator.dupe(u8, path_part);

                                return .{
                                    .is_new = false,
                                    .content = .{ .Tag = existing_file.value_ptr },
                                    .key = existing_file.key_ptr,
                                };
                            } else {
                                return error.TagExists;
                            }
                        } else {
                            // target tag/dir does not exist
                            if (create_new) {
                                if (create_as_dir) {
                                    const existing_dir = try current_dir.dirs.getOrPut(path_part);
                                    if (existing_dir.found_existing) {
                                        if (!overwrite) {
                                            return error.DirExists;
                                        }

                                        return .{
                                            .is_new = false,
                                            .content = .{ .Dir = existing_dir.value_ptr },
                                            .key = existing_dir.key_ptr,
                                        };
                                    }
                                    // create NEW directory
                                    log.debug("Making new tag dir {s}", .{path_part});
                                    existing_dir.value_ptr.* = try Dir(Stored).init(self.allocator, current_dir, path_part);
                                    return .{
                                        .is_new = true,
                                        .content = .{ .Dir = existing_dir.value_ptr },
                                        .key = existing_dir.key_ptr,
                                    };
                                }

                                log.debug("Making new tag file {s}", .{path_part});
                                existing_file.value_ptr.* = Tag(Stored){
                                    .name = try self.allocator.dupe(u8, path_part),
                                    .parent = current_dir,
                                    .targets = Tag(Stored).Targets.init(self.allocator),
                                };
                                // the caller should assign reverse pointer to the tag
                                return .{
                                    .is_new = true,
                                    .content = .{ .Tag = existing_file.value_ptr },
                                    .key = existing_file.key_ptr,
                                };
                            } else {
                                log.debug("Path {s} not found", .{path_part});
                                return error.TargetNotFound;
                            }
                        }
                    }
                }

                // traverse directories
                current_dir_entry = try current_dir.dirs.getOrPut(path_part);
                if (current_dir_entry.found_existing) {
                    current_dir = current_dir_entry.value_ptr;
                } else {
                    no_further_dirs = true;
                }
            }
            // at this point we have found a directory but not a file
            return .{
                .is_new = false,
                .content = .{ .Dir = current_dir },
                .key = current_dir_entry.key_ptr,
            };
        }
    };
}

pub const Error = error{ NotUntagged, NotTagged, TagExists, DirExists, AlreadyTagged, DirectoryNotFound, TargetNotFound };

pub fn Dir(comptime taggable: type) type {
    return struct {
        const DirMap = std.StringHashMap(Dir(taggable));
        const FileMap = std.StringHashMap(Tag(taggable));
        dirs: DirMap,
        files: FileMap,
        /// is not owned. Only needed for reverse path resolution for Tag(taggable)
        name: String,
        parent: ?*@This(),

        fn init(allocator: std.mem.Allocator, parent: ?*@This(), name: String) !@This() {
            return Dir(taggable){
                .name = name,
                .dirs = DirMap.init(allocator),
                .files = FileMap.init(allocator),
                .parent = parent,
            };
        }

        fn deinit(self: *@This()) void {
            self.dirs.deinit();
            self.files.deinit();
        }
    };
}
pub fn Tag(comptime taggable: type) type {
    return struct {
        pub const Targets = std.AutoHashMap(*taggable, void);
        /// name is duplicated when stored
        name: String,
        parent: *Dir(taggable),
        // TODO should ideally be a iterable continuously growwing hash-set
        targets: Targets,

        pub fn getPathAlloc(self: *const @This(), allocator: std.mem.Allocator) !String {
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

        pub fn getFirstTarget(self: *const @This()) ?*taggable {
            var it = self.targets.keyIterator();
            return if (it.next()) |next| return next.* else null;
        }
    };
}

/// find shader entry point among other shaders sources in the shader
/// TODO search for main instead of searching for the source which does not have any symlinks
fn findMainShaderSource(sources: []const Shader.Source) ?Shader.Source {
    for (sources) |s| {
        if (s.tag) |tag| {
            if (tag.targets.count() == 1) { // The tag is only used by this program (not symlinked to some other program)
                return s;
            }
        }
    }
    return null;
}
