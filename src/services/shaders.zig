// Copyright (C) 2025  Ondřej Sabela
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
//! (Should not contain any `gl*` or `vk*` calls).
//! Provides
//! - specific virtual storage implementations for shaders and programs
//! - instrumentation state management caching
//! - debugging state management
//! - workspace path mappings
//! This service is meant to be completely enclosed within the backend service.
//! Even some of the fields are meant to be manipulated directly by the backend.
//! Some functions in this module require to be called by the drawing thread.
//!
//! Uses GLSLang for preprocessing

const std = @import("std");
const analyzer = @import("glsl_analyzer");
const argsm = @import("args");

const common = @import("common");
const log = common.log;
const declarations = @import("../declarations.zig");
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

const String = []const u8;
const CString = [*:0]const u8;
const ZString = [:0]const u8;
const Dim = common.VariableArray(usize, 3);
const Storage = storage.Storage;
const Tag = storage.Tag;
// each ref can have multiple source parts
const StagesRefMap = std.AutoHashMapUnmanaged(Shader.Stage.Ref, *Shader.Stage);

/// `#pragma deshader` specifications. `#pragma deshader` arguments are passed like command-line parameters
/// e.g. separated by spaces. To pass an argument with spaces, enclose it in double quotes.
/// Double quotes can be escaped by `\`.
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
/// Platform native "context" (GL context or VK instance)
pub const BackendContext = opaque {};

/// When an item is removed, `Invalidated` event must be sent (all threadIds across all services are invalidated)
var services = std.ArrayHashMapUnmanaged(
    *const BackendContext,
    *Service,
    common.ArrayAddressContext(*const BackendContext),
    true,
).empty;
var services_by_name = std.StringHashMapUnmanaged(*Service).empty;
var spec: analyzer.Spec = undefined;
var spec_arena: std.heap.ArenaAllocator = undefined;
var inited_static = false;
var breakpoints_counter: usize = 0;

pub var available_data: std.StringHashMap(Data) = undefined;
pub var data_breakpoints: std.StringHashMap(StoredDataBreakpoint) = undefined;
/// Set to true to indicate a request for starting debugging to the backend
pub var debugging = false;
/// Sets if only the selected shader thread will be paused and the others will run the whole program
pub var single_pause_mode = true; // TODO more modes (breakpoint only, free run)
/// Indicator of a user action which has been taken since the last frame (continue, step...).
/// When no user action was taken, the debugging dispatch loop for the current shader can be exited.
/// When a user action is taken, the dispatch loop is surely continued.
pub var user_action: bool = false;

/// IDs of shader, indexes of part, IDs of stops that were not yet sent to the debug adapter.
/// Free for usage by external code (e.g. gl_shaders module)
dirty_breakpoints: std.ArrayListUnmanaged(struct { Shader.Stage.Ref, usize, usize }) = .empty,
/// Opaque backend-specific context. Identifies the service uniquely.
context: *const BackendContext,
/// Human-friendly name of this service/context. Also a unique identifier.
/// Owned by the service.
name: String,

/// Workspace paths are like "include-paths" mappings.
/// This field maps one-to-many [fs directory]<=>[deshader virtual directories].
/// The order of `VirtualDir`s matters (it is like "include path" priority).
/// If a tagged shader (or a shader nested in a program) is found in a workspace path, it can be saved
/// or read from the physical storage.
/// TODO watch the filesystem
physical_to_virtual: ArrayBufMap(VirtualDir.Set),

Shaders: Shader.Stage.StorageT,
Programs: Shader.Program.StorageT,
allocator: std.mem.Allocator,
/// Async event queue. Should be processed by the drawing thread.
bus: common.Bus(ResourceLocator.TagEvent, true),
instruments_any: std.ArrayListUnmanaged(Processor.Instrument) = .empty,
instruments_scoped: std.ArrayListUnmanaged(Processor.Instrument) = .empty,
instrument_clients: std.ArrayListUnmanaged(declarations.instrumentation.InstrumentClient) = .empty,
revert_requested: bool = false, // set by the command listener thread, read by the drawing thread
/// Instrumentation and debugging state cache for each shader stage of each instrumented program
state: std.AutoHashMapUnmanaged(Shader.Stage.Ref, Shader.Stage.State) = .empty,
/// Should be accesed by the backend and fillect with the actual support information
support: Processor.Config.Capabilities = .{ .buffers = false, .include = true, .all_once = false },
force_support: bool = false,

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

pub fn deinit(service: *@This()) void {
    service.allocator.free(service.name);
    var it = service.Shaders.all.valueIterator();
    while (it.next()) |s| {
        if (s.*.state) |st| st.deinit(service, s.*) catch {};
    }
    service.instruments_any.deinit(service.allocator);
    service.instruments_scoped.deinit(service.allocator);
    service.instrument_clients.deinit(service.allocator);

    service.bus.deinit();
    service.Programs.deinit(.{service.allocator});
    service.Shaders.deinit(.{});
    service.physical_to_virtual.deinit();
    service.dirty_breakpoints.deinit(service.allocator);

    service.state.deinit(service.allocator);
    const a = service.allocator;
    service.* = undefined;
    a.destroy(service);
}

pub fn deinitServices(allocator: std.mem.Allocator) void {
    for (services.values()) |service| {
        service.deinit();
    }
    services.deinit(allocator);
    services_by_name.deinit(allocator);
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

pub fn getOrAddService(context: *const BackendContext, allocator: std.mem.Allocator) !*Service {
    const result = try services.getOrPut(allocator, context);
    if (result.found_existing) {
        return result.value_ptr.*;
    }

    const new = try allocator.create(Service);
    result.value_ptr.* = new;

    const thr_name = try common.process.getSelfThreadName(allocator);
    defer allocator.free(thr_name);
    const name = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ thr_name, services.count() });
    try services_by_name.put(allocator, name, new);

    new.* = Service{
        .allocator = allocator,
        .bus = common.Bus(ResourceLocator.TagEvent, true).init(allocator),
        .context = context,
        .name = name,
        .physical_to_virtual = ArrayBufMap(VirtualDir.Set).init(allocator),
        .Shaders = @TypeOf(new.Shaders).init(allocator, {}),
        // SAFETY: assigned right after
        .Programs = undefined,
    };
    new.Programs = Shader.Program.StorageT.init(allocator, &new.Shaders.bus);

    try new.Shaders.bus.addListener(new, &shaderTagEvent);
    try new.Programs.bus.addListener(new, &programTagEvent);
    return new;
}

pub fn addInstrument(self: *Service, i: Processor.Instrument) !void {
    if (i.tag) |_| {
        try self.instruments_scoped.append(self.allocator, i);
    } else {
        try self.instruments_any.append(self.allocator, i);
    }
}

pub fn addInstrumentClient(self: *Service, i: declarations.instrumentation.InstrumentClient) !void {
    try self.instrument_clients.append(self.allocator, i);
}

fn programTagEvent(self: *Service, event: Shader.Program.StorageT.StoredTag.Event, _: std.mem.Allocator) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    const name = try std.fmt.allocPrint(arena.allocator(), "{}", .{event.tag});
    try self.bus.dispatchAsync(ResourceLocator.TagEvent{
        .action = event.action,
        .locator = ResourceLocator{ .programs = storage.Locator(Shader.Program).Nesting(Shader.SourcePart){
            .name = .{
                .tagged = name,
            },
            .fullPath = name,
            .nested = .tagged_root,
        } },
        .ref = @intFromEnum(event.tag.target.ref),
    }, arena);
}

fn shaderTagEvent(
    self: *Service,
    event: Shader.SourcePart.StorageT.StoredTag.Event,
    _: std.mem.Allocator,
) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    const name = try std.fmt.allocPrint(arena.allocator(), "{}", .{event.tag});
    try self.bus.dispatchAsync(ResourceLocator.TagEvent{
        .action = event.action,
        .locator = ResourceLocator{ .sources = storage.Locator(Shader.SourcePart){
            .name = .{
                .tagged = name,
            },
        } },
        .ref = @intFromEnum(event.tag.target.stage.ref),
    }, arena);
}

pub fn getServiceByName(name: String) ?*Service {
    return services_by_name.get(name);
}

pub fn getService(context: *const BackendContext) ?*Service {
    return services.get(context);
}

pub fn servicesCount() usize {
    return services.count();
}

pub fn clearBreakpoints(self: *@This(), resource: ResourceLocator) !void {
    const shader = try self.getSourceByRLocator(resource);
    shader.*.clearBreakpoints();
}

pub fn clearStageBreakpoints(self: *@This(), resource: ResourceLocator) !void {
    const shader = try self.getSourceByRLocator(resource);
    for (shader.*.stage.parts.items) |*part| {
        part.clearBreakpoints();
    }
}

pub fn clearServices(allocator: std.mem.Allocator) void {
    for (services.values()) |*service| {
        service.deinit(allocator);
    }
    services.clearAndFree();
    services_by_name.clearAndFree();
}

pub fn clearWorkspacePaths(service: *@This()) void {
    for (service.physical_to_virtual.hash_map.values()) |*val| {
        val.deinit(service.allocator);
    }
    service.physical_to_virtual.clearAndFree();
}

pub fn allServices() []*Service {
    return services.values();
}

pub fn allContexts() []*const anyopaque {
    return services.keys();
}

pub fn fromOpaque(o: *declarations.types.Service) *@This() {
    return @alignCast(@ptrCast(o));
}

pub fn runInstrumentsPhase(service: *@This(), comptime phase: std.meta.FieldEnum(Processor.Instrument), args: anytype) !void {
    for (service.instruments_any.items) |*instr| {
        if (@field(instr, @tagName(phase))) |p| {
            @call(.auto, p, args) catch |err|
                log.err("Instrument {x} failed to {s}: {} {?}", .{ instr.id, @tagName(phase), err, @errorReturnTrace() });
        }
    }
    for (service.instruments_scoped.items) |*instr| {
        if (@field(instr, @tagName(phase))) |p| {
            @call(.auto, p, args) catch |err|
                log.err("Instrument {x} failed to {s}: {} {?}", .{ instr.id, @tagName(phase), err, @errorReturnTrace() });
        }
    }
}

