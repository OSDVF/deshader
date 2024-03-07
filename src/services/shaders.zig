/// Graphics API agnostic storage and interface for shader sources and programs
const std = @import("std");
const builtin = @import("builtin");

const common = @import("../common.zig");
const log = @import("../log.zig").DeshaderLog;
const decls = @import("../declarations/shaders.zig");
const storage = @import("storage.zig");

const String = []const u8;
const CString = [*:0]const u8;
const Storage = storage.Storage;
const Tag = storage.Tag;

pub var Shaders: Storage(*Shader.SourceInterface, void) = undefined;
pub var Programs: Storage(Shader.Program, *Shader.SourceInterface) = undefined;
var g_allocator: std.mem.Allocator = undefined;
var g_breakpoint_last: usize = 0;
/// Maps real absolute paths to virtual workspace paths
/// Warning: when unsetting or setting this variable, no path resolution is done, no paths in storage are updated or synced
/// Serves just as a reference when reading and writing files
pub var workspace_paths: std.StringHashMap(std.StringHashMap(void)) = undefined;
pub fn addWorkspacePath(real: String, virtual: String) !void {
    var entry = try workspace_paths.getOrPut(real);
    if (entry.found_existing) {
        try entry.value_ptr.put(virtual, {});
    } else {
        entry.value_ptr.* = std.StringHashMap(void).init(g_allocator);
        try entry.value_ptr.put(virtual, {});
    }
}

pub fn init(a: std.mem.Allocator) !void {
    Programs = try @TypeOf(Programs).init(a);
    Shaders = try @TypeOf(Shaders).init(a);
    workspace_paths = @TypeOf(workspace_paths).init(a);
    g_allocator = a;
}

// Used just for type resolution
const SourcePayload: decls.SourcesPayload = undefined;
const ProgramPayload: decls.ProgramPayload = undefined;

pub const Breakpoint = struct {
    id: ?usize,
    message: ?String = null,
    line: ?usize = null,
    column: ?usize = null,
    endLine: ?usize = null,
    endColumn: ?usize = null,

    pub fn init() @This() {
        const result = @This(){
            .id = g_breakpoint_last,
        };
        g_breakpoint_last += 1;
        return result;
    }
};

