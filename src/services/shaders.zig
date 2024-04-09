//! Graphics API agnostic virtual storage and instrumentation interface for shader sources and programs
//! Should not contain any gl* or vk* calls
const std = @import("std");
const builtin = @import("builtin");
const analyzer = @import("glsl_analyzer");

const common = @import("../common.zig");
const log = @import("../log.zig").DeshaderLog;
const decls = @import("../declarations/shaders.zig");
const storage = @import("storage.zig");
const debug = @import("debug.zig");
const instrumentation = @import("instrumentation.zig");
const ArrayBufMap = @import("array_buf_map.zig").ArrayBufMap;

const glslang = @cImport({
    @cInclude("glslang/Include/glslang_c_interface.h");
    @cInclude("glslang/Public/resource_limits_c.h");
});

const Service = @This();
pub var instance = Service{}; // global instance. Should be used only outside of the module. The module itself should not depend on it.

const String = []const u8;
const CString = [*:0]const u8;
const Storage = storage.Storage;
const Tag = storage.Tag;

pub const VirtualDir = union(enum) {
    pub const ProgramDir = *Storage(Shader.Program, *Shader.SourceInterface).StoredDir;
    pub const ShaderDir = *Storage(*Shader.SourceInterface, void).StoredDir;
    pub const Set = std.AutoArrayHashMapUnmanaged(VirtualDir, void);

    Program: ProgramDir,
    Shader: ShaderDir,

    pub fn physical(self: *const @This()) *?String {
        return switch (self.*) {
            .Program => |d| &d.physical,
            .Shader => |d| &d.physical,
        };
    }
};

/// Represents a virtual resource path
pub const GenericLocator = union(enum) {
    programs: struct {
        /// null means untagged root
        program: ?storage.Locator,
        source: ?storage.Locator,
    },
    /// null means untagged root
    sources: ?storage.Locator,

    pub const sources_path = "/sources";
    pub const programs_path = "/programs";

    pub fn parse(path: String) !GenericLocator {
        if (std.mem.startsWith(u8, path, programs_path)) {
            if (std.mem.lastIndexOfScalar(u8, path, '/')) |last_slash| {
                if (last_slash == 0) return .{ .programs = .{ .program = .{ .tagged = "" }, .source = null } };

                const program_locator = try storage.Locator.parse(path[programs_path.len..last_slash]);
                const source_locator: ?storage.Locator = blk: {
                    if (path.len <= last_slash + 1) break :blk null;

                    const last_dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
                    if (last_dot > last_slash + 1) {
                        if (std.fmt.parseInt(storage.DoubleUsize, path[last_slash + 1 .. last_dot], 10) catch null) |combined| {
                            break :blk storage.Locator.untagged(combined);
                        }
                    }
                    break :blk try storage.Locator.parse(path[last_slash + 1 ..]);
                };

                return .{ .programs = .{ .program = program_locator, .source = source_locator } };
            }
            return error.InvalidPath; // that means something like programs/asd.asd
        } else if (std.mem.startsWith(u8, path, sources_path)) {
            if (path.len == sources_path.len) return .{ .sources = .{ .tagged = "" } };
            return .{ .sources = try storage.Locator.parse(path[sources_path.len..]) };
        } else return error.InvalidPath;
    }
};

//
// Breakpoints
//
/// line must be defined at least.
pub const Breakpoint = struct {
    id: ?usize = null,
    verified: bool = false,
    message: ?String = null,
    line: usize,
    column: ?usize = null,
    endLine: ?usize = null,
    endColumn: ?usize = null,
    source: ?*const Shader.SourceInterface = null,

    /// `source.path` must be freed if not null
    pub fn toDAPAlloc(self: @This(), allocator: std.mem.Allocator, program: ?*const Shader.Program, part_index: usize) !debug.Breakpoint {
        return debug.Breakpoint{
            .id = self.id,
            .verified = true,
            .message = self.message,
            .line = self.line,
            .column = self.column,
            .endLine = self.endLine,
            .endColumn = self.endColumn,
            .path = if (self.source) |s| try s.toDAPAlloc(allocator, program, part_index) else return error.NoSource,
        };
    }
};

//
// Workspaces functionality
//

pub fn getDirByLocator(service: *@This(), locator: GenericLocator) !?VirtualDir {
    return switch (locator) {
        .sources => |s| if (try service.Shaders.getDirByPath((s orelse return error.TargetNotFound).tagged)) |d| .{ .Shader = d } else null,
        .programs => |p| if (try service.Programs.getDirByPath((p.program orelse return error.TargetNotFound).tagged)) |d| .{ .Program = d } else null,
    };
}

/// Maps real absolute directory paths to virtual storage paths
/// *NOTE: when unsetting or setting path mappings, virtual paths must exist. Physical paths are not validated in any way.*
/// physical paths can be mapped to multiple virtual paths but not vice versa
pub fn mapPhysicalToVirtual(service: *@This(), physical: String, virtual: GenericLocator) !void {
    // check for parent overlap
    // TODO more effective

    const entry = try service.physical_to_virtual.getOrPut(physical);
    if (!entry.found_existing) {
        entry.value_ptr.* = VirtualDir.Set{};
    }

    const virtual_dir = try service.getDirByLocator(virtual);
    if (virtual_dir) |dir| {
        if (dir.physical().*) |existing_phys| {
            service.allocator.free(existing_phys);
        }
        dir.physical().* = entry.key_ptr.*;
        _ = try entry.value_ptr.getOrPut(service.allocator, dir); // means 'put' effectively on set-like hashmaps
    }
}

pub fn clearWorkspacePaths(service: *@This()) void {
    for (service.physical_to_virtual.hash_map.values()) |*val| {
        val.deinit(service.allocator);
    }
    service.physical_to_virtual.clearAndFree();
}

/// When `virtual` is null, all virtual paths associated with the physical path will be removed
pub fn removeWorkspacePath(service: *@This(), real: String, virtual: ?GenericLocator) !bool {
    const virtual_dir = if (virtual) |v| try service.getDirByLocator(v) else null;

    if (service.physical_to_virtual.getPtr(real)) |virtual_dirs| {
        const result = if (virtual_dir) |v|
            virtual_dirs.swapRemove(v)
        else
            false;

        if (virtual_dirs.count() == 0 or virtual == null) {
            virtual_dirs.deinit(service.allocator);
            return service.physical_to_virtual.remove(real);
        }

        return result;
    }
    return false;
}

const DirOrFile = union(enum) {
    Dir: std.fs.Dir,
    File: std.fs.File,
};

fn openDirOrFile(parent: std.fs.Dir, name: String) !DirOrFile {
    if (parent.openFile(name, .{})) |file| {
        return .{ .File = file };
    } else |_| if (parent.openDir(name, .{})) |dir| {
        return .{ .Dir = dir };
    } else |_| {
        return error.TargetNotFound;
    }
}

fn ChildOrT(comptime t: type) type {
    switch (@typeInfo(t)) {
        .Pointer => |p| return p.child,
        else => return t,
    }
}

pub fn isNesting(comptime t: type) bool {
    return @hasDecl(ChildOrT(t), "getNested");
}

