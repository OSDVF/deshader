const std = @import("std");
const builtin = @import("builtin");

const log = @import("../log.zig").DeshaderLog;
const decls = @import("../declarations/shaders.zig");
const storage = @import("storage.zig");

const String = []const u8;
const CString = [*:0]const u8;
const Storage = storage.Storage;
const Tag = storage.Tag;

pub var Shaders: Storage(Shader.Source) = undefined;
pub var Programs: Storage(Shader.Program) = undefined;

// Used just for type resolution
const SourcePayload: decls.SourcesPayload = undefined;
const ProgramPayload: decls.ProgramPayload = undefined;

pub fn mergeObj(comptime T: type, self: *T, payload: T) !void {
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
}

pub const Shader = struct {
    /// Contrary to decls.SourcePayload this is just a single tagged shader source code.
    pub const Source = struct {
        ref: @TypeOf(SourcePayload.ref) = 0,
        tag: ?*Tag(@This()) = null,
        source: ?String = null,
        type: @TypeOf(SourcePayload.type) = decls.SourceType.unknown,
        context: ?*const anyopaque = null,
        compile: @TypeOf(SourcePayload.compile) = null,
        save: @TypeOf(SourcePayload.save) = null,

        pub fn fromPayload(payload: decls.SourcesPayload, index: usize) @This() {
            std.debug.assert(index < payload.count);
            var source: ?String = null;
            if (payload.sources != null) {
                if (payload.lengths) |lens| {
                    source = payload.sources.?[index][0..lens[index]];
                } else {
                    source = std.mem.span(payload.sources.?[index]);
                }
            }
            return @This(){
                .ref = payload.ref,
                .type = payload.type,
                .compile = payload.compile,
                .context = if (payload.contexts != null) payload.contexts.?[index] else null,
                .source = source,
            };
        }

        pub fn toString(self: *const @This()) String {
            return self.type.toExtension();
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn eql(self: *const @This(), other: *const @This()) bool {
            return self.ref == other.ref and self.source == other.source and self.type == other.type and self.context == other.context;
        }
    };

    pub const Program = struct {
        pub const Shaders = std.ArrayList(Storage(Shader.Source).RefMap.Entry);
        ref: @TypeOf(ProgramPayload.ref) = 0,
        tag: ?*Tag(Program) = null,
        /// Ref and sources
        shaders: ?Program.Shaders = null,
        context: @TypeOf(ProgramPayload.context) = null,
        link: @TypeOf(ProgramPayload.link) = null,

        pub fn deinit(self: *@This()) void {
            if (self.shaders) |s| {
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

//
// Helper functions
//

pub fn sourcesCreateUntagged(sources: decls.SourcesPayload) !void {
    const new_stored = try Shaders.allocator.alloc(Shader.Source, sources.count);
    for (new_stored, 0..) |*stored, i| {
        stored.* = Shader.Source.fromPayload(sources, i);
    }
    try Shaders.createUntagged(new_stored);
}

pub fn sourceReplaceUntagged(sources: decls.SourcesPayload) !void {
    var existing = Shaders.all.getPtr(sources.ref);
    if (existing) |e_sources| {
        if (e_sources.items.len != sources.count) {
            try e_sources.resize(sources.count);
        }
        for (e_sources.items, 0..) |*item, i| {
            try mergeObj(@TypeOf(item.*), item, Shader.Source.fromPayload(sources, i));
        }
    }
}

pub fn sourceType(ref: usize, @"type": decls.SourceType) !void {
    var maybe_sources = Shaders.all.get(ref);

    if (maybe_sources) |sources| {
        for (sources.items) |*item| {
            item.type = @"type";
        }
    } else {
        return error.TargetNotFound;
    }
}

pub fn sourceCompileFunc(ref: usize, func: @TypeOf((Shader.Source{}).compile)) !void {
    var maybe_sources = Shaders.all.get(ref);

    if (maybe_sources) |sources| {
        for (sources.items) |*item| {
            item.compile = func;
        }
    } else {
        return error.TargetNotFound;
    }
}

pub fn sourceContext(ref: usize, source_index: usize, context: *const anyopaque) !void {
    var maybe_sources = Shaders.all.get(ref);

    if (maybe_sources) |sources| {
        std.debug.assert(sources.contexts != null);
        sources.contexts[source_index] = context;
    } else {
        return error.TargetNotFound;
    }
}

/// Change existing source part. Does not allocate any new memory or reallocate existing source array
pub fn sourceSource(ref: usize, source_index: usize, source_code: CString) !void {
    var maybe_sources = Shaders.all.get(ref);

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
                program.shaders = Shader.Program.Shaders.init(existing_program.allocator);
            }
            try program.shaders.?.append(existing_source);
        } else {
            return error.TargetNotFound;
        }
    } else {
        return error.TargetNotFound;
    }
}