pub const Shader = struct {
    /// Interface for interacting with a single source code part
    /// Note: this is not a source code itself, but a wrapper around it
    pub const SourceInterface = struct {
        ref: @TypeOf(SourcePayload.ref) = 0,
        tag: ?*Tag(*@This()) = null,
        type: @TypeOf(SourcePayload.type) = @enumFromInt(0),
        language: @TypeOf(SourcePayload.language) = @enumFromInt(0),
        /// Can be anything that is needed for the host application
        context: ?*const anyopaque = null,
        compile: @TypeOf(SourcePayload.compile) = null,
        save: @TypeOf(SourcePayload.save) = null,
        /// Line and column
        breakpoints: std.ArrayList(Breakpoint),

        implementation: *anyopaque, // is on heap
        /// The most important part of interface implementation
        getSourceImpl: *const anyopaque,
        deinitImpl: *const anyopaque,

        pub fn toExtension(self: *const @This()) String {
            return self.type.toExtension();
        }

        pub fn deinit(self: *@This()) void {
            @as(*const fn (*const anyopaque) void, @ptrCast(self.deinitImpl))(self.implementation);
        }

        pub fn getSource(self: *@This()) ?String {
            return @as(*const fn (*const anyopaque) ?String, @ptrCast(self.getSourceImpl))(self.implementation);
        }

        pub fn eql(self: *const @This(), other: *const @This()) bool {
            return self.ref == other.ref and self.source == other.source and self.type == other.type and self.context == other.context;
        }
    };

    /// Contrary to decls.SourcePayload this is just a single tagged shader source code.
    /// Contains a copy of the original passed string
    pub const MemorySource = struct {
        super: *SourceInterface,
        source: ?String = null,
        allocator: std.mem.Allocator,

        pub fn fromPayload(allocator: std.mem.Allocator, payload: decls.SourcesPayload, index: usize) !*@This() {
            std.debug.assert(index < payload.count);
            var source: ?String = null;
            if (payload.sources != null) {
                if (payload.lengths) |lens| {
                    source = try allocator.dupe(u8, payload.sources.?[index][0..lens[index]]);
                } else {
                    source = try allocator.dupe(u8, std.mem.span(payload.sources.?[index]));
                }
            }
            const result = try allocator.create(@This());
            const interface = try allocator.create(SourceInterface);
            interface.* = SourceInterface{
                .implementation = result,
                .ref = payload.ref,
                .type = payload.type,
                .breakpoints = @TypeOf(interface.breakpoints).init(allocator),
                .compile = payload.compile,
                .context = if (payload.contexts != null) payload.contexts.?[index] else null,
                .getSourceImpl = &getSource,
                .deinitImpl = &deinit,
            };
            result.* = @This(){
                .allocator = allocator,
                .super = interface,
                .source = source,
            };
            return result;
        }

        pub fn getSource(this: *@This()) ?String {
            return this.source;
        }

        pub fn deinit(this: *@This()) void {
            if (this.source) |s| {
                this.allocator.free(s);
            }
            this.super.breakpoints.deinit();
            this.allocator.destroy(this.super);
            this.allocator.destroy(this);
        }
    };

    pub const Program = struct {
        pub const ShadersRefMap = std.AutoHashMap(usize, *const std.ArrayList(*SourceInterface));
        pub const ShaderIterator = struct {
            program: *const Program,
            shaders: Program.ShadersRefMap.ValueIterator,

            /// Returns the next shader source name and its object. The name is allocated with the allocator
            /// TODO maybe should return all the linked shader sources instead
            pub fn nextAlloc(self: *ShaderIterator, allocator: std.mem.Allocator) error{OutOfMemory}!?struct { name: []const u8, source: *const Shader.SourceInterface } {
                if (self.shaders.next()) |current_targets| {
                    if (findAssociatedSource(current_targets.*.items)) |current| {
                        if (current.tag) |tag| {
                            return .{ .name = try allocator.dupe(u8, tag.name), .source = current };
                        } else {
                            if (self.program.tag) |program_tag| {
                                return .{
                                    .name = try std.mem.concat(allocator, u8, &.{ program_tag.name, current.toExtension() }),
                                    .source = current,
                                };
                            } else {
                                return .{
                                    .name = try std.fmt.allocPrint(allocator, "{d}{s}", .{ self.program.ref, current.toExtension() }),
                                    .source = current,
                                };
                            }
                        }
                    }
                }
                return null;
            }
        };

        ref: @TypeOf(ProgramPayload.ref) = 0,
        tag: ?*Tag(Program) = null,
        /// Ref and sources
        shaders: ?Program.ShadersRefMap = null,
        context: @TypeOf(ProgramPayload.context) = null,
        link: @TypeOf(ProgramPayload.link) = null,

        pub fn deinit(self: *@This()) void {
            if (self.shaders) |*s| {
                s.deinit();
            }
        }

        pub fn eql(self: *const @This(), other: *const @This()) bool {
            if (self.shaders != null and other.shaders != null) {
                if (self.shaders.?.items.len != other.shaders.?.items.len) {
                    return false;
                }
                for (self.shaders.?.items, other.shaders.?.items) |s_ptr, o_ptr| {
                    if (!s_ptr.eql(o_ptr)) {
                        return false;
                    }
                }
            }
            return self.ref == other.ref;
        }

        pub fn listFiles(self: *const @This()) ?Program.ShaderIterator {
            if (self.shaders) |s| {
                return Program.ShaderIterator{
                    .program = self,
                    .shaders = s.valueIterator(),
                };
            } else return null;
        }

        pub fn statFile(_: *const @This(), _: []const u8) storage.StatPayload {
            return storage.StatPayload{
                .type = @intFromEnum(storage.FileType.File),
            };
        }

        const DirOrFile = Storage(@This(), *Shader.SourceInterface).DirOrFile;
        const Nested = @TypeOf(Shaders).StoredTag;
        pub fn makePathAlloc(
            self: *@This(),
            name: String,
            create: bool,
            overwrite: bool,
            create_as_dir: bool,
            allocator: std.mem.Allocator,
        ) !DirOrFile {
            if (create_as_dir or create or overwrite) {
                return error.NotSupported;
            } else if (self.shaders) |s| {
                var iter = s.valueIterator();
                var name_iter = std.mem.splitScalar(u8, name, '.');
                const name_name = name_iter.first();
                const name_extension = name_iter.rest();
                while (iter.next()) |current_targets| {
                    if (findAssociatedSourceMutable(current_targets.*.items)) |current| {
                        if (current.*.tag) |tag| {
                            if (std.mem.eql(u8, name, tag.name)) {
                                var dupedTag = tag.*;
                                dupedTag.targets = try common.dupeHashMap(Nested.Targets, allocator, tag.*.targets);
                                return DirOrFile{
                                    .content = .{ .Nested = dupedTag },
                                    .is_new = false,
                                    .key = name,
                                };
                            }
                        } else {
                            // no tagged shader with this name was found. Try to find unnamed shaders with names derived from the program
                            var stat: storage.Stat = undefined;
                            if (blk: {
                                if (self.tag) |program_tag| {
                                    stat = program_tag.stat;
                                    break :blk std.mem.eql(u8, name_name, program_tag.name); // will produce ./programName.shaderExtension
                                } else if (std.fmt.parseInt(usize, name_name, 0)) |parsed| {
                                    stat = storage.Stat.now(); //TODO how to store the real stat?
                                    break :blk parsed == self.ref; // will produce ./programRefNumber.shaderExtension
                                } else |_| {
                                    break :blk false;
                                }
                            }) {
                                if (std.mem.eql(u8, name_extension, current.*.toExtension()[1..])) {
                                    var newTargets = Nested.Targets.init(allocator);
                                    try newTargets.put(current, {});
                                    return DirOrFile{
                                        .content = .{
                                            .Nested = Nested{
                                                .targets = newTargets,
                                                .parent = null,
                                                .stat = stat,
                                                .name = name,
                                            },
                                        },
                                        .is_new = false,
                                        .key = name,
                                    };
                                }
                            }
                        }
                    }
                }
            }
            return error.TargetNotFound;
        }

        /// find shader entry point among other shaders sources in the shader
        /// TODO search for main instead of searching for the source which does not have any symlinks
        fn findMainShaderSource(sources: []*const Shader.SourceInterface) ?*const Shader.SourceInterface {
            for (sources) |s| {
                if (s.tag) |tag| {
                    if (tag.targets.count() == 1) { // The tag is only used by this program (not symlinked to some other program)
                        return s;
                    }
                }
            }
            return null;
        }

        /// find the shader source tag which is contained in this program
        /// TODO does it really work like the first is always the correct target?
        fn findAssociatedSource(sources: []*const Shader.SourceInterface) ?*const Shader.SourceInterface {
            for (sources) |s| {
                return s;
            }
            return null;
        }

        /// find the shader source tag which is contained in this program
        /// TODO does it really work like the first is always the correct target?
        fn findAssociatedSourceMutable(sources: []*Shader.SourceInterface) ?**Shader.SourceInterface {
            for (sources) |*s| {
                return s;
            }
            return null;
        }

        pub const Pipeline = union(decls.PipelineType) {
            Null: void,
            Rasterize: Rasterize,
            Compute: Compute,
            Ray: Raytrace,

            pub const Rasterize = struct {
                vertex: ?*SourceInterface,
                geometry: ?*SourceInterface,
                tess_control: ?*SourceInterface,
                tess_evaluation: ?*SourceInterface,
                fragment: ?*SourceInterface,
                task: ?*SourceInterface,
                mesh: ?*SourceInterface,
            };
            pub const Compute = struct {
                compute: *SourceInterface,
            };
            pub const Raytrace = struct {
                raygen: *SourceInterface,
                anyhit: ?*SourceInterface,
                closesthit: *SourceInterface,
                intersection: ?*SourceInterface,
                miss: *SourceInterface,
                callable: ?*SourceInterface,
            };
        };
    };
};

