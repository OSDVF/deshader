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
// along with this program. If not, see <https://www.gnu.org/licenses/>.

//! ## Instrumentation Runtime and Shader Storage Frontend Service
//!
//! See [processor.zig](processor.zig) for details about the whole instrumentation architecture design.
//!
//! > Runtime Frontend is a graphics API agnostic interface for shader sources and programs
//! (Should not contain any `gl*` or `vk*` calls)
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
const decls_instruments = @import("../declarations/instruments.zig");
const instruments = @import("instruments.zig");
const storage = @import("storage.zig");
const debug = @import("debug.zig");
const commands = @import("../commands.zig");
const Processor = @import("processor.zig");
const ArrayBufMap = @import("../common/array_buf_map.zig").ArrayBufMap;

const glslang = @cImport({
    @cInclude("glslang/Include/glslang_c_interface.h");
    @cInclude("glslang/Public/resource_limits_c.h");
});

const Ref = usize;
const String = []const u8;
const CString = [*:0]const u8;
const ZString = [:0]const u8;
const Storage = storage.Storage;
const Tag = storage.Tag;
// each ref can have multiple source parts
const ShadersRefMap = std.AutoHashMapUnmanaged(usize, Shader.Parts);

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
/// When an item is removed, `Invalidated` event must be sent (all threadIds across all services are invalidated)
var services = std.AutoArrayHashMapUnmanaged(*const anyopaque, Service){};
var services_by_name = std.StringHashMapUnmanaged(*Service){};
var spec: analyzer.Spec = undefined;
var spec_arena: std.heap.ArenaAllocator = undefined;

pub var inited_static = false;
pub var available_data: std.StringHashMap(Data) = undefined;
pub var data_breakpoints: std.StringHashMap(StoredDataBreakpoint) = undefined;
pub var debugging = false;
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

/// Workspace paths are like "include-paths" mappings.
/// This field maps one-to-many [fs directory]<=>[deshader virtual directories].
/// The order of `VirtualDir`s matters (it is like "include path" priority).
/// If a tagged shader (or a shader nested in a program) is found in a workspace path, it can be saved or read from the physical storage.
/// TODO watch the filesystem
physical_to_virtual: ArrayBufMap(VirtualDir.Set) = undefined,

Shaders: Shader.SourcePart.StorageT,
Programs: Shader.Program.StorageT,
allocator: std.mem.Allocator,
/// Async event queue. Should be processed by the drawing thread.
bus: common.Bus(ResourceLocator.TagEvent, true),
instruments_any: std.ArrayListUnmanaged(Processor.Instrument) = .{},
instruments_scoped: std.ArrayListUnmanaged(Processor.Instrument) = .{},
instrument_clients: std.ArrayListUnmanaged(decls_instruments.InstrumentClient) = .{},
revert_requested: bool = false, // set by the command listener thread, read by the drawing thread
/// Instrumentation and debugging state cache for each shader stage of each program
state: std.AutoHashMapUnmanaged(usize, State) = .{},
support: Processor.Config.Support = .{ .buffers = false, .include = true, .all_once = false },

pub fn initStatic(allocator: std.mem.Allocator) !void {
    available_data = @TypeOf(available_data).init(allocator);
    data_breakpoints = @TypeOf(data_breakpoints).init(allocator);

    if (glslang.glslang_initialize_process() == 0) {
        return error.GLSLang;
    }
    inited_static = true;

    spec_arena = std.heap.ArenaAllocator.init(allocator);
    spec = try analyzer.Spec.load(spec_arena.allocator());
}

pub fn deinitStatic() void {
    if (inited_static) {
        available_data.deinit();
        data_breakpoints.deinit();

        glslang.glslang_finalize_process();

        spec_arena.deinit();
    } else {
        log.warn("Deinitializing shaders service without initializing it", .{});
    }
}