fn statStorage(stor: anytype, locator: ?storage.Locator, nested: ?storage.Locator) !storage.StatPayload {
    switch (locator orelse storage.Locator{ .untagged = .{ .ref = 0, .part = 0 } }) {
        .untagged => |combined| return if (locator == null)
            try storage.Stat.now().toPayload(.Directory, 0)
        else if (stor.all.get(combined.ref)) |parts| blk: {
            const item = parts.items[combined.part];
            break :blk item.stat.toPayload(
                storage.FileType.File,
                item.lenOr0(),
            );
        } else error.TargetNotFound,
        .tagged => |tagged| {
            var path_it = std.mem.splitScalar(u8, tagged, '/');
            var dir = stor.tagged_root;
            if (std.mem.eql(u8, tagged, "") and nested == null) return dir.stat.toPayload(.Directory, 0);
            var last_part = path_it.first();

            var last_was_dir = false;
            while (path_it.next()) |part| {
                if (dir.dirs.get(part)) |subdir| {
                    dir = subdir;
                    if (path_it.peek() == null) {
                        last_was_dir = true;
                    }
                } else {
                    last_part = part;
                    break;
                }
            }

            if (last_was_dir) {
                const v_stat = dir.stat;
                if (dir.physical) |physical| {
                    var physical_dir = try std.fs.openDirAbsolute(physical, .{});
                    // traverse physical directory tree
                    while (path_it.next()) |part| {
                        switch (try openDirOrFile(physical_dir, part)) {
                            .File => |file| { // NOTE: silently follows physical symlinks
                                const f_stat = try file.stat();
                                return storage.StatPayload.fromPhysical(f_stat, storage.FileType.File);
                            },
                            .Dir => |p_dir| {
                                if (path_it.peek() == null) {
                                    return storage.StatPayload.fromPhysical(try p_dir.stat(), storage.FileType.Directory);
                                }
                                physical_dir = p_dir;
                            },
                        }
                    }
                }
                return v_stat.toPayload(.Directory, 0);
            }
            if (dir.files.get(last_part)) |file| {
                const is_nesting = comptime isNesting(@TypeOf(file.target.*));
                if (nested != null and is_nesting) {
                    const stage = try file.target.getNested(nested.?);
                    return stage.content.Nested.stat.toPayload(.File, stage.content.Nested.lenOr0());
                } else {
                    return file.target.*.stat.toPayload(if (is_nesting) .Directory else .File, file.target.*.lenOr0());
                }
            }
            return error.TargetNotFound;
        },
    }
}

pub fn stat(self: *@This(), locator: GenericLocator) !storage.StatPayload {
    switch (locator) {
        .sources => |sources| {
            return statStorage(self.Shaders, sources, null);
        },
        .programs => |programs| {
            return statStorage(self.Programs, programs.program, programs.source);
        },
    }
}

//
// Data breakpoints
//
pub const Expression = String;
pub const Data = struct {
    pub const Id = String;
    accessType: debug.DataBreakpoint.AccessType,
    description: String,
};
pub const StoredDataBreakpoint = struct {
    accessType: debug.DataBreakpoint.AccessType,
    condition: ?String,
    /// An expression that controls how many hits of the breakpoint are ignored.
    /// The debug adapter is expected to interpret the expression as needed.
    hitCondition: ?String,
};
pub fn setDataBreakpoint(service: *@This(), bp: debug.DataBreakpoint) !debug.DataBreakpoint {
    if (service.data_breakpoints.contains(bp.dataId)) {
        return error.AlreadyExists;
    } else if (!service.available_data.contains(bp.dataId)) {
        return error.TargetNotFound;
    } else {
        try service.data_breakpoints.put(service.allocator, bp.dataId, .{
            .accessType = bp.accessType,
            .condition = bp.condition,
            .hitCondition = bp.hitCondition,
        });
        return bp;
    }
}
pub fn clearDataBreakpoints(service: *@This()) void {
    service.data_breakpoints.clearAndFree(service.allocator);
}
pub const CompileFunc = *const fn (program: Shader.Program, stage: usize, source: String) anyerror!void;

available_data: std.StringHashMapUnmanaged(Data) = .{},
data_breakpoints: std.StringHashMapUnmanaged(StoredDataBreakpoint) = .{},
/// IDs of shader, indexes of part, IDs of breakpoints that were not yet sent to the debug adapter. Free for usage by external code (e.g. gl_shaders module)
breakpoints_to_send: std.ArrayListUnmanaged(struct { usize, usize, usize }) = .{},

/// Workspace paths are like "include path" mappings
/// Maps one to many [fs directory]<=>[deshader virtual directories] (hence the two complementary hashmaps)
/// If a tagged shader (or a shader nested in a program) is found in a workspace path, it can be saved or read from the physical storage
/// TODO watch the filesystem
physical_to_virtual: ArrayBufMap(VirtualDir.Set) = undefined,

Shaders: Storage(*Shader.SourceInterface, void) = undefined,
Programs: Storage(Shader.Program, *Shader.SourceInterface) = undefined,
allocator: std.mem.Allocator = undefined,
debugging: bool = false, // TODO per-context or per-thread?
revert_requested: bool = false, // set by the command listener thread, read by the drawing thread

pub fn init(service: *@This(), a: std.mem.Allocator) !void {
    service.Programs = try @TypeOf(service.Programs).init(a);
    service.Shaders = try @TypeOf(service.Shaders).init(a);
    service.physical_to_virtual = ArrayBufMap(VirtualDir.Set).init(a);
    service.allocator = a;
    if (glslang.glslang_initialize_process() == 0) {
        return error.GLSLang;
    }
}

pub fn deinit(service: *@This()) void {
    service.Programs.deinit(.{});
    service.Shaders.deinit(.{});
    service.data_breakpoints.deinit(service.allocator);
    service.available_data.deinit(service.allocator);
    service.physical_to_virtual.deinit();
    service.breakpoints_to_send.deinit(service.allocator);

    glslang.glslang_finalize_process();
}

pub const Threads = struct {
    dimensions: [3]usize,
    id: usize,
    name: String,
    type: String,

    pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(self.type);
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("dimensions");
        try jw.beginArray();
        for (self.dimensions) |d| {
            if (d == 0) {
                break;
            }
            try jw.write(d);
        }
        try jw.endArray();
        try jw.endObject();
    }

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub fn listThreads(self: *const @This(), allocator: std.mem.Allocator) ![]Threads {
    var threads = std.ArrayListUnmanaged(Threads){};
    var p_it = self.Programs.all.iterator();
    while (p_it.next()) |program_entry| {
        const program = &program_entry.value_ptr.items[0];
        var c_it = program.cached.iterator();
        while (c_it.next()) |cached_entry| {
            const params: Shader.InstrumentationParams = cached_entry.value_ptr.params;
            if (program.stages.?.get(cached_entry.key_ptr.*)) |shader_parts| {
                const shader: *Shader.SourceInterface = shader_parts.items[0]; // TODO is it bad when the shader is dirty?
                try threads.append(allocator, Threads{
                    .id = cached_entry.key_ptr.* << 16,
                    .type = @tagName(shader.type),
                    .name = try shader.basenameAlloc(allocator, 0),
                    .dimensions = switch (shader.type) {
                        .gl_geometry, .gl_vertex, .gl_tess_control, .gl_tess_evaluation, .vk_vertex, .vk_tess_control, .vk_tess_evaluation, .vk_geometry => .{ params.vertices, 0, 0 }, //TODO count output primitives
                        .gl_fragment, .vk_fragment => .{ params.screen[0], params.screen[1], 0 },
                        .gl_compute, .gl_mesh, .gl_task, .vk_compute, .vk_task, .vk_mesh => params.compute,
                        .vk_raygen, .vk_anyhit, .vk_closesthit, .vk_miss, .vk_intersection, .vk_callable, .unknown => unreachable, //TODO raytracing
                    },
                });
            }
        }
    }
    return threads.toOwnedSlice(allocator);
}

