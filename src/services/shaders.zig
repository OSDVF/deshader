const std = @import("std");
const builtin = @import("builtin");

const String = []const u8;
const CString = [*:0]const u8;
const log = @import("../log.zig").DeshaderLog;
const decls = @import("../declarations/shaders.zig");

pub var Sources: Storage(Shader.Source, decls.SourcesPayload) = undefined;
pub var Programs: Storage(Shader.Program, decls.ProgramPayload) = undefined;

pub fn sourceTag(ref: usize, source_index: usize, path: CString, move: bool, overwrite_other: bool) !void {
    var maybe_sources = Sources.all.getPtr(ref);
    const path_copy = try Sources.allocator.dupeZ(u8, std.mem.span(path));
    errdefer Sources.allocator.free(path_copy);

    if (maybe_sources) |sources| {
        std.debug.assert(sources.count > source_index);
        std.debug.assert(sources.ref != 0);
        std.debug.assert(sources.sources != null);
        std.debug.assert(sources.type != .unknown);
        // no-copy assign
        if (sources.paths == null or sources.paths.?[source_index][0] == 0 or move) {
            const single_source = decls.SourcesPayload{
                .ref = sources.ref,
                .contexts = if (sources.contexts != null) @constCast(&[_]?*const anyopaque{sources.contexts.?[source_index]}) else null,
                .paths = @constCast(&[_]CString{path_copy}),
                .compile = sources.compile,
                .type = sources.type,
            };
            try Sources.putTagged(single_source, move, overwrite_other);
            sources.paths.?[source_index] = path_copy;
        } else {
            return error.AlreadyTagged;
        }
    } else {
        return error.TargetNotFound;
    }
}

pub fn sourceType(ref: usize, @"type": decls.SourceType) !void {
    var maybe_sources = Sources.all.get(ref);

    if (maybe_sources) |sources| {
        sources.type = @"type";
    } else {
        return error.TargetNotFound;
    }
}

pub fn sourceCompileFunc(ref: usize, func: @TypeOf((Shader.Source{}).compile)) !void {
    var maybe_sources = Sources.all.get(ref);

    if (maybe_sources) |sources| {
        sources.compile = func;
    } else {
        return error.TargetNotFound;
    }
}

pub fn sourceContext(ref: usize, source_index: usize, context: *const anyopaque) !void {
    var maybe_sources = Sources.all.get(ref);

    if (maybe_sources) |sources| {
        std.debug.assert(sources.contexts != null);
        sources.contexts[source_index] = context;
    } else {
        return error.TargetNotFound;
    }
}

pub fn sourceSource(ref: usize, source_index: usize, source_code: CString) !void {
    var maybe_sources = Sources.all.get(ref);

    if (maybe_sources) |sources| {
        std.debug.assert(sources.sources != null);
        sources.sources[source_index] = source_code;
    } else {
        return error.TargetNotFound;
    }
}

pub fn programTag(ref: usize, path: CString, move: bool, overwrite_other: bool) !void {
    var maybe_program = Programs.all.get(ref);
    const path_copy = try Programs.allocator.dupeZ(u8, std.mem.span(path));
    errdefer Programs.allocator.free(path_copy);

    if (maybe_program) |program| {
        std.debug.assert(program.ref != 0);
        // no-copy assign
        if (program.path == null or program.path[0] == 0 or move) {
            program.path = path_copy;
            try Programs.putTagged(program, move, overwrite_other);
        } else {
            return error.AlreadyTagged;
        }
    } else {
        return error.TargetNotFound;
    }
}

pub const ShaderErrors = error{ PipelineMismatch, NullPipeline };