//
// Helper functions
//

pub fn sourcesCreateUntagged(sources: decls.SourcesPayload) !void {
    const new_stored = try Shaders.allocator.alloc(*Shader.SourceInterface, sources.count);
    defer Shaders.allocator.free(new_stored);
    for (new_stored, 0..) |*stored, i| {
        stored.* = (try Shader.MemorySource.fromPayload(Shaders.allocator, sources, i)).super;
    }
    try Shaders.createUntagged(new_stored);
}

pub fn sourceReplaceUntagged(sources: decls.SourcesPayload) !void {
    const existing = Shaders.all.getPtr(sources.ref);
    if (existing) |e_sources| {
        if (e_sources.items.len != sources.count) {
            try e_sources.resize(sources.count);
        }
        for (e_sources.items, 0..) |*item, i| {
            const data = try Shader.MemorySource.fromPayload(Shaders.allocator, sources, i);
            defer data.deinit();
            const item_impl: *Shader.MemorySource = @alignCast(@ptrCast(item.*.implementation)); //TODO generic
            if (item_impl.source == null and data.source != null) {
                item_impl.source = try item_impl.allocator.dupe(u8, data.source.?);
            }
        }
    }
}

pub fn sourceType(ref: usize, @"type": decls.SourceType) !void {
    const maybe_sources = Shaders.all.get(ref);

    if (maybe_sources) |sources| {
        for (sources.items) |*item| {
            item.type = @"type";
        }
    } else {
        return error.TargetNotFound;
    }
}

