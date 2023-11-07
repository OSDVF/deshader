const std = @import("std");

const String = []const u8;
const CString = [*:0]const u8;
const log = @import("../log.zig").DeshaderLog;
const decls = @import("../declarations/shaders.zig");

pub var Sources: Storage(Shader.Source, decls.SourcePayload) = undefined;
pub var Programs: Storage(Shader.Program, decls.ProgramPayload) = undefined;

/// Provides virtual shader storage
/// All detected shaders are stored here with their tags
/// Stored type must have a .tag field with the type ?*Tag(Stored) and a hydrate(Payload) method
/// Payload type must have a .path field with the type ?CString
/// Both the tyes must have
///    .ref: ?*const anyopaque
pub fn Storage(comptime Stored: type, comptime Payload: type) type {
    return struct {
        pub const TagMap = std.StringHashMap(Dir(Stored));
        pub const RefMap = std.AutoHashMap(*const anyopaque, Stored);
        tagged: TagMap, //mapped by tag
        all: RefMap, //mapped by platform pointer
        allocator: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator) !@This() {
            return @This(){
                .allocator = alloc,
                .tagged = TagMap.init(alloc),
                .all = RefMap.init(alloc),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.tagged.deinit();
            self.all.deinit();
        }

        pub fn addTagged(self: *@This(), payload: Payload, move: bool, overwrite_other: bool) !void {
            std.debug.assert(payload.path != null);
            // check for all
            const maybe_ptr = try self.all.getOrPut(payload.ref);
            if (maybe_ptr.found_existing) {
                if (!move) {
                    log.err("Tried to put tag {s} to {x} but the pointer is already tagged", .{ payload.path.?, payload.ref });
                    return error.TagExists;
                }
            }

            var target = try self.makePathPtr(std.mem.span(payload.path.?), true, overwrite_other, false);

            if (target.content == .Dir) {
                log.err("Tried to put tag {s} to {x} but the path is a directory", .{ payload.path.?, payload.ref });
                return error.DirExists;
            }

            if (!target.is_new) {
                if (overwrite_other) {
                    try removeTag(target.content.Tag);
                } else {
                    log.err("Tried to put tag {s} to {x} but the path is already tagged", .{ payload.path.?, payload.ref });
                    return error.AlreadyTagged;
                }
            }

            // associate new content
            try target.content.Tag.content.hydrate(payload);
        }

        /// assumes that the payload does not have a tag
        pub fn addUntagged(self: *@This(), ref: *const anyopaque, payload: ?Payload) !void {
            std.debug.assert(payload == null or payload.?.path == null);

            const maybe_ptr = try self.all.getOrPut(ref);
            if (maybe_ptr.found_existing) {
                return error.TagExists;
            }
            // assign payload values to the stored struct
            if (payload != null) {
                try maybe_ptr.value_ptr.hydrate(payload.?);
            }
        }

        pub fn remove(self: *@This(), path: String, dir: bool) !void {
            const ptr = try self.makePathPtr(path, false, false, false);
            switch (ptr.content) {
                .Dir => |content_dir| {
                    if (!dir) {
                        return error.DirExists;
                    }
                    var subdirs = content_dir.dirs.iterator();
                    while (subdirs.next()) |subdir| {
                        // remove subdirs
                        try self.remove(subdir.key_ptr.*, true);
                        // TODO convert to tail-recursion
                        // remove self
                        content_dir.deinit();
                        if (content_dir.parent) |parent| {
                            parent.dirs.removeByPtr(ptr.key);
                        }
                    }
                },
                .Tag => |content_tag| {
                    content_tag.parent.files.removeByPtr(ptr.key);
                },
            }
        }

        fn removeTag(existing_tag: *Tag(Stored)) !void {
            log.debug("Removing tag {s} from source {x}", .{ existing_tag.name, existing_tag.content.ref });
            // remove existing tag
            if (!existing_tag.parent.files.remove(existing_tag.name)) {
                log.err("Tag {s} not found in parent directory", .{existing_tag.name});
                return error.NotTagged;
            }
            // remove tag from the payload
            existing_tag.content.tag = null;
        }

        const DirOrFile = struct {
            is_new: bool,
            content: union(enum) {
                Tag: *Tag(Stored),
                Dir: *Dir(Stored),
            },
            key: *String,
        };

        /// Gets an existing tag or directory, or creates a new Tag(payload) or Dir(payload) (according to is_dir).
        /// create_dir means "if the target does not exist, create it as a directory"
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
                            log.debug("Recursively creating director {s}", .{path_part});
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

                                try removeTag(existing_file.value_ptr);

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
                                    .content = undefined,
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
        name: String,
        parent: *Dir(taggable),
        content: taggable,
    };
}