pub fn programAttachSource(ref: usize, source: usize) !void {
    if (Sources.all.getPtr(source)) |existing_source| {
        if (Programs.all.getPtr(ref)) |existing_program| {
            // swicth on source type
            inline for (@typeInfo(decls.SourceType).Enum.fields) |target_s_type| {
                if (@intFromEnum(existing_source.type) == target_s_type.value) {
                    const target_p_type = @field(decls.SourceTypeToPipeline, target_s_type.name);
                    if (target_p_type == .Null) {
                        return error.NullPipeline;
                    }

                    // specific pipeline e.g. Null or Rasterize
                    if (existing_program.program.type == .Null or existing_program.program.type == target_p_type) {
                        existing_program.program.type = target_p_type;
                        var pipeline = &@field(existing_program.program.pipeline, @tagName(target_p_type));
                        // skip gl_ or vk_ prefix
                        @field(pipeline.*, target_s_type.name[3..]) = existing_source.ref;

                        // Update tagged
                        if (Programs.taggedByRef.get(ref)) |tagged_program| {
                            if (Sources.taggedByRef.get(source)) |tagged_source| {
                                if (tagged_program.program == .Null or tagged_program.program == target_p_type) {
                                    var target_tagged_pipeline = &@field(tagged_program.program, @tagName(target_p_type));
                                    // skip gl_ or vk_ prefix
                                    @field(target_tagged_pipeline.*, target_s_type.name[3..]) = tagged_source;
                                }
                            }
                        }
                    } else {
                        return error.PipelineMismatch;
                    }
                    break;
                }
            }
        } else {
            return error.TargetNotFound;
        }
    } else {
        return error.TargetNotFound;
    }
}

