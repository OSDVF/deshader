/// Graphics API agnostic storage and interface for shader sources and programs
const std = @import("std");
const builtin = @import("builtin");

const log = @import("../log.zig").DeshaderLog;
const decls = @import("../declarations/shaders.zig");
const storage = @import("storage.zig");

const String = []const u8;
const CString = [*:0]const u8;
const Storage = storage.Storage;
const Tag = storage.Tag;

pub var Shaders: Storage(*Shader.SourceInterface) = undefined;
pub var Programs: Storage(Shader.Program) = undefined;
var g_allocator: std.mem.Allocator = undefined;
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

pub fn mergePayload(comptime T: type, self: T, payload: T) !void {
    comptime var inner = @typeInfo(@TypeOf(payload));
    inline while (inner == .Optional or inner == .Pointer) {
        if (inner == .Optional) {
            inner = @typeInfo(inner.Optional.child);
        } else {
            inner = @typeInfo(inner.Pointer.child);
        }
    }
    inline for (inner.Struct.fields) |field| {
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
        breakpoints: std.ArrayList(std.meta.Tuple(&.{ usize, usize })),

        implementation: *anyopaque, // is on heap
        /// The most important part of interface implementation
        getSourceImpl: *const anyopaque,
        deinitImpl: *const anyopaque,

        pub fn toString(self: *const @This()) String {
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
        pub const Shaders = std.ArrayList(Storage(*Shader.SourceInterface).RefMap.Entry);
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
            try mergePayload(@TypeOf(item.*), item.*, data.super);
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