// Used just for type resolution
const SourcePayload: decls.SourcePayload = undefined;
const ProgramPayload: decls.ProgramPayload = undefined;

pub const Shader = struct {
    pub const Source = struct {
        tag: ?*Tag(@This()),
        source: @TypeOf(SourcePayload.source) = undefined,
        ref: @TypeOf(SourcePayload.ref) = undefined,
        context: @TypeOf(SourcePayload.context) = undefined,
        compile: @TypeOf(SourcePayload.compile) = undefined,

        pub fn hydrate(self: *@This(), payload: decls.SourcePayload) !void {
            inline for (@typeInfo(@TypeOf(payload)).Struct.fields) |field| {
                if (@hasField(@This(), field.name)) {
                    const val = @field(payload, field.name);
                    log.debug("Assigning field {s} with {any}", .{ field.name, val });
                    @field(self.*, field.name) = val;
                }
            }
        }
    };

    pub const Program = struct {
        tag: ?*Tag(Program) = null,
        ref: @TypeOf(ProgramPayload.ref) = undefined,
        context: @TypeOf(ProgramPayload.context) = undefined,
        link: @TypeOf(ProgramPayload.link) = undefined,
        program: Pipeline = undefined,

        pub fn hydrate(self: *@This(), payload: decls.ProgramPayload) !void {
            inline for (@typeInfo(@TypeOf(payload)).Struct.fields) |field| {
                if (@hasField(@This(), field.name)) {
                    const val = @field(payload, field.name);

                    switch (@TypeOf(val)) {
                        decls.PipelinePayload => {
                            // for the program field we must hydrate the union
                            inline for (@typeInfo(decls.PipelineType).Enum.fields) |enum_field| {
                                if (@intFromEnum(payload.program.type) == enum_field.value) {
                                    if (@hasField(Pipeline, enum_field.name)) {
                                        const pipeline = @field(payload.program.pipeline, enum_field.name);
                                        var result_pipeline = @field(self.program, enum_field.name);
                                        log.debug("Assigning field {s} with {any}", .{ enum_field.name, pipeline });
                                        inline for (@typeInfo(@TypeOf(result_pipeline)).Struct.fields) |result_field| {
                                            const pip_val = @field(pipeline, result_field.name);
                                            @field(result_pipeline, result_field.name) = if (@typeInfo(@TypeOf(pip_val)) == .Optional) if (pip_val != null) Sources.all.get(pip_val.?) else null else Sources.all.get(pip_val) orelse {
                                                log.err("Could not find source {s}", .{pip_val});
                                                return error.TargetNotFound;
                                            };
                                        }
                                    }
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
            Rasterize: Rasterize,
            Compute: Compute,
            Ray: Raytrace,

            pub const Rasterize = struct {
                vertex: ?Source,
                geometry: ?Source,
                tesselation_control: ?Source,
                tesselation_evaluation: ?Source,
                fragment: ?Source,
            };
            pub const Compute = struct {
                source: Source,
            };
            pub const Raytrace = struct {
                generation: Source,
                any_hit: ?Source,
                closest_hit: Source,
                intersection: ?Source,
                miss: Source,
            };
        };
    };
};