/// Empty variables used just for type resolution
const SourcePayload: decls.SourcesPayload = undefined;
const ProgramPayload: decls.ProgramPayload = undefined;

pub const InstrumentationResult = struct {
    invalidated: bool,
    outputs: std.AutoHashMapUnmanaged(usize, *instrumentation.Result.Outputs),
};

pub const Shader = struct {
    /// Interface for interacting with a single source code part
    /// Note: this is not a source code itself, but a wrapper around it
    /// TODO: find a better way to represent source parts vs whole shader sources
    pub const SourceInterface = struct {
        ref: @TypeOf(SourcePayload.ref) = 0,
        tags: std.StringArrayHashMapUnmanaged(*Tag(*@This())) = .{},
        type: @TypeOf(SourcePayload.type) = @enumFromInt(0),
        language: @TypeOf(SourcePayload.language) = @enumFromInt(0),
        /// Can be anything that is needed for the host application
        context: ?*const anyopaque = null,
        /// Function that compiles the (instrumented) shader within the host application context. Defaults to glShaderSource and glCompileShader
        compileHost: @TypeOf(SourcePayload.compile) = null,
        saveHost: @TypeOf(SourcePayload.save) = null,
        stat: storage.Stat,

        /// Private. Access through addBreakpoint and removeBreakpoint
        breakpoints: std.ArrayList(?Breakpoint),
        /// Needs re-instrumentation (breakpoints or source has changed)
        dirty: bool = true,
        /// Tree of the original shader source code. Used for breakpoint location calculation
        tree: ?analyzer.parse.Tree = null,
        implementation: *anyopaque, // is on heap
        //
        // Pointers to interface implementation methods. VTable not used here for saving one dereference
        //
        /// Returns the currently saved (not instrumented) shader source part
        getSourceImpl: *const anyopaque,
        replaceSourceImpl: *const anyopaque,
        deinitImpl: *const anyopaque,

        pub usingnamespace Storage(*@This(), void).TaggableMixin;

        pub fn deinit(self: *@This()) !void {
            self.tags.deinit(self.breakpoints.allocator);
            self.breakpoints.deinit();
            @as(*const fn (*const anyopaque) void, @ptrCast(self.deinitImpl))(self.implementation);
        }

        pub fn basenameAlloc(source: *const SourceInterface, allocator: std.mem.Allocator, part_index: usize) !String {
            if (source.firstTag()) |t| {
                return try allocator.dupe(u8, t.name);
            } else {
                return try std.fmt.allocPrint(allocator, "{x}{s}", .{ storage.combinedRef(source.ref, part_index), source.toExtension() });
            }
        }

        pub fn lenOr0(self: *const @This()) usize {
            return if (self.getSource()) |s| s.len else 0;
        }

        pub fn getSource(self: *const @This()) ?String {
            return @as(*const fn (*const anyopaque) ?String, @ptrCast(self.getSourceImpl))(self.implementation);
        }

        pub fn invalidate(self: *@This()) void {
            if (self.tree) |*t| {
                t.deinit(self.breakpoints.allocator);
            }
            self.tree = null;
            self.dirty = true;
        }

        pub fn parseTree(self: *@This()) !*const analyzer.parse.Tree {
            if (self.tree) |t| {
                return &t;
            } else {
                if (self.getSource()) |s| {
                    self.tree = try analyzer.parse.parse(self.breakpoints.allocator, s, .{});
                    return &self.tree.?;
                } else return error.NoSource;
            }
        }

        pub fn replaceSource(self: *@This(), source: String) std.mem.Allocator.Error!void {
            self.invalidate();
            return @as(*const fn (*const anyopaque, String) std.mem.Allocator.Error!void, @ptrCast(self.replaceSourceImpl))(self.implementation, source);
        }

        pub fn toDAPAlloc(self: @This(), allocator: std.mem.Allocator, program: ?*const Program, part_index: usize) !String {
            const basename = try self.basenameAlloc(allocator, part_index);
            defer allocator.free(basename);
            if (program) |p| {
                if (p.firstTag()) |t| {
                    const program_path = try t.fullPathAlloc(allocator, false);
                    defer allocator.free(program_path);
                    return std.fmt.allocPrint(allocator, GenericLocator.programs_path ++ "{s}/{s}", .{ program_path, basename });
                } else {
                    return std.fmt.allocPrint(allocator, GenericLocator.programs_path ++ storage.untagged_path ++ "/{x}/{s}", .{ p.ref, basename });
                }
            }

            if (self.firstTag()) |t| {
                const source_path = try t.fullPathAlloc(allocator, false);
                defer allocator.free(source_path);
                return std.fmt.allocPrint(allocator, GenericLocator.sources_path ++ "{s}", .{source_path});
            } else {
                return std.fmt.allocPrint(allocator, GenericLocator.sources_path ++ storage.untagged_path ++ "/{x}{s}", .{ storage.combinedRef(self.ref, part_index), self.toExtension() });
            }
        }

        /// bp: an uninitialized / un-hydrated breakpoint
        /// Returns DebugAdapterProtocol breakpoint
        /// `source.path` must be freed if not null
        pub fn addBreakpoint(self: *@This(), bp: Breakpoint, allocator: std.mem.Allocator, program: ?*const Program, part_index: usize) !debug.Breakpoint {
            var new = bp;
            new.source = self;
            find: {
                for (self.breakpoints.items, 0..) |slot, i| {
                    if (slot == null) {
                        new.id = i;
                        self.breakpoints.items[i] = new;
                        break :find;
                    }
                }
                new.id = self.breakpoints.items.len;
                try self.breakpoints.append(new);
            }

            self.invalidate();
            return new.toDAPAlloc(allocator, program, part_index); //TODO check validity
        }

        pub fn removeBreakpoint(self: *@This(), id: usize) !void {
            for (0.., self.breakpoints.items) |i, bp| {
                if (bp.id) |existing| {
                    if (existing == id) {
                        self.breakpoints.swapRemove(i);
                        self.invalidate();
                        return;
                    }
                }
            }
            return error.InvalidBreakpoint;
        }

        pub fn clearBreakpoints(self: *@This()) void {
            self.invalidate();
            self.breakpoints.clearRetainingCapacity();
        }

        //
        // Methods copied from analyzer.Document
        //
        pub fn utf8FromPosition(self: @This(), position: analyzer.lsp.Position) u32 {
            var remaining_lines = position.line;
            var i: usize = 0;
            if (self.getSource()) |bytes| {
                while (remaining_lines != 0 and i < bytes.len) {
                    remaining_lines -= @intFromBool(bytes[i] == '\n');
                    i += 1;
                }

                const rest = bytes[i..];

                var remaining_chars = position.character;
                var codepoints = std.unicode.Utf8View.initUnchecked(rest).iterator();
                while (remaining_chars != 0) {
                    const codepoint = codepoints.nextCodepoint() orelse break;
                    remaining_chars -|= std.unicode.utf16CodepointSequenceLength(codepoint) catch unreachable;
                }

                return @intCast(i + codepoints.i);
            } else {
                return 0;
            }
        }

        pub fn save(self: *@This()) void {
            self.saveHost();
        }

        /// Including the dot
        pub fn toExtension(self: *const @This()) String {
            return self.type.toExtension();
        }
    };

    /// SourceInterface.breakpoints already contains all breakpoints inserted by pragmas, so the pragmas should be skipped
    fn skipPragmaDeshader(line: String) bool {
        if (analyzer.parse.parsePreprocessorDirective(line)) |directive| {
            switch (directive) {
                .pragma => |pragma| {
                    if (std.mem.eql(u8, line[pragma.name.start..pragma.name.end], "deshader")) {
                        return true;
                    }
                },
                else => {},
            }
        }
        return false;
    }

    /// Breakpoint marker string. glsl_analyzer is modified to ignore these markers when parsing AST, but adds them to a separate list
    const marker = " " ++ blk: {
        const dummy = instrumentation.ParseInfo{
            .arena_state = undefined,
            .tree = undefined,
            .ignored = undefined,
            .diagnostics = undefined,
            .calls = undefined,
            .version = undefined,
            .version_span = undefined,
            .extensions = undefined,
        };
        break :blk dummy.breakpoint_identifier;
    } ++ "() ";

    pub const InstrumentationParams = struct {
        allocator: std.mem.Allocator,
        //dimensions
        screen: [2]usize,
        vertices: usize,
        instances: usize,
        compute: [3]usize,

        max_buffers: usize,
        free_attachments: std.ArrayList(u5),
        used_buffers: std.ArrayList(usize),
        used_xfb: u4, // transform feedback buffer count is generally limited to 4
    };

    pub fn instrument(parts: []*SourceInterface, params: *InstrumentationParams) !instrumentation.Result {
        const info = toGLSLangStage(parts[0].type); //the parts should all be of the same type
        // Create debugging buffer GLSL source code
        const preprocessed = preprocess: {
            var total_len: usize = 0;
            var total_breakpoints: usize = 0;
            for (parts) |part| {
                total_len += part.lenOr0();
                total_breakpoints += part.breakpoints.items.len;
            }
            var lines_to_mark = try std.ArrayListUnmanaged(String).initCapacity(params.allocator, total_len / 80); // does not need to be freed because it only references the lines in the original source
            for (parts) |part| {
                if (part.getSource()) |source| {
                    var line_iterator = std.mem.splitScalar(u8, source, '\n');
                    while (line_iterator.next()) |line| {
                        try lines_to_mark.append(params.allocator, line);
                    }
                }
            }
            var marked = try std.ArrayListUnmanaged(u8).initCapacity(params.allocator, total_len + marker.len * total_breakpoints);
            defer marked.deinit(params.allocator);

            for (parts) |part| {
                std.sort.heap(?Breakpoint, part.breakpoints.items, {}, struct {
                    pub fn bpSort(_: void, a: ?Breakpoint, b: ?Breakpoint) bool {
                        if (a == null) {
                            return false;
                        }
                        if (b == null) {
                            return true;
                        }
                        if (a.?.line != b.?.line) {
                            return a.?.line < b.?.line;
                        }
                        if (a.?.column != b.?.column) {
                            return a.?.column orelse 0 < b.?.column orelse 0;
                        }
                        if (a.?.endLine != b.?.endLine) {
                            return (a.?.endLine orelse a.?.line) < (b.?.endLine orelse b.?.line);
                        }
                        if (a.?.endColumn != b.?.endColumn) {
                            return (a.?.endColumn orelse a.?.column orelse 0) < (b.?.endColumn orelse b.?.column orelse 0);
                        }
                        return false;
                    }
                }.bpSort);
                var last_line: usize = 0;
                var last_column: usize = 0;
                for (part.breakpoints.items) |maybe_bp| {
                    if (maybe_bp) |bp| {
                        // Insert the lines before the breakpoint
                        const column = bp.column orelse 0;
                        if (bp.line > last_line) {
                            if (!skipPragmaDeshader(lines_to_mark.items[last_line])) {
                                // insert the rest of the last line
                                try marked.appendSlice(params.allocator, lines_to_mark.items[last_line][last_column..]);
                                try marked.append(params.allocator, '\n');
                            }
                        }
                        for ((last_line + 1)..bp.line) |i| {
                            if (!skipPragmaDeshader(lines_to_mark.items[i])) {
                                try marked.appendSlice(params.allocator, lines_to_mark.items[i]);
                                try marked.append(params.allocator, '\n');
                            }
                        }

                        // insert the marker into the line
                        const skip = skipPragmaDeshader(lines_to_mark.items[bp.line]);
                        if (!skip) {
                            try marked.appendSlice(params.allocator, lines_to_mark.items[bp.line][0..column]);
                            last_column = column;
                        }
                        try marked.appendSlice(params.allocator, marker);
                        last_line = bp.line;
                        if (skip) {
                            last_line += 1;
                            last_column = 0;
                        }
                    }
                }
                try marked.appendSlice(params.allocator, lines_to_mark.items[last_line][last_column..]);
                try marked.append(params.allocator, '\n');
                // Insert the rest of the lines
                for ((last_line + 1)..lines_to_mark.items.len) |i| {
                    try marked.appendSlice(params.allocator, lines_to_mark.items[i]);
                    try marked.append(params.allocator, '\n');
                }
            }
            try marked.append(params.allocator, 0); // null terminator

            lines_to_mark.deinit(params.allocator);

            // Preprocess the shader code with the breakpoint markers
            const input = glslang.glslang_input_t{
                .language = glslang.GLSLANG_SOURCE_GLSL,
                .stage = info.stage,
                .client = info.client,
                .client_version = glslang.GLSLANG_TARGET_OPENGL_450, //TODO different targets
                .target_language = glslang.GLSLANG_TARGET_NONE,
                .target_language_version = glslang.GLSLANG_TARGET_NONE,
                .code = marked.items.ptr,
                .default_version = 100,
                .default_profile = glslang.GLSLANG_NO_PROFILE,
                .force_default_version_and_profile = @intFromBool(false),
                .forward_compatible = @intFromBool(false),
                .messages = glslang.GLSLANG_MSG_DEFAULT_BIT,
                .resource = glslang.glslang_default_resource(),
            };
            if (glslang.glslang_shader_create(&input)) |shader| {
                defer glslang.glslang_shader_delete(shader);
                if (glslang.glslang_shader_preprocess(shader, &input) == 0) {
                    log.err("Failed to preprocess shader: {s}\nInfo Log:\n{s}\nDebug log:\n{s}", .{
                        marked.items,
                        glslang.glslang_shader_get_info_log(shader),
                        glslang.glslang_shader_get_info_debug_log(shader),
                    });
                    return error.GLSLang;
                }
                break :preprocess try params.allocator.dupe(u8, std.mem.span(glslang.glslang_shader_get_preprocessed_code(shader))); // TODO really need to dupe?
            } else {
                return error.GLSLang;
            }
        };
        defer params.allocator.free(preprocessed);

        var processor = instrumentation.Processor{
            .allocator = params.allocator,
            .threads = switch (info.stage) {
                glslang.GLSLANG_STAGE_VERTEX, glslang.GLSLANG_STAGE_GEOMETRY => &[_]usize{params.vertices},
                glslang.GLSLANG_STAGE_FRAGMENT => &params.screen,
                else => unreachable, // TODO other stages
            },
            .free_attachments = &params.free_attachments,
            .max_buffers = params.max_buffers,
            .shader_type = parts[0].type,
            .used_buffers = &params.used_buffers,
            .used_xfb = params.used_xfb,
        };
        try processor.setup(preprocessed);
        // Generates instrumented source with breakpoints and debug outputs applied
        const applied = try processor.applyTo(preprocessed);
        return applied;
    }

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
                source = if (payload.lengths) |lens|
                    try allocator.dupe(u8, payload.sources.?[index][0..lens[index]])
                else
                    try allocator.dupe(u8, std.mem.span(payload.sources.?[index]));
            }
            const result = try allocator.create(@This());
            const interface = try allocator.create(SourceInterface);
            interface.* = SourceInterface{
                .implementation = result,
                .ref = payload.ref,
                .type = payload.type,
                .breakpoints = @TypeOf(interface.breakpoints).init(allocator),
                .compileHost = payload.compile,
                .saveHost = payload.save,
                .language = payload.language,
                .context = if (payload.contexts != null) payload.contexts.?[index] else null,
                .stat = storage.Stat.now(),
                .getSourceImpl = &getSource,
                .replaceSourceImpl = &replaceSource,
                .deinitImpl = &MemorySource.deinit,
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

        /// The old source will be freed if it exists. The new source will be copied and owned
        pub fn replaceSource(this: *@This(), source: String) std.mem.Allocator.Error!void {
            if (this.source) |s| {
                this.allocator.free(s);
            }
            this.source = try this.allocator.dupe(u8, source);
        }

        pub fn deinit(this: *@This()) void {
            if (this.source) |s| {
                this.allocator.free(s);
            }
            this.allocator.destroy(this.super);
            this.allocator.destroy(this);
        }
    };

    pub const Program = struct {
        // each ref can have multiple source parts
        pub const ShadersRefMap = std.AutoHashMap(usize, *const std.ArrayList(*SourceInterface));
        const DirOrStored = Storage(@This(), *Shader.SourceInterface).DirOrStored;

        ref: @TypeOf(ProgramPayload.ref) = 0,
        tags: std.StringArrayHashMapUnmanaged(*Tag(@This())) = .{},
        /// Ref and sources
        stages: ?Program.ShadersRefMap = null,
        context: @TypeOf(ProgramPayload.context) = null,
        /// Function for attaching and linking the shader. Defaults to glAttachShader and glLinkShader wrapper
        link: @TypeOf(ProgramPayload.link),

        stat: storage.Stat,

        cached: std.AutoHashMapUnmanaged(usize, Cached) = .{},
        // all implementations at https://opengl.gpuinfo.org/displaycapability.php?name=GL_MAX_COLOR_ATTACHMENTS
        // and https://vulkan.gpuinfo.org/displaydevicelimit.php?name=maxFragmentOutputAttachments&platform=all
        // report max 8 so 32 should be anough
        used_outputs: [32]u1 = [_]u1{0} ** 32,

        pub usingnamespace Storage(@This(), *SourceInterface).TaggableMixin;

        const Cached = struct {
            params: InstrumentationParams,
            /// uses allocator from params
            outputs: ?instrumentation.Result.Outputs,

            pub fn deinit(self: *@This()) void {
                if (self.outputs) |*o| {
                    o.deinit(self.params.allocator);
                }
                self.params.free_attachments.deinit();
                self.params.used_buffers.deinit();
            }
        };

        pub fn deinit(self: *@This()) void {
            if (self.stages) |*s| {
                s.deinit();
            }
            var it = self.cached.valueIterator();
            var allocator: std.mem.Allocator = undefined; // TODO better storage for the allocator
            while (it.next()) |r| {
                allocator = r.params.allocator;
                r.deinit();
            }
            self.tags.deinit(allocator);
            self.cached.deinit(allocator);
        }

        pub fn eql(self: *const @This(), other: *const @This()) bool {
            if (self.stages != null and other.stages != null) {
                if (self.stages.?.items.len != other.stages.?.items.len) {
                    return false;
                }
                for (self.stages.?.items, other.stages.?.items) |s_ptr, o_ptr| {
                    if (!s_ptr.eql(o_ptr)) {
                        return false;
                    }
                }
            }
            return self.ref == other.ref;
        }

        pub fn lenOr0(_: @This()) usize {
            return 0;
        }

        pub fn revertInstrumentation(self: *@This(), allocator: std.mem.Allocator) !void {
            if (self.stages) |shaders_map| {
                // compile the shaders
                var it = shaders_map.valueIterator();
                while (it.next()) |shader_parts| {
                    const shader = shader_parts.*.items[0];
                    if (shader.compileHost) |compile| {
                        var sources = try allocator.alloc(CString, shader_parts.*.items.len);
                        var lengths = try allocator.alloc(usize, shader_parts.*.items.len);
                        var paths = try allocator.alloc(?CString, shader_parts.*.items.len);
                        defer {
                            for (sources, lengths, paths) |s, l, p| {
                                allocator.free(s[0..l :0]);
                                if (p) |pa| allocator.free(pa[0 .. std.mem.len(pa) + 1 :0]);
                            }
                            allocator.free(sources);
                            allocator.free(lengths);
                            allocator.free(paths);
                        }
                        var has_paths = false;
                        for (shader_parts.*.items, 0..) |part, i| {
                            const source = part.getSource();
                            sources[i] = try allocator.dupeZ(u8, source orelse "");
                            lengths[i] = if (source) |s| s.len else 0;
                            paths[i] = if (part.firstTag()) |t| blk: {
                                has_paths = true;
                                break :blk try t.fullPathAlloc(allocator, true);
                            } else null;
                        }
                        const payload = decls.SourcesPayload{
                            .ref = shader.ref,
                            .paths = if (has_paths) paths.ptr else null,
                            .compile = shader.compileHost,
                            .contexts = blk: {
                                var contexts = try allocator.alloc(?*const anyopaque, shader_parts.*.items.len);
                                for (shader_parts.*.items, 0..) |part, i| {
                                    contexts[i] = part.context;
                                }
                                break :blk contexts.ptr;
                            },
                            .count = shader_parts.*.items.len,
                            .language = shader.language,
                            .sources = sources.ptr,
                            .lengths = lengths.ptr,
                            .type = shader.type,
                            .save = shader.saveHost,
                        };
                        defer allocator.free(payload.contexts.?[0..payload.count]);
                        const status = compile(payload, "", 0);

                        if (status != 0) {
                            log.err("Failed to compile program {x} shader {x} (code {d})", .{ self.ref, shader.ref, status });
                        }
                    } else {
                        log.warn("No function to compile shader {x} provided.", .{self.ref});
                    }
                }
                // Link the program
                if (self.link) |linkFunc| {
                    const path = if (self.firstTag()) |t| try t.fullPathAlloc(allocator, true) else null;
                    defer if (path) |p| allocator.free(p);
                    const result = linkFunc(decls.ProgramPayload{
                        .context = self.context,
                        .count = 0,
                        .link = linkFunc,
                        .path = if (path) |p| p.ptr else null,
                        .ref = self.ref,
                        .shaders = null,
                    });
                    if (result != 0) {
                        log.err("Failed to link to revert instrumentation for program {x}. Code {d}", .{ self.ref, result });
                        return error.Link;
                    }
                } else {
                    log.warn("No function to link program {x} provided.", .{self.ref}); // TODO forward logging to the connected client
                }
            }
        }

        pub fn setUsedOutput(self: *@This(), index: usize) void {
            self.used_outputs[index] = 1;
        }

        pub fn unsetUsedOutput(self: *@This(), index: usize) void {
            self.used_outputs[index] = 0;
        }

        fn instrumentOrGetCached(self: *@This(), params: *InstrumentationParams, key: usize, sources: []*SourceInterface) !union(enum) {
            cached: ?*instrumentation.Result.Outputs,
            new: instrumentation.Result,
        } {
            return find_cached: {
                if (self.cached.getPtr(key)) |c| {
                    // check for params mismatch
                    if (params.free_attachments.items.len > 0) {
                        if (params.free_attachments.items.len != c.params.free_attachments.items.len) {
                            break :find_cached null;
                        }
                        for (params.free_attachments.items, c.params.free_attachments.items) |p, c_p| {
                            if (p != c_p) {
                                break :find_cached null;
                            }
                        }
                    }
                    if (params.screen[0] != 0) {
                        if (params.screen[0] != c.params.screen[0] or params.screen[1] != c.params.screen[1]) {
                            break :find_cached null;
                        }
                    }
                    if (params.vertices != 0) {
                        if (params.vertices != c.params.vertices) {
                            break :find_cached null;
                        }
                    }
                    if (params.compute[0] != 0) {
                        if (params.compute[0] != c.params.compute[0] or params.compute[1] != c.params.compute[1] or params.compute[2] != c.params.compute[2]) {
                            break :find_cached null;
                        }
                    }
                    for (sources) |s| {
                        if (s.dirty) {
                            break :find_cached null;
                        }
                    }

                    break :find_cached .{
                        .cached = if (c.outputs) |*o| o else null, //should really be there when the cache check passes
                    };
                } else {
                    break :find_cached null;
                }
            } orelse blk: {
                // Get new instrumentation
                const result = try Shader.instrument(sources, params);
                errdefer result.deinit(params.allocator);
                if (result.source) |s| {
                    log.debug("Instrumented source:\n{s}", .{s[0..result.length]});
                }
                if (result.outputs.diagnostics.items.len > 0) {
                    log.info("Shader {x} instrumentation diagnostics:", .{self.ref});
                    for (result.outputs.diagnostics.items) |diag| {
                        log.info("{d}: {s}", .{ diag.span.start, diag.message }); // TODO line and column pos instead of offset
                    }
                }
                break :blk .{ .new = result };
            };
        }

        /// Instruments all (or selected) shader stages of the program.
        /// The returned hashmap should be freed by the caller, but not the content it refers to.
        /// *NOTE: Should be called by the drawing thread because shader source code compilation is invoked insde.*
        pub fn instrument(self: *Shader.Program, in_params: Shader.InstrumentationParams, stages: ?std.EnumSet(decls.SourceType)) !InstrumentationResult {
            // copy free_attachments and used_buffers for passing them by reference because all stages will share them
            var params = in_params;
            var copied_a = try std.ArrayList(u5).initCapacity(params.allocator, params.free_attachments.items.len);
            copied_a.appendSliceAssumeCapacity(params.free_attachments.items);
            params.free_attachments = copied_a;
            defer copied_a.deinit();
            var copied_b = try std.ArrayList(usize).initCapacity(params.allocator, params.used_buffers.items.len);
            copied_b.appendSliceAssumeCapacity(params.used_buffers.items);
            params.used_buffers = copied_b;
            defer copied_b.deinit();

            var outputs = std.AutoHashMapUnmanaged(usize, *instrumentation.Result.Outputs){};
            var invalidated = false;
            if (self.stages) |shaders_map| {
                // Collapse the map into a list
                const shader_count = shaders_map.count();
                const shaders_list = try params.allocator.alloc(ShadersRefMap.Entry, shader_count);
                defer params.allocator.free(shaders_list);
                {
                    var iter = shaders_map.iterator();
                    var i: usize = 0;
                    while (iter.next()) |entry| : (i += 1) {
                        shaders_list[i] = entry;
                    }
                }

                try outputs.ensureTotalCapacity(params.allocator, shader_count);
                // needs re-link?
                var dirty = false;
                for (shaders_list) |shader_entry| {
                    const shader_parts = shader_entry.value_ptr; // One shader represented by a list of its source parts
                    const first_part = shader_parts.*.items[0];
                    if (stages) |s| { //filter out only the selected stages
                        if (!s.contains(first_part.type)) {
                            continue;
                        }
                    }

                    var shader_result = try self.instrumentOrGetCached(
                        &params,
                        shader_entry.key_ptr.*,
                        shader_parts.*.items,
                    );
                    switch (shader_result) {
                        .cached => |cached_outputs| if (cached_outputs) |o| try outputs.put(params.allocator, shader_entry.key_ptr.*, o),
                        .new => |*new_result| {
                            invalidated = true;

                            errdefer new_result.deinit(params.allocator);
                            for (shader_parts.*.items) |part| {
                                part.dirty = false;
                            }
                            errdefer {
                                for (shader_parts.*.items) |part| {
                                    part.invalidate();
                                }
                            }

                            // A new instrumentation was emitted
                            if (new_result.source) |instrumented_source| {
                                // If any instrumentation was emitted,
                                // replace the shader source with the instrumented one on the host side
                                if (first_part.compileHost) |c| {
                                    const payload = decls.SourcesPayload{
                                        .ref = first_part.ref,
                                        .compile = first_part.compileHost,
                                        .contexts = blk: {
                                            var contexts = try params.allocator.alloc(?*const anyopaque, shader_parts.*.items.len);
                                            for (shader_parts.*.items, 0..) |part, i| {
                                                contexts[i] = part.context;
                                            }
                                            break :blk contexts.ptr;
                                        },
                                        .count = shader_parts.*.items.len,
                                        .language = first_part.language,
                                        .lengths = blk: {
                                            var lengths = try params.allocator.alloc(usize, shader_parts.*.items.len);
                                            for (shader_parts.*.items, 0..) |part, i| {
                                                lengths[i] = part.lenOr0();
                                            }
                                            break :blk lengths.ptr;
                                        },
                                        .sources = blk: {
                                            var sources = try params.allocator.alloc(CString, shader_parts.*.items.len);
                                            for (shader_parts.*.items, 0..) |part, i| {
                                                sources[i] = try params.allocator.dupeZ(u8, part.getSource() orelse "");
                                            }
                                            break :blk sources.ptr;
                                        },
                                        .save = first_part.saveHost,
                                        .type = first_part.type,
                                    };
                                    defer {
                                        for (payload.sources.?[0..payload.count], payload.lengths.?[0..payload.count]) |s, l| {
                                            params.allocator.free(s[0 .. l + 1]); //also free the null terminator
                                        }
                                        params.allocator.free(payload.sources.?[0..payload.count]);
                                        params.allocator.free(payload.lengths.?[0..payload.count]);
                                        params.allocator.free(payload.contexts.?[0..payload.count]);
                                    }
                                    const result = c(payload, instrumented_source, @intCast(new_result.length));
                                    if (result != 0) {
                                        log.err("Failed to compile instrumented shader {x}. Code {d}", .{ self.ref, result });
                                        new_result.deinit(params.allocator);
                                        continue;
                                    }
                                } else {
                                    log.err("No compileHost function for shader {x}", .{self.ref});
                                    new_result.deinit(params.allocator);
                                    continue;
                                }

                                dirty = true;
                            }

                            // Update the cache
                            const cache_entry = try self.cached.getOrPut(params.allocator, first_part.ref);
                            if (cache_entry.found_existing) {
                                const c = cache_entry.value_ptr;
                                // Update params
                                if (params.free_attachments.items.len > 0) {
                                    c.params.free_attachments.clearRetainingCapacity();
                                    try c.params.free_attachments.ensureTotalCapacity(in_params.free_attachments.items.len);
                                    c.params.free_attachments.appendSliceAssumeCapacity(in_params.free_attachments.items);
                                }
                                if (params.screen[0] != 0) {
                                    c.params.screen = params.screen;
                                }
                                if (params.vertices != 0) {
                                    c.params.vertices = params.vertices;
                                }
                                if (params.compute[0] != 0) {
                                    c.params.compute = params.compute;
                                }
                                if (params.used_buffers.items.len > 0) {
                                    c.params.used_buffers.clearRetainingCapacity();
                                    try c.params.used_buffers.ensureTotalCapacity(in_params.used_buffers.items.len);
                                    c.params.used_buffers.appendSliceAssumeCapacity(in_params.used_buffers.items);
                                }
                            } else {
                                // Initialize cache
                                cache_entry.value_ptr.* = .{
                                    .params = .{
                                        .allocator = params.allocator,
                                        .compute = params.compute,
                                        .free_attachments = std.ArrayList(u5).fromOwnedSlice(params.allocator, try params.allocator.dupe(u5, params.free_attachments.items)),
                                        .instances = params.instances,
                                        .max_buffers = params.max_buffers,
                                        .screen = params.screen,
                                        .used_buffers = std.ArrayList(usize).fromOwnedSlice(params.allocator, try params.allocator.dupe(usize, params.used_buffers.items)),
                                        .used_xfb = params.used_xfb,
                                        .vertices = params.vertices,
                                    },
                                    .outputs = null,
                                };
                            }
                            if (new_result.source == null) {
                                new_result.deinit(params.allocator);
                            } else {
                                // Update cache value
                                cache_entry.value_ptr.outputs = new_result.toOwnedOutputs(params.allocator);
                                try outputs.put(params.allocator, shader_entry.key_ptr.*, &cache_entry.value_ptr.outputs.?);
                            }
                        },
                    }
                }

                // Re-link the program
                if (dirty) {
                    if (self.link) |l| {
                        const path = if (self.firstTag()) |t| try t.fullPathAlloc(params.allocator, true) else null;
                        defer if (path) |p|
                            params.allocator.free(p);
                        const result = l(decls.ProgramPayload{
                            .ref = self.ref,
                            .context = self.context,
                            .count = 0,
                            .link = self.link,
                            .path = if (path) |p| p.ptr else null,
                            .shaders = null, // the shaders array is useful only for attaching new shaders
                        });
                        if (result != 0) {
                            log.err("Failed to link program {x} for instrumentation. Code {d}", .{ self.ref, result });
                            return error.Link;
                        }
                    } else {
                        log.err("No link function provided for program {x}", .{self.ref});
                        return error.Link;
                    }
                }
                return .{ .outputs = outputs, .invalidated = invalidated };
            } else {
                log.warn("Program {x} has no shaders", .{self.ref});
                return error.TargetNotFound;
            }
        }

        pub fn listFiles(self: *const @This()) ?Program.ShaderIterator {
            if (self.stages) |s| {
                return Program.ShaderIterator{
                    .program = self,
                    .current_parts = null,
                    .shaders = s.valueIterator(),
                };
            } else return null;
        }

        pub fn getNested(
            self: *const @This(),
            locator: storage.Locator,
        ) !DirOrStored {
            if (self.stages) |s| {
                switch (locator) {
                    .tagged => |name| {
                        var iter = s.valueIterator();
                        while (iter.next()) |stage_parts| {
                            for (stage_parts.*.items) |current| {
                                if (current.tags.contains(name)) {
                                    return DirOrStored{
                                        .content = .{ .Nested = current },
                                        .is_new = false,
                                    };
                                }
                            }
                        }
                    },
                    .untagged => |combined| {
                        if (s.get(combined.ref)) |stage| {
                            return DirOrStored{
                                .content = .{ .Nested = stage.items[combined.part] },
                                .is_new = false,
                            };
                        }
                    },
                }
            }
            return error.TargetNotFound;
        }

        // naming scheme:
        // 1. tagged source
        // /sources/glfw/asd.vertasd
        // 2. untagged source
        // /sources/untagged/01.vert
        // 3. untagged program, untagged source
        // /programs/untagged/0/02.frag
        // 4. untagged program, tagged source
        // /programs/untagged/1/tag.vertasd
        // 5. tagged program, untagged source
        // /programs/glfw/asd/03.frag
        // 6. tagged program, tagged source
        // /programs/glfw/asd/tag.fragasd

        pub const ShaderIterator = struct {
            program: *const Program,
            shaders: Program.ShadersRefMap.ValueIterator,
            current_parts: ?*const std.ArrayList(*SourceInterface),
            part_index: usize = 0,

            /// Returns the next shader source name and its object. The name is allocated with the allocator
            pub fn nextAlloc(self: *ShaderIterator, allocator: std.mem.Allocator) error{OutOfMemory}!?struct { name: []const u8, source: *const Shader.SourceInterface } {
                var current: *const SourceInterface = undefined;
                var found = false;
                while (!found) {
                    if (self.current_parts == null or self.current_parts.?.items.len <= self.part_index) {
                        while (self.shaders.next()) |next| { // find the first non-empty source
                            if (next.*.items.len > 0) {
                                self.current_parts = next.*;
                                self.part_index = 0;
                                break;
                            }
                        } else { // not found
                            return null;
                        }
                    } else { //TODO really correct check?
                        found = true;
                        current = self.current_parts.?.items[self.part_index];
                        self.part_index += 1;
                    }
                }

                return .{
                    .name = try current.basenameAlloc(allocator, self.part_index),
                    .source = current,
                };
            }
        };

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

pub fn sourcesCreateUntagged(service: *Service, sources: decls.SourcesPayload) !void {
    const new_stored = try service.Shaders.allocator.alloc(*Shader.SourceInterface, sources.count);
    defer service.Shaders.allocator.free(new_stored);
    for (new_stored, 0..) |*stored, i| {
        stored.* = (try Shader.MemorySource.fromPayload(service.Shaders.allocator, sources, i)).super;
    }
    try service.Shaders.createUntagged(new_stored);
}

/// Replace shader's source code
pub fn sourceSource(service: *Service, sources: decls.SourcesPayload, replace: bool) !void {
    const existing = service.Shaders.all.getPtr(sources.ref);
    if (existing) |e_sources| {
        if (e_sources.items.len != sources.count) {
            try e_sources.resize(sources.count);
        }
        for (e_sources.items, 0..) |item, i| {
            if (item.getSource() == null or replace) {
                try item.replaceSource(std.mem.span(sources.sources.?[i]));
            }
        }
    }
}

pub fn sourceType(service: *Service, ref: usize, @"type": decls.SourceType) !void {
    const maybe_sources = service.Shaders.all.get(ref);

    if (maybe_sources) |sources| {
        for (sources.items) |*item| {
            item.type = @"type";
        }
    } else {
        return error.TargetNotFound;
    }
}

pub fn sourceCompileFunc(service: *Service, ref: usize, func: @TypeOf((Shader.Source{}).compile)) !void {
    const maybe_sources = service.Shaders.all.get(ref);

    if (maybe_sources) |sources| {
        for (sources.items) |*item| {
            item.compile = func;
        }
    } else {
        return error.TargetNotFound;
    }
}

pub fn sourceContext(service: *Service, ref: usize, source_index: usize, context: *const anyopaque) !void {
    const maybe_sources = service.Shaders.all.get(ref);

    if (maybe_sources) |sources| {
        std.debug.assert(sources.contexts != null);
        sources.contexts[source_index] = context;
    } else {
        return error.TargetNotFound;
    }
}

/// With sources
pub fn programCreateUntagged(service: *Service, program: decls.ProgramPayload) !void {
    try service.Programs.appendUntagged(Shader.Program{
        .ref = program.ref,
        .context = program.context,
        .link = program.link,
        .stages = null,
        .stat = storage.Stat.now(),
    });

    if (program.shaders) |shaders| {
        std.debug.assert(program.count > 0);
        for (shaders[0..program.count]) |shader| {
            try service.programAttachSource(program.ref, shader);
        }
    }
}

pub fn programAttachSource(service: *Service, ref: usize, source: usize) !void {
    if (service.Shaders.all.getEntry(source)) |existing_source| {
        if (service.Programs.all.getPtr(ref)) |existing_program| {
            std.debug.assert(existing_program.items.len == 1);
            var program = &existing_program.items[0]; // note the reference
            if (program.stages == null) {
                program.stages = Shader.Program.ShadersRefMap.init(existing_program.allocator);
            }
            try program.stages.?.put(existing_source.key_ptr.*, existing_source.value_ptr);
        } else {
            return error.TargetNotFound;
        }
    } else {
        return error.TargetNotFound;
    }
}

/// Must be called from the drawing thread
fn revert(service: *Service) !void {
    service.debugging = false;
    var it = service.Programs.all.valueIterator();
    while (it.next()) |program| {
        try program.items[0].revertInstrumentation(service.allocator);
    }
}

pub fn checkDebuggingOrRevert(service: *Service) bool {
    if (service.revert_requested) {
        service.revert_requested = false;
        service.revert() catch |err| log.err("Failed to revert instrumentation: {}", .{err});
        return false;
    } else {
        return service.debugging;
    }
}

const ShaderInfoForGLSLang = struct {
    stage: glslang.glslang_stage_t,
    client: glslang.glslang_client_t,
};
fn toGLSLangStage(stage: decls.SourceType) ShaderInfoForGLSLang {
    return switch (stage) {
        .gl_vertex => .{ .client = glslang.GLSLANG_CLIENT_OPENGL, .stage = glslang.GLSLANG_STAGE_VERTEX },
        .gl_fragment => .{ .client = glslang.GLSLANG_CLIENT_OPENGL, .stage = glslang.GLSLANG_STAGE_FRAGMENT },
        .gl_geometry => .{ .client = glslang.GLSLANG_CLIENT_OPENGL, .stage = glslang.GLSLANG_STAGE_GEOMETRY },
        .gl_tess_control => .{ .client = glslang.GLSLANG_CLIENT_OPENGL, .stage = glslang.GLSLANG_STAGE_TESSCONTROL },
        .gl_tess_evaluation => .{ .client = glslang.GLSLANG_CLIENT_OPENGL, .stage = glslang.GLSLANG_STAGE_TESSEVALUATION },
        .gl_compute => .{ .client = glslang.GLSLANG_CLIENT_OPENGL, .stage = glslang.GLSLANG_STAGE_COMPUTE },
        .gl_mesh => .{ .client = glslang.GLSLANG_CLIENT_OPENGL, .stage = glslang.GLSLANG_STAGE_MESH },
        .gl_task => .{ .client = glslang.GLSLANG_CLIENT_OPENGL, .stage = glslang.GLSLANG_STAGE_TASK },
        .vk_vertex => .{ .client = glslang.GLSLANG_CLIENT_VULKAN, .stage = glslang.GLSLANG_STAGE_VERTEX },
        .vk_tess_control => .{ .client = glslang.GLSLANG_CLIENT_VULKAN, .stage = glslang.GLSLANG_STAGE_TESSCONTROL },
        .vk_tess_evaluation => .{ .client = glslang.GLSLANG_CLIENT_VULKAN, .stage = glslang.GLSLANG_STAGE_TESSEVALUATION },
        .vk_geometry => .{ .client = glslang.GLSLANG_CLIENT_VULKAN, .stage = glslang.GLSLANG_STAGE_GEOMETRY },
        .vk_fragment => .{ .client = glslang.GLSLANG_CLIENT_VULKAN, .stage = glslang.GLSLANG_STAGE_FRAGMENT },
        .vk_compute => .{ .client = glslang.GLSLANG_CLIENT_VULKAN, .stage = glslang.GLSLANG_STAGE_COMPUTE },
        .vk_raygen => .{ .client = glslang.GLSLANG_CLIENT_VULKAN, .stage = glslang.GLSLANG_STAGE_RAYGEN },
        .vk_anyhit => .{ .client = glslang.GLSLANG_CLIENT_VULKAN, .stage = glslang.GLSLANG_STAGE_ANYHIT },
        .vk_closesthit => .{ .client = glslang.GLSLANG_CLIENT_VULKAN, .stage = glslang.GLSLANG_STAGE_CLOSESTHIT },
        .vk_miss => .{ .client = glslang.GLSLANG_CLIENT_VULKAN, .stage = glslang.GLSLANG_STAGE_MISS },
        .vk_intersection => .{ .client = glslang.GLSLANG_CLIENT_VULKAN, .stage = glslang.GLSLANG_STAGE_INTERSECT },
        .vk_callable => .{ .client = glslang.GLSLANG_CLIENT_VULKAN, .stage = glslang.GLSLANG_STAGE_CALLABLE },
        .vk_task => .{ .client = glslang.GLSLANG_CLIENT_VULKAN, .stage = glslang.GLSLANG_STAGE_TASK },
        .vk_mesh => .{ .client = glslang.GLSLANG_CLIENT_VULKAN, .stage = glslang.GLSLANG_STAGE_MESH },
        .unknown => .{ .client = glslang.GLSLANG_CLIENT_NONE, .stage = 0 },
    };
}
