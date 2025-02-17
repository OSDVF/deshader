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

//! > Graphics API agnostic interface for shader sources and programs
//! (Should not contain any gl* or vk* calls)
//! Provides
//! - specific virtual storage implementations for shaders and programs
//! - instrumentation state management caching
//! - debugging state management
//! - workspace path mappings
//! Some functions in this module require to be called by the drawing thread
//!
//! Uses GLSLang for preprocessing

const std = @import("std");
const builtin = @import("builtin");
const analyzer = @import("glsl_analyzer");
const argsm = @import("args");

const common = @import("common");
const log = common.log;
const decls = @import("../declarations/shaders.zig");
const storage = @import("storage.zig");
const debug = @import("debug.zig");
const commands = @import("../commands.zig");
const instrumentation = @import("instrumentation.zig");
const ArrayBufMap = @import("array_buf_map.zig").ArrayBufMap;

const glslang = @cImport({
    @cInclude("glslang/Include/glslang_c_interface.h");
    @cInclude("glslang/Public/resource_limits_c.h");
});

pub const STACK_TRACE_MAX = 32;
pub const StackTraceT = u32;
const Ref = usize;
const String = []const u8;
const CString = [*:0]const u8;
const ZString = [:0]const u8;
const Storage = storage.Storage;
const Tag = storage.Tag;
// each ref can have multiple source parts
const ShadersRefMap = std.AutoHashMap(usize, *std.ArrayListUnmanaged(Shader.SourcePart));

/// `#pragma deshader` specifications. `#pragma deshader` arguments are passed like command-line parameters
/// e.g. separated by spaces. To pass an argument with spaces, enclose it in double quotes. Double quotes can be escaped by `\`.
pub const Pragmas = union(enum) {
    breakpoint: void,
    /// Conditional breakpoint
    @"breakpoint-if": void,
    /// Breakpoints with condition for how many hits can be ignored
    @"breakpoint-after": void,
    /// Conditional and hit-conditional breakpoint
    @"breakpoint-if-after": void,
    /// This source will be included only once
    once: void,
    /// All sources in this application should be included only once
    @"all-once": void,
    /// Logpoint
    print: void,
    /// Conditional logpoint
    @"print-if": void,
    /// Map physical workspace path to a virtual shader workspace path (2 positional arguments)
    workspace: void,
    /// Set this source virtual path
    source: void,

    @"source-link": void,
    @"source-purge-previous": void,
};

const Service = @This();

pub var inited_static = false;
pub var available_data: std.StringHashMap(Data) = undefined;
pub var data_breakpoints: std.StringHashMap(StoredDataBreakpoint) = undefined;
pub var debugging = false;
/// When an item is removed, `Invalidated` event must be sent (all threadIds across all services are invalidated)
var services = std.AutoArrayHashMapUnmanaged(*const anyopaque, Service){};
var services_by_name = std.StringHashMapUnmanaged(*Service){};
/// Sets if only the selected shader thread will be paused and the others will run the whole program
pub var single_pause_mode = true; // TODO more modes (breakpoint only, free run)
/// Indicator of a user action which has been taken since the last frame (continue, step...).
/// When no user action was taken, the debugging dispatch loop for the current shader can be exited.
pub var user_action: bool = false;

/// IDs of shader, indexes of part, IDs of stops that were not yet sent to the debug adapter. Free for usage by external code (e.g. gl_shaders module)
dirty_breakpoints: std.ArrayListUnmanaged(struct { Ref, usize, usize }) = .{},
context: *const anyopaque,
/// Human-friendly name of this service/context.
/// Owned by the service.
name: String,

/// Workspace paths are like "include path" mappings
/// Maps one to many [fs directory]<=>[deshader virtual directories] (hence the two complementary hashmaps)
/// If a tagged shader (or a shader nested in a program) is found in a workspace path, it can be saved or read from the physical storage
/// TODO watch the filesystem
physical_to_virtual: ArrayBufMap(VirtualDir.Set) = undefined,

Shaders: Shader.SourcePart.StorageT,
Programs: Shader.Program.StorageT,
allocator: std.mem.Allocator,
revert_requested: bool = false, // set by the command listener thread, read by the drawing thread
/// Instrumentation and debugging state for each stage
state: std.AutoHashMapUnmanaged(usize, State) = .{},
support: instrumentation.Processor.Config.Support = .{ .buffers = false, .max_variables_size = 0, .include = true, .all_once = false },

pub fn initStatic(allocator: std.mem.Allocator) !void {
    available_data = @TypeOf(available_data).init(allocator);
    data_breakpoints = @TypeOf(data_breakpoints).init(allocator);

    if (glslang.glslang_initialize_process() == 0) {
        return error.GLSLang;
    }
    inited_static = true;
}

pub fn deinitStatic() void {
    if (inited_static) {
        available_data.deinit();
        data_breakpoints.deinit();

        glslang.glslang_finalize_process();
    } else {
        log.warn("Deinitializing shaders service without initializing it", .{});
    }
}

pub fn deinit(service: *@This()) void {
    service.Programs.deinit(.{});
    service.Shaders.deinit(.{});
    service.physical_to_virtual.deinit();
    service.dirty_breakpoints.deinit(service.allocator);
    var it = service.state.valueIterator();
    while (it.next()) |s| {
        s.deinit();
    }
    service.state.deinit(service.allocator);
}

pub fn getOrAddService(context: *const anyopaque, allocator: std.mem.Allocator) !@TypeOf(services).GetOrPutResult {
    const result = try services.getOrPut(allocator, context);
    if (!result.found_existing) {
        const thr_name = try common.process.getSelfThreadName(allocator);
        defer allocator.free(thr_name);
        const name = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ thr_name, services.count() });
        try services_by_name.put(allocator, name, result.value_ptr);

        result.value_ptr.* = Service{
            .physical_to_virtual = ArrayBufMap(VirtualDir.Set).init(allocator),
            .Shaders = @TypeOf(result.value_ptr.Shaders).init(allocator),
            .Programs = @TypeOf(result.value_ptr.Programs).init(allocator),
            .allocator = allocator,
            .context = context,
            .name = name,
        };
    }
    return result;
}

pub fn getServiceByName(name: String) ?*Service {
    return services_by_name.get(name);
}

pub fn getService(context: *const anyopaque) ?*Service {
    return services.getPtr(context);
}

pub fn servicesCount() usize {
    return services.count();
}

/// *NOTE*: Invalidated event should be called on DAP after calling this functon.
/// *NOTE*: service.deinit() should be called before calling this function.
pub fn removeService(context: *const anyopaque, allocator: std.mem.Allocator) bool {
    if (services.getPtr(context)) |service| {
        service.deinit();
        std.debug.assert(services_by_name.remove(service.name));
        allocator.free(service.name);
        std.debug.assert(services.swapRemove(context));
        return true;
    }
    return false;
}

pub fn clearServices(allocator: std.mem.Allocator) void {
    for (services.values()) |*service| {
        service.deinit(allocator);
    }
    services.clearAndFree();
    services_by_name.clearAndFree();
}

pub fn deinitServices(allocator: std.mem.Allocator) void {
    for (services.values()) |*service| {
        service.deinit();
    }
    services.deinit(allocator);
    services_by_name.deinit(allocator);
}

pub fn allServices() []Service {
    return services.values();
}

pub fn allContexts() []*const anyopaque {
    return services.keys();
}

pub fn serviceNames() @TypeOf(services_by_name).KeyIterator {
    return services_by_name.keyIterator();
}

pub fn lockServices() void {
    services_by_name.lockPointers();
}

pub fn unlockServices() void {
    services_by_name.unlockPointers();
}

pub const VirtualDir = union(enum) {
    pub const ProgramDir = *Storage(Shader.Program, Shader.SourcePart, true).StoredDir;
    pub const ShaderDir = *Storage(Shader.SourcePart, void, false).StoredDir;
    pub const Set = std.AutoArrayHashMapUnmanaged(VirtualDir, void);

    Program: ProgramDir,
    Shader: ShaderDir,

    pub fn physical(self: @This()) *?String {
        return switch (self) {
            .Program => |d| &d.physical,
            .Shader => |d| &d.physical,
        };
    }

    pub fn parent(self: @This()) ?VirtualDir {
        switch (self) {
            .Program => |d| if (d.parent) |p| return VirtualDir{ .Program = p } else return null,
            .Shader => |d| if (d.parent) |p| return VirtualDir{ .Shader = p } else return null,
        }
    }

    pub fn name(self: @This()) String {
        return switch (self) {
            .Program => |d| d.name,
            .Shader => |d| d.name,
        };
    }
};

/// Service, Resource and Locator.
/// Globally identifies any shader resource in the workspace.
pub const ServiceLocator = struct {
    service: *Service,
    resource: ?ResourceLocator,

    /// `/abcdef/programs/...`
    ///
    /// Returns `null` for root
    pub fn parse(path: String) !?ServiceLocator {
        var it = try std.fs.path.ComponentIterator(.posix, u8).init(path);
        if (it.first()) |service_compound| {
            if (services_by_name.get(service_compound.name)) |service| {
                if (it.peekNext()) |_| {
                    return .{ .service = service, .resource = try ResourceLocator.parse(path[it.end_index..]) };
                } else {
                    return .{ .service = service, .resource = null };
                }
            }
        }
        return null;
    }

    pub fn format(self: @This(), comptime _: String, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll(self.service.name);
        if (self.resource) |r| {
            try writer.print("/{}", .{r});
        }
    }
};