pub fn serviceNames() @TypeOf(services_by_name).KeyIterator {
    return services_by_name.keyIterator();
}

pub fn toOpaque(self: *@This()) *declarations.types.Service {
    return @ptrCast(self);
}

pub fn lockServices() void {
    services_by_name.lockPointers();
}

pub fn unlockServices() void {
    services_by_name.unlockPointers();
}

pub const VirtualDir = union(enum) {
    pub const ProgramDir = *Shader.Program.StorageT.StoredDir;
    pub const ShaderDir = *Shader.Stage.StorageT.StoredDir;
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
/// Globally identifies any shader (or virtual) resource in the workspace.
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
    programs: storage.Locator(Shader.Program).Nesting(Shader.SourcePart),
    /// Shader source part.
    sources: storage.Locator(Shader.SourcePart),
    /// Capabilities file is autogenerated based on `shaders.capabilities`
    capabilities: Processor.Config.Capabilities.Format,

    pub const sources_path = "/sources";
    pub const programs_path = "/programs";
    pub const capabilities_path = "/capabilities";

    pub const TagEvent = struct {
        locator: ResourceLocator,
        ref: declarations.types.PlatformRef,
        action: storage.Action,
    };

    pub const Error = error{
        /// Attempt to write to a virtual (sysfs-like) => protected resource
        Protected,
    };

    pub fn parse(path: String) !ResourceLocator {
        if (std.mem.startsWith(u8, path, programs_path)) {
            return @This(){
                .programs = try storage.Locator(Shader.Program).Nesting(Shader.SourcePart).parse(
                    path[programs_path.len..],
                ),
            };
        } else if (std.mem.startsWith(u8, path, sources_path)) {
            return @This(){ .sources = try storage.Locator(Shader.SourcePart).parse(path[sources_path.len..]) };
        } else if (std.mem.startsWith(u8, path, capabilities_path))
            if (std.meta.stringToEnum(Processor.Config.Capabilities.Format, path[capabilities_path.len + 1 ..])) |fmt| {
                return @This(){ .capabilities = fmt };
            };
        return storage.Error.InvalidPath;
    }

    pub fn meta(self: @This()) ?storage.MetaFile {
        return switch (self) {
            .programs => |p| p.nested.meta, //TODO if(p.hasNested()) p.nested.meta else p.meta,
            .sources => |s| s.meta,
            else => null,
        };
    }

    pub fn isInstrumented(self: @This()) bool {
        return if (self.meta()) |m| m == .instrumented else false;
    }

    pub fn isTagged(self: @This()) bool {
        return switch (self) {
            inline .programs, .sources => |l| !l.isUntagged(),
            else => false,
        };
    }

    pub fn isReadOnly(self: @This()) bool {
        return self == .capabilities or self.meta() != null;
    }

    pub fn name(self: @This()) ?String {
        return switch (self) {
            .programs => |p| p.fullPath,
            .sources => |s| switch (s.name) {
                .tagged => |t| t,
                else => null,
            },
            else => null,
        };
    }

    /// Creates a `SourcePart` `ResourceLoicator`
    pub fn fromSourceRef(ref: Shader.SourcePart.Ref, part: usize) @This() {
        return @This(){ .sources = .{ .name = .{ .untagged = .{ .ref = ref, .part = part } } } };
    }

    pub fn getSourcePart(self: @This()) ?usize {
        return switch (self) {
            .sources => |s| if (s.name.untaggedOrNull()) |u| u.part else null,
            .programs => |p| if (p.maybeNested()) |n| if (n.name.untaggedOrNull()) |u| u.part else null else null,
            else => null,
        };
    }

    pub fn toTagged(self: @This(), allocator: std.mem.Allocator, basename: String) !@This() {
        return switch (self) {
            .programs => |p| .{ .programs = try p.toTagged(allocator, basename) },
            .sources => |s| .{ .sources = try s.toTagged(basename) },
            else => storage.Error.InvalidPath,
        };
    }

    pub fn format(self: @This(), comptime _: String, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .programs => |p| {
                try writer.writeAll(programs_path[1..]);
                try writer.print("{}", .{p});
            },
            .sources => |s| {
                try writer.writeAll(sources_path[1..]);
                try writer.print("{}", .{s});
            },
            .capabilities => try writer.writeAll(capabilities_path[1..]),
        }
    }
};

//
// Workspaces functionality
//

pub fn getDirByLocator(service: *@This(), locator: ResourceLocator) !VirtualDir {
    return switch (locator) {
        .sources => |s| .{ .Shader = try service.Shaders.getDirByPath(s.name.taggedOrNull() orelse return storage.Error.InvalidPath) },
        .programs => |p| .{ .Program = try service.Programs.getDirByPath(p.name.taggedOrNull() orelse return storage.Error.InvalidPath) },
        else => return storage.Error.InvalidPath,
    };
}

/// Maps real absolute directory paths to virtual storage paths.
///
/// *NOTE: when unsetting or setting path mappings, virtual paths must exist.
/// Physical paths are not validated in any way.*
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
    var virtual_dir = service.getDirByLocator(virtual) catch |err|
        if (err == error.TagExists)
            try (try service.getResourcesByLocator(virtual)).firstParent()
        else
            return err;
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

/// *NOTE*: Invalidated event should be called on DAP after calling this functon.
/// *NOTE*: service.deinit() should be called before calling this function.
pub fn removeService(context: *const BackendContext) bool {
    if (services.get(context)) |service| {
        std.debug.assert(services_by_name.remove(service.name));
        service.deinit();
        std.debug.assert(services.swapRemove(context));
        return true;
    }
    return false;
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
        .pointer => |p| return p.child,
        else => return t,
    }
}

pub fn isNesting(comptime t: type) bool {
    return @hasDecl(ChildOrT(t), "getNested");
}