pub fn deinit(service: *@This()) void {
    service.bus.deinit();
    service.instruments_any.deinit(service.allocator);
    service.instruments_scoped.deinit(service.allocator);
    service.instrument_clients.deinit(service.allocator);
    service.Programs.deinit(.{service.allocator});
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
            .allocator = allocator,
            .bus = common.Bus(ResourceLocator.TagEvent, true).init(allocator),
            .physical_to_virtual = ArrayBufMap(VirtualDir.Set).init(allocator),
            .Shaders = @TypeOf(result.value_ptr.Shaders).init(allocator, {}),
            .Programs = undefined,
            .context = context,
            .name = name,
        };
        result.value_ptr.Programs = @TypeOf(result.value_ptr.Programs).init(allocator, &result.value_ptr.Shaders.bus);

        try result.value_ptr.Shaders.bus.addListener(&shaderTagEvent, result.value_ptr);
        try result.value_ptr.Programs.bus.addListener(&programTagEvent, result.value_ptr);
    }
    return result;
}

pub fn addInstrument(self: *Service, i: Processor.Instrument) !void {
    if (i.tag) |_| {
        try self.instruments_scoped.append(self.allocator, i);
    } else {
        try self.instruments_any.append(self.allocator, i);
    }
}

pub fn addInstrumentClient(self: *Service, i: decls_instruments.InstrumentClient) !void {
    try self.instrument_clients.append(self.allocator, i);
}

fn programTagEvent(m_self: ?*anyopaque, event: Shader.Program.StorageT.StoredTag.Event, _: std.mem.Allocator) anyerror!void {
    const self: *@This() = @alignCast(@ptrCast(m_self.?));
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    const name = try std.fmt.allocPrint(arena.allocator(), "{}", .{event.tag});
    try self.bus.dispatchAsync(ResourceLocator.TagEvent{
        .action = event.action,
        .locator = ResourceLocator{ .programs = storage.Locator.Nesting{
            .name = .{
                .tagged = name,
            },
            .fullPath = name,
            .nested = storage.Locator.tagged_root,
        } },
        .ref = event.tag.target.ref,
    }, arena);
}