/// Represents a virtual resource or directory path inside a service.
pub const ResourceLocator = union(enum) {
    programs: storage.Locator.Nesting,
    /// Shader source part.
    sources: storage.Locator,

    pub const sources_path = "/sources";
    pub const programs_path = "/programs";

    pub fn parse(path: String) !ResourceLocator {
        if (std.mem.startsWith(u8, path, programs_path)) {
            return @This(){
                .programs = try storage.Locator.Nesting.parse(path[programs_path.len..]),
            };
        } else if (std.mem.startsWith(u8, path, sources_path)) {
            return @This(){ .sources = try storage.Locator.parse(path[sources_path.len..]) };
        } else return storage.Error.InvalidPath;
    }

    pub fn isInstrumented(self: @This()) bool {
        return switch (self) {
            .programs => |p| p.nested.instrumented,
            .sources => |s| s.instrumented,
        };
    }

    pub fn isTagged(self: @This()) bool {
        return switch (self) {
            .programs => |p| p.name == .tagged,
            .sources => |s| s.name == .tagged,
        };
    }

    pub fn name(self: @This()) String {
        return switch (self) {
            .programs => |p| p.fullPath,
            .sources => |s| s.name,
        };
    }

    pub fn toTagged(self: @This(), allocator: std.mem.Allocator, basename: String) !@This() {
        return switch (self) {
            .programs => |p| .{ .programs = try p.toTagged(allocator, basename) },
            .sources => |s| .{ .sources = try s.toTagged(basename) },
        };
    }

    pub fn format(self: @This(), comptime _: String, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .programs => |p| {
                try writer.writeAll(programs_path[1..]);
                try writer.print("/{}", .{p});
            },
            .sources => |s| {
                try writer.writeAll(sources_path[1..]);
                try writer.print("/{}", .{s});
            },
        }
    }
};

/// Instrumentation and debuging state of a single shader stage
const State = struct {
    /// Input params for the instrumentation process
    pub const Params = struct {
        allocator: std.mem.Allocator,
        //dimensions
        screen: [2]usize,
        vertices: usize,
        instances: usize,
        // xyz group count and xyz group sizes
        compute: [6]usize,

        max_attachments: usize,
        max_buffers: usize,
        /// Maximum number of XFB float output variables
        max_xfb: usize,
        search_paths: ?std.AutoHashMapUnmanaged(Ref, []String),
        used_buffers: std.ArrayList(Ref),
        used_interface: std.ArrayList(Ref),
    };
    /// Needs re-instrumentation (stepping enabled flag, pause mode, or source code has changed)
    dirty: bool,
    params: Params,
    /// Mutable state of debug outputs generated by the instrumentation. Can be edited externally (e.g. to assign host-side refs).
    /// Uses allocator from `params`. If `outputs` are null, no instrumentation was done.
    outputs: instrumentation.Result.Outputs,
    //
    // Client debugger state. Does not affect the instrumentation
    //
    /// If source stepping is ongoing, this is the global index of the currently reached step.
    /// Can be used for the purpose of setting the target step index with `target_step`.
    reached_step: ?struct {
        id: u32,
        /// Index into `Outputs.parts_offsets`
        index: u32,
    } = null,
    /// Index for the step counter to check for.
    /// Set to non-null value to enable stepping.
    target_step: ?u32 = null,
    /// Same as `target_step`, but is checked only on places with breakpoints.
    target_bp: u32 = 0,
    selected_thread: [3]usize = .{ 0, 0, 0 },
    selected_group: ?[3]usize = .{ 0, 0, 0 },

    pub fn globalSelectedThread(self: *const @This()) usize {
        const groups = self.selected_group orelse .{ 0, 0, 0 };
        var group_area: usize = self.outputs.group_dim[0];
        for (self.outputs.group_dim[1..]) |g| {
            group_area *= g;
        }

        const group_offset = if (self.outputs.group_count) |gc| blk: {
            var selected_g_flat: usize = groups[0];
            if (gc.len > 1) {
                selected_g_flat += groups[1] * self.outputs.group_dim[0];
                if (gc.len > 2) {
                    selected_g_flat += groups[2] * self.outputs.group_dim[0] * self.outputs.group_dim[1];
                }
            }
            break :blk selected_g_flat * group_area;
        } else 0;

        var thread_in_group = self.selected_thread[0];
        if (self.outputs.group_dim.len > 1) {
            thread_in_group += self.selected_thread[1] * self.outputs.group_dim[0];
            if (self.outputs.group_dim.len > 2) {
                thread_in_group += self.selected_thread[2] * self.outputs.group_dim[0] * self.outputs.group_dim[1];
            }
        }

        return group_offset + thread_in_group;
    }

    pub fn deinit(self: *@This()) void {
        self.outputs.deinit(self.params.allocator);
        self.params.used_interface.deinit();
        self.params.used_buffers.deinit();
    }
};

//
// Workspaces functionality
//

pub fn getDirByLocator(service: *@This(), locator: ResourceLocator) !VirtualDir {
    return switch (locator) {
        .sources => |s| .{ .Shader = try service.Shaders.getDirByPath(s.name.tagged) },
        .programs => |p| .{ .Program = try service.Programs.getDirByPath(p.name.tagged) },
    };
}

/// Maps real absolute directory paths to virtual storage paths.
///
/// *NOTE: when unsetting or setting path mappings, virtual paths must exist. Physical paths are not validated in any way.*
/// Physical paths can be mapped to multiple virtual paths but not vice versa.
pub fn mapPhysicalToVirtual(service: *@This(), physical: String, virtual: ResourceLocator) !void {
    // check for parent overlap
    // TODO more effective

    const entry = try service.physical_to_virtual.getOrPut(physical);
    if (!entry.found_existing) {
        entry.value_ptr.* = VirtualDir.Set{};
    }

    const dir = try service.getDirByLocator(virtual);
    if (dir.physical().*) |existing_phys| {
        service.allocator.free(existing_phys);
    }
    dir.physical().* = entry.key_ptr.*;
    _ = try entry.value_ptr.getOrPut(service.allocator, dir); // means 'put' effectively on set-like hashmaps
}

/// Actually checks if the path exists in real filesystem
pub fn resolvePhysicalByVirtual(service: *@This(), virtual: ResourceLocator) !?CString {
    // Get the virtual directory
    var stack = std.ArrayListUnmanaged(VirtualDir){};
    var virtual_dir = service.getDirByLocator(virtual) catch |err| if (err == error.TagExists) try (try service.getResourcesByLocator(virtual)).firstParent() else return err;
    var physical = virtual_dir.physical().*;
    // Walk the directory tree to find the physical connection
    return while (true) {
        if (virtual_dir.parent()) |p| {
            try stack.append(service.allocator, virtual_dir);
            virtual_dir = p;
            physical = p.physical().*;
            const path = try getPathFromStack(service.allocator, stack, physical orelse continue);
            std.fs.cwd().accessZ(path, .{}) catch |err| switch (err) {
                error.FileNotFound, error.BadPathName => {
                    defer service.allocator.free(path);
                    // try next parent
                    continue;
                },
                else => return err,
            };
            break path.ptr;
        } else {
            return null; // No physical connection found in the directory tree
        }
    };
}

fn getPathFromStack(allocator: std.mem.Allocator, stack: std.ArrayListUnmanaged(VirtualDir), root: String) !ZString {
    var path = std.ArrayListUnmanaged(u8){};
    try path.appendSlice(allocator, root);
    for (stack.items) |i| {
        try path.append(allocator, '/');
        try path.appendSlice(allocator, i.name());
    }
    return try path.toOwnedSliceSentinel(allocator, 0);
}

pub fn clearWorkspacePaths(service: *@This()) void {
    for (service.physical_to_virtual.hash_map.values()) |*val| {
        val.deinit(service.allocator);
    }
    service.physical_to_virtual.clearAndFree();
}

/// When `virtual` is null, all virtual paths associated with the physical path will be removed
pub fn removeWorkspacePath(service: *@This(), real: String, virtual: ?ResourceLocator) !bool {
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

fn statStorage(stor: anytype, locator: storage.Locator.Name, nested: ?storage.Locator) !storage.StatPayload {
    // {target, ?remaining_iterator}
    var dir_or_file = blk: {
        switch (locator) {
            .untagged => |combined| if (combined.isRoot())
                return try storage.Stat.now().toPayload(.Directory, 0) // TODO: untagged root not always dirty
            else if (stor.all.get(combined.ref)) |parts| {
                const item = if (@TypeOf(stor.*).isParted) &parts.items[combined.part] else parts;
                break :blk .{ item, null };
            } else return error.TargetNotFound,
            .tagged => |tagged| {
                var path_it = std.mem.splitScalar(u8, tagged, '/');
                var dir = stor.tagged_root;
                if (std.mem.eql(u8, tagged, "")) return dir.stat.toPayload(.Directory, 0); // TODO: tagged root not always dirty
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
                        defer physical_dir.close();
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
                                    physical_dir.close();
                                    physical_dir = p_dir;
                                },
                            }
                        }
                    }
                    return v_stat.toPayload(.Directory, 0);
                }
                if (dir.files.get(last_part)) |file| {
                    break :blk .{ file.target, path_it };
                    // is a source in Shaders or a program in Programs
                    // or can be a (un)tagged nested under tagged program
                }
                return error.TargetNotFound;
            },
        }
    };

    const is_nesting = comptime isNesting(@TypeOf(dir_or_file[0]));
    blk: {
        if (is_nesting) {
            const stage = try if (dir_or_file[1]) |remaining_iterator|
                dir_or_file[0].getNested(((try storage.Locator.parse(remaining_iterator.rest())).file() orelse return storage.Error.InvalidPath).name)
            else if (nested) |n| if (n.file()) |nf|
                dir_or_file[0].getNested(nf.name)
            else
                break :blk else break :blk;

            if (stage.Nested.nested) |target| {
                // Nested file
                var payload = try target.stat.toPayload(.File, target.lenOr0());
                if (target.tag != null) {
                    payload.type = payload.type | @intFromEnum(storage.FileType.SymbolicLink);
                }
                if (nested != null and nested.?.instrumented) {
                    payload.permission = .ReadOnly;
                }
                return payload;
            } else {
                // Nested untagged root
                return stage.Nested.parent.stat.toPayload(.Directory, 0);
            }
        }
    }

    var payload = try dir_or_file[0].stat.toPayload(if (is_nesting) .Directory else .File, dir_or_file[0].lenOr0());
    if (locator == .tagged) {
        payload.type = payload.type | @intFromEnum(storage.FileType.SymbolicLink);
    }
    return payload;
}