fn statStorage(
    stor: anytype,
    locator: @TypeOf(stor.*).Locator,
    nested: ?storage.Locator(Shader.SourcePart),
) !storage.StatPayload {
    // {target, ?remaining_iterator}
    var file = blk: {
        switch (locator.name) {
            .untagged => |combined| if (combined.isRoot())
                return try storage.Stat.now().toPayload(.Directory, 0) // TODO: untagged root not always dirty
            else if (stor.all.get(combined.ref)) |item_or_parts| {
                const item = if (@TypeOf(stor.*).IsParted) &item_or_parts.parts.items[combined.part] else item_or_parts;
                break :blk .{ item, null };
            } else return error.TargetNotFound,
            .tagged => |tagged| {
                var path_it = std.mem.splitScalar(u8, tagged, '/');
                var dir = stor.tagged_root;
                // TODO: tagged root not always dirty
                if (std.mem.eql(u8, tagged, "")) return dir.stat.toPayload(.Directory, 0);
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
                                        return storage.StatPayload.fromPhysical(
                                            try p_dir.stat(),
                                            storage.FileType.Directory,
                                        );
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
                file[0].getNested(
                    ((try storage.Locator(Shader.SourcePart).parse(remaining_iterator.rest())).file() orelse
                        return storage.Error.InvalidPath).name,
                )
            else if (nested) |n| if (n.file()) |nf|
                file[0].getNested(nf.name)
            else
                break :blk else break :blk;

            if (stage.Nested.nested) |target| {
                // Nested file
                var payload = if (nested.?.meta != null)
                    target.i_stat
                else
                    try target.stat.toPayload(.File, target.lenOr0());
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

    var payload = if (!is_nesting and locator.meta != null)
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
        .capabilities => try self.Shaders.stat(Shader.SourcePart.StorageT.Locator.Name.untagged_root),
    };
    if (locator.isReadOnly()) {
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
        /// The thread ID of the shader that will be sent to the debug adapter
        impl: usize,
        pub fn parse(thread_id: usize) @This() {
            return .{ .impl = thread_id };
        }

        pub fn service(self: *const @This()) !*Service {
            const index = self.impl % 100;
            if (index >= services.count()) return error.ServiceNotFound;
            return services.values()[index];
        }

        pub fn stage(self: *const @This()) Shader.Stage.Ref {
            return @enumFromInt(self.impl / 100);
        }

        pub fn from(serv: *const Service, ref: Shader.Stage.Ref) !@This() {
            const service_index = services.getIndex(serv.context) orelse return error.ServiceNotFound;
            std.debug.assert(service_index < 100);
            return .{ .impl = ref.toInt() * 100 + service_index };
        }
    };

    id: Locator,
    name: String,
    group_dim: Dim,
    group_count: ?Dim,
    selected: Shader.Stage.State.Selected,
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
        try jw.write(self.selected.thread);

        try jw.objectField("groupDim");
        try jw.beginArray();
        for (self.group_dim.slice()) |d| {
            if (d == 0) {
                break;
            }
            try jw.write(d);
        }
        try jw.endArray();

        if (self.group_count) |groups| {
            try jw.objectField("groupCount");
            try jw.beginArray();
            for (groups.slice()) |d| {
                if (d == 0) {
                    break;
                }
                try jw.write(d);
            }
            try jw.endArray();

            try jw.objectField("selectedGroup");
            try jw.write(self.selected.group);
        }

        try jw.endObject();
    }

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// The `path` field of the breakpoint will be unset.
pub fn addBreakpoint(
    self: *@This(),
    resource: ResourceLocator,
    bp: debug.SourceBreakpoint,
) !Shader.SourcePart.Breakpoint {
    const shader = try self.getSourceByRLocator(resource);
    const new = try shader.addBreakpoint(bp);
    if (shader.stage.state) |state| {
        state.dirty = true;
    }
    return new;
}

/// The `path` field of the breakpoint will be set to the full path of the `SourcePart`.
pub fn addBreakpointAlloc(
    self: *@This(),
    resource: ResourceLocator,
    bp: debug.SourceBreakpoint,
    allocator: std.mem.Allocator,
) !debug.Breakpoint {
    const shader = try self.getSourceByRLocator(resource);
    var new = try shader.addBreakpoint(bp);
    new.path = try self.fullPath(allocator, shader, resource == .programs, resource.getSourcePart());
    if (shader.stage.state) |state| {
        state.dirty = true;
    }
    return new.toDAP();
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

/// Accepts any `ResourceLocator` and returns the inner-most resource the locator points to (follows nested resources).
pub fn getResourcesByLocator(self: *@This(), locator: ResourceLocator) !ProgramOrShader {
    return switch (locator) {
        .programs => |p| //
        switch (try self.Programs.getByLocator(p.name, p.nested.name)) {
            .Nested => |nested| .{
                .program = nested.parent,
                .shader = .{
                    .source = nested.nested orelse return storage.Error.DirExists,
                    .part = nested.part,
                },
            },
            .Tag => |tag| .{
                .program = tag.target,
                .shader = null,
            },
            else => storage.Error.DirExists,
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
        else => return storage.Error.InvalidPath,
    };
}

/// Accepts any `ResourceLocator` and returns `SourcePart` if the locator points to a source part or a source part nested under a program.
pub fn getSourceByRLocator(self: *@This(), locator: ResourceLocator) !*Shader.SourcePart {
    return switch (locator) {
        .programs => |p| if (p.hasNested()) try self.Programs.getNestedByLocator(p.name, p.nested.name) else storage.Error.DirExists,
        .sources => |s| try self.Shaders.getStoredByLocator(s.name),
        else => return storage.Error.InvalidPath,
    };
}

/// Tries to get tagged path, or falls back to untagged path. `part_index` is a hint which results in
/// a small optimization (no searching among source parts will be performed)
pub fn fullPath(
    self: @This(),
    allocator: std.mem.Allocator,
    source: *Shader.SourcePart,
    program: bool,
    part_index: ?usize,
) !String {
    const basename = try source.basenameAlloc(allocator, part_index);
    defer allocator.free(basename);
    if (program) if (source.stage.program) |p| {
        if (p.tag) |t| {
            const program_path = try t.fullPathAlloc(allocator, false);
            defer allocator.free(program_path);
            return std.fmt.allocPrint(
                allocator,
                "/{s}" ++ ResourceLocator.programs_path ++ "{s}/{s}",
                .{ self.name, program_path, basename },
            );
        } else {
            return std.fmt.allocPrint(
                allocator,
                "/{s}" ++ ResourceLocator.programs_path ++ storage.untagged_path ++ "/{x}/{s}",
                .{ self.name, p.ref, basename },
            );
        }
    };

    if (source.tag) |t| {
        const source_path = try t.fullPathAlloc(allocator, false);
        defer allocator.free(source_path);
        return std.fmt.allocPrint(
            allocator,
            "/{s}" ++ ResourceLocator.sources_path ++ "{s}",
            .{ self.name, source_path },
        );
    } else {
        return std.fmt.allocPrint(
            allocator,
            "/{s}" ++ ResourceLocator.sources_path ++ storage.untagged_path ++ "/{}{s}",
            .{
                self.name,
                storage.Locator(Shader.SourcePart).PartRef{
                    .ref = source.ref(),
                    .part = part_index orelse source.getPartIndex() orelse unreachable,
                },
                source.toExtension(),
            },
        );
    }
}

pub fn removeBreakpoint(self: *@This(), resource: ResourceLocator, id: usize) !void {
    const shader = try self.getSourceByRLocator(resource);
    try shader.*.removeBreakpoint(id);
    if (self.state.getPtr(shader.*.ref())) |state| {
        state.dirty = true;
    }
}

pub fn runningShaders(
    self: *const @This(),
    allocator: std.mem.Allocator,
    result: *std.ArrayListUnmanaged(Running),
) !void {
    var c_it = self.state.iterator();
    while (c_it.next()) |state_entry| {
        if (self.Shaders.all.get(state_entry.key_ptr.*)) |stage| { // TODO is it bad when the shader is dirty?
            // SAFETY: will be assigned in loop
            var name = std.ArrayListUnmanaged(u8).empty;
            defer name.deinit(allocator);

            for (stage.parts.items) |part| if (part.tag) |t| {
                if (name.items.len > 0) try name.append(allocator, ',');
                try name.appendSlice(allocator, t.name);
            };

            try result.append(allocator, Running{
                .id = try Running.Locator.from(self, stage.ref),
                .type = @tagName(stage.stage),
                .name = if (name.items.len > 0) try name.toOwnedSlice(allocator) else try std.fmt.allocPrint(
                    allocator,
                    "{}{s}",
                    .{
                        storage.Locator(Shader.SourcePart).PartRef{ .ref = stage.ref, .part = 0 },
                        stage.toExtension(),
                    },
                ),
                .group_dim = try stage.groupDim(),
                .group_count = try stage.groupCount(),
                .selected = state_entry.value_ptr.selected,
            });
        }
    }
}

/// Invalidate all shader's instrumentation state.
/// All programs are re-instrumented at the next instrumentation dispatch.
pub fn invalidate(self: *@This()) void {
    var programs = self.Programs.all.valueIterator();
    while (programs.next()) |program| {
        program.*.invalidate();
    }

    var stages = self.Shaders.all.valueIterator();
    while (stages.next()) |stage| {
        stage.*.invalidate();
    }
}

pub fn setForceSupport(self: *@This(), force: bool) void {
    self.force_support = force;
    self.invalidate();
}

pub fn selectThread(shader_locator: usize, thread: []usize, group: ?[]usize) !void {
    const locator = Running.Locator.parse(shader_locator);
    const service = try locator.service();
    const state = service.state.getPtr(locator.stage()) orelse return Error.NoInstrumentation;
    const shader = service.Shaders.all.get(locator.stage()) orelse return storage.Error.TargetNotFound;

    for (0..thread.len) |i| {
        state.selected.thread[i] = thread[i];
    }
    if (group) |g| if (state.selected.group) |*sg|
        for (0..g.len) |i| {
            sg[i] = g[i];
        };

    shader.program.?.state.?.uniforms_dirty = true;
}

// shader stages order: vertex, tessellation control, tessellation evaluation, geometry, fragment, compute
const stages_order = std.EnumMap(declarations.shaders.StageType, usize).init(.{
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

fn sortStages(_: void, a: *Shader.Stage, b: *Shader.Stage) bool {
    return (stages_order.get(a.stage) orelse 0) <
        (stages_order.get(b.stage) orelse 0);
}

pub const Error = error{
    NoCompileCallback,
    /// No instrumentation was emitted on a stage
    NoInstrumentation,
    SourceExists,
};

/// Methods for working with a collection of `SourcePart`s
pub const Shader = struct {
    /// Empty variables used just for type resolution
    // SAFETY: not used in runtime
    const SourcesPayload: declarations.shaders.StagePayload = undefined;
    // SAFETY: not used in runtime
    const ProgramPayload: declarations.shaders.ProgramPayload = undefined;

    pub const BreakpointSpecial = struct {
        /// Service-unique id
        id: ID,
        step_id: instruments.Step.T,
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

        pub const ID = usize;
    };

    pub const Stage = struct {
        allocator: std.mem.Allocator,

        /// Can be anything that is needed for the host application
        context: ?*anyopaque = null,
        language: @TypeOf(SourcesPayload.language) = @enumFromInt(0),
        parts: Parts = .empty,
        program: ?*Program = null,

        /// Special ref 0 means that this is source part is a named string (header file, not a standalone shader)
        ref: Ref = Ref.named_strings,
        /// Instrumentation state
        state: ?*State = null,
        stage: declarations.shaders.StageType = @enumFromInt(0),

        /// Graphics API-dependent function that compiles the (instrumented) shader within the host application context.
        /// Defaults to glShaderSource and glCompileShader
        compileHost: @TypeOf(SourcesPayload.compile) = null,
        saveHost: @TypeOf(SourcesPayload.save) = null,
        currentSourceHost: @TypeOf(SourcesPayload.currentSource) = null,
        free: @TypeOf(SourcesPayload.free) = null,

        pub fn deinit(self: *@This()) void {
            self.parts.deinit(self.allocator);
        }

        /// Free payload created by `toPayload`
        pub fn freePayload(payload: declarations.shaders.StagePayload, allocator: std.mem.Allocator) void {
            for (payload.sources.?[0..payload.count], payload.lengths.?[0..payload.count]) |s, l| {
                allocator.free(s[0 .. l + 1]); //also free the null terminator
            }
            allocator.free(payload.sources.?[0..payload.count]);
            allocator.free(payload.lengths.?[0..payload.count]);
        }

        pub fn fromOpaque(stage: *declarations.types.Stage) *@This() {
            return @alignCast(@ptrCast(stage));
        }

        pub fn groupDim(self: *const @This()) !Dim {
            if (self.program) |program| if (program.state) |state| return state.params.groupDim(self.stage);
            return Error.NoInstrumentation;
        }

        pub fn groupCount(self: *const @This()) !?Dim {
            if (self.program) |program| if (program.state) |state| return state.params.groupCount(self.stage);
            return Error.NoInstrumentation;
        }

        pub fn totalThreadsCount(self: *const @This()) !usize {
            if (self.program) |program| if (program.state) |state| return state.params.totalThreadsCount(self.stage);
            return Error.NoInstrumentation;
        }

        /// Instrument and recompile the shader stage
        pub fn instrumentAndCompile(self: *Shader.Stage, service: *Service) !void {
            // create stage state
            const state = try service.state.getOrPutValue(service.allocator, self.ref, State{});
            errdefer {
                service.state.removeByPtr(state.key_ptr);
                self.state = null;
            }
            self.state = state.value_ptr;

            // Get new instrumentation
            var instrumentation = try self.instrument(service);
            defer instrumentation.deinit(self.allocator);

            if (state.value_ptr.channels.diagnostics.items.len > 0) {
                log.info("Stage {x} instrumentation diagnostics:", .{self.ref});
                for (state.value_ptr.channels.diagnostics.items) |diag| {
                    log.info("{d}: {s}", .{ diag.d.span.start, diag.d.message }); // TODO line and column pos instead of offset
                }
            }

            // A new instrumentation was emitted
            if (instrumentation.source) |instrumented_source| {
                // If any instrumentation was emitted,
                // replace the shader source with the instrumented one on the host side
                if (self.compileHost) |compile| {
                    const payload = try self.toPayload(self.allocator);
                    defer Shader.Stage.freePayload(payload, self.allocator);

                    const compile_status = compile(service.toOpaque(), payload, instrumented_source, @intCast(instrumentation.length));
                    if (compile_status != 0) {}
                    for (self.parts.items) |*sp| {
                        sp.i_stat.size = instrumentation.length;
                        sp.i_stat.stat.dirty();
                    }
                } else {
                    return Error.NoCompileCallback;
                }
            } else {
                return Error.NoInstrumentation;
            }
        }

        fn instrument(
            stage: *Stage,
            service: *Service,
        ) !Processor.Result {
            const info = toGLSLangStage(stage.stage); //the parts should all be of the same type

            var instruments_scoped = std.EnumMap(analyzer.parse.Tag, std.ArrayListUnmanaged(Processor.Instrument)){};
            for (service.instruments_scoped.items) |instr| {
                const entry: *std.ArrayListUnmanaged(Processor.Instrument) = instruments_scoped.getPtr(instr.tag.?) orelse blk: {
                    instruments_scoped.put(instr.tag.?, std.ArrayListUnmanaged(Processor.Instrument){});
                    break :blk instruments_scoped.getPtr(instr.tag.?).?;
                };
                try entry.append(service.allocator, instr);
            }
            defer {
                var it = instruments_scoped.iterator();
                while (it.next()) |entry| {
                    entry.value.deinit(service.allocator);
                }
            }

            const program = stage.program.?;
            const params = &program.state.?.params;

            var processor = Processor{
                .config = .{
                    .allocator = service.allocator,
                    .spec = spec,
                    //SAFETY: will be assigned after preprocessing by glslang
                    .source = undefined,
                    .instruments_any = service.instruments_any.items,
                    .instruments_scoped = instruments_scoped,
                    .program = &stage.program.?.state.?.channels,
                    .support = service.support,
                    .force_support = service.force_support,
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
                    .shader_stage = stage.stage,
                    .stage = &stage.state.?.channels,
                    .single_thread_mode = single_pause_mode,
                    .uniform_names = &program.uniform_names,
                    .uniform_locations = &program.uniform_locations,
                    .used_buffers = &params.context.used_buffers,
                    .used_interface = &params.context.used_interface,
                },
            };

            var result_parts = try std.ArrayListUnmanaged(*SourcePart).initCapacity(service.allocator, stage.parts.items.len);
            defer result_parts.deinit(service.allocator);
            var already_included = std.StringHashMapUnmanaged(void){};
            defer already_included.deinit(service.allocator);

            processor.config.source = preprocess: {
                var total_code_len: usize = 0;
                var total_stops_count: usize = 0;
                for (stage.parts.items) |*part| {
                    const source = part.getSource() orelse "";
                    // Process #include directives
                    if (service.support.include) if (params.context.search_paths) |search_paths| if (search_paths.get(stage.ref)) |sp| {
                        try part.flattenIncluded(
                            service,
                            sp,
                            service.allocator,
                            if (part.once or service.support.all_once)
                                &already_included
                            else
                                null,
                            &result_parts,
                        );
                    };
                    try result_parts.append(common.allocator, part);

                    const part_stops = try part.possibleSteps();
                    total_code_len += source.len;
                    total_stops_count += part_stops.len;
                }

                var marked = try std.ArrayListUnmanaged(u8).initCapacity(
                    service.allocator,
                    total_code_len + (instruments.Step.step_identifier.len + 3) * total_stops_count,
                );
                defer marked.deinit(service.allocator);

                try service.runInstrumentsPhase(.preprocess, .{ &processor, result_parts.items, &marked });

                try marked.append(service.allocator, 0); // null terminator

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
                    .messages = glslang.GLSLANG_MSG_DEFAULT_BIT | glslang.GLSLANG_MSG_ONLY_PREPROCESSOR_BIT,
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
                // TODO really need to dupe?
                break :preprocess try service.allocator.dupe(u8, std.mem.span(glslang.glslang_shader_get_preprocessed_code(shader)));
            };
            defer service.allocator.free(processor.config.source);

            try processor.setup();
            defer processor.deinit();
            // Generates instrumented source with breakpoints and debug outputs applied
            const applied = try processor.apply();
            return applied;
        }

        /// Invalidate the stage instrumentation state
        pub fn invalidate(self: *@This()) void {
            if (self.state) |state| {
                state.dirty = true;
            }
            if (self.program) |program| {
                //TODO invalidate program when no state?
                program.invalidate();
            }
        }

        /// Returns the selected thread number in one-dimensional space
        pub fn linearSelectedThread(self: *const @This()) !usize {
            if (self.program) |program| if (program.state) |p_state| if (self.state) |state| {
                const groups = state.selected.group orelse .{ 0, 0, 0 };
                const group_dim = p_state.params.groupDim(self.stage).slice();

                var group_area: usize = group_dim[0];
                for (group_dim[1..]) |g| {
                    group_area *= g;
                }

                const group_offset = if (p_state.params.groupCount(self.stage)) |gc| blk: {
                    var selected_g_flat: usize = groups[0];
                    if (gc.len > 1) {
                        selected_g_flat += groups[1] * group_dim[0];
                        if (gc.len > 2) {
                            selected_g_flat += groups[2] * group_dim[0] * group_dim[1];
                        }
                    }
                    break :blk selected_g_flat * group_area;
                } else 0;

                var thread_in_group = state.selected.thread[0];
                if (group_dim.len > 1) {
                    thread_in_group += state.selected.thread[1] * group_dim[0];
                    if (group_dim.len > 2) {
                        thread_in_group += state.selected.thread[2] * group_dim[0] * group_dim[1];
                    }
                }

                return group_offset + thread_in_group;
            };
            return Error.NoInstrumentation;
        }

        pub fn renew(self: *@This(), service: *Service) !void {
            self.state.?.renew();

            try service.runInstrumentsPhase(.renewStage, .{self.toOpaque()});
        }

        pub fn toOpaque(self: *@This()) *declarations.types.Stage {
            return @ptrCast(self);
        }

        /// The result can be freed with `freePayload`
        pub fn toPayload(self: *const @This(), allocator: std.mem.Allocator) !declarations.shaders.StagePayload {
            return declarations.shaders.StagePayload{
                .ref = self.ref.toInt(),
                .compile = self.compileHost,
                // TODO .paths
                .context = self.context,
                .count = self.parts.items.len,
                .language = self.language,
                .lengths = blk: {
                    var lengths = try allocator.alloc(usize, self.parts.items.len);
                    for (self.parts.items, 0..) |part, i| {
                        lengths[i] = part.lenOr0();
                    }
                    break :blk lengths.ptr;
                },
                .sources = blk: {
                    var sources = try allocator.alloc(CString, self.parts.items.len);
                    for (self.parts.items, 0..) |*part, i| {
                        sources[i] = try allocator.dupeZ(u8, part.getSource() orelse "");
                    }
                    break :blk sources.ptr;
                },
                .save = self.saveHost,
                .stage = self.stage,
            };
        }

        pub fn toExtension(self: Stage) String {
            return self.stage.toExtension();
        }

        pub const Parts = std.ArrayListUnmanaged(SourcePart);
        /// Provides a compile-time check that we are not mixing program and shader stage references
        pub const Ref = enum(declarations.types.PlatformRef) {
            root = 0,
            _,
            pub const named_strings = @This().root;

            const ref = RefMixin(@This(), "S");
            pub const toInt = ref.toInt;
            pub const cast = ref.cast;
            pub const format = ref.format;
        };
        pub const State = struct {
            /// This stage needs re-instrumentation (breakpoint added). Do not modify directly but use `Stage.invalidate()`
            dirty: bool = false,
            /// Debug outputs and control variables generated by the instruments and instrumentation processor.
            channels: Processor.StageChannels = .{},
            /// Thread selection is done per-stage
            selected: Selected = .{},

            /// Deinits the output channels but persists Respones and Controls
            pub fn renew(self: *@This()) void {
                self.channels.renew();
            }

            pub fn deinit(self: *@This(), service: *Service, stage: *Stage) !void {
                self.channels.deinit(service.allocator);

                try service.runInstrumentsPhase(.deinitStage, .{stage.toOpaque()});
            }

            pub fn fromOpaque(state: *declarations.instrumentation.State) *@This() {
                return @alignCast(@ptrCast(state));
            }

            pub fn toOpaque(self: *@This()) *declarations.instrumentation.State {
                return @ptrCast(self);
            }

            pub const Selected = struct {
                thread: [3]usize = .{ 0, 0, 0 },
                group: ?[3]usize = .{ 0, 0, 0 },
            };
        };
        pub const StorageT = Storage(SourcePart, void, @This());
    };

    /// Class for interacting with a single source code part.
    /// Implements `Storage.Stored`.
    pub const SourcePart = struct {
        pub const StorageT = Stage.StorageT;
        pub const Ref = Stage.Ref;

        /// Can be used for formatting
        pub const WithIndex = struct {
            source: *const SourcePart,
            part_index: usize,

            pub fn format(
                self: @This(),
                comptime fmt_str: []const u8,
                _: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                if (comptime std.mem.eql(u8, fmt_str, "name")) {
                    if (self.source.tag) |t| {
                        try writer.writeAll(t.name);
                    } else {
                        try writer.print(
                            "{}{s}",
                            .{
                                storage.Locator(Shader.SourcePart).PartRef{ .ref = self.source.stage.ref, .part = self.part_index },
                                self.source.toExtension(),
                            },
                        );
                    }
                } else {
                    @compileError("Unknown format string for Shader.SourcePart.WithIndex: {" ++ fmt_str ++ "}");
                }
            }
        };

        /// Keyed by the session-unique breakpoint ID
        breakpoints: std.AutoHashMapUnmanaged(BreakpointSpecial.ID, BreakpointSpecial) = .empty,
        /// Attributes of metadata files - really corresponds to the time of last instrumented source change
        i_stat: storage.StatPayload,
        /// Does this source have #pragma deshader once
        once: bool = false,
        /// Possible breakpoint or debugging step locations. Access using `possibleSteps()`
        possible_steps: ?Steps = null,
        /// Contains a copy of the original passed string. Must be allocated by the `allocator`
        source: ?String = null,
        stage: *Stage,
        stat: storage.Stat,
        /// Maps step ID tothe breakpoint ID
        step_breakpoints: std.AutoHashMapUnmanaged(instruments.Step.T, BreakpointSpecial.ID) = .empty,
        tag: ?*Tag(@This()) = null,
        /// Syntax tree of the original shader source code. Used for breakpoint location calculation
        tree: ?analyzer.parse.Tree = null,

        pub const Step = struct {
            /// Line & column
            pos: analyzer.lsp.Position,
            /// Character offset from the beginning of the file
            offset: usize,
            /// "length" of the step (for example if the statement ends in middle of the line)
            wrap_next: usize = 0,
        };
        pub const Steps = std.MultiArrayList(Step);

        pub fn init(self: *@This(), stage: *Stage) void {
            const now = storage.Stat.now();
            self.* = .{
                .stat = now,
                .i_stat = .empty_readonly,
                .stage = stage,
            };
        }

        pub fn deinit(self: *@This()) !void {
            if (self.source) |s| {
                self.stage.allocator.free(s);
            }
            var it = self.breakpoints.valueIterator();
            while (it.next()) |bp| {
                bp.deinit(self.stage.allocator);
            }
            self.breakpoints.deinit(self.stage.allocator);
            self.step_breakpoints.deinit(self.stage.allocator);
            if (self.possible_steps) |*s| {
                s.deinit(self.stage.allocator);
            }
            if (self.tree) |*t| {
                t.deinit(self.stage.allocator);
            }
        }

        /// The result will have empty path field
        pub fn addBreakpoint(self: *@This(), bp: debug.SourceBreakpoint) !Breakpoint {
            var new = Breakpoint{
                // SAFETY: assigned in the loop
                .id = undefined,
                // SAFETY: assigned in the loop
                .step_id = undefined,
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
                                defer breakpoints_counter += 1;

                                last_found_col = pos.character;
                                new.column = pos.character;
                                new.verified = true;
                                new.id = breakpoints_counter;
                                new.step_id = @intCast(index);
                            }
                        } else if (wanted_col != 0) {
                            if (last_found_col == 0) {
                                new.verified = false;
                                break;
                            }
                        }
                    } else {
                        defer breakpoints_counter += 1;

                        new.id = breakpoints_counter;
                        new.column = pos.character;
                        new.verified = true;
                        new.step_id = @intCast(index);
                        break;
                    }
                } else if (pos.line > bp.line) {
                    break;
                }
            }

            if (new.verified) {
                const gp = try self.step_breakpoints.getOrPut(self.stage.allocator, new.step_id);
                if (gp.found_existing) {
                    new.id = gp.value_ptr.*;
                    breakpoints_counter -= 1;

                    log.debug("Updated stage {} breakpoint {d} at step {d} (line {?d})", .{ self.stage.ref, new.id, new.step_id, new.line });
                } else {
                    gp.value_ptr.* = new.id;
                    log.debug("Added stage {} breakpoint {d} at step {d} (line {?d})", .{ self.stage.ref, new.id, new.step_id, new.line });

                    try self.breakpoints.put(self.stage.allocator, new.id, BreakpointSpecial{
                        .id = new.id,
                        .step_id = new.step_id,
                        .condition = if (bp.condition) |c| try self.stage.allocator.dupe(u8, c) else null,
                        .hit_condition = if (bp.hitCondition) |c| try self.stage.allocator.dupe(u8, c) else null,
                        .log_message = if (bp.logMessage) |m| try self.stage.allocator.dupe(u8, m) else null,
                    });
                }
            } else {
                new.reason = "failed";
            }
            return new; //TODO check validity more precisely
        }

        /// Specifying `part_index` is a hint which results in a small optimization (no searching among source parts will be performed)
        pub fn basenameAlloc(self: *const SourcePart, allocator: std.mem.Allocator, part_index: ?usize) !String {
            const found_part_index = part_index orelse self.getPartIndex() orelse unreachable;
            if (self.tag) |t| {
                return try allocator.dupe(u8, t.name);
            } else {
                return try std.fmt.allocPrint(allocator, "{}{s}", .{
                    storage.Locator(Shader.SourcePart).PartRef{ .ref = self.stage.ref, .part = found_part_index },
                    self.toExtension(),
                });
            }
        }

        pub fn dirty(self: *@This()) void {
            self.stat.stat.dirty();
            self.i_stat.stat.dirty();
            if (self.tag) |t| {
                t.parent.dirty();
            }
            if (self.stage.program) |p| {
                p.dirty();
            }
        }

        pub fn getPartIndex(self: *const @This()) ?usize {
            return common.indexOfSliceMember(SourcePart, self.stage.parts.items, self);
        }

        pub fn lenOr0(self: *const @This()) usize {
            return if (self.getSource()) |s| s.len else 0;
        }

        /// Returns the currently saved (not instrumented) shader source part
        pub fn getSource(self: *const @This()) ?String {
            return self.source;
        }

        /// Updates the 'accessed' time on the .insturmented "file"
        pub fn instrumentedSource(self: *@This(), service: *Service) !?String {
            if (self.stage.currentSourceHost) |currentSource| {
                const path = if (self.tag) |t| try t.fullPathAlloc(self.stage.allocator, true) else null;
                defer if (path) |p| self.stage.allocator.free(p);
                if (currentSource(service.toOpaque(), self.stage.context, self.stage.ref.toInt(), if (path) |p|
                    p.ptr
                else
                    null, if (path) |p| p.len else 0)) |source|
                {
                    self.i_stat.stat.touch();
                    return std.mem.span(source);
                }
            } else {
                log.warn("No currentSourceHost function for stage {x}", .{self.ref()});
            }
            return null;
        }

        // TODO do not include if it's fully enclosed in include guard
        /// Flattens all included source parts into `result_parts` arraylist
        pub fn flattenIncluded(
            self: *@This(),
            service: *Service,
            search_paths: []String,
            allocator: std.mem.Allocator,
            already_included: ?*std.StringHashMapUnmanaged(void),
            result_parts: *std.ArrayListUnmanaged(*SourcePart),
        ) !void {
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

        /// Invalidate instrumentation and code analysis state
        pub fn invalidate(self: *@This()) void {
            if (self.tree) |*t| {
                t.deinit(self.stage.allocator);
                self.tree = null;
            }
            if (self.possible_steps) |*s| {
                s.deinit(self.stage.allocator);
                self.possible_steps = null;
            }
            self.tree = null;
            self.i_stat = storage.StatPayload.empty_readonly;
            self.stage.invalidate();
        }

        pub fn parseTree(self: *@This()) !*const analyzer.parse.Tree {
            if (self.tree) |t| {
                return &t;
            } else {
                if (self.getSource()) |s| {
                    self.tree = try analyzer.parse.parse(self.stage.allocator, s, .{});
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
                            try result.append(self.stage.allocator, .{ .pos = span.position(source), .offset = span.start, .wrap_next = 0 });
                        },
                        .declaration => {
                            if (tree.tag(tree.parent(node) orelse 0) == .block)
                                try result.append(self.stage.allocator, .{ .pos = span.position(source), .offset = span.start, .wrap_next = 0 });
                        },
                        else => {
                            // TODO steps inside expressions, condition lists...
                        },
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

        pub fn removeBreakpoint(self: *@This(), id: usize) !void {
            if (self.breakpoints.fetchRemove(id)) |kv| {
                std.debug.assert(self.step_breakpoints.remove(kv.value.step_id));
            } else return error.InvalidBreakpoint;
        }

        /// The old source will be freed if it exists. The new source will be copied and owned
        pub fn replaceSource(self: *@This(), source: String) std.mem.Allocator.Error!void {
            self.invalidate();
            if (self.source) |s| {
                self.stage.allocator.free(s);
            }
            self.dirty();
            self.source = try self.stage.allocator.dupe(u8, source);
        }

        pub fn recompile(self: *@This(), service: *Service) !void {
            if (self.stage.compileHost) |c| {
                const payload = try self.stage.toPayload(service.allocator);
                defer Shader.Stage.freePayload(payload, service.allocator);
                const result = c(service.toOpaque(), payload, "", 0);
                var success = true;
                if (result != 0) {
                    log.err("Failed to compile stage {x} (code {d})", .{ self.stage.ref, result });
                    success = false;
                }

                if (!success) {
                    return error.Unexpected;
                }
            }
        }

        pub fn clearBreakpoints(self: *@This()) void {
            self.step_breakpoints.clearRetainingCapacity();
            self.breakpoints.clearRetainingCapacity();
            self.invalidate();
        }

        /// Including the dot
        pub fn toExtension(self: *const @This()) String {
            return self.stage.stage.toExtension();
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

        pub fn ref(self: *const @This()) Ref {
            return self.stage.ref;
        }

        pub const Breakpoint = struct {
            /// Must be session-unique
            id: usize,
            step_id: instruments.Step.T,
            /// ID may be invalid when the breakpoint is not verified
            verified: bool = false,
            message: ?String = null,
            line: ?usize = null,
            column: ?usize = null,
            endLine: ?usize = null,
            endColumn: ?usize = null,
            path: String,
            /// Reason for not being verified 'pending', 'failed'
            reason: ?String = null,

            pub fn toDAP(self: @This()) debug.Breakpoint {
                return .{
                    .id = self.id,
                    .verified = self.verified,
                    .message = self.message,
                    .line = self.line,
                    .column = self.column,
                    .endLine = self.endLine,
                    .endColumn = self.endColumn,
                    .reason = self.reason,
                    .path = self.path,
                };
            }
        };
    };

    pub const Program = struct {
        ref: Ref = @enumFromInt(0),
        tag: ?*Tag(@This()) = null,
        /// Ref and sources
        stages: StagesRefMap = .empty,
        context: @TypeOf(ProgramPayload.context) = null,
        /// Function for attaching and linking the shader. Defaults to glAttachShader and glLinkShader wrapper
        link: @TypeOf(ProgramPayload.link),

        stat: storage.Stat,
        state: ?State = null,

        // TODO maybe could be put into `state` as well
        uniform_locations: std.ArrayListUnmanaged(String) = .empty, //will be filled by the instrumentation routine TODO or backend?
        uniform_names: std.StringHashMapUnmanaged(usize) = .empty, //inverse to uniform_locations

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.stages.deinit(allocator); // The contents are inside `Storage`
            if (self.state) |*s| s.deinit(allocator);
            self.uniform_locations.deinit(allocator);
            self.uniform_names.deinit(allocator);
        }

        pub fn dirty(self: *@This()) void {
            self.stat.stat.dirty();
            if (self.tag) |t| {
                t.parent.dirty();
            }
        }

        pub fn fromOpaque(program: *declarations.instrumentation.Program) *@This() {
            return @alignCast(@ptrCast(program));
        }

        /// Instruments all shader stages of the program.
        /// The returned `state` hashmap should be freed by the caller, but not the content it refers to.
        /// Check the cached shader instrumentation state against `params`, eventually instrument dirty stage and relink them.
        /// *NOTE: Should be called by the drawing thread because shader source code compilation is invoked insde.*
        pub fn instrument(self: *@This(), service: *Service, params: Shader.Program.State.Params) !declarations.instrumentation.Result {
            // Collapse the map into a list
            const shader_count = self.stages.count();
            const stages_list = try service.allocator.alloc(*Shader.Stage, shader_count);
            defer service.allocator.free(stages_list);
            {
                var iter = self.stages.valueIterator();
                var i: usize = 0;
                while (iter.next()) |entry| : (i += 1) {
                    stages_list[i] = entry.*;
                }
            }
            // sort the stages by the order they will be executed
            std.sort.heap(*Shader.Stage, stages_list, {}, sortStages);

            const program_state: enum { clean, dirty, new } = if (self.state) |*state|
                if (try state.check(params, self.ref)) .clean else blk: {
                    try self.renew(service);
                    state.params = try params.clone(service.allocator);
                    break :blk .dirty;
                }
            else blk: {
                // Create new state
                self.state = State{
                    .params = try params.clone(service.allocator),
                };
                log.debug("New instrumentation for program {}", .{self.ref});
                break :blk .new;
            };
            errdefer {
                if (self.state) |*s| s.deinit(service.allocator);
                self.state = null;
            }

            // needs re-link?
            var any_stage_reinsturmented = false;
            for (stages_list) |stage| {
                stage_cache: switch (if (stage.state) |s| if (s.dirty) .dirty else program_state else .new) {
                    .dirty => {
                        if (stage.state) |_| try stage.renew(service);
                        continue :stage_cache .new;
                    },
                    .new => {
                        if (stage.instrumentAndCompile(service)) {
                            any_stage_reinsturmented = true;
                            stage.state.?.dirty = false;
                        } else |err| {
                            log.err("Error instrumenting stage {x}: {} at {?}", .{ stage.ref, err, @errorReturnTrace() });
                        }
                    },
                    else => {}, // no change in input parameters
                }
            }

            // Re-link the program
            if (any_stage_reinsturmented) {
                if (self.link) |link| {
                    const path = if (self.tag) |t| try t.fullPathAlloc(service.allocator, true) else null;
                    defer if (path) |p|
                        service.allocator.free(p);
                    const result = link(service.toOpaque(), declarations.shaders.ProgramPayload{
                        .ref = self.ref.toInt(),
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

            self.state.?.dirty = false;

            return .{
                .instrumented = any_stage_reinsturmented,
                .program = self.toOpaque(),
            };
        }

        pub fn invalidate(self: *@This()) void {
            if (self.state) |*state| {
                state.dirty = true;
            }
        }

        fn relink(self: *@This(), service: *Service) !void {
            if (self.link) |lnk| {
                const result = lnk(service.toOpaque(), declarations.shaders.ProgramPayload{
                    .context = self.context,
                    .link = self.link,
                    .ref = self.ref.toInt(),
                    // TODO .path
                });
                if (result != 0) {
                    log.err("Failed to link program {x} (code {d})", .{ self.ref, result });
                    return error.Link;
                }
            }
        }

        fn renew(self: *@This(), service: *Service) !void {
            try service.runInstrumentsPhase(.renewProgram, .{self.toOpaque()});

            self.state.?.channels.renew();
            self.state.?.params.deinit(service.allocator);
        }

        pub fn toOpaque(self: *@This()) *declarations.instrumentation.Program {
            return @ptrCast(self);
        }

        pub fn touch(self: *@This()) void {
            self.stat.stat.touch();
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

        pub fn revertInstrumentation(self: *@This(), service: *Service) !void {
            const allocator = service.allocator;
            const state = &(self.state orelse return);
            defer {
                state.deinit(allocator);
                self.state = null;
            }

            self.uniform_locations.clearRetainingCapacity();
            self.uniform_names.clearRetainingCapacity();
            // compile the shaders
            var it = self.stages.valueIterator();
            while (it.next()) |stage| {
                if (stage.*.state) |stage_state| {
                    try stage_state.deinit(service, stage.*);
                    std.debug.assert(service.state.remove(stage.*.ref));
                    stage.*.state = null;
                } else {
                    return;
                }

                const parts = stage.*.parts.items;
                if (stage.*.compileHost) |compile| {
                    var sources = try allocator.alloc(CString, parts.len);
                    var lengths = try allocator.alloc(usize, parts.len);
                    var paths = try allocator.alloc(?CString, parts.len);
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
                    for (parts, 0..) |*part, i| {
                        const source = part.getSource();
                        sources[i] = try allocator.dupeZ(u8, source orelse "");
                        lengths[i] = if (source) |s| s.len else 0;
                        paths[i] = if (part.tag) |t| blk: {
                            has_paths = true;
                            break :blk try t.fullPathAlloc(allocator, true);
                        } else null;
                    }
                    const payload = declarations.shaders.StagePayload{
                        .ref = stage.*.ref.toInt(),
                        .paths = if (has_paths) paths.ptr else null,
                        .compile = stage.*.compileHost,
                        .context = stage.*.context,
                        .count = parts.len,
                        .language = stage.*.language,
                        .sources = sources.ptr,
                        .lengths = lengths.ptr,
                        .stage = stage.*.stage,
                        .save = stage.*.saveHost,
                    };
                    const status = compile(service.toOpaque(), payload, "", 0);

                    if (status != 0) {
                        log.err("Failed to compile program {x} shader {x} (code {d})", .{ self.ref, stage.*.ref, status });
                    }
                } else {
                    log.warn("No function to compile shader {x} provided.", .{self.ref});
                }
            }
            // Link the program
            if (self.link) |linkFunc| {
                const path = if (self.tag) |t| try t.fullPathAlloc(allocator, true) else null;
                defer if (path) |p| allocator.free(p);
                const result = linkFunc(service.toOpaque(), declarations.shaders.ProgramPayload{
                    .context = self.context,
                    .count = 0,
                    .link = linkFunc,
                    .path = if (path) |p| p.ptr else null,
                    .ref = self.ref.toInt(),
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
                .stages = self.stages.valueIterator(),
            };
        }

        fn addNestedToResult(
            allocator: std.mem.Allocator,
            part: Shader.SourcePart.WithIndex,
            prepend: String,
            nested_postfix: ?String,
            untagged: ?bool,
            meta: String,
            result: *std.ArrayListUnmanaged(CString),
        ) !void {
            return result.append(allocator, try std.fmt.allocPrintZ(
                allocator,
                "{s}{s}{s}{name}{s}{s}{s}",
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
                    if (meta.len > 0) "." else "",
                    meta,
                    nested_postfix orelse "",
                },
            ));
        }

        /// List entities under `Stored`: virtual directories and `Nested` items
        ///
        /// `untagged` - list untagged sources, list tagged ones otherwise (disjoint), `null` for both.
        /// Returns `true` if the `Stored` has some untagged `Nested` items
        pub fn listNested(
            self: *const @This(),
            allocator: std.mem.Allocator,
            prepend: String,
            nested_postfix: ?String,
            untagged: ?bool,
            meta: bool,
            result: *std.ArrayListUnmanaged(CString),
        ) !bool {
            if (self.stages.count() == 0) {
                return false;
            }
            var shader_iter = self.listFiles();
            var has_untagged = false;
            while (shader_iter.next()) |part| {
                if (part.source.tag == null) has_untagged = true;
                if (untagged == null or (part.source.tag == null) == untagged.?) {
                    try addNestedToResult(allocator, part, prepend, nested_postfix, untagged, "", result);
                    if (meta) {
                        for (std.meta.tags(storage.MetaFile)) |m| {
                            try addNestedToResult(allocator, part, prepend, nested_postfix, untagged, @tagName(m), result);
                        }
                    }
                }
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
            name: storage.Locator(Shader.SourcePart).Name,
        ) storage.Error!DirOrStored.Content {
            // try tagged // TODO something better than linear scan
            switch (name) {
                .tagged => |tag| {
                    var iter = self.stages.valueIterator();
                    while (iter.next()) |stage| {
                        for (stage.*.parts.items, 0..) |*source, part| {
                            if (source.tag) |t| if (std.mem.eql(u8, t.name, tag)) {
                                return DirOrStored.Content{
                                    .Nested = .{
                                        .parent = self,
                                        .nested = source,
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
                                .nested = &stage.parts.items[combined.part],
                                .part = combined.part,
                            },
                        };
                    }
                },
            }
            return storage.Error.TargetNotFound;
        }

        /// Full mutable instrumentation and debuging state
        pub const State = struct {
            /// Input and output channels for communication with instrumentation backend
            channels: Processor.ProgramChannels = .{},
            /// Needs re-instrumentation (stepping enabled flag, pause mode, or source code has changed).
            /// Meant to be assigned from some instrument callback.
            dirty: bool = false,
            params: Params,
            /// A flag for the runtime backend (e.g. `backend/gl.zig`) for setting the required uniforms for source-stepping.
            /// A stage doesn't need to be re-instrumented event if any of its parts is dirty.
            ///
            /// WARNING: this will be cleared automatically after every instrument-clients' `onBeforeDraw` callbacks are called.
            uniforms_dirty: bool = true,

            /// Check the cached shader stage instrumentation state against `params` and create a new one if needed
            fn check(self: *@This(), params: State.Params, ref: Ref) !bool {
                if (self.dirty) { // marked dirty by user action (breakpoint added...)
                    log.debug("Program {x} instrumentation state marked dirty", .{ref});
                    // deinit the state as it will be replaced by the new state
                    return false;
                }
                // check for params mismatch
                if (params.context.used_interface.items.len > 0) {
                    if (params.context.used_interface.items.len != self.params.context.used_interface.items.len) {
                        log.debug("Program {x} interface shape changed", .{ref});
                        return false;
                    }
                    for (params.context.used_interface.items, self.params.context.used_interface.items) |p, c_p| {
                        if (p != c_p) {
                            log.debug("Program {x} interface {d} changed", .{ ref, p });
                            return false;
                        }
                    }
                }
                if (params.context.screen[0] != 0) {
                    if (params.context.screen[0] != self.params.context.screen[0] or
                        params.context.screen[1] != self.params.context.screen[1])
                    {
                        log.debug("Program {x} screen changed", .{ref});
                        return false;
                    }
                }
                if (params.vertices != 0) {
                    if (params.vertices != self.params.vertices) {
                        log.debug("Program {x} vertices changed", .{ref});
                        return false;
                    }
                }
                if (params.compute[0] != 0) {
                    if (params.compute[0] != self.params.compute[0] or params.compute[1] != self.params.compute[1] or
                        params.compute[2] != self.params.compute[2])
                    {
                        log.debug("Program {x} compute shape changed", .{ref});
                        return false;
                    }
                }

                return true; //should really run to here when the cache check passes

            }

            fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                self.channels.deinit(allocator);
                self.params.deinit(allocator);
            }

            /// Input params for the instrumentation process
            pub const Params = struct {
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
                    search_paths: ?std.AutoHashMapUnmanaged(Shader.Stage.Ref, []String),
                    /// List of buffers binding points which are reported as used by the backend
                    used_buffers: std.ArrayListUnmanaged(usize),
                    /// List of interface locations which are reported as used by the backend
                    used_interface: std.ArrayListUnmanaged(usize),

                    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                        self.used_interface.deinit(allocator);
                        self.used_buffers.deinit(allocator);
                    }
                };

                pub fn clone(self: *const @This(), allocator: std.mem.Allocator) !Params {
                    var new = self.*;
                    // copy used_interface and used_buffers for passing them by reference because all stages will share them
                    new.context.used_interface = try self.context.used_interface.clone(allocator);
                    new.context.used_buffers = try self.context.used_buffers.clone(allocator);
                    return new;
                }

                pub fn groupDim(self: *const @This(), stage: declarations.shaders.StageType) Dim {
                    return switch (stage) {
                        .gl_tess_evaluation,
                        .vk_tess_evaluation,
                        .gl_tess_control,
                        .vk_tess_control,
                        .gl_vertex,
                        .vk_vertex,
                        => Dim.init(.{self.vertices}) catch unreachable,
                        .gl_fragment, .vk_fragment => Dim.init(self.context.screen) catch unreachable,
                        .gl_compute, .vk_compute => Dim.init(self.compute[0..3]) catch unreachable,
                        else => unreachable, //TODO
                    };
                }

                pub fn groupCount(self: *const @This(), stage: declarations.shaders.StageType) ?Dim {
                    return switch (stage) {
                        .gl_tess_evaluation, .vk_tess_evaluation, .gl_tess_control, .vk_tess_control, .gl_vertex, .vk_vertex => null,
                        .gl_fragment, .vk_fragment => Dim.init(.{self.instances}) catch unreachable,
                        .gl_compute, .vk_compute => Dim.init(self.compute[3..6]) catch unreachable,
                        else => unreachable, //TODO
                    };
                }

                pub fn totalThreadsCount(self: *const @This(), stage: declarations.shaders.StageType) !usize {
                    const gd = self.groupDim(stage).slice();
                    const one_group_total: usize = switch (gd.len) {
                        1 => gd[0],
                        2 => gd[0] * gd[1],
                        3 => gd[0] * gd[1] * gd[2],
                        else => unreachable,
                    };

                    const groups_total: usize = if (self.groupCount(stage)) |gc|
                        switch (gc.len) {
                            1 => gc.raw[0],
                            2 => gc.raw[0] * gc.raw[1],
                            3 => gc.raw[0] * gc.raw[1] * gc.raw[2],
                            else => unreachable,
                        }
                    else
                        1;

                    return one_group_total * groups_total;
                }

                pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                    self.context.deinit(allocator);
                }
            };
        };
        pub const StorageT = Storage(@This(), Shader.SourcePart, void);
        pub const Ref = enum(declarations.types.PlatformRef) {
            root = 0,
            _,
            const ref = RefMixin(@This(), "P");
            pub const toInt = ref.toInt;
            pub const cast = ref.cast;
            pub const format = ref.format;
        };
        const DirOrStored = StorageT.DirOrStored;

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
            stages: StagesRefMap.ValueIterator,
            current_parts: ?[]SourcePart,
            part_index: usize = 0,

            pub fn next(self: *ShaderIterator) ?SourcePart.WithIndex {
                // SAFETY: initialized in the loop
                var part: *const SourcePart = undefined;
                var found = false;
                const found_part: usize = while (!found) {
                    if (self.current_parts == null or self.current_parts.?.len <= self.part_index) {
                        break while (self.stages.next()) |stage_i| { // find the first non-empty source
                            if (stage_i.*.parts.items.len > 0) {
                                self.current_parts = stage_i.*.parts.items;
                                self.part_index = 0;
                                part = &self.current_parts.?[self.part_index];
                                break self.part_index;
                            }
                        } else { // not found
                            return null;
                        };
                    } else if (self.current_parts) |p| { //TODO really correct check?
                        defer self.part_index += 1;
                        found = true;
                        part = &p[self.part_index];
                        break self.part_index;
                    }
                } else unreachable;

                return SourcePart.WithIndex{
                    .part_index = found_part,
                    .source = part,
                };
            }
        };
    };
};

//
// Helper functions
//

pub fn stageCreateUntagged(service: *Service, payload: declarations.shaders.StagePayload) !void {
    const stage: *Shader.Stage = try service.Shaders.createUntagged(@enumFromInt(payload.ref), payload.count);
    if (payload.sources) |s| {
        const lengths = if (payload.lengths) |l| l[0..payload.count] else blk: {
            const lens = try service.allocator.alloc(usize, payload.count);
            for (s, lens) |source, *l| {
                l.* = std.mem.len(source);
            }
            break :blk lens;
        };
        for (s, stage.parts.items, lengths) |source, *part, length| {
            part.init(stage);
            part.source = try service.allocator.dupe(u8, source[0..length]);
        }
        if (payload.lengths == null) {
            service.allocator.free(lengths);
        }
    }

    stage.compileHost = payload.compile;
    stage.context = payload.context;
    stage.currentSourceHost = payload.currentSource;
    stage.language = payload.language;
    stage.saveHost = payload.save;
    stage.ref = @enumFromInt(payload.ref);
}

/// Replace shader's source code
/// If `replace` is false and the source already exists, error is returned
pub fn stageSource(service: *Service, sources: declarations.shaders.StagePayload, replace: bool) !void {
    if (service.Shaders.all.get(@enumFromInt(sources.ref))) |stage| {
        if (stage.parts.items.len != sources.count) {
            try stage.parts.resize(stage.allocator, sources.count);
        }
        for (stage.parts.items, 0..) |*item, i| {
            if (item.getSource() == null or replace) {
                if (sources.lengths) |l| {
                    try item.replaceSource(sources.sources.?[i][0..l[i]]);
                    try scanForPragmaDeshader(service, item, i);
                } else {
                    try item.replaceSource(std.mem.span(sources.sources.?[i]));
                    try scanForPragmaDeshader(service, item, i);
                }
            } else return Error.SourceExists;
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
                                try service.mapPhysicalToVirtual(
                                    opts.positionals[0],
                                    .{ .sources = .{ .name = .{ .tagged = opts.positionals[1] } } },
                                );
                            },
                            .source => {
                                _ = try service.Shaders.assignTagTo(shader, opts.positionals[0], .Error);
                            },
                            .@"source-link" => {
                                _ = try service.Shaders.assignTagTo(shader, opts.positionals[0], .Link);
                            },
                            .@"source-purge-previous" => {
                                _ = try service.Shaders.assignTagTo(shader, opts.positionals[0], .Overwrite);
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
                                const bp = try shader.addBreakpoint(new);
                                if (bp.verified) { // if verified
                                    // push an event to the debugger
                                    if (commands.instance != null and commands.instance.?.hasClient()) {
                                        commands.instance.?.sendEvent(
                                            .breakpoint,
                                            debug.BreakpointEvent{ .breakpoint = bp.toDAP(), .reason = .new },
                                        ) catch {};
                                    } else {
                                        service.dirty_breakpoints.append(service.allocator, .{ shader.ref(), index, bp.id }) catch {};
                                    }
                                } else {
                                    log.warn("Breakpoint at line {d} for stage {x} part {d} could not be placed.", .{ line_i, shader.ref(), index });
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
                log.debug(
                    "Ignoring pragma in shader source: {s}, because is at {d} and comment at {d}, block: {any}",
                    .{ line, pragma_found, comment_found, in_block_comment },
                );
            }
        }
    }
}

pub fn sourceType(service: *Service, ref: u64, stage: declarations.shaders.StageType) !void {
    const maybe_sources = service.Shaders.all.get(ref);

    if (maybe_sources) |sources| {
        for (sources.items) |*item| {
            item.stage = stage;
        }
    } else {
        return error.TargetNotFound;
    }
}

pub fn sourceCompileFunc(service: *Service, ref: u64, func: @TypeOf((Shader.Source{}).compile)) !void {
    const maybe_sources = service.Shaders.all.get(ref);

    if (maybe_sources) |sources| {
        for (sources.items) |*item| {
            item.compile = func;
        }
    } else {
        return error.TargetNotFound;
    }
}

pub fn sourceContext(service: *Service, ref: u64, source_index: usize, context: *const anyopaque) !void {
    const maybe_sources = service.Shaders.all.get(ref);

    if (maybe_sources) |sources| {
        std.debug.assert(sources.contexts != null);
        sources.contexts[source_index] = context;
    } else {
        return error.TargetNotFound;
    }
}
/// Assign and save `SourcePart`'s source code physically.
/// New source will be copied and owned by the `SourcePart`.
pub fn saveSource(service: *Service, locator: ResourceLocator, new: String, compile: bool, link: bool) !void {
    const shader = try service.getSourceByRLocator(locator);

    const newZ = try shader.stage.allocator.dupeZ(u8, new);
    defer shader.stage.allocator.free(newZ);
    // TODO more effective than getting it twice
    const index = common.indexOfSliceMember(Shader.SourcePart, shader.stage.parts.items, shader).?;
    const physical = try service.resolvePhysicalByVirtual(locator) orelse return error.NotPhysical;
    var success = true;
    if (shader.stage.saveHost) |s| {
        const result = s(shader.ref().toInt(), index, newZ, new.len, physical);
        if (result != 0) {
            success = false;
            log.err("Probably failed to save shader {x} (code {d})", .{ shader.ref(), result });
        }
    } else log.warn("No save function for shader {x}", .{shader.ref()});
    try service.setSource(shader, try shader.stage.allocator.realloc(newZ[0..new.len], new.len), compile, link);
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

pub fn setSource(service: *Service, part: *Shader.SourcePart, new: String, compile: bool, link: bool) !void {
    const old_source = part.source;

    part.source = try part.stage.allocator.dupe(u8, new);
    errdefer {
        if (part.source) |s| {
            part.stage.allocator.free(s);
        }
        part.source = old_source;
        if (compile) if (part.recompile(service)) {
            if (link) if (part.stage.program) |program| program.relink(service) catch {};
        } else |_| {};
    }

    part.invalidate();
    part.dirty();
    if (compile) {
        try part.recompile(service);
        if (link) if (part.stage.program) |program| try program.relink(service);
    }

    if (old_source) |s| {
        part.stage.allocator.free(s);
    }
}

/// With sources
pub fn programCreateUntagged(service: *Service, program: declarations.shaders.ProgramPayload) !void {
    const new = try service.Programs.createUntagged(@enumFromInt(program.ref));
    new.* = Shader.Program{
        .ref = @enumFromInt(program.ref),
        .context = program.context,
        .link = program.link,
        .stat = storage.Stat.now(),
    };

    if (program.shaders) |shaders| {
        std.debug.assert(program.count > 0);
        for (shaders[0..program.count]) |shader| {
            try service.programAttachStage(@enumFromInt(program.ref), @enumFromInt(shader));
        }
    }
}

pub fn programAttachStage(service: *Service, ref: Shader.Program.Ref, stage: Shader.Stage.Ref) !void {
    if (service.Shaders.all.getEntry(stage)) |existing_stage| {
        if (service.Programs.all.get(ref)) |program| {
            try program.stages.put(service.allocator, existing_stage.key_ptr.*, existing_stage.value_ptr.*);
            existing_stage.value_ptr.*.program = program;
        } else {
            return error.TargetNotFound;
        }
    } else {
        return error.TargetNotFound;
    }
}

pub fn programDetachStage(service: *Service, ref: Shader.Program.Ref, stage: Shader.Stage.Ref) !void {
    if (service.Programs.all.get(ref)) |program| {
        if (program.stages.fetchRemove(stage)) |s| {
            s.value.program = null;
            return;
        }
    }
    return error.TargetNotFound;
}

pub fn untag(service: *Service, path: ResourceLocator) !void {
    switch (path) {
        .programs => |p| {
            if (p.nested.isRoot()) {
                try service.Programs.untag(p.name.taggedOrNull() orelse return ResourceLocator.Error.Protected, true);
            } else {
                const nested = try service.Programs.getNestedByLocator(p.name, p.nested.name);
                (nested.tag orelse return ResourceLocator.Error.Protected).remove();
            }
        },
        .sources => |s| {
            try service.Shaders.untag(s.name.taggedOrNull() orelse return ResourceLocator.Error.Protected, true);
        },
        else => return ResourceLocator.Error.Protected,
    }
}

/// Must be called from the drawing thread
pub fn revert(service: *Service) !void {
    log.info("Reverting instrumentation", .{});
    var it = service.Programs.all.valueIterator();
    while (it.next()) |program| {
        try program.*.revertInstrumentation(service);
    }
}

/// Must be called from the drawing thread. Checks if the debugging is requested and reverts the instrumentation if needed
pub fn checkDebuggingOrRevert(service: *Service) bool {
    if (service.revert_requested) {
        service.revert_requested = false;
        service.revert() catch |err| log.err("Failed to revert instrumentation: {} at {?}", .{ err, @errorReturnTrace() });
    }
    return debugging;
}

const ShaderInfoForGLSLang = struct {
    stage: glslang.glslang_stage_t,
    client: glslang.glslang_client_t,
};
fn toGLSLangStage(stage: declarations.shaders.StageType) ShaderInfoForGLSLang {
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

pub const default_scoped_instruments = blk: {
    var scoped_instruments = std.EnumMap(analyzer.parse.Tag, []const Processor.Instrument){};
    for (std.meta.declarations(instruments)) |decl| {
        const instr_def = @field(instruments, decl.name);
        if (@typeInfo(instr_def) != .@"struct" or !@hasDecl(instr_def, "tag")) {
            //probabaly not an instrument definition
            continue;
        }
        const instr = Processor.Instrument{
            .id = instr_def.id,
            .tag = instr_def.tag,
            .dependencies = if (@hasField(instr_def, "dependencies")) &instr_def.dependencies else null,
            .collect = if (std.meta.hasMethod(instr_def, "collect")) &instr_def.collect else null,
            .constructors = if (std.meta.hasMethod(instr_def, "constructors")) &instr_def.constructors else null,
            .deinitProgram = if (std.meta.hasMethod(instr_def, "deinitProgram")) &instr_def.deinitProgram else null,
            .deinitStage = if (std.meta.hasMethod(instr_def, "deinitStage")) &instr_def.deinitStage else null,
            .instrument = if (std.meta.hasMethod(instr_def, "instrument")) &instr_def.instrument else null,
            .preprocess = if (std.meta.hasMethod(instr_def, "preprocess")) &instr_def.preprocess else null,
            .renewProgram = if (std.meta.hasMethod(instr_def, "renewProgram")) &instr_def.renewProgram else null,
            .renewStage = if (std.meta.hasMethod(instr_def, "renewStage")) &instr_def.renewStage else null,
            .setup = if (std.meta.hasMethod(instr_def, "setup")) &instr_def.setup else null,
            .finally = if (std.meta.hasMethod(instr_def, "finally")) &instr_def.finally else null,
        };
        if (scoped_instruments.get(instr_def.tag)) |existing| {
            scoped_instruments.put(instr_def.tag, existing ++ .{instr});
        } else {
            scoped_instruments.put(instr_def.tag, &.{instr});
        }
    }
    break :blk scoped_instruments;
};

fn RefMixin(comptime T: type, comptime prefix: String) type {
    return struct {
        pub fn toInt(self: T) declarations.types.PlatformRef {
            return @intFromEnum(self);
        }
        pub fn cast(self: T, comptime U: type) U {
            return @intCast(self.toInt());
        }
        pub fn format(
            self: T,
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try writer.print(prefix ++ "{x}", .{@intFromEnum(self)});
        }
    };
}