pub fn sourceCompileFunc(ref: usize, func: @TypeOf((Shader.Source{}).compile)) !void {
    const maybe_sources = Shaders.all.get(ref);

    if (maybe_sources) |sources| {
        for (sources.items) |*item| {
            item.compile = func;
        }
    } else {
        return error.TargetNotFound;
    }
}

pub fn sourceContext(ref: usize, source_index: usize, context: *const anyopaque) !void {
    const maybe_sources = Shaders.all.get(ref);

    if (maybe_sources) |sources| {
        std.debug.assert(sources.contexts != null);
        sources.contexts[source_index] = context;
    } else {
        return error.TargetNotFound;
    }
}

/// Change existing source part. Does not allocate any new memory or reallocate existing source array
pub fn sourceSource(ref: usize, source_index: usize, source_code: CString) !void {
    const maybe_sources = Shaders.all.get(ref);

    if (maybe_sources) |sources| {
        std.debug.assert(sources.items.len != 0);
        sources.items[source_index].source = source_code;
    } else {
        return error.TargetNotFound;
    }
}

/// With sources
pub fn programCreateUntagged(program: decls.ProgramPayload) !void {
    try Programs.appendUntagged(Shader.Program{
        .ref = program.ref,
        .context = program.context,
        .link = program.link,
        .shaders = null,
    });

    if (program.shaders) |shaders| {
        std.debug.assert(program.count > 0);
        for (shaders[0..program.count]) |shader| {
            try programAttachSource(program.ref, shader);
        }
    }
}

pub fn programAttachSource(ref: usize, source: usize) !void {
    if (Shaders.all.getEntry(source)) |existing_source| {
        if (Programs.all.getPtr(ref)) |existing_program| {
            std.debug.assert(existing_program.items.len == 1);
            var program = &existing_program.items[0]; // note the reference
            if (program.shaders == null) {
                program.shaders = Shader.Program.ShadersRefMap.init(existing_program.allocator);
            }
            try program.shaders.?.put(existing_source.key_ptr.*, existing_source.value_ptr);
        } else {
            return error.TargetNotFound;
        }
    } else {
        return error.TargetNotFound;
    }
}