pub fn stat(self: *@This(), locator: ResourceLocator) !storage.StatPayload {
    var s = switch (locator) {
        .sources => |sources| try statStorage(&self.Shaders, sources.name, null),
        .programs => |programs| try statStorage(&self.Programs, programs.name, programs.nested),
    };
    if (locator.isInstrumented()) {
        s.permission = .ReadOnly;
    }
    return s;
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
pub fn setDataBreakpoint(bp: debug.DataBreakpoint) !debug.DataBreakpoint {
    if (data_breakpoints.contains(bp.dataId)) {
        return error.AlreadyExists;
    } else if (!available_data.contains(bp.dataId)) {
        return error.TargetNotFound;
    } else {
        try data_breakpoints.put(bp.dataId, .{
            .accessType = bp.accessType,
            .condition = bp.condition,
            .hitCondition = bp.hitCondition,
        });
        return bp;
    }
}
pub fn clearDataBreakpoints() void {
    data_breakpoints.clearAndFree();
}
pub const CompileFunc = *const fn (program: Shader.Program, stage: usize, source: String) anyerror!void;

/// Single unique running shader instance descriptor payload for the debug adapter
pub const Running = struct {
    /// Shader identifier that is unique among all services (all contexts).
    /// Contains information about the corresponding `Service` and shader.
    pub const Locator = struct {
        impl: usize,
        pub fn parse(thread_id: usize) @This() {
            return .{ .impl = thread_id };
        }

        pub fn service(self: *const @This()) !*Service {
            const index = self.impl % 100;
            if (index >= services.count()) return error.ServiceNotFound;
            return &services.values()[index];
        }

        pub fn shader(self: *const @This()) usize {
            return self.impl / 100;
        }

        pub fn from(serv: *const Service, shader_ref: usize) !@This() {
            const service_index = services.getIndex(serv.context) orelse return error.ServiceNotFound;
            std.debug.assert(service_index < 100);
            return .{ .impl = shader_ref * 100 + service_index };
        }
    };

    id: Locator,
    name: String,
    group_dim: []usize,
    group_count: ?[]usize,
    selected_thread: [3]usize,
    selected_group: ?[3]usize,
    type: String,

    pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(self.type);
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.objectField("id");
        try jw.write(self.id.impl);
        try jw.objectField("selectedThread"); // zig vs JSON case :)
        try jw.write(self.selected_thread);

        try jw.objectField("groupDim");
        try jw.beginArray();
        for (self.group_dim) |d| {
            if (d == 0) {
                break;
            }
            try jw.write(d);
        }
        try jw.endArray();

        if (self.group_count) |groups| {
            try jw.objectField("groupCount");
            try jw.beginArray();
            for (groups) |d| {
                if (d == 0) {
                    break;
                }
                try jw.write(d);
            }
            try jw.endArray();

            try jw.objectField("selectedGroup");
            try jw.write(self.selected_group);
        }

        try jw.endObject();
    }

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub fn addBreakpoint(self: *@This(), locator: storage.Locator, bp: debug.SourceBreakpoint) !debug.Breakpoint {
    const shader = try self.Shaders.getStoredByLocator(locator.name);
    const new = try shader.*.addBreakpoint(bp);
    if (self.state.getPtr(shader.*.ref)) |state| {
        state.dirty = true;
    }
    return new;
}

const ProgramOrShader = struct {
    program: ?*const Shader.Program,
    shader: ?struct {
        source: *Shader.SourcePart,
        part: usize,
    },

    pub fn firstParent(self: *const @This()) !VirtualDir {
        if (self.shader) |shader| {
            if (shader.source.tag) |tag| {
                return VirtualDir{ .Shader = tag.parent };
            }
        }
        return error.NotTagged;
    }
};

pub fn getResourcesByLocator(self: *@This(), locator: ResourceLocator) !ProgramOrShader {
    return switch (locator) {
        .programs => |p| //
        switch (try self.Programs.getByLocator(p.name, p.nested.name)) {
            .Nested => |nested| .{
                .program = nested.parent,
                .shader = .{
                    .source = nested.nested orelse return error.DirExists,
                    .part = nested.part,
                },
            },
            .Tag => |tag| .{
                .program = tag.target,
                .shader = null,
            },
            else => error.DirExists,
        },
        .sources => |s| .{
            .program = null,
            .shader = .{
                .source = try self.Shaders.getStoredByLocator(s.name),
                .part = switch (s.name) {
                    .untagged => |comb| comb.part,
                    else => 0,
                },
            },
        },
    };
}

pub fn getSourceByRLocator(self: *@This(), locator: ResourceLocator) !*Shader.SourcePart {
    return switch (locator) {
        .programs => |p| try self.Programs.getNestedByLocator(p.name, p.nested.name),
        .sources => |s| try self.Shaders.getStoredByLocator(s.name),
    };
}

pub fn addBreakpointAlloc(self: *@This(), locator: ResourceLocator, bp: debug.SourceBreakpoint, allocator: std.mem.Allocator) !debug.Breakpoint {
    const target = try self.getResourcesByLocator(locator);
    const shader = target.shader orelse return error.TargetNotFound;
    var new = try shader.source.addBreakpoint(bp);
    new.path = try self.fullPath(allocator, shader.source, target.program, shader.part);
    if (self.state.getPtr(shader.source.ref)) |state| {
        state.dirty = true;
    }
    return new;
}

/// Tries to get tagged path, or falls back to untagged path
pub fn fullPath(self: @This(), allocator: std.mem.Allocator, shader: *Shader.SourcePart, program: ?*const Shader.Program, part_index: usize) !String {
    const basename = try shader.basenameAlloc(allocator, part_index);
    defer allocator.free(basename);
    if (program) |p| {
        if (p.tag) |t| {
            const program_path = try t.fullPathAlloc(allocator, false);
            defer allocator.free(program_path);
            return std.fmt.allocPrint(allocator, "/{s}" ++ ResourceLocator.programs_path ++ "{s}/{s}", .{ self.name, program_path, basename });
        } else {
            return std.fmt.allocPrint(allocator, "/{s}" ++ ResourceLocator.programs_path ++ storage.untagged_path ++ "/{x}/{s}", .{ self.name, p.ref, basename });
        }
    }

    if (shader.tag) |t| {
        const source_path = try t.fullPathAlloc(allocator, false);
        defer allocator.free(source_path);
        return std.fmt.allocPrint(allocator, "/{s}" ++ ResourceLocator.sources_path ++ "{s}", .{ self.name, source_path });
    } else {
        return std.fmt.allocPrint(allocator, "/{s}" ++ ResourceLocator.sources_path ++ storage.untagged_path ++ "/{}{s}", .{ self.name, storage.Locator.PartRef{ .ref = shader.ref, .part = part_index }, shader.toExtension() });
    }
}

pub fn removeBreakpoint(self: *@This(), locator: storage.Locator, bp: debug.SourceBreakpoint) !void {
    const shader = try self.Shaders.getStoredByLocator(locator) orelse return error.TargetNotFound;
    try shader.*.removeBreakpoint(bp);
    if (self.state.getPtr(shader.*.ref)) |state| {
        state.dirty = true;
    }
}

pub fn clearBreakpoints(self: *@This(), locator: storage.Locator) !void {
    const shader = try self.Shaders.getStoredByLocator(locator) orelse return error.TargetNotFound;
    try shader.*.clearBreakpoints();
    if (self.state.getPtr(shader.*.ref)) |state| {
        state.dirty = true;
    }
}

pub fn runningShaders(self: *const @This(), allocator: std.mem.Allocator, result: *std.ArrayListUnmanaged(Running)) !void {
    var c_it = self.state.iterator();
    while (c_it.next()) |state_entry| {
        if (self.Shaders.all.get(state_entry.key_ptr.*)) |shader_parts| {
            const shader: *Shader.SourcePart = &shader_parts.items[0]; // TODO is it bad when the shader is dirty?
            try result.append(allocator, Running{
                .id = try Running.Locator.from(self, shader.ref),
                .type = @tagName(shader.stage),
                .name = try std.fmt.allocPrint(allocator, "{name}", .{Shader.SourcePart.WithIndex{ .source = shader, .part_index = 0 }}),
                .group_dim = state_entry.value_ptr.outputs.group_dim,
                .group_count = state_entry.value_ptr.outputs.group_count,
                .selected_thread = state_entry.value_ptr.selected_thread,
                .selected_group = state_entry.value_ptr.selected_group,
            });
        }
    }
}

/// Invalidate all shader's instrumentation state
pub fn invalidate(self: *@This()) void {
    var it = self.state.valueIterator();
    while (it.next()) |state| {
        state.dirty = true;
    }
}

pub fn selectThread(shader_locator: usize, thread: []usize, group: ?[]usize) !void {
    const locator = Running.Locator.parse(shader_locator);
    const service = try locator.service();
    const state = service.state.getPtr(locator.shader()) orelse return error.NotInstrumented;
    const shader = service.Shaders.all.get(locator.shader()) orelse return error.TargetNotFound;

    for (0..thread.len) |i| {
        state.selected_thread[i] = thread[i];
    }
    if (group) |g| if (state.selected_group) |*sg|
        for (0..g.len) |i| {
            sg[i] = g[i];
        };

    for (shader.items) |*s| {
        s.i_dirty = true;
    }
}

pub fn stackTrace(allocator: std.mem.Allocator, args: debug.StackTraceArguments) !debug.StackTraceResponse {
    const levels = args.levels orelse 1;
    var result = std.ArrayListUnmanaged(debug.StackFrame){};
    const locator = Running.Locator.parse(args.threadId);
    const service = try locator.service();

    const state = service.state.get(locator.shader()) orelse return error.NotInstrumented;
    if (state.reached_step) |global_step| {
        const shader = service.Shaders.all.get(locator.shader()) orelse return error.TargetNotFound;
        const local = state.outputs.localStepOffset(global_step.id);

        if (local.offset) |o| {
            const s = shader.items[local.part].possible_steps.?.items(.pos)[global_step.id - o];
            try result.append(allocator, debug.StackFrame{
                .id = 0,
                .line = s.line,
                .column = s.character,
                .name = "main",
                .path = try service.fullPath(allocator, &(shader).items[local.part], null, local.part),
            });
            if (levels > 1) {
                for (1..levels) |_| {
                    // TODO nesting
                }
            }
        } else {
            log.warn("Reached global stop index {d} did not match any local stop.", .{global_step.id});
        }
    }
    const arr = try result.toOwnedSlice(allocator);

    return debug.StackTraceResponse{
        .stackFrames = arr,
        .totalFrames = if (arr.len > 0) 1 else 0,
    };
}

pub fn disableBreakpoints(self: *@This(), shader_ref: usize) !void {
    const shader = self.Shaders.all.get(shader_ref) orelse return error.TargetNotFound;
    const state = self.state.getPtr(shader_ref) orelse return error.NotInstrumented;

    state.target_bp = std.math.maxInt(u32); // TODO shader uses u32. Would 64bit be a lot slower?

    for (shader.items) |*s| {
        s.dirty = true;
    }
}

/// Continue to next breakpoint hit or end of the shader
pub fn @"continue"(self: *@This(), shader_ref: usize) !void {
    const shader = self.Shaders.all.get(shader_ref) orelse return error.TargetNotFound;
    const state = self.state.getPtr(shader_ref) orelse return error.NotInstrumented;

    state.target_bp = (if (state.reached_step) |s| s.index else 0) +% 1;
    if (state.target_step) |_| {
        state.target_step = std.math.maxInt(u32);
    }

    for (shader.items) |*s| {
        s.i_dirty = true;
    }
}

/// Increments the desired step (or also desired breakpoint) selector for the shader `shader_ref`.
pub fn advanceStepping(self: *@This(), shader_ref: usize, target: ?u32) !void {
    const shader: *std.ArrayListUnmanaged(Shader.SourcePart) = self.Shaders.all.get(shader_ref) orelse return error.TargetNotFound;

    const state = self.state.getPtr(shader_ref) orelse return error.NotInstrumented;
    const next = (if (state.reached_step) |s| s.index else 0) +% 1;
    if (state.target_step == null) {
        // invalidate instrumentated code because stepping was previously disabled
        state.dirty = true;
    }

    if (target) |t| {
        state.target_step = t;
        state.target_bp = t;
    } else {
        state.target_step = next; //TODO limits
        state.target_bp = next;
    }

    for (shader.items) |*s| {
        s.i_dirty = true;
    }
}

pub fn disableStepping(self: *@This(), shader_ref: usize) !void {
    const shader = self.Shaders.all.get(shader_ref) orelse return error.TargetNotFound;

    const state = self.state.getPtr(shader_ref) orelse return error.NotInstrumented;
    if (state.params.target_step) {
        state.params.target_step = null;
        state.dirty = true;
        for (shader.items) |*s| {
            s.dirty = true;
        }
    }
}

fn instrumentOrGetCached(self: *@This(), program: *Shader.Program, params: *State.Params, key: usize, sources: []Shader.SourcePart) !union(enum) {
    cached: *State,
    new: instrumentation.Result,
} {
    const state = self.state.getPtr(key);
    return find_cached: {
        if (state) |c| {
            if (c.dirty) { // marked dirty by another mechanism
                log.debug("Shader {x} marked dirty", .{key});
                break :find_cached null;
            }
            // check for params mismatch
            if (params.used_interface.items.len > 0) {
                if (params.used_interface.items.len != c.params.used_interface.items.len) {
                    log.debug("Shader {x} interface shape changed", .{key});
                    break :find_cached null;
                }
                for (params.used_interface.items, c.params.used_interface.items) |p, c_p| {
                    if (p != c_p) {
                        log.debug("Shader {x} interface {d} changed", .{ key, p });
                        break :find_cached null;
                    }
                }
            }
            if (params.screen[0] != 0) {
                if (params.screen[0] != c.params.screen[0] or params.screen[1] != c.params.screen[1]) {
                    log.debug("Shader {x} screen changed", .{key});
                    break :find_cached null;
                }
            }
            if (params.vertices != 0) {
                if (params.vertices != c.params.vertices) {
                    log.debug("Shader {x} vertices changed", .{key});
                    break :find_cached null;
                }
            }
            if (params.compute[0] != 0) {
                if (params.compute[0] != c.params.compute[0] or params.compute[1] != c.params.compute[1] or params.compute[2] != c.params.compute[2]) {
                    log.debug("Shader {x} compute shape changed", .{key});
                    break :find_cached null;
                }
            }

            break :find_cached .{
                .cached = c, //should really be there when the cache check passes
            };
        } else {
            log.debug("Shader {x} was not instrumented before", .{key});
            break :find_cached null;
        }
    } orelse blk: {
        // Get new instrumentation
        // TODO what if threads_offset has changed
        const result = try Shader.instrument(self, sources, if (state) |s| s.target_step != null else false, params, &program.uniform_locations, &program.uniform_names);
        errdefer result.deinit(params.allocator);
        if (result.source) |s| {
            if (sources[0].tag) |tag| {
                log.debug("Shader {x}:{s} instrumented source:\n{s}", .{ sources[0].ref, tag.name, s[0..result.length] });
            } else {
                log.debug("Shader {x} instrumented source:\n{s}", .{ sources[0].ref, s[0..result.length] });
            }
        }
        if (result.outputs.diagnostics.items.len > 0) {
            log.info("Shader {x} instrumentation diagnostics:", .{sources[0].ref});
            for (result.outputs.diagnostics.items) |diag| {
                log.info("{d}: {s}", .{ diag.span.start, diag.message }); // TODO line and column pos instead of offset
            }
        }
        break :blk .{ .new = result };
    };
}

// shader stages order: vertex, tessellation control, tessellation evaluation, geometry, fragment, compute
const stages_order = std.EnumMap(decls.Stage, usize).init(.{
    .gl_vertex = 0,
    .vk_vertex = 0,
    .gl_tess_control = 1,
    .vk_tess_control = 1,
    .gl_tess_evaluation = 2,
    .vk_tess_evaluation = 2,
    .gl_task = 1,
    .vk_task = 1,
    .gl_mesh = 2, // replaces vertex, geometry and tesselation
    .vk_mesh = 2,
    .gl_geometry = 3,
    .vk_geometry = 3,
    .gl_fragment = 4,
    .vk_fragment = 4,
    .gl_compute = 5,
    .vk_compute = 5,
    .vk_raygen = 6,
    .vk_anyhit = 7,
    .vk_closesthit = 7,
    .vk_miss = 7,
    .vk_intersection = 7,
    .vk_callable = 7,
    .unknown = std.math.maxInt(usize),
});

fn sortStages(_: void, a: ShadersRefMap.Entry, b: ShadersRefMap.Entry) bool {
    return (stages_order.get(a.value_ptr.*.items[0].stage) orelse 0) < (stages_order.get(b.value_ptr.*.items[0].stage) orelse 0);
}

/// Instruments all (or selected) shader stages of the program.
/// The returned Outputs hashmap should be freed by the caller, but not the content it refers to.
/// *NOTE: Should be called by the drawing thread because shader source code compilation is invoked insde.*
pub fn instrument(self: *@This(), program: *Shader.Program, in_params: State.Params) !InstrumentationResult {
    // copy free_attachments and used_buffers for passing them by reference because all stages will share them
    var params = in_params;
    var copied_i = try std.ArrayList(usize).initCapacity(params.allocator, params.used_interface.items.len);
    copied_i.appendSliceAssumeCapacity(params.used_interface.items);
    params.used_interface = copied_i;
    var copied_b = try std.ArrayList(usize).initCapacity(params.allocator, params.used_buffers.items.len);
    copied_b.appendSliceAssumeCapacity(params.used_buffers.items);
    params.used_buffers = copied_b;

    var state = std.AutoArrayHashMapUnmanaged(usize, *State){};
    var invalidated_any = false;
    var invalidated_uniforms = false;
    // Collapse the map into a list
    const shader_count = program.stages.count();
    const shaders_list = try params.allocator.alloc(ShadersRefMap.Entry, shader_count);
    defer params.allocator.free(shaders_list);
    {
        var iter = program.stages.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| : (i += 1) {
            shaders_list[i] = entry;
        }
    }
    // sort the stages by the order they will be executed
    std.sort.heap(ShadersRefMap.Entry, shaders_list, {}, sortStages);

    try state.ensureTotalCapacity(params.allocator, shader_count);
    // needs re-link?
    var re_link = false;
    for (shaders_list) |shader_entry| {
        const shader_parts = shader_entry.value_ptr; // One shader represented by a list of its source parts
        const first_part = shader_parts.*.items[0];

        for (shader_parts.*.items) |*sp| {
            if (sp.i_dirty) {
                invalidated_uniforms = true;
                sp.i_dirty = false; // clear
            }
        }

        var shader_result = try self.instrumentOrGetCached(
            program,
            &params,
            shader_entry.key_ptr.*,
            shader_parts.*.items,
        );
        switch (shader_result) {
            .cached => |cached_state| try state.put(params.allocator, shader_entry.key_ptr.*, cached_state),
            .new => |*new_result| {
                invalidated_any = true;
                errdefer new_result.deinit(params.allocator);

                // A new instrumentation was emitted
                if (new_result.source) |instrumented_source| {
                    // If any instrumentation was emitted,
                    // replace the shader source with the instrumented one on the host side
                    if (first_part.compileHost) |c| {
                        const payload = try Shader.SourcePart.toPayload(params.allocator, shader_parts.*.items);
                        defer Shader.SourcePart.freePayload(payload, params.allocator);

                        const result = c(payload, instrumented_source, @intCast(new_result.length));
                        if (result != 0) {
                            log.err("Failed to compile instrumented shader {x}. Code {d}", .{ program.ref, result });
                            new_result.deinit(params.allocator);
                            continue;
                        }
                    } else {
                        log.err("No compileHost function for shader {x}", .{program.ref});
                        new_result.deinit(params.allocator);
                        continue;
                    }

                    re_link = true;
                }

                // Update the cache
                const cache_entry = try self.state.getOrPut(params.allocator, first_part.ref);
                if (cache_entry.found_existing) {
                    const c = cache_entry.value_ptr;
                    // Update params
                    if (params.used_interface.items.len > 0) {
                        c.params.used_interface.clearRetainingCapacity();
                        try c.params.used_interface.ensureTotalCapacity(in_params.used_interface.items.len);
                        c.params.used_interface.appendSliceAssumeCapacity(in_params.used_interface.items);
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
                    if (params.used_buffers.capacity > 0) {
                        c.params.used_buffers.clearRetainingCapacity();
                        try c.params.used_buffers.ensureTotalCapacity(in_params.used_buffers.items.len);
                        c.params.used_buffers.appendSliceAssumeCapacity(in_params.used_buffers.items);
                    }
                    c.dirty = false;
                    c.outputs = new_result.toOwnedOutputs(params.allocator);
                } else {
                    // Initialize state cache entry
                    cache_entry.value_ptr.* = State{
                        .params = .{
                            .allocator = params.allocator,
                            .compute = params.compute,
                            .instances = params.instances,
                            .max_attachments = params.max_attachments,
                            .max_buffers = params.max_buffers,
                            .max_xfb = params.max_xfb,
                            .screen = params.screen,
                            .search_paths = params.search_paths,
                            .used_buffers = std.ArrayList(usize).fromOwnedSlice(params.allocator, try params.allocator.dupe(usize, params.used_buffers.items)),
                            .used_interface = std.ArrayList(usize).fromOwnedSlice(params.allocator, try params.allocator.dupe(usize, params.used_interface.items)),
                            .vertices = params.vertices,
                        },
                        .dirty = false,
                        .outputs = new_result.toOwnedOutputs(params.allocator),
                    };
                }
                if (new_result.source != null) {
                    try state.put(params.allocator, shader_entry.key_ptr.*, cache_entry.value_ptr);
                }
            },
        }
    }

    // Re-link the program
    if (re_link) {
        if (program.link) |l| {
            const path = if (program.tag) |t| try t.fullPathAlloc(params.allocator, true) else null;
            defer if (path) |p|
                params.allocator.free(p);
            const result = l(decls.ProgramPayload{
                .ref = program.ref,
                .context = program.context,
                .count = 0,
                .link = program.link,
                .path = if (path) |p| p.ptr else null,
                .shaders = null, // the shaders array is useful only for attaching new shaders
            });
            if (result != 0) {
                log.err("Failed to link program {x} for instrumentation. Code {d}", .{ program.ref, result });
                return error.Link;
            }
        } else {
            log.err("No link function provided for program {x}", .{program.ref});
            return error.Link;
        }
    }
    return .{ .state = state, .invalidated = invalidated_any, .uniforms_invalidated = invalidated_uniforms };
}

/// Empty variables used just for type resolution
const SourcesPayload: decls.SourcesPayload = undefined;
const ProgramPayload: decls.ProgramPayload = undefined;

pub const InstrumentationResult = struct {
    invalidated: bool,
    uniforms_invalidated: bool,
    /// Instrumentation state for shader stages in the order as they are executed
    state: std.AutoArrayHashMapUnmanaged(usize, *State),
};

/// Methods for working with a collection of `SourcePart`s
pub const Shader = struct {
    pub const BreakpointSpecial = struct {
        condition: ?String,
        hit_condition: ?String,
        log_message: ?String,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (self.hit_condition) |hc| {
                allocator.free(hc);
            }
            if (self.condition) |c| {
                allocator.free(c);
            }
            if (self.log_message) |lm| {
                allocator.free(lm);
            }
        }
    };

    /// Class for interacting with a single source code part.
    /// Implements `Storage.Stored`.
    pub const SourcePart = struct {
        const StorageT = Storage(@This(), void, true);
        /// Can be used for formatting
        pub const WithIndex = struct {
            source: *const SourcePart,
            part_index: usize,

            pub fn format(self: @This(), comptime fmt_str: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                if (comptime std.mem.eql(u8, fmt_str, "name")) {
                    if (self.source.tag) |t| {
                        try writer.writeAll(t.name);
                    } else {
                        try writer.print("{}{s}", .{ storage.Locator.PartRef{ .ref = self.source.ref, .part = self.part_index }, self.source.toExtension() });
                    }
                } else {
                    @compileError("Unknown format string for Shader.SourcePart.WithIndex: {" ++ fmt_str ++ "}");
                }
            }
        };

        /// Special ref 0 means that this is source part is a named string (header file, not a standalone shader)
        ref: @TypeOf(SourcesPayload.ref) = 0,
        stat: storage.Stat,

        // SourcePart
        tag: ?*Tag(@This()) = null,
        stage: @TypeOf(SourcesPayload.stage) = @enumFromInt(0),
        language: @TypeOf(SourcesPayload.language) = @enumFromInt(0),
        /// Can be anything that is needed for the host application
        context: ?*const anyopaque = null,
        /// Graphics API-dependednt function that compiles the (instrumented) shader within the host application context. Defaults to glShaderSource and glCompileShader
        compileHost: @TypeOf(SourcesPayload.compile) = null,
        saveHost: @TypeOf(SourcesPayload.save) = null,
        currentSourceHost: @TypeOf(SourcesPayload.currentSource) = null,
        free: @TypeOf(SourcesPayload.free) = null,

        program: ?*Program = null,
        /// Does this source have #pragma deshader once
        once: bool = false,

        allocator: std.mem.Allocator,
        /// Contains a copy of the original passed string. Must be allocated by the `allocator`
        source: ?String = null,
        /// Contains references (indexes) to `stops` in the source code
        breakpoints: std.AutoHashMapUnmanaged(usize, BreakpointSpecial) = .{},
        /// A flag for the platform interface (e.g. `gl_shaders`) for setting the required uniforms for source-stepping
        i_dirty: bool = true, // TODO where to clear this?
        /// Syntax tree of the original shader source code. Used for breakpoint location calculation
        tree: ?analyzer.parse.Tree = null,
        /// Possible breakpoint or debugging step locations. Access using `possibleSteps()`
        possible_steps: ?Steps = null,

        pub const Steps = std.MultiArrayList(struct {
            pos: analyzer.lsp.Position,
            offset: usize,
            wrap_next: usize = 0,
        });

        pub fn deinit(self: *@This()) !void {
            if (self.source) |s| {
                self.allocator.free(s);
            }
            var it = self.breakpoints.valueIterator();
            while (it.next()) |bp| {
                bp.deinit(self.allocator);
            }
            self.breakpoints.deinit(self.allocator);
            if (self.possible_steps) |*s| {
                s.deinit(self.allocator);
            }
            if (self.tree) |*t| {
                t.deinit(self.allocator);
            }
        }

        pub fn touch(self: *@This()) void {
            self.stat.touch();
            if (self.tag) |t| {
                t.parent.touch();
            }
            if (self.program) |p| {
                p.touch();
            }
        }

        pub fn dirty(self: *@This()) void {
            self.stat.dirty();
            if (self.tag) |t| {
                t.parent.dirty();
            }
            if (self.program) |p| {
                p.dirty();
            }
        }

        pub fn basenameAlloc(source: *const SourcePart, allocator: std.mem.Allocator, part_index: usize) !String {
            if (source.tag) |t| {
                return try allocator.dupe(u8, t.name);
            } else {
                return try std.fmt.allocPrint(allocator, "{}{s}", .{ storage.Locator.PartRef{ .ref = source.ref, .part = part_index }, source.toExtension() });
            }
        }

        pub fn lenOr0(self: *const @This()) usize {
            return if (self.getSource()) |s| s.len else 0;
        }

        pub fn init(allocator: std.mem.Allocator, payload: decls.SourcesPayload, index: usize) !@This() {
            std.debug.assert(index < payload.count);
            var source: ?String = null;
            if (payload.sources != null) {
                source = if (payload.lengths) |lens|
                    try allocator.dupe(u8, payload.sources.?[index][0..lens[index]])
                else
                    try allocator.dupe(u8, std.mem.span(payload.sources.?[index]));
            }
            return SourcePart{
                .allocator = allocator,
                .ref = payload.ref,
                .stage = payload.stage,
                .compileHost = payload.compile,
                .saveHost = payload.save,
                .currentSourceHost = payload.currentSource,
                .language = payload.language,
                .context = if (payload.contexts != null) payload.contexts.?[index] else null,
                .stat = storage.Stat.now(),
                .source = source,
            };
        }

        /// Returns the currently saved (not instrumented) shader source part
        pub fn getSource(self: *const @This()) ?String {
            return self.source;
        }

        pub fn instrumentedSource(self: *const @This()) !?String {
            if (self.currentSourceHost) |c| {
                const path = if (self.tag) |t| try t.fullPathAlloc(self.allocator, true) else null;
                defer if (path) |p| self.allocator.free(p);
                if (c(self.ref, if (path) |p| p.ptr else null, if (path) |p| p.len else 0)) |source| {
                    return std.mem.span(source);
                }
            } else {
                log.warn("No currentSourceHost function for shader {x}", .{self.ref});
            }
            return null;
        }

        // TODO do not include if it's fully enclosed in include guard
        /// Flattens all included source parts into `result_parts` arraylist
        pub fn flattenIncluded(self: *@This(), service: *Service, search_paths: []String, allocator: std.mem.Allocator, already_included: ?*std.StringHashMapUnmanaged(void), result_parts: *std.ArrayListUnmanaged(*SourcePart)) !void {
            const tree = try self.parseTree();
            const source = self.getSource().?;
            for (tree.ignored()) |ignored| {
                const line = source[ignored.start..ignored.end];
                const directive = analyzer.parse.parsePreprocessorDirective(line) orelse continue;
                switch (directive) {
                    .include => |include| {
                        const include_path = line[include.path.start..include.path.end];

                        for (search_paths) |sp| {
                            const absolute_path = try std.fs.path.join(allocator, &.{ sp, include_path });
                            defer allocator.free(absolute_path);
                            if (already_included) |a| if (a.contains(absolute_path)) {
                                continue;
                            };

                            const included = service.Shaders.getStoredByPath(absolute_path) catch |err| {
                                if (err == storage.Error.DirectoryNotFound or err == storage.Error.TargetNotFound) {
                                    continue;
                                }
                                return err;
                            };

                            try included.flattenIncluded(service, search_paths, allocator, already_included, result_parts);

                            try result_parts.append(allocator, included);
                            if (already_included) |a| _ = try a.getOrPut(common.allocator, absolute_path);
                        }
                    },
                    else => continue,
                }
            }
        }

        /// The old source will be freed if it exists. The new source will be copied and owned
        pub fn replaceSource(self: *@This(), source: String) std.mem.Allocator.Error!void {
            self.invalidate();
            if (self.source) |s| {
                self.allocator.free(s);
            }
            self.dirty();
            self.source = try self.allocator.dupe(u8, source);
        }

        /// Invalidate instrumentation and code analysis state
        pub fn invalidate(self: *@This()) void {
            if (self.tree) |*t| {
                t.deinit(self.allocator);
            }
            if (self.possible_steps) |*s| {
                s.deinit(self.allocator);
            }
            self.tree = null;
        }

        pub fn parseTree(self: *@This()) !*const analyzer.parse.Tree {
            if (self.tree) |t| {
                return &t;
            } else {
                if (self.getSource()) |s| {
                    self.tree = try analyzer.parse.parse(self.allocator, s, .{});
                    return &self.tree.?;
                } else return error.NoSource;
            }
        }

        pub fn possibleSteps(self: *@This()) !Steps {
            if (self.possible_steps) |s| {
                return s;
            } else {
                var result = Steps{};
                const tree = try self.parseTree();
                const source = self.getSource().?;
                for (tree.nodes.items(.tag), 0..) |tag, node| {
                    const span = tree.nodeSpan(@intCast(node));
                    switch (tag) {
                        .statement => {
                            try result.append(self.allocator, .{ .pos = span.position(source), .offset = span.start, .wrap_next = 0 });
                        },
                        .declaration => {
                            if (tree.tag(tree.parent(node) orelse 0) == .block)
                                try result.append(self.allocator, .{ .pos = span.position(source), .offset = span.start, .wrap_next = 0 });
                        },
                        else => {},
                    }
                }
                const Sort = struct {
                    list: Steps,

                    pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                        const a = ctx.list.items(.pos)[a_index];
                        const b = ctx.list.items(.pos)[b_index];

                        return a.line < b.line or (a.line == b.line and a.character < b.character);
                    }
                };
                result.sortUnstable(Sort{ .list = result });
                self.possible_steps = result;
                return result;
            }
        }

        /// Fill `marked` with the insturmented version of the source part
        pub fn instrument(part: *@This(), step_part_offset: *usize, prev_offset: *usize, marked: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
            const part_steps = try part.possibleSteps();
            const part_source = part.getSource().?;

            defer step_part_offset.* += part_steps.len;
            for (part_steps.items(.offset), part_steps.items(.wrap_next), 0..) |offset, wrap, index| {
                // insert the previous part
                try marked.appendSlice(allocator, part_source[prev_offset.*..offset]);

                const eol = std.mem.indexOfScalar(u8, part_source[offset..], '\n') orelse part_source.len;
                const line = part_source[offset..][0..eol];

                if (parsePragmaDeshader(line)) { //ignore pragma deshader (hide Deshader from the API)
                    prev_offset.* += line.len;
                } else {
                    // insert the marker _step_(id, wrapped_code) into the line
                    const global_id = step_part_offset.* + index;
                    const writer = marked.writer(allocator);
                    if (wrap > 0) {
                        try writer.print(" {s}({d},{s}) ", .{ step_marker, global_id, part_source[offset .. offset + wrap] });
                    }
                    // note the spaces
                    try writer.print(" {s}({d}) ", .{ step_marker, global_id });
                    prev_offset.* = offset + wrap;
                }
            }

            // Insert rest of the source
            try marked.appendSlice(allocator, part_source[prev_offset.*..]);
        }

        /// The result will have empty path field
        pub fn addBreakpoint(self: *@This(), bp: debug.SourceBreakpoint) !debug.Breakpoint {
            var new = debug.Breakpoint{
                .id = null,
                .line = bp.line,
                .column = bp.column,
                .verified = false,
                .path = "",
            };
            var last_found_col: usize = 0;
            const steps = try self.possibleSteps();
            for (steps.items(.pos), 0..) |pos, index| {
                if (pos.line == bp.line or pos.line == bp.line + 1) { // permit 1 line differences
                    if (bp.column) |wanted_col| {
                        if (pos.character <= wanted_col) {
                            if (pos.character > last_found_col) {
                                last_found_col = pos.character;
                                new.column = pos.character;
                                new.verified = true;
                                new.id = index;
                            }
                        } else if (wanted_col != 0) {
                            if (last_found_col == 0) {
                                new.verified = false;
                                break;
                            }
                        }
                    } else {
                        new.id = index;
                        new.column = pos.character;
                        new.verified = true;
                        break;
                    }
                } else if (pos.line > bp.line) {
                    break;
                }
            }

            if (new.verified) {
                const gp = try self.breakpoints.getOrPut(self.allocator, new.id.?);
                if (gp.found_existing) {
                    gp.value_ptr.deinit(self.allocator);
                }
                gp.value_ptr.* = BreakpointSpecial{
                    .condition = if (bp.condition) |c| try self.allocator.dupe(u8, c) else null,
                    .hit_condition = if (bp.hitCondition) |c| try self.allocator.dupe(u8, c) else null,
                    .log_message = if (bp.logMessage) |m| try self.allocator.dupe(u8, m) else null,
                };
            } else {
                new.reason = "failed";
            }
            return new; //TODO check validity more precisely
        }

        pub fn removeBreakpoint(self: *@This(), stop_id: usize) !void {
            if (!self.breakpoints.remove(stop_id)) {
                return error.InvalidBreakpoint;
            }
        }

        pub fn clearBreakpoints(self: *@This()) void {
            self.breakpoints.clearRetainingCapacity();
        }

        /// Including the dot
        pub fn toExtension(self: *const @This()) String {
            return self.stage.toExtension();
        }

        /// The result can be freed with `freePayload`
        pub fn toPayload(allocator: std.mem.Allocator, parts: []Shader.SourcePart) !decls.SourcesPayload {
            return decls.SourcesPayload{
                .ref = parts[0].ref,
                .compile = parts[0].compileHost,
                // TODO .paths
                .contexts = blk: {
                    var contexts = try allocator.alloc(?*const anyopaque, parts.len);
                    for (parts, 0..) |part, i| {
                        contexts[i] = part.context;
                    }
                    break :blk contexts.ptr;
                },
                .count = parts.len,
                .language = parts[0].language,
                .lengths = blk: {
                    var lengths = try allocator.alloc(usize, parts.len);
                    for (parts, 0..) |part, i| {
                        lengths[i] = part.lenOr0();
                    }
                    break :blk lengths.ptr;
                },
                .sources = blk: {
                    var sources = try allocator.alloc(CString, parts.len);
                    for (parts, 0..) |part, i| {
                        sources[i] = try allocator.dupeZ(u8, part.getSource() orelse "");
                    }
                    break :blk sources.ptr;
                },
                .save = parts[0].saveHost,
                .stage = parts[0].stage,
            };
        }

        /// Free payload created by `toPayload`
        pub fn freePayload(payload: decls.SourcesPayload, allocator: std.mem.Allocator) void {
            for (payload.sources.?[0..payload.count], payload.lengths.?[0..payload.count]) |s, l| {
                allocator.free(s[0 .. l + 1]); //also free the null terminator
            }
            allocator.free(payload.sources.?[0..payload.count]);
            allocator.free(payload.lengths.?[0..payload.count]);
            allocator.free(payload.contexts.?[0..payload.count]);
        }
    };

    /// SourceInterface.breakpoints already contains all breakpoints inserted by pragmas, so the pragmas should be skipped
    fn parsePragmaDeshader(line: String) bool {
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

    /// Step marker string. glsl_analyzer is modified to ignore these markers when parsing AST, but adds them to a separate list
    const step_marker = blk: { // get the default struct field value
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
        break :blk dummy.step_identifier;
    };

    /// `SourcePart` collection must be insturmented together
    pub fn instrument(
        service: *Service,
        source_parts: []SourcePart,
        stepping: bool,
        params: *State.Params, //includes allocator
        uniform_locations: *std.ArrayListUnmanaged(String),
        uniform_names: *std.StringHashMapUnmanaged(usize),
    ) !instrumentation.Result {
        const info = toGLSLangStage(source_parts[0].stage); //the parts should all be of the same type

        var breakpoints = std.AutoHashMapUnmanaged(usize, void){};
        defer breakpoints.deinit(params.allocator);

        var part_step_offsets = try params.allocator.alloc(usize, source_parts.len);
        var result_parts = try std.ArrayListUnmanaged(*SourcePart).initCapacity(params.allocator, source_parts.len);
        var already_included = std.StringHashMapUnmanaged(void){};
        defer already_included.deinit(params.allocator);

        const preprocessed = preprocess: {
            var total_code_len: usize = 0;
            var total_stops_count: usize = 0;
            for (source_parts) |*part| {
                const source = part.getSource() orelse "";
                // Process #include directives
                if (service.support.include) if (params.search_paths) |search_paths| if (search_paths.get(part.ref)) |sp| {
                    try part.flattenIncluded(service, sp, params.allocator, if (part.once or service.support.all_once) &already_included else null, &result_parts);
                };
                try result_parts.append(common.allocator, part);

                const part_stops = try part.possibleSteps();
                total_code_len += source.len;
                total_stops_count += part_stops.len;
            }

            var marked = try std.ArrayListUnmanaged(u8).initCapacity(params.allocator, total_code_len + (step_marker.len + 3) * total_stops_count);
            defer marked.deinit(params.allocator);

            var stop_part_offset: usize = 0;
            var prev_offset: usize = 0;
            for (source_parts, 0..) |*part, p| {
                prev_offset = 0;
                part_step_offsets[p] = stop_part_offset;
                try part.instrument(&stop_part_offset, &prev_offset, &marked, params.allocator);

                var it = part.breakpoints.keyIterator();
                while (it.next()) |b| {
                    try breakpoints.put(params.allocator, b.* + stop_part_offset, {});
                }
            }

            try marked.append(params.allocator, 0); // null terminator

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
            const shader = glslang.glslang_shader_create(&input) orelse return error.GLSLang;
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
        };
        defer params.allocator.free(preprocessed);

        var processor = instrumentation.Processor{
            .config = .{
                .allocator = params.allocator,
                .breakpoints = breakpoints,
                .support = service.support,
                .group_dim = switch (info.stage) {
                    glslang.GLSLANG_STAGE_VERTEX, glslang.GLSLANG_STAGE_GEOMETRY => &[_]usize{params.vertices},
                    glslang.GLSLANG_STAGE_FRAGMENT => &params.screen,
                    glslang.GLSLANG_STAGE_COMPUTE => params.compute[3..6],
                    else => unreachable, //TODO other stages
                },
                .groups_count = switch (info.stage) {
                    glslang.GLSLANG_STAGE_COMPUTE => params.compute[0..3],
                    else => null,
                },
                .max_buffers = params.max_buffers,
                .max_interface = switch (info.stage) {
                    glslang.GLSLANG_STAGE_FRAGMENT => params.max_attachments,
                    else => params.max_xfb, // do not care about stages without xfb support, because it will be 0 for them
                },
                .parts = result_parts,
                .part_stops = part_step_offsets,
                .stepping = stepping,
                .shader_stage = source_parts[0].stage,
                .single_thread_mode = single_pause_mode,
                .uniform_names = uniform_names,
                .uniform_locations = uniform_locations,
                .used_buffers = &params.used_buffers,
                .used_interface = &params.used_interface,
            },
        };
        try processor.setup(preprocessed);
        // Generates instrumented source with breakpoints and debug outputs applied
        const applied = try processor.applyTo(preprocessed);
        return applied;
    }

    pub const Program = struct {
        const StorageT = Storage(@This(), Shader.SourcePart, false);
        const DirOrStored = StorageT.DirOrStored;

        ref: @TypeOf(ProgramPayload.ref) = 0,
        tag: ?*Tag(@This()) = null,
        /// Ref and sources
        stages: ShadersRefMap,
        context: @TypeOf(ProgramPayload.context) = null,
        /// Function for attaching and linking the shader. Defaults to glAttachShader and glLinkShader wrapper
        link: @TypeOf(ProgramPayload.link),

        stat: storage.Stat,

        uniform_locations: std.ArrayListUnmanaged(String) = .{}, //will be filled by the instrumentation routine
        uniform_names: std.StringHashMapUnmanaged(usize) = .{}, //inverse to uniform_locations

        pub fn deinit(self: *@This()) void {
            self.stages.deinit();
        }

        pub fn dirty(self: *@This()) void {
            self.stat.dirty();
            if (self.tag) |t| {
                t.parent.dirty();
            }
        }

        pub fn touch(self: *@This()) void {
            self.stat.touch();
            if (self.tag) |t| {
                t.parent.touch();
            }
        }

        pub fn eql(self: *const @This(), other: *const @This()) bool {
            if (self.stages != null and other.stages != null) {
                if (self.stages.items.len != other.stages.items.len) {
                    return false;
                }
                for (self.stages.items, other.stages.items) |s_ptr, o_ptr| {
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
            self.uniform_locations.clearRetainingCapacity();
            self.uniform_names.clearRetainingCapacity();
            // compile the shaders
            var it = self.stages.valueIterator();
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
                    for (shader_parts.*.items, 0..) |*part, i| {
                        const source = part.getSource();
                        sources[i] = try allocator.dupeZ(u8, source orelse "");
                        lengths[i] = if (source) |s| s.len else 0;
                        paths[i] = if (part.tag) |t| blk: {
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
                        .stage = shader.stage,
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
                const path = if (self.tag) |t| try t.fullPathAlloc(allocator, true) else null;
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

        pub fn listFiles(self: *const @This()) Program.ShaderIterator {
            return Program.ShaderIterator{
                .program = self,
                .current_parts = null,
                .shaders = self.stages.valueIterator(),
            };
        }

        /// List entities under `Stored`: virtual directories and `Nested` items
        ///
        /// `untagged` - list untagged sources, list tagged ones otherwise (disjoint), `null` for both.
        /// Returns `true` if the `Stored` has some untagged `Nested` items
        pub fn listNested(self: *const @This(), allocator: std.mem.Allocator, prepend: String, nested_postfix: ?String, untagged: ?bool, result: *std.ArrayListUnmanaged(CString)) !bool {
            if (self.stages.count() == 0) {
                return false;
            }
            var shader_iter = self.listFiles();
            var has_untagged = false;
            while (shader_iter.next()) |part| {
                if (part.source.tag == null) has_untagged = true;
                if (untagged == null or (part.source.tag == null) == untagged.?)
                    try result.append(allocator, try std.fmt.allocPrintZ(
                        allocator,
                        "{s}{s}{s}{name}{s}",
                        .{
                            if (prepend.len == 0)
                                prepend
                            else
                                common.noTrailingSlash(prepend),
                            if (prepend.len == 0)
                                prepend
                            else
                                "/",
                            if (part.source.tag == null and untagged == null //recursive
                            ) storage.untagged_path[1..] ++ "/" else "",
                            part,
                            nested_postfix orelse "",
                        },
                    ));
            }
            return has_untagged;
        }

        pub fn format(value: @This(), comptime fmt_str: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            if (comptime std.mem.eql(u8, fmt_str, "name")) {
                if (value.tag) |t| {
                    return writer.writeAll(t.name);
                }
                return writer.print("{x}", .{value.ref});
            } else {
                @compileError("Unknown format string for Shader.Program: {" ++ fmt_str ++ "}");
            }
        }

        pub fn hasUntaggedNested(self: *const @This()) bool {
            var iter = self.stages.valueIterator();
            while (iter.next()) |parts| {
                const shader = parts.items[0];
                if (shader.tag == null) return true;
            }
            return false;
        }

        /// accepts `ResourceLocator.programs.nested` or the basename inside `ResourceLocator.programs.sub`
        pub fn getNested(
            self: *const @This(),
            name: storage.Locator.Name,
        ) storage.Error!DirOrStored.Content {
            // try tagged // TODO something better than linear scan
            switch (name) {
                .tagged => |tag| {
                    var iter = self.stages.valueIterator();
                    while (iter.next()) |stage_parts| {
                        for (stage_parts.*.items, 0..) |*stage, part| {
                            if (stage.tag) |t| if (std.mem.eql(u8, t.name, tag)) {
                                return DirOrStored.Content{
                                    .Nested = .{
                                        .parent = self,
                                        .nested = stage,
                                        .part = part,
                                    },
                                };
                            };
                        }
                    }
                },
                .untagged => |combined| {
                    if (self.stages.get(combined.ref)) |stage| {
                        return DirOrStored.Content{
                            .Nested = .{
                                .parent = self,
                                .nested = &stage.items[combined.part],
                                .part = combined.part,
                            },
                        };
                    }
                },
            }
            return storage.Error.TargetNotFound;
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
            shaders: ShadersRefMap.ValueIterator,
            current_parts: ?[]SourcePart,
            part_index: usize = 0,

            pub fn next(self: *ShaderIterator) ?SourcePart.WithIndex {
                var stage: *const SourcePart = undefined;
                var found_part: usize = undefined;
                var found = false;
                while (!found) {
                    if (self.current_parts == null or self.current_parts.?.len <= self.part_index) {
                        while (self.shaders.next()) |n| { // find the first non-empty source
                            if (n.*.capacity > 0) {
                                self.current_parts = n.*.items;
                                self.part_index = 0;
                                found_part = self.part_index;
                                break;
                            }
                        } else { // not found
                            return null;
                        }
                    } else if (self.current_parts) |p| { //TODO really correct check?
                        found = true;
                        stage = &p[self.part_index];
                        found_part = self.part_index;
                        self.part_index += 1;
                    }
                }

                return SourcePart.WithIndex{
                    .part_index = found_part,
                    .source = stage,
                };
            }
        };
    };
};

//
// Helper functions
//

pub fn sourcesCreateUntagged(service: *Service, sources: decls.SourcesPayload) !void {
    const new_stored = try service.Shaders.createUntagged(sources.ref, sources.count);
    for (new_stored, 0..) |*template, i| {
        template.* = try Shader.SourcePart.init(service.allocator, sources, i);
    }
}

/// Replace shader's source code
pub fn sourceSource(service: *Service, sources: decls.SourcesPayload, replace: bool) !void {
    if (service.Shaders.all.get(sources.ref)) |e_sources| {
        if (e_sources.items.len != sources.count) {
            try e_sources.resize(service.allocator, sources.count);
        }
        for (e_sources.items, 0..) |*item, i| {
            if (item.getSource() == null or replace) {
                if (sources.lengths) |l| {
                    try item.replaceSource(sources.sources.?[i][0..l[i]]);
                    try scanForPragmaDeshader(service, item, i);
                } else {
                    try item.replaceSource(std.mem.span(sources.sources.?[i]));
                    try scanForPragmaDeshader(service, item, i);
                }
            }
        }
    }
}

fn scanForPragmaDeshader(service: *Service, shader: *Shader.SourcePart, index: usize) !void {
    const source = shader.source orelse return error.NoSource;
    var it = std.mem.splitScalar(u8, source, '\n');
    var in_block_comment = false;
    var line_i: usize = 0;
    while (it.next()) |line| : (line_i += 1) {
        // GLSL cannot have strings so we can just search for uncommented pragma
        var pragma_found: usize = std.math.maxInt(usize);
        var comment_found: usize = std.math.maxInt(usize);
        const pragma_text = "#pragma deshader";
        if (std.ascii.indexOfIgnoreCase(line, pragma_text)) |i| {
            pragma_found = i;
        }
        if (std.mem.indexOf(u8, line, "/*")) |i| {
            if (i < pragma_found) {
                in_block_comment = true;
                comment_found = @min(comment_found, i);
            }
        }
        if (std.mem.indexOf(u8, line, "*/")) |_| {
            in_block_comment = false;
        }
        if (std.mem.indexOf(u8, line, "//")) |i| {
            if (i < pragma_found) {
                comment_found = @min(comment_found, i);
            }
        }
        if (pragma_found != std.math.maxInt(usize)) {
            if (comment_found > pragma_found and !in_block_comment) {
                var arg_iter = common.CliArgsIterator{ .s = line, .i = pragma_found + pragma_text.len };
                // skip leading whitespace
                while (line[arg_iter.i] == ' ' or line[arg_iter.i] == '\t') {
                    arg_iter.i += 1;
                }
                var ec = argsm.ErrorCollection.init(common.allocator);
                defer ec.deinit();
                if (argsm.parseWithVerb(
                    struct {},
                    Pragmas,
                    &arg_iter,
                    common.allocator,
                    argsm.ErrorHandling{ .collect = &ec },
                )) |opts| {
                    defer opts.deinit();
                    if (opts.verb) |v| {
                        switch (v) {
                            // Workspace include
                            .workspace => {
                                try service.mapPhysicalToVirtual(opts.positionals[0], .{ .sources = .{ .name = .{ .tagged = opts.positionals[1] } } });
                            },
                            .source => {
                                _ = try service.Shaders.assignTag(shader.ref, index, opts.positionals[0], .Error);
                            },
                            .@"source-link" => {
                                _ = try service.Shaders.assignTag(shader.ref, index, opts.positionals[0], .Link);
                            },
                            .@"source-purge-previous" => {
                                _ = try service.Shaders.assignTag(shader.ref, index, opts.positionals[0], .Overwrite);
                            },
                            .breakpoint, .print, .@"breakpoint-if", .@"breakpoint-after", .@"breakpoint-if-after", .@"print-if" => {
                                const condition_pos: usize = if (v == .@"breakpoint-after" or v == .@"breakpoint-if" or v == .@"print-if") 1 else 0;
                                const new = debug.SourceBreakpoint{
                                    .line = line_i + 1,
                                    .logMessage = if (v == .print or v == .@"print-if")
                                        std.mem.join(common.allocator, " ", opts.positionals[condition_pos..]) catch null
                                    else
                                        null,
                                    .condition = switch (v) {
                                        .@"breakpoint-if", .@"breakpoint-if-after", .@"print-if" => opts.positionals[condition_pos],
                                        else => null,
                                    },
                                    .hitCondition = switch (v) {
                                        .@"breakpoint-after" => opts.positionals[condition_pos],
                                        .@"breakpoint-if-after" => opts.positionals[condition_pos + 1],
                                        else => null,
                                    },
                                }; // The breakpoint is in fact targeted on the next line
                                const bp = try service.addBreakpoint(.{ .name = .{ .untagged = .{ .ref = shader.ref, .part = index } } }, new);
                                if (bp.id) |stop_id| { // if verified
                                    log.debug("Shader {x} part {d}: breakpoint at line {d}, column {?d}", .{ shader.ref, index, line_i, bp.column });
                                    // push an event to the debugger
                                    if (commands.instance != null and commands.instance.?.hasClient()) {
                                        commands.instance.?.sendEvent(.breakpoint, debug.BreakpointEvent{ .breakpoint = bp, .reason = .new }) catch {};
                                    } else {
                                        service.dirty_breakpoints.append(service.allocator, .{ shader.ref, index, stop_id }) catch {};
                                    }
                                } else {
                                    log.warn("Breakpoint at line {d} for shader {x} part {d} could not be placed.", .{ line_i, shader.ref, index });
                                }
                                if (new.logMessage) |l| {
                                    common.allocator.free(l);
                                }
                            },
                            .once => shader.once = true,
                            .@"all-once" => service.support.all_once = true,
                        }
                    } else {
                        log.warn("Unknown pragma: {s}", .{line});
                    }
                } else |err| {
                    log.warn("Failed to parse pragma in shader source: {s}, because of {}", .{ line, err });
                }
                for (ec.errors()) |err| {
                    log.info("Pragma parsing: {} at {s}", .{ err.kind, err.option });
                }
            } else {
                log.debug("Ignoring pragma in shader source: {s}, because is at {d} and comment at {d}, block: {any}", .{ line, pragma_found, comment_found, in_block_comment });
            }
        }
    }
}

pub fn sourceType(service: *Service, ref: usize, stage: decls.Stage) !void {
    const maybe_sources = service.Shaders.all.get(ref);

    if (maybe_sources) |sources| {
        for (sources.items) |*item| {
            item.stage = stage;
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
/// Save source code physically.
/// New source will be copied and owned by the SourcePart.
pub fn saveSource(service: *Service, locator: ResourceLocator, new: String, compile: bool, link: bool) !void {
    const shader = try service.getSourceByRLocator(locator);

    const newZ = try shader.allocator.dupeZ(u8, new);
    // TODO more effective than getting it twice
    const index = common.indexOfSliceMember(Shader.SourcePart, service.Shaders.all.get(shader.ref).?.items, shader).?;
    const physical = try service.resolvePhysicalByVirtual(locator) orelse return error.NotPhysical;
    var success = true;
    if (shader.saveHost) |s| {
        const result = s(shader.ref, index, newZ, new.len, physical);
        if (result != 0) {
            success = false;
            log.err("Probably failed to save shader {x} (code {d})", .{ shader.ref, result });
        }
    } else log.warn("No save function for shader {x}", .{shader.ref});
    try service.setSource(shader, try shader.allocator.realloc(newZ[0..new.len], new.len), compile, link);
    if (!success) {
        return error.Unexpected;
    }
}

pub fn setSourceByLocator(service: *Service, locator: ResourceLocator, new: String) !void {
    return service.setSource(try service.getSourceByRLocator(locator) orelse return error.TargetNotFound, new, true, true);
}

pub fn setSourceByLocator2(service: *Service, locator: ResourceLocator, new: String, compile: bool, link: bool) !void {
    return service.setSource(try service.getSourceByRLocator(locator), new, compile, link);
}

pub fn setSource(service: *Service, shader: *Shader.SourcePart, new: String, compile: bool, link: bool) !void {
    if (shader.source) |s| {
        shader.allocator.free(s);
    }
    shader.source = new;
    shader.invalidate();
    shader.dirty();
    if (compile)
        if (shader.compileHost) |c| {
            const parts = service.Shaders.all.get(shader.ref).?;
            const payload = try Shader.SourcePart.toPayload(service.allocator, parts.items);
            defer Shader.SourcePart.freePayload(payload, service.allocator);
            var result = c(payload, "", 0);
            var success = true;
            if (result != 0) {
                log.err("Failed to compile shader {x} (code {d})", .{ shader.ref, result });
                success = false;
            }

            if (link) if (shader.program) |program| if (program.link) |lnk| {
                result = lnk(decls.ProgramPayload{
                    .context = program.context,
                    .link = program.link,
                    .ref = program.ref,
                    // TODO .path
                });
                if (result != 0) {
                    log.err("Failed to link program {x} (code {d})", .{ program.ref, result });
                    success = false;
                }
            };
            if (!success) {
                return error.Unexpected;
            }
        };
}

/// With sources
pub fn programCreateUntagged(service: *Service, program: decls.ProgramPayload) !void {
    const new = try service.Programs.createUntagged(program.ref);
    new.* = Shader.Program{
        .ref = program.ref,
        .context = program.context,
        .link = program.link,
        .stages = ShadersRefMap.init(service.allocator),
        .stat = storage.Stat.now(),
    };

    if (program.shaders) |shaders| {
        std.debug.assert(program.count > 0);
        for (shaders[0..program.count]) |shader| {
            try service.programAttachSource(program.ref, shader);
        }
    }
}

pub fn programAttachSource(service: *Service, ref: usize, source: usize) !void {
    if (service.Shaders.all.getEntry(source)) |existing_source| {
        if (service.Programs.all.get(ref)) |program| {
            try program.stages.put(existing_source.key_ptr.*, existing_source.value_ptr.*);
            for (existing_source.value_ptr.*.items) |*part| part.program = program;
        } else {
            return error.TargetNotFound;
        }
    } else {
        return error.TargetNotFound;
    }
}

pub fn programDetachSource(service: *Service, ref: usize, source: usize) !void {
    if (service.Programs.all.get(ref)) |program| {
        if (program.stages.fetchRemove(source)) |s| {
            for (s.value.items) |*item| {
                item.program = null;
            }
            return;
        }
    }
    return error.TargetNotFound;
}

pub fn untag(service: *Service, path: ResourceLocator) !void {
    switch (path) {
        .programs => |p| {
            if (p.nested.isRoot()) {
                try service.Programs.untag(p.name.tagged, true);
            } else {
                const nested = try service.Programs.getNestedByLocator(p.name, p.nested.name);
                nested.tag.?.remove();
            }
        },
        .sources => |s| {
            try service.Shaders.untag(s.name.tagged, true);
        },
    }
}

/// Must be called from the drawing thread
pub fn revert(service: *Service) !void {
    log.info("Reverting instrumentation", .{});
    var it = service.Programs.all.valueIterator();
    while (it.next()) |program| {
        try program.*.revertInstrumentation(service.allocator);
    }
}

/// Must be called from the drawing thread. Checks if the debugging is requested and reverts the instrumentation if needed
pub fn checkDebuggingOrRevert(service: *Service) bool {
    if (service.revert_requested) {
        service.revert_requested = false;
        service.revert() catch |err| log.err("Failed to revert instrumentation: {} at {?}", .{ err, @errorReturnTrace() });
        debugging = false;
        return false;
    } else {
        return debugging;
    }
}

const ShaderInfoForGLSLang = struct {
    stage: glslang.glslang_stage_t,
    client: glslang.glslang_client_t,
};
fn toGLSLangStage(stage: decls.Stage) ShaderInfoForGLSLang {
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