/// Provides virtual shader storage
/// All detected shaders are stored here with their tags
/// Stored type must have a .tag field with the type ?*Tag(Stored) and a hydrate(Payload) method
/// Payload type must have a .path field with the type ?CString
/// Both the tyes must have
///    .ref: usize
/// toString on ShaderSource is a specialization
pub fn Storage(comptime Stored: type, comptime Payload: type) type {
    return struct {
        pub const TagMap = std.StringHashMap(Dir(Stored));
        pub const RefMap = std.AutoHashMap(usize, Payload);
        pub const RefTagMap = std.AutoHashMap(usize, *Stored);
        tagged: TagMap, // programs / source parts mapped by tag
        taggedByRef: RefTagMap,
        all: RefMap, // programs / source "bundles" mapped by platform pointer
        allocator: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator) !@This() {
            return @This(){
                .allocator = alloc,
                .tagged = TagMap.init(alloc),
                .taggedByRef = RefTagMap.init(alloc),
                .all = RefMap.init(alloc),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.tagged.deinit();
            self.taggedByRef.deinit();
            self.all.deinit();
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
                                    // create virtual tree according to shader types
                                    const pipeline = file.value_ptr.content.program;
                                    // switch on pipeline type
                                    inline for (@typeInfo(decls.PipelineType).Enum.fields) |field| {
                                        if (@intFromEnum(pipeline) == field.value and field.value != 0) { // Exclude the Null pipeline type
                                            const pipeline_content = @field(pipeline, field.name);
                                            inline for (@typeInfo(@TypeOf(pipeline_content)).Struct.fields) |result_field| { // for each pipeline stage
                                                const source = @field(pipeline_content, result_field.name);
                                                const optional = @typeInfo(@TypeOf(source)) == .Optional;
                                                if (!optional or source != null) {
                                                    try result.append(try std.mem.concatWithSentinel(self.allocator, u8, &.{ current_path.items, file.value_ptr.name, (if (optional) source.? else source).toString() }, 0));
                                                }
                                            }
                                            break;
                                        }
                                    }
                                },
                                else => {
                                    try result.append(try std.mem.concatWithSentinel(self.allocator, u8, &.{ current_path.items, file.value_ptr.name, file.value_ptr.content.toString() }, 0));
                                },
                            }
                        }
                    }
                }
            }

            if (untagged) {
                // print untagged
                var iter = self.all.iterator();
                while (iter.next()) |item| {
                    if (self.taggedByRef.contains(item.key_ptr.*)) {
                        continue;
                    }
                    switch (Payload) { //Specialization
                        decls.ProgramPayload => {
                            // create virtual tree according to shader types
                            const program = item.value_ptr.program;
                            // switch on pipeline type
                            inline for (@typeInfo(decls.PipelineType).Enum.fields) |field| {
                                if (@intFromEnum(program.type) == field.value and field.value != 0) { // Exclude the Null pipeline type
                                    const pipeline_content = @field(program.pipeline, field.name);
                                    inline for (@typeInfo(@TypeOf(pipeline_content)).Struct.fields) |result_field| {
                                        const source_ptr = @field(pipeline_content, result_field.name);
                                        if (source_ptr != 0) {
                                            const source = Sources.all.get(source_ptr);
                                            try result.append(try std.fmt.allocPrintZ(self.allocator, "/untagged/program{d}/{d}{s}", .{ item.value_ptr.ref, if (source != null) source.?.ref else 0, if (source != null) source.?.toString() else "null" }));
                                        }
                                    }
                                    break;
                                }
                            }
                        },
                        else => {
                            try result.append(try std.fmt.allocPrintZ(self.allocator, "/untagged/{x}{s}", .{ item.value_ptr.ref, item.value_ptr.toString() }));
                        },
                    }
                }
            }
            return try result.toOwnedSlice();
        }

        /// for SourcesPayload the Payload should contain only a single source
        pub fn putTagged(self: *@This(), payload: Payload, move: bool, overwrite_other: bool) !void {
            var path: ?CString = undefined;
            switch (Payload) { // debug specialization
                decls.SourcesPayload => {
                    std.debug.assert(payload.count == 1);
                    path = payload.paths.?[0];
                },
                else => path = payload.path,
            }
            std.debug.assert(path != null);
            // check for all
            const maybe_ptr = try self.taggedByRef.getOrPut(payload.ref);
            if (maybe_ptr.found_existing) {
                if (!move) {
                    log.err("Tried to put tag {s} to {x} but the pointer is already tagged", .{ path.?, payload.ref });
                    return error.TagExists;
                }
            }

            var target = try self.makePathPtr(std.mem.span(path.?), true, overwrite_other, false);

            if (target.content == .Dir) {
                log.err("Tried to put tag {s} to {x} but the path is a directory", .{ path.?, payload.ref });
                return error.DirExists;
            }

            // associate new content
            try target.content.Tag.content.hydrate(payload);
            try self.taggedByRef.put(payload.ref, &target.content.Tag.content);
        }

        pub fn mkdir(self: *@This(), path: String) !Dir(Stored) {
            return try self.makePathPtr(path, true, false, true).content.Dir;
        }

        /// assumes that the payload does not have a tag
        pub fn putUntagged(self: *@This(), payload: Payload, merge: bool) !void {
            switch (Payload) {
                decls.SourcesPayload => {
                    std.debug.assert(payload.count == 0 or payload.paths == null);
                },
                else => {
                    std.debug.assert(payload.path == null);
                },
            }

            const maybe_ptr = try self.all.getOrPut(payload.ref);
            if (maybe_ptr.found_existing) {
                if (merge) {
                    inline for (@typeInfo(Payload).Struct.fields) |field| {
                        const source = @field(payload, field.name);
                        if (@typeInfo(@TypeOf(source)) == .Optional) {
                            if (source != null) {
                                @field(maybe_ptr.value_ptr.*, field.name) = source;
                            }
                        } else {
                            @field(maybe_ptr.value_ptr.*, field.name) = source;
                        }
                    }
                } else {
                    return error.TagExists;
                }
            }
            maybe_ptr.value_ptr.* = payload;
        }

        /// dir => remove recursively
        pub fn removeByTag(self: *@This(), path: String, dir: bool) !void {
            const ptr = try self.makePathPtr(path, false, false, false); // also checks for existence
            switch (ptr.content) {
                .Dir => |content_dir| {
                    if (!dir) {
                        return error.DirExists;
                    }
                    var subdirs = content_dir.dirs.iterator();
                    while (subdirs.next()) |subdir| {
                        // remove content of subdirs
                        try self.removeByTag(subdir.key_ptr.*, true);

                        // remove self
                        var files_it = content_dir.files.valueIterator();
                        while (files_it.next()) |file| {
                            std.debug.assert(self.taggedByRef.remove(file.content.ref));
                        }
                        content_dir.deinit(); // removes subdirs and files references
                        // TODO convert to tail-recursion
                        if (content_dir.parent) |parent| {
                            parent.dirs.removeByPtr(ptr.key);
                        }
                    }
                },
                .Tag => |content_tag| { // a single file
                    if (!self.taggedByRef.remove(ptr.content.Tag.content.ref)) {
                        log.err("Tag {d} not found in taggedByRef", .{ptr.content.Tag.content.ref});
                        return error.NotTagged;
                    }
                    content_tag.parent.files.removeByPtr(ptr.key);
                },
            }
        }

        pub fn remove(self: *@This(), ref: usize) !void {
            const removed_maybe = self.all.fetchRemove(ref);
            if (removed_maybe) |removed| {
                switch (Payload) {
                    decls.SourcesPayload => if (removed.value.paths != null) {
                        for (removed.value.paths.?, 0..removed.value.count) |path, i| {
                            _ = i;
                            try self.removeByTag(std.mem.span(path), false);
                        }
                    },
                    else => try self.removeByTag(removed.value.path, false),
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
        /// create_new => creates a new Tag(payload) or Dir(payload) (according to "create_as_dir").
        /// create_as_dir means "if the target does not exist, create it as a directory"
        /// Makes this kind of a universal function
        pub fn makePathPtr(self: *@This(), path: String, create_new: bool, overwrite: bool, create_as_dir: bool) !DirOrFile {
            var path_iterator = std.mem.splitScalar(u8, path, '/');
            var current_dir_entry = try self.tagged.getOrPut(path_iterator.first());
            if (!current_dir_entry.found_existing) {
                // create root-level directory if it does not exist
                current_dir_entry.value_ptr.* = try Dir(Stored).init(self.allocator, null);
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
                            const new_dir = try Dir(Stored).init(self.allocator, current_dir);
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
                                const old_ref = existing_file.value_ptr.content.ref;
                                if (!self.taggedByRef.remove(old_ref)) {
                                    log.err("Tag {d} not found in taggedByRef", .{old_ref});
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
                                existing_file.value_ptr.name = path_part;
                                existing_file.value_ptr.content = Stored{};

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
                                    existing_dir.value_ptr.* = try Dir(Stored).init(self.allocator, current_dir);
                                    return .{
                                        .is_new = true,
                                        .content = .{ .Dir = existing_dir.value_ptr },
                                        .key = existing_dir.key_ptr,
                                    };
                                }

                                log.debug("Making new tag file {s}", .{path_part});
                                existing_file.value_ptr.* = Tag(Stored){
                                    .name = path_part,
                                    .parent = current_dir,
                                    .content = Stored{},
                                };
                                // assign reverse pointer to the tag
                                existing_file.value_ptr.content.tag = existing_file.value_ptr;
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

fn Dir(comptime taggable: type) type {
    return struct {
        const DirMap = std.StringHashMap(Dir(taggable));
        const FileMap = std.StringHashMap(Tag(taggable));
        dirs: DirMap,
        files: FileMap,
        parent: ?*@This(),

        fn init(allocator: std.mem.Allocator, parent: ?*@This()) !@This() {
            return Dir(taggable){
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
/// Encapsulates taggable content but does not own contents inside the taggable
fn Tag(comptime taggable: type) type {
    return struct {
        /// is not duplicated when stored because the memory should be already existing in some Payload.path
        name: String,
        parent: *Dir(taggable),
        content: taggable,
    };
}

// Used just for type resolution
const SourcePayload: decls.SourcesPayload = undefined;
const ProgramPayload: decls.ProgramPayload = undefined;

pub const Shader = struct {
    /// Contrary to decls.SourcePayload this is just a single tagged shader source code.
    pub const Source = struct {
        ref: @TypeOf(SourcePayload.ref) = 0,
        tag: ?*Tag(@This()) = null,
        source: ?CString = null,
        type: @TypeOf(SourcePayload.type) = decls.SourceType.unknown,
        context: ?*const anyopaque = null,
        compile: @TypeOf(SourcePayload.compile) = null,

        /// hydrate a single shader source
        pub fn hydrate(self: *@This(), payload: decls.SourcesPayload) !void {
            std.debug.assert(payload.count == 1);
            // Catches just "ref", "type" and "compile" properties
            inline for (@typeInfo(@TypeOf(payload)).Struct.fields) |field| {
                if (@hasField(@This(), field.name)) {
                    const val = @field(payload, field.name);
                    if (@typeInfo(@TypeOf(val)) == .Optional) {
                        if (val != null) {
                            @field(self.*, field.name) = val.?;
                            log.debug("Assigning field {s} with {any}", .{ field.name, val });
                        }
                    } else {
                        @field(self.*, field.name) = val;
                    }
                }
            }
            // source and context must be individually hydrated
            if (payload.sources != null) {
                self.source = payload.sources.?[0];
            }
            if (payload.contexts != null) {
                self.context = payload.contexts.?[0];
            }
        }

        pub fn toString(self: *const @This()) String {
            return self.type.toExtension();
        }
    };

    pub const Program = struct {
        ref: @TypeOf(ProgramPayload.ref) = 0,
        tag: ?*Tag(Program) = null,
        program: Pipeline = .{ .Null = {} },
        context: @TypeOf(ProgramPayload.context) = null,
        link: @TypeOf(ProgramPayload.link) = null,

        pub fn hydrate(self: *@This(), payload: decls.ProgramPayload) !void {
            inline for (@typeInfo(@TypeOf(payload)).Struct.fields) |field| {
                if (@hasField(@This(), field.name)) {
                    const val = @field(payload, field.name);

                    switch (@TypeOf(val)) {
                        decls.PipelinePayload => {
                            // for the program field we must hydrate the union
                            inline for (@typeInfo(decls.PipelineType).Enum.fields) |enum_field| { // for each of pipeline types
                                // switch on pipeline type
                                if (@intFromEnum(payload.program.type) == enum_field.value) {
                                    if (@hasField(Pipeline, enum_field.name)) {
                                        // source pipeline
                                        const pipeline = @field(payload.program.pipeline, enum_field.name);
                                        var destination_pipeline = @field(self.program, enum_field.name);
                                        log.debug("Assigning field {s} with {any}", .{ enum_field.name, pipeline });
                                        const pipeline_type = @typeInfo(@TypeOf(destination_pipeline));
                                        if (pipeline_type == .Struct) { // It can also be void for the Null type
                                            inline for (pipeline_type.Struct.fields) |result_field| {
                                                const pip_val = @field(pipeline, result_field.name);
                                                @field(destination_pipeline, result_field.name) = if (@typeInfo(@TypeOf(pip_val)) == .Optional) if (pip_val != null) Sources.taggedByRef.get(pip_val.?) else null else Sources.taggedByRef.get(pip_val) orelse {
                                                    log.err("Could not find source {x}", .{pip_val});
                                                    return error.TargetNotFound;
                                                };
                                            }
                                        }
                                    }
                                    break;
                                }
                            }
                        },
                        else => {
                            log.debug("Assigning field {s} with {any}", .{ field.name, val });
                            @field(self.*, field.name) = val;
                        },
                    }
                }
            }
        }

        pub const Pipeline = union(decls.PipelineType) {
            Null: void,
            Rasterize: Rasterize,
            Compute: Compute,
            Ray: Raytrace,

            pub const Rasterize = struct {
                vertex: ?*Source,
                geometry: ?*Source,
                tess_control: ?*Source,
                tess_evaluation: ?*Source,
                fragment: ?*Source,
                task: ?*Source,
                mesh: ?*Source,
            };
            pub const Compute = struct {
                compute: *Source,
            };
            pub const Raytrace = struct {
                raygen: *Source,
                anyhit: ?*Source,
                closesthit: *Source,
                intersection: ?*Source,
                miss: *Source,
                callable: ?*Source,
            };
        };
    };
};