fn shaderTagEvent(m_self: ?*anyopaque, event: Shader.SourcePart.StorageT.StoredTag.Event, _: std.mem.Allocator) anyerror!void {
    const self: *@This() = @alignCast(@ptrCast(m_self.?));
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    const name = try std.fmt.allocPrint(arena.allocator(), "{}", .{event.tag});
    try self.bus.dispatchAsync(ResourceLocator.TagEvent{
        .action = event.action,
        .locator = ResourceLocator{ .sources = storage.Locator{
            .name = .{
                .tagged = name,
            },
        } },
        .ref = event.tag.target.ref,
    }, arena);
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

    pub const TagEvent = struct {
        locator: ResourceLocator,
        ref: Ref,
        action: storage.Action,
    };

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

    pub fn name(self: @This()) ?String {
        return switch (self) {
            .programs => |p| p.fullPath,
            .sources => |s| switch (s.name) {
                .tagged => |t| t,
                else => null,
            },
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

/// Full mutable instrumentation and debuging state (inputs, outputs, settings) of a single shader stage
pub const State = struct {
    /// Input params for the instrumentation process
    pub const Params = struct {
        allocator: std.mem.Allocator,
        vertices: usize,
        instances: usize,
        // xyz group count and xyz group sizes
        compute: [6]usize,

        context: Context,

        pub const Context = struct {
            //dimensions
            screen: [2]usize,
            max_attachments: usize,
            max_buffers: usize,
            /// Maximum number of XFB float output variables
            max_xfb: usize,
            search_paths: ?std.AutoHashMapUnmanaged(Ref, []String),
            program: *Shader.Program,
            used_buffers: std.ArrayListUnmanaged(Ref),
            used_interface: std.ArrayListUnmanaged(Ref),

            pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                self.used_interface.deinit(allocator);
                self.used_buffers.deinit(allocator);
            }
        };

        pub fn clone(self: *const @This()) !Params {
            var new = self.*;
            new.context.used_interface = try self.context.used_interface.clone(self.allocator);
            new.context.used_buffers = try self.context.used_buffers.clone(self.allocator);
            return new;
        }

        pub fn deinit(self: *@This()) void {
            self.context.deinit(self.allocator);
        }
    };
    /// Needs re-instrumentation (stepping enabled flag, pause mode, or source code has changed)
    dirty: bool,
    params: Params,
    /// Mutable state of debug outputs generated by the instrumentation and control variables. Can be edited externally (e.g. when assigning host-side refs).
    /// Uses allocator from `params`. If `outputs` are null, no instrumentation was done.
    channels: Processor.Result.Channels,
    instruments: std.AutoArrayHashMapUnmanaged(u64, decls_instruments.InstrumentClient) = .{},
    selected_thread: [3]usize = .{ 0, 0, 0 },
    selected_group: ?[3]usize = .{ 0, 0, 0 },

    pub fn globalSelectedThread(self: *const @This()) usize {
        const groups = self.selected_group orelse .{ 0, 0, 0 };
        var group_area: usize = self.channels.group_dim[0];
        for (self.channels.group_dim[1..]) |g| {
            group_area *= g;
        }

        const group_offset = if (self.channels.group_count) |gc| blk: {
            var selected_g_flat: usize = groups[0];
            if (gc.len > 1) {
                selected_g_flat += groups[1] * self.channels.group_dim[0];
                if (gc.len > 2) {
                    selected_g_flat += groups[2] * self.channels.group_dim[0] * self.channels.group_dim[1];
                }
            }
            break :blk selected_g_flat * group_area;
        } else 0;

        var thread_in_group = self.selected_thread[0];
        if (self.channels.group_dim.len > 1) {
            thread_in_group += self.selected_thread[1] * self.channels.group_dim[0];
            if (self.channels.group_dim.len > 2) {
                thread_in_group += self.selected_thread[2] * self.channels.group_dim[0] * self.channels.group_dim[1];
            }
        }

        return group_offset + thread_in_group;
    }

    pub fn deinit(self: *@This()) void {
        self.channels.deinit(self.params.allocator);
        for (self.instruments.values()) |*instr| {
            if (instr.deinit) |de| {
                de(self);
            }
        }
        self.instruments.deinit(self.params.allocator);
        self.params.deinit();
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

fn statStorage(stor: anytype, locator: @TypeOf(stor.*).Locator, nested: ?storage.Locator) !storage.StatPayload {
    // {target, ?remaining_iterator}
    var file = blk: {
        switch (locator.name) {
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

    //
    // (nested) file or nested-untagged-root
    //
    const is_nesting = comptime isNesting(@TypeOf(file[0]));
    blk: {
        if (is_nesting) {
            const stage = try if (file[1]) |remaining_iterator|
                file[0].getNested(((try storage.Locator.parse(remaining_iterator.rest())).file() orelse return storage.Error.InvalidPath).name)
            else if (nested) |n| if (n.file()) |nf|
                file[0].getNested(nf.name)
            else
                break :blk else break :blk;

            if (stage.Nested.nested) |target| {
                // Nested file
                var payload = if (nested.?.instrumented) target.i_stat else try target.stat.toPayload(.File, target.lenOr0());
                if (target.tag != null) {
                    payload.type = payload.type | @intFromEnum(storage.FileType.SymbolicLink);
                }
                return payload;
            } else {
                // Nested untagged root
                return stage.Nested.parent.stat.toPayload(.Directory, 0);
            }
        }
    }

    var payload = if (!is_nesting and locator.instrumented)
        file[0].i_stat
    else
        try file[0].stat.toPayload(if (is_nesting) .Directory else .File, file[0].lenOr0());

    if (!locator.isUntagged()) {
        payload.type = payload.type | @intFromEnum(storage.FileType.SymbolicLink);
    }
    return payload;
}

pub fn stat(self: *@This(), locator: ResourceLocator) !storage.StatPayload {
    var s = switch (locator) {
        .sources => |sources| try statStorage(&self.Shaders, sources, null),
        .programs => |programs| try statStorage(&self.Programs, programs, programs.nested),
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
    new.path = try self.fullPath(allocator, shader.source, locator == .programs, shader.part);
    if (self.state.getPtr(shader.source.ref)) |state| {
        state.dirty = true;
    }
    return new;
}

/// Tries to get tagged path, or falls back to untagged path. `part_index` is a hint which results in a small optimization (no searching among source parts will be performed)
pub fn fullPath(self: @This(), allocator: std.mem.Allocator, shader: *Shader.SourcePart, program: bool, part_index: ?usize) !String {
    const basename = try shader.basenameAlloc(allocator, part_index);
    defer allocator.free(basename);
    if (program) if (shader.program) |p| {
        if (p.tag) |t| {
            const program_path = try t.fullPathAlloc(allocator, false);
            defer allocator.free(program_path);
            return std.fmt.allocPrint(allocator, "/{s}" ++ ResourceLocator.programs_path ++ "{s}/{s}", .{ self.name, program_path, basename });
        } else {
            return std.fmt.allocPrint(allocator, "/{s}" ++ ResourceLocator.programs_path ++ storage.untagged_path ++ "/{x}/{s}", .{ self.name, p.ref, basename });
        }
    };

    if (shader.tag) |t| {
        const source_path = try t.fullPathAlloc(allocator, false);
        defer allocator.free(source_path);
        return std.fmt.allocPrint(allocator, "/{s}" ++ ResourceLocator.sources_path ++ "{s}", .{ self.name, source_path });
    } else {
        return std.fmt.allocPrint(allocator, "/{s}" ++ ResourceLocator.sources_path ++ storage.untagged_path ++ "/{}{s}", .{ self.name, storage.Locator.PartRef{ .ref = shader.ref, .part = part_index orelse shader.getPartIndex() orelse unreachable }, shader.toExtension() });
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
                .group_dim = state_entry.value_ptr.channels.group_dim,
                .group_count = state_entry.value_ptr.channels.group_count,
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
        s.b_dirty = true;
    }
}

/// Check the cached shader stage instrumentation state against `params` and create a new one if needed
fn getOrCreateStateCache(self: *@This(), params: State.Params, stage: Ref) !struct {
    state: enum { New, Cached, Dirty },
    value: *State,
} {
    const state = try self.state.getOrPut(self.allocator, stage);
    if (state.found_existing) {
        const c = state.value_ptr;
        if (c.dirty) { // marked dirty by user action (breakpoint added...)
            log.debug("Shader {x} instrumentation state marked dirty", .{stage});
            // deinit the state as it will be replaced by the new state
            return .{ .state = .Dirty, .value = c };
        }
        // check for params mismatch
        if (params.context.used_interface.items.len > 0) {
            if (params.context.used_interface.items.len != c.params.context.used_interface.items.len) {
                log.debug("Shader {x} interface shape changed", .{stage});
                return .{ .state = .Dirty, .value = c };
            }
            for (params.context.used_interface.items, c.params.context.used_interface.items) |p, c_p| {
                if (p != c_p) {
                    log.debug("Shader {x} interface {d} changed", .{ stage, p });
                    return .{ .state = .Dirty, .value = c };
                }
            }
        }
        if (params.context.screen[0] != 0) {
            if (params.context.screen[0] != c.params.context.screen[0] or params.context.screen[1] != c.params.context.screen[1]) {
                log.debug("Shader {x} screen changed", .{stage});
                return .{ .state = .Dirty, .value = c };
            }
        }
        if (params.vertices != 0) {
            if (params.vertices != c.params.vertices) {
                log.debug("Shader {x} vertices changed", .{stage});
                return .{ .state = .Dirty, .value = c };
            }
        }
        if (params.compute[0] != 0) {
            if (params.compute[0] != c.params.compute[0] or params.compute[1] != c.params.compute[1] or params.compute[2] != c.params.compute[2]) {
                log.debug("Shader {x} compute shape changed", .{stage});
                return .{ .state = .Dirty, .value = c };
            }
        }

        return .{ .state = .Cached, .value = c }; //should really run to here when the cache check passes
    } else {
        log.debug("Shader {x} was not instrumented before", .{stage});
        return .{ .state = .New, .value = state.value_ptr };
    }
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
    .gl_mesh = 2, // mesh replaces vertex, geometry and tesselation
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
/// The returned `state` hashmap should be freed by the caller, but not the content it refers to.
/// *NOTE: Should be called by the drawing thread because shader source code compilation is invoked insde.*
pub fn instrument(self: *@This(), program: *Shader.Program, params: State.Params) !InstrumentationResult {
    // copy used_interface and used_buffers for passing them by reference because all stages will share them
    var stages = std.AutoArrayHashMapUnmanaged(usize, *State){};
    var invalidated_any = false;
    var invalidated_uniforms = false; // TODO some mismatch between b_dirty and invalidated_uniforms
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

    try stages.ensureTotalCapacity(params.allocator, shader_count);
    // needs re-link?
    var re_link = false;
    for (shaders_list) |shader_entry| {
        const shader_parts = shader_entry.value_ptr.*; // One shader represented by a list of its source parts
        const first_part = shader_parts.*.items[0];

        for (shader_parts.items) |*sp| {
            if (sp.b_dirty) {
                invalidated_uniforms = true;
                sp.b_dirty = false; // clear
            }
        }

        const result = try self.getOrCreateStateCache(params, shader_entry.key_ptr.*);
        switch (result.state) {
            .New, .Dirty => |st| {
                invalidated_any = true;
                if (st == .Dirty) {
                    result.value.deinit();
                }
                // Create new state
                var new_params = try params.clone();

                // Get new instrumentation
                // TODO what if threads_offset has changed
                var instrumentation = try Shader.instrument(self, shader_parts.items, &new_params);
                errdefer instrumentation.deinit(params.allocator);
                if (instrumentation.channels.diagnostics.items.len > 0) {
                    log.info("Shader {x} instrumentation diagnostics:", .{first_part.ref});
                    for (instrumentation.channels.diagnostics.items) |diag| {
                        log.info("{d}: {s}", .{ diag.span.start, diag.message }); // TODO line and column pos instead of offset
                    }
                }

                // A new instrumentation was emitted
                if (instrumentation.source) |instrumented_source| {
                    // If any instrumentation was emitted,
                    // replace the shader source with the instrumented one on the host side
                    if (first_part.compileHost) |compile| {
                        const payload = try Shader.SourcePart.toPayload(params.allocator, shader_parts.items);
                        defer Shader.SourcePart.freePayload(payload, params.allocator);

                        const compile_status = compile(payload, instrumented_source, @intCast(instrumentation.length));
                        if (compile_status != 0) {
                            log.err("Failed to compile instrumented shader {x}. Code {d}", .{ program.ref, compile_status });
                            instrumentation.deinit(params.allocator);
                            continue;
                        }
                        for (shader_parts.items) |*sp| {
                            sp.i_stat.size = instrumentation.length;
                            sp.i_stat.dirty();
                        }
                    } else {
                        log.err("No compileHost function for shader {x}", .{program.ref});
                        instrumentation.deinit(params.allocator);
                        continue;
                    }

                    re_link = true;
                }
                result.value.* = State{
                    .params = new_params,
                    .dirty = false,
                    .channels = instrumentation.toOwnedChannels(params.allocator),
                };
            },
            .Cached => {},
        }
        // MAYBE if (new_result.source != null)
        try stages.put(params.allocator, shader_entry.key_ptr.*, result.value);
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
    return InstrumentationResult{ .stages = stages, .invalidated = invalidated_any, .uniforms_invalidated = invalidated_uniforms };
}

/// Empty variables used just for type resolution
const SourcesPayload: decls.SourcesPayload = undefined;
const ProgramPayload: decls.ProgramPayload = undefined;

/// Result for one `Program` instrumentation
pub const InstrumentationResult = struct {
    /// True if any of the shader stages was re-instrumented (aggregate of `State.dirty`)
    invalidated: bool,
    /// True if any of the shader stages had their uniforms invalidated (aggregate of `SourcePart.b_dirty`)
    uniforms_invalidated: bool,
    /// Instrumentation state for shader stages in the order as they are executed
    stages: std.AutoArrayHashMapUnmanaged(usize, *State),
};

/// Methods for working with a collection of `SourcePart`s
pub const Shader = struct {
    pub const Parts = *std.ArrayListUnmanaged(SourcePart);
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
        pub const StorageT = Storage(@This(), void, true);
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
        context: ?*anyopaque = null,
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
        /// A flag for the runtime backend (e.g. `backend/gl.zig`) for setting the required uniforms for source-stepping
        b_dirty: bool = true, // TODO where to clear this?
        /// Attributes of the .instrumented "file"
        i_stat: storage.StatPayload,
        /// Syntax tree of the original shader source code. Used for breakpoint location calculation
        tree: ?analyzer.parse.Tree = null,
        /// Possible breakpoint or debugging step locations. Access using `possibleSteps()`
        possible_steps: ?Steps = null,

        pub const Step = struct {
            /// Line & column
            pos: analyzer.lsp.Position,
            /// Character offset from the beginning of the file
            offset: usize,
            /// "length" of the step (for example if the statement ends in middle of the line)
            wrap_next: usize = 0,
        };
        pub const Steps = std.MultiArrayList(Step);

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

        pub fn getPartIndex(self: *const @This()) ?usize {
            return common.indexOfSliceMember(SourcePart, self.program.?.stages.get(self.ref).?.items, self);
        }

        /// Specifying `part_index` is a hint which results in a small optimization (no searching among source parts will be performed)
        pub fn basenameAlloc(self: *const SourcePart, allocator: std.mem.Allocator, part_index: ?usize) !String {
            const found_part_index = part_index orelse self.getPartIndex() orelse unreachable;
            if (self.tag) |t| {
                return try allocator.dupe(u8, t.name);
            } else {
                return try std.fmt.allocPrint(allocator, "{}{s}", .{ storage.Locator.PartRef{ .ref = self.ref, .part = found_part_index }, self.toExtension() });
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
                .context = payload.context,
                .stat = storage.Stat.now(),
                .i_stat = storage.StatPayload.empty_readonly,
                .source = source,
            };
        }

        /// Returns the currently saved (not instrumented) shader source part
        pub fn getSource(self: *const @This()) ?String {
            return self.source;
        }

        /// Updates the 'accessed' time on the .insturmented "file"
        pub fn instrumentedSource(self: *@This()) !?String {
            if (self.currentSourceHost) |currentSource| {
                const path = if (self.tag) |t| try t.fullPathAlloc(self.allocator, true) else null;
                defer if (path) |p| self.allocator.free(p);
                if (currentSource(self.context, self.ref, if (path) |p| p.ptr else null, if (path) |p| p.len else 0)) |source| {
                    self.i_stat.touch();
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
            self.i_stat = storage.StatPayload.empty_readonly;
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
                .context = parts[0].context,
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
        }
    };

    /// `SourcePart` collection (a stage) instrumented together
    pub fn instrument(
        service: *Service,
        source_parts: []SourcePart,
        params: *State.Params, //includes allocator
    ) !Processor.Result {
        const info = toGLSLangStage(source_parts[0].stage); //the parts should all be of the same type

        var instruments_scoped = std.EnumMap(analyzer.parse.Tag, std.ArrayListUnmanaged(Processor.Instrument)){};
        for (service.instruments_scoped.items) |instr| {
            const entry: *std.ArrayListUnmanaged(Processor.Instrument) = instruments_scoped.getPtr(instr.tag.?) orelse blk: {
                instruments_scoped.put(instr.tag.?, std.ArrayListUnmanaged(Processor.Instrument){});
                break :blk instruments_scoped.getPtr(instr.tag.?).?;
            };
            try entry.append(params.allocator, instr);
        }

        const program = source_parts[0].program.?;

        var processor = Processor{
            .config = .{
                .allocator = params.allocator,
                .spec = spec,
                .source = undefined,
                .instruments_any = service.instruments_any.items,
                .instruments_scoped = instruments_scoped,
                .program = source_parts[0].program.?.channels,
                .support = service.support,
                .group_dim = switch (info.stage) {
                    glslang.GLSLANG_STAGE_VERTEX, glslang.GLSLANG_STAGE_GEOMETRY => &[_]usize{params.vertices},
                    glslang.GLSLANG_STAGE_FRAGMENT => &params.context.screen,
                    glslang.GLSLANG_STAGE_COMPUTE => params.compute[3..6],
                    else => unreachable, //TODO other stages
                },
                .groups_count = switch (info.stage) {
                    glslang.GLSLANG_STAGE_COMPUTE => params.compute[0..3],
                    else => null,
                },
                .max_buffers = params.context.max_buffers,
                .max_interface = switch (info.stage) {
                    glslang.GLSLANG_STAGE_FRAGMENT => params.context.max_attachments,
                    else => params.context.max_xfb, // do not care about stages without xfb support, because it will be 0 for them
                },
                .shader_stage = source_parts[0].stage,
                .single_thread_mode = single_pause_mode,
                .uniform_names = &program.uniform_names,
                .uniform_locations = &program.uniform_locations,
                .used_buffers = &params.context.used_buffers,
                .used_interface = &params.context.used_interface,
            },
        };

        var result_parts = try std.ArrayListUnmanaged(*SourcePart).initCapacity(params.allocator, source_parts.len);
        var already_included = std.StringHashMapUnmanaged(void){};
        defer already_included.deinit(params.allocator);

        const preprocessed = preprocess: {
            var total_code_len: usize = 0;
            var total_stops_count: usize = 0;
            for (source_parts) |*part| {
                const source = part.getSource() orelse "";
                // Process #include directives
                if (service.support.include) if (params.context.search_paths) |search_paths| if (search_paths.get(part.ref)) |sp| {
                    try part.flattenIncluded(service, sp, params.allocator, if (part.once or service.support.all_once) &already_included else null, &result_parts);
                };
                try result_parts.append(common.allocator, part);

                const part_stops = try part.possibleSteps();
                total_code_len += source.len;
                total_stops_count += part_stops.len;
            }

            var marked = try std.ArrayListUnmanaged(u8).initCapacity(params.allocator, total_code_len + (instruments.Step.step_identifier.len + 3) * total_stops_count);
            defer marked.deinit(params.allocator);

            for (service.instruments_any.items) |instr| {
                if (instr.preprocess) |preprocess| {
                    try preprocess(&processor, result_parts.items, &marked);
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

        try processor.setup();
        // Generates instrumented source with breakpoints and debug outputs applied
        const applied = try processor.apply();
        return applied;
    }

    pub const Program = struct {
        pub const StorageT = Storage(@This(), Shader.SourcePart, false);
        const DirOrStored = StorageT.DirOrStored;

        ref: @TypeOf(ProgramPayload.ref) = 0,
        tag: ?*Tag(@This()) = null,
        /// Ref and sources
        stages: ShadersRefMap = .{},
        context: @TypeOf(ProgramPayload.context) = null,
        /// Function for attaching and linking the shader. Defaults to glAttachShader and glLinkShader wrapper
        link: @TypeOf(ProgramPayload.link),

        stat: storage.Stat,

        /// Input and output channels for communication with instrumentation backend
        channels: Processor.Channels = .{},
        // TODO maybe could be put into `channels` as well
        uniform_locations: std.ArrayListUnmanaged(String) = .{}, //will be filled by the instrumentation routine TODO or backend?
        uniform_names: std.StringHashMapUnmanaged(usize) = .{}, //inverse to uniform_locations

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.stages.deinit(allocator);
            self.channels.deinit(allocator);
            self.uniform_locations.deinit(allocator);
            self.uniform_names.deinit(allocator);
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
                        .context = shader_parts.*.items[0].context,
                        .count = shader_parts.*.items.len,
                        .language = shader.language,
                        .sources = sources.ptr,
                        .lengths = lengths.ptr,
                        .stage = shader.stage,
                        .save = shader.saveHost,
                    };
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
            try program.stages.put(service.allocator, existing_source.key_ptr.*, existing_source.value_ptr.*);
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

/// Returns all declarations (functions, struct) of the given type in the `scope`
fn allDecls(comptime T: type, scope: anytype) []const T {
    const d = std.meta.declarations(@TypeOf(scope));
    comptime var array: [d.len]T = undefined;
    for (d, 0..) |decl, i| {
        array[i] = @field(scope, decl.name);
    }
    return array;
}

pub const default_scoped_instruments = blk: {
    var scoped_instruments = std.EnumMap(analyzer.parse.Tag, []const Processor.Instrument){};
    for (std.meta.declarations(instruments)) |decl| {
        const instr_def = @field(instruments, decl.name);
        if ((@typeInfo(@TypeOf(instr_def)) != .Struct) or !@hasField(instr_def, "tag")) {
            //probabaly not an instrument definition
            continue;
        }
        const instr = Processor.Instrument{
            .id = instr_def.id,
            .tag = instr_def.tag,
            .collect = if (@hasField(instr_def, "collect")) &instr_def.collect else null,
            .deinit = if (@hasField(instr_def, "deinit")) &instr_def.deinit else null,
            .constructors = if (@hasField(instr_def, "constructors")) &instr_def.constructors else null,
            .preprocess = if (@hasField(instr_def, "preprocess")) &instr_def.preprocess else null,
            .instrument = if (@hasField(instr_def, "instrument")) &instr_def.instrument else null,
            .setup = if (@hasField(instr_def, "setup")) &instr_def.setup else null,
        };
        scoped_instruments.put(instr_def.tag, instr);
    }
    break :blk scoped_instruments;
};
