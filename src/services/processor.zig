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

//! # Deshader GLSL Instrumentation
//! The instrumentation process consists of several intercomunicting "layers":
//!
//! - Shader Processor (this file)
//! - Runtime Frontend (`shaders`)
//! - Runtime Backend ([`backend/gl.zig`](../backends/gl.zig))

const std = @import("std");
const builtin = @import("builtin");
const analyzer = @import("glsl_analyzer");
const log = @import("common").log;
const decls = @import("../declarations/shaders.zig");
const shaders = @import("shaders.zig");
const sema = @import("sema.zig");

const String = []const u8;
const CString = [*:0]const u8;
const ZString = [:0]const u8;
pub const NodeId = u32;

pub const Error = error{ InvalidTree, OutOfStorage, NoArguments };
pub const Parsed = struct {
    arena_state: std.heap.ArenaAllocator.State,
    tree: analyzer.parse.Tree,
    ignored: []const analyzer.parse.Token,
    diagnostics: []const analyzer.parse.Diagnostic,

    /// sorted ascending by position in the code
    calls: std.StringHashMap(std.ArrayList(NodeId)),
    /// GLSL version
    version: u16,
    /// Is this an OpenGL ES shader?
    es: bool,
    version_span: analyzer.parse.Span,

    // List of enabled extensions
    extensions: []const []const u8,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.arena_state.promote(allocator).deinit();
    }

    pub fn parseSource(parent_allocator: std.mem.Allocator, text: []const u8) (std.fmt.ParseIntError || std.mem.Allocator.Error || analyzer.parse.Parser.Error)!@This() {
        var arena = std.heap.ArenaAllocator.init(parent_allocator);
        errdefer arena.deinit();

        var diagnostics = std.ArrayList(analyzer.parse.Diagnostic).init(arena.allocator());

        var ignored = std.ArrayList(analyzer.parse.Token).init(parent_allocator);
        defer ignored.deinit();

        var calls = std.StringHashMap(std.ArrayList(NodeId)).init(arena.allocator());
        errdefer {
            var it = calls.valueIterator();
            while (it.next()) |v| {
                v.deinit();
            }
            calls.deinit();
        }

        const tree = try analyzer.parse.parse(arena.allocator(), text, .{
            .ignored = &ignored,
            .diagnostics = &diagnostics,
            .calls = &calls,
        });

        var extensions = std.ArrayList([]const u8).init(arena.allocator());
        errdefer extensions.deinit();

        var version: u16 = 0;
        var es = false;
        var version_span = analyzer.parse.Span{ .start = 0, .end = 0 };

        for (ignored.items) |token| {
            const line = text[token.start..token.end];
            switch (analyzer.parse.parsePreprocessorDirective(line) orelse continue) {
                .extension => |extension| {
                    const name = extension.name;
                    try extensions.append(line[name.start..name.end]);
                },
                .version => |version_token| {
                    var version_parts = std.mem.splitAny(u8, line[version_token.number.start..version_token.number.end], " \t");
                    if (version_parts.next()) |version_part| {
                        version = try std.fmt.parseInt(u16, version_part, 10);
                    }
                    if (version_parts.next()) |version_part| {
                        if (std.mem.eql(u8, version_part, "es")) {
                            es = true;
                        }
                    }
                    version_span = token;
                },
                else => continue,
            }
        }

        return .{
            .arena_state = arena.state,
            .tree = tree,
            .ignored = tree.ignored(),
            .diagnostics = diagnostics.items,
            .extensions = extensions.items,
            .calls = calls,
            .version = version,
            .es = es,
            .version_span = version_span,
        };
    }
};

pub const Result = struct {
    /// The new source code with the inserted instrumentation or null if no changes were made by the instrumentation
    source: ?CString,
    length: usize,
    channels: Result.Channels,
    spirv: ?String,

    /// Actually it can be modified by the platform specific code (e.g. to set the selected thread location)
    pub const Channels = struct {
        /// Filled with storages created by the individual instruments
        /// Do not access this from instruments directly. Use `Processor.outChannel` instead.
        out: std.AutoArrayHashMapUnmanaged(u64, *OutputStorage) = .empty,
        /// Filled with control variables created by the individual instruments (e.g. desired step)
        controls: std.AutoArrayHashMapUnmanaged(u64, *anyopaque) = .empty,
        /// Provided for storing `result` variables from the platform backend instrument clients (e.g. reached step)
        responses: std.AutoArrayHashMapUnmanaged(u64, *anyopaque) = .empty,
        /// Each group has the dimensions of `group_dim`
        group_dim: []usize,
        /// Number of groups in each grid dimension
        group_count: ?[]usize = null,

        /// Function names. Index in the values array is the function's id (used when creating a stack trace)
        functions: []String,
        diagnostics: std.ArrayListUnmanaged(struct {
            d: analyzer.parse.Diagnostic,
            free: bool = false,
        }) = .{},

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            for (self.out.values()) |v| {
                allocator.destroy(v);
            }
            self.out.deinit(allocator);
            self.controls.deinit(allocator);
            for (self.diagnostics.items) |d| {
                if (d.free)
                    allocator.free(d.d.message);
            }
            self.diagnostics.deinit(allocator);
            allocator.free(self.group_dim);
            for (self.functions) |f| {
                allocator.free(f);
            }
            allocator.free(self.functions);
        }

        /// The total global count of threads summed from all dimensions and all groups
        pub fn totalThreadsCount(self: @This()) usize {
            var total: usize = 1;
            for (self.group_dim) |dim| {
                total *= dim;
            }
            if (self.group_count) |groups| {
                for (groups) |count| {
                    total *= count;
                }
            }
            return total;
        }

        pub fn getControl(self: @This(), comptime T: type, id: u64) ?T {
            return if (self.controls.get(id)) |p| @ptrCast(p) else null;
        }

        pub fn getResponse(self: @This(), comptime T: type, id: u64) ?T {
            return if (self.responses.get(id)) |p| @ptrCast(p) else null;
        }
    };

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.source) |s| {
            allocator.free(s[0 .. self.length - 1 :0]);
        }
        self.channels.deinit(allocator);
    }

    /// Frees the source buffer and returns the Output object
    pub fn toOwnedChannels(self: *@This(), allocator: std.mem.Allocator) Result.Channels {
        if (self.source) |s| {
            allocator.free(s[0 .. self.length - 1 :0]); // Include the null-terminator (asserting :0 adds one to the length)
        }
        return self.channels;
    }
};

/// Prototype for function that instruments the shader code
pub const Instrument = struct {
    pub const Id = u64;
    id: Id,
    tag: ?analyzer.parse.Tag,

    collect: ?*const fn () void, //TODO
    constructors: ?*const fn (processor: *Processor, main: NodeId) anyerror!void,
    deinit: ?*const fn (state: *shaders.State) anyerror!void,
    instrument: ?*const fn (processor: *Processor, node: NodeId, context: *TraverseContext) anyerror!void,
    preprocess: ?*const fn (processor: *Processor, source_parts: []*shaders.Shader.SourcePart, result: *std.ArrayListUnmanaged(u8)) anyerror!void,
    setup: ?*const fn (processor: *Processor) anyerror!void,
    /// Can be used to destroy scratch variables
    setupDone: ?*const fn (processor: *Processor) anyerror!void,
};

/// Physically are the channels always stored in one of program's stage's `Channels` and thes maps inside this struct contains references only
pub const Channels = struct {
    out: std.AutoArrayHashMapUnmanaged(u64, *Processor.OutputStorage) = .empty,
    controls: std.AutoArrayHashMapUnmanaged(u64, *anyopaque) = .empty,
    responses: std.AutoArrayHashMapUnmanaged(u64, *anyopaque) = .empty,

    pub fn getControl(self: @This(), comptime T: type, id: u64) ?T {
        return if (self.controls.get(id)) |p| @alignCast(@ptrCast(p)) else null;
    }

    pub fn getResponse(self: @This(), comptime T: type, id: u64) ?T {
        return if (self.responses.get(id)) |p| @alignCast(@ptrCast(p)) else null;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.out.deinit(allocator);
        self.controls.deinit(allocator);
        self.responses.deinit(allocator);
    }
};

pub const Processor = @This();
pub const Config = struct {
    pub const Support = struct {
        buffers: bool,
        /// Supports #include directives (ARB_shading_language_include, GOOGL_include_directive)
        include: bool,
        /// Not really a support flag, but an option for the preprocessor to not include any source file multiple times.
        all_once: bool,
    };

    allocator: std.mem.Allocator,
    spec: analyzer.Spec,
    source: String,
    support: Support,
    /// Turn of deducing supported features from the declared GLSL source code version and extensions
    force_support: bool,
    group_dim: []const usize,
    groups_count: ?[]const usize,
    /// Program-wide channels, shared between all shader stages. The channels should be onlly Buffers
    program: *Channels,
    instruments_any: []const Instrument,
    instruments_scoped: std.EnumMap(analyzer.parse.Tag, std.ArrayListUnmanaged(Instrument)),
    max_buffers: usize,
    max_interface: usize,
    shader_stage: decls.Stage,
    single_thread_mode: bool,
    /// Program-wide
    uniform_locations: *std.ArrayListUnmanaged(String), //will be filled by the instrumentation routine
    /// Program-wide
    uniform_names: *std.StringHashMapUnmanaged(usize), //inverse to uniform_locations
    /// Program-wide
    used_buffers: *std.ArrayListUnmanaged(usize),
    /// Stage-specific
    used_interface: *std.ArrayListUnmanaged(usize),
};

config: Config,

//
// Working variables
//
threads_total: usize = 0, // Sum of all threads dimesions sizes
/// Dimensions of the output buffer (vertex count / screen resolution / global threads count)
threads: []usize = undefined,

/// Offset of #version directive (if any was found)
after_version: usize = 0,
arena: std.heap.ArenaAllocator = undefined,
channels: Result.Channels = .{ // undefined fields will be assigned in setup()
    .group_dim = undefined,
    .functions = undefined,
},
last_interface_decl: usize = 0,
last_interface_node: NodeId = 0,
last_interface_location: usize = 0,
uses_dual_source_blend: bool = false,
vulkan: bool = false,
parsed: Parsed = undefined,
rand: std.Random.DefaultPrng = undefined,
scratch: std.AutoArrayHashMapUnmanaged(Instrument.Id, *anyopaque) = .empty,

/// Maps offsets in file to the inserted instrumented code fragments (sorted)
/// Both the key and the value are stored as Treap's Key (a bit confusing)
inserts: Inserts = .{}, // Will be inserted many times but iterated only once at applyTo

//
// Instrumentation privitives - identifiers for various storage and control variables
//

/// These are not meant to be used externally because they will be postfixed with a random number or stage name
pub const templates = struct {
    pub const prefix = "deshader_";
    pub const cursor = "cursor";
    const temp = prefix ++ "temp";
    pub const temp_thread_id = prefix ++ "threads";
    /// Provided as a identifier of the current thread in global space
    pub const global_thread_id = prefix ++ "global_id";
    pub const wg_size = Processor.templates.prefix ++ "workgroup_size";
};

const echo_diagnostics = false;

pub fn deinit(self: *@This()) void {
    _ = self.toOwnedChannels();
    self.channels.deinit(self.config.allocator);
}

pub fn toOwnedChannels(self: *@This()) Result.Channels {
    self.config.allocator.free(self.threads);
    self.inserts.deinit(self.config.allocator);
    self.scratch.deinit(self.config.allocator);
    self.arena.deinit();

    return self.channels;
}

fn findDirectParent(tag: analyzer.parse.Tag, tree: analyzer.parse.Tree, node: NodeId, comptime extractor: type) ?extractor {
    const parent = tree.parent(node) orelse return null;
    if (tree.tag(parent) == tag) {
        return extractor.extract(tree, parent);
    }
    return null;
}

/// Should be run on semi-initialized `Output` (only fields with no default values need to be initialized)
pub fn setup(self: *@This()) !void {
    // TODO explicit uniform locations
    // TODO place outputs with explicit locations at correct place
    self.arena = std.heap.ArenaAllocator.init(self.config.allocator);
    self.rand = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    self.inserts.init(self.config.allocator);
    self.channels.group_dim = try self.config.allocator.dupe(usize, self.config.group_dim);
    self.channels.group_count = if (self.config.groups_count) |g| try self.config.allocator.dupe(usize, g) else null;

    self.parsed = try Parsed.parseSource(self.config.allocator, self.config.source);
    defer self.parsed.deinit(self.config.allocator);
    const tree = self.parsed.tree;
    const source = self.config.source;

    var function_id_counter: usize = 0;
    var root_scope = sema.Scope{
        .function_counter = &function_id_counter,
    };
    defer root_scope.deinit(self.config.allocator);

    var root_ctx = TraverseContext{
        .block = tree.root,
        .function = null,
        .inserts = self.inserts,
        .scope = &root_scope,
        .statement = null,
    };
    if (!self.config.force_support) {
        if ((self.parsed.version != 0 and self.parsed.version < 400) or (self.parsed.es and self.parsed.version < 310)) {
            self.config.support.buffers = false; // the extension is not supported in older GLSL
        }
    }
    self.after_version = self.parsed.version_span.end + 1; // assume there is a line break
    self.last_interface_decl = self.after_version;

    if (self.config.groups_count) |groups| {
        std.debug.assert(groups.len == self.config.group_dim.len);

        self.threads = try self.config.allocator.alloc(usize, groups.len);
        for (self.config.group_dim, groups, self.threads) |dim, count, *thread| {
            thread.* = dim * count;
        }
    } else {
        self.threads = try self.config.allocator.dupe(usize, self.config.group_dim);
    }
    for (self.threads) |thread| {
        self.threads_total += thread;
    }

    try self.declareThreadId();

    // Run the setup phase of the instruments
    try self.runAllInstrumentsPhase(tree.root, "setup", .{self});

    // Iterate through top-level declarations
    // Traverse the tree top-down
    if (tree.nodes.len > 1) { // not only the `file` node
        var node: NodeId = 0;
        while (node < tree.nodes.len) : (node = tree.children(node).end) {
            const tag = tree.tag(node);
            switch (tag) {
                .function_declaration => {
                    if (try root_scope.fill(self.config.allocator, tree, node, source)) |ext| {
                        switch (ext) {
                            .function => |decl| {
                                const name = decl.get(.identifier, tree).?.text(source, tree);

                                // Initialize hit indicator in the "step storage"
                                if (std.mem.eql(u8, name, "main")) {
                                    const block = decl.get(.block, tree).?;

                                    // Run the constructors phase of the instruments
                                    try self.runAllInstrumentsPhase(node, "constructors", .{ self, block.node });
                                }
                            },
                            else => {},
                        }
                    } else log.warn("Could not extract declaration at node {d}", .{node});
                },
                .declaration => {
                    log.debug("Top level declaration: {s}", .{tree.nodeSpan(node).text(source)});
                    if (analyzer.syntax.ExternalDeclaration.tryExtract(tree, node)) |decl| {
                        var location: ?usize = null;
                        if (switch (decl) {
                            .variable => |v| v.get(.qualifiers, tree),
                            else => null,
                        }) |qualifiers| {
                            var it = qualifiers.iterator(); // keyword_in, keyword_out, layout_qualifier
                            while (it.next(tree)) |qualifier| {
                                switch (qualifier) {
                                    .layout => |layout| {
                                        if (self.config.shader_stage.isFragment()) { // search for index = x => dual source blending is enabled
                                            const l_qualifiers = layout.get(.layout_qualifiers, tree) orelse continue;
                                            var q_it = l_qualifiers.iterator();
                                            while (q_it.next(tree)) |q| {
                                                switch (q) {
                                                    .assignment => |assignment| {
                                                        // keyword_layout, (, assignment, )
                                                        const identifier = assignment.get(.identifier, tree) orelse continue;
                                                        // identifier, =, number
                                                        const identifier_type = enum {
                                                            index,
                                                            location,
                                                        };
                                                        const i_t = std.meta.stringToEnum(identifier_type, identifier.text(source, tree));
                                                        if (i_t) |i_t_val| {
                                                            switch (i_t_val) {
                                                                .index => {
                                                                    self.uses_dual_source_blend = true;
                                                                },
                                                                .location => {
                                                                    location = std.fmt.parseInt(usize, tree.nodeSpan(assignment.get(.value, tree).?.node).text(source), 0) catch location;
                                                                },
                                                            }
                                                        }
                                                    },
                                                    else => {},
                                                }
                                            }
                                        }
                                    },
                                    .storage => |storage_q| {
                                        switch (storage_q) {
                                            .out => |_| {
                                                self.last_interface_node = @intCast(node);
                                                self.last_interface_decl = tree.nodeSpanExtreme(self.last_interface_node, .end);
                                            },
                                            else => {},
                                        }
                                    },
                                    else => {},
                                }
                            }
                        }
                        if (self.last_interface_node == node) {
                            self.last_interface_location = location orelse (self.last_interface_location + 1); // TODO implicit locations až se vzbudíš, TODO glBindFragDataLocation
                        }
                    }
                },
                else => {},
            }
        }
    }

    if (self.config.support.buffers and (self.parsed.version >= 310 or self.config.force_support)) {
        try self.insertStart(" #extension GL_ARB_shader_storage_buffer_object : require\n", self.after_version);
        // To support SSBOs as instrumentation output channels
    }

    // Start the instrumentation by processing the root node
    _ = try self.processNode(
        tree.root,
        &root_ctx,
    );

    // Copy the function to id mapping to outputs
    self.channels.functions = try self.config.allocator.alloc(String, root_scope.functions.size);
    var it = root_scope.functions.keyIterator();
    var i: usize = 0;
    while (it.next()) |func| {
        self.channels.functions[i] = try self.config.allocator.dupe(u8, func.*);
        i += 1;
    }
    //const result = try self.config.allocator.alloc([]const analyzer.lsp.Position, stops.items.len);
    //for (result, stops.items) |*target, src| {
    //    target.* = try self.config.allocator.dupe(analyzer.lsp.Position, src.items);
    //}
    //self.channelss.steps = result;
    // Run the setupDone phase of the instruments
    try self.runAllInstrumentsPhase(tree.root, "setupDone", .{self});
}

fn runAllInstrumentsPhase(self: *@This(), node: NodeId, comptime func: String, args: anytype) !void {
    for (self.config.instruments_any) |instrument| {
        if (@field(instrument, func)) |f| {
            @call(.auto, f, args) catch |err| {
                try self.addDiagnostic(err, @src(), self.parsed.tree.nodeSpan(node), @errorReturnTrace());
            };
        }
    }

    var it = self.config.instruments_scoped.iterator();
    while (it.next()) |instruments| {
        for (instruments.value.items) |instrument| {
            if (@field(instrument, func)) |f| {
                @call(.auto, f, args) catch |err| {
                    try self.addDiagnostic(err, @src(), self.parsed.tree.nodeSpan(node), @errorReturnTrace());
                };
            }
        }
    }
}

/// TODO add special deshader variables to documentation
pub fn declareThreadId(self: *@This()) !void {
    // Initialize the global thread id
    switch (self.config.shader_stage) {
        .gl_fragment, .vk_fragment => {
            try self.insertStart(try self.print(
                "const uvec2 " ++ templates.temp_thread_id ++ "= uvec2({d}, {d});\n" ++
                    "uint " ++ templates.global_thread_id ++ " = uint(gl_FragCoord.y) * " ++ templates.temp_thread_id ++ ".x + uint(gl_FragCoord.x);\n",
                .{ self.threads[0], self.threads[1] },
            ), self.after_version);
        },
        .gl_geometry => {
            try self.insertStart(try self.print(
                "const uint " ++ templates.temp_thread_id ++ "= {d};\n" ++
                    "uint " ++ templates.global_thread_id ++ "= gl_PrimitiveIDIn * " ++ templates.temp_thread_id ++ " + gl_InvocationID;\n",
                .{self.threads[0]},
            ), self.after_version);
        },
        .gl_tess_evaluation => {
            try self.insertStart(try self.print(
                "ivec2 " ++ templates.temp_thread_id ++ "= ivec2(gl_TessCoord.xy * float({d}-1) + 0.5);\n" ++
                    "uint " ++ templates.global_thread_id ++ " =" ++ templates.temp_thread_id ++ ".y * {d} + " ++ templates.temp_thread_id ++ ".x;\n",
                .{ self.threads[0], self.threads[0] },
            ), self.after_version);
        },
        .gl_mesh, .gl_task, .gl_compute => {
            try self.insertStart(
                try self.print("uint " ++ templates.global_thread_id ++
                    "= gl_GlobalInvocationID.z * gl_NumWorkGroups.x * gl_NumWorkGroups.y * " ++ templates.wg_size ++ " + gl_GlobalInvocationID.y * gl_NumWorkGroups.x * " ++ templates.wg_size ++ " + gl_GlobalInvocationID.x);\n", .{}),
                self.after_version,
            );
            if (self.parsed.version < 430) {
                try self.insertStart(
                    try self.print("const uvec3 " ++ templates.wg_size ++ "= uvec3({d},{d},{d});\n", .{ self.config.group_dim[0], self.config.group_dim[1], self.config.group_dim[2] }),
                    self.after_version,
                );
            } else {
                try self.insertStart(
                    "uvec3 " ++ templates.wg_size ++ "= gl_WorkGroupSize;\n",
                    self.after_version,
                );
            }
        },
        else => {},
    }
}

const StoragePreference = enum { Buffer, Interface, PreferBuffer, PreferInterface };

/// Creates a storage slot in the shader (or program-wide for buffers), and also adds it to correct channel definitions and initializes its readback buffer (if the passed `size` > 0).
///
/// `format`, `fit_into_component` and `component` are used only for interface storages.
pub fn addStorage(
    self: *@This(),
    id: u64,
    preference: StoragePreference,
    format: OutputStorage.Location.Format,
    fit_into_component: ?OutputStorage.Location,
    component: ?usize,
) !*OutputStorage {
    const value = try switch (preference) {
        .Buffer => if (self.config.program.out.get(id)) |existing| return existing else OutputStorage.nextBuffer(&self.config),
        .PreferBuffer => if (self.config.program.out.get(id)) |existing| return existing else OutputStorage.nextPreferBuffer(&self.config, format, fit_into_component, component),

        .Interface => OutputStorage.nextInterface(&self.config, format, fit_into_component, component),
        .PreferInterface => OutputStorage.nextInterface(&self.config, format, fit_into_component, component) catch if (self.config.program.out.get(id)) |existing| return existing else OutputStorage.nextBuffer(&self.config),
    };

    const result: *OutputStorage = switch (value.location) {
        .interface => blk: {
            const local = try self.channels.out.getOrPut(self.config.allocator, id);
            local.value_ptr.* = try self.config.allocator.create(OutputStorage);
            std.debug.assert(!local.found_existing);
            break :blk local.value_ptr.*;
        },
        .buffer => blk: {
            const global = try self.config.program.out.getOrPut(self.config.allocator, id);
            if (!global.found_existing) {
                const local = try self.channels.out.getOrPut(self.config.allocator, id);
                global.value_ptr.* = try self.config.allocator.create(OutputStorage);
                local.value_ptr.* = global.value_ptr.*;
            }
            break :blk global.value_ptr.*;
        },
    };
    result.* = value;
    return result;
}
pub fn VarResult(comptime T: type) type {
    return struct {
        found_existing: bool,
        value_ptr: *T,
    };
}

fn varImpl(self: *@This(), id: u64, comptime T: type, default: ?T, source: *std.AutoArrayHashMapUnmanaged(u64, *anyopaque), program_source: ?*std.AutoArrayHashMapUnmanaged(u64, *anyopaque)) !VarResult(T) {
    if (program_source) |ps| {
        const global = try ps.getOrPut(self.config.allocator, id);
        if (!global.found_existing) {
            const local = try source.getOrPut(self.config.allocator, id);
            local.value_ptr.* = try self.config.allocator.create(T);
            global.value_ptr.* = local.value_ptr.*;
            if (default) |d| {
                @as(*T, @alignCast(@ptrCast(local.value_ptr.*))).* = d;
            }
        }
        return VarResult(T){
            .found_existing = global.found_existing,
            .value_ptr = @alignCast(@ptrCast(global.value_ptr.*)),
        };
    } else {
        const local = try source.getOrPut(self.config.allocator, id);
        if (!local.found_existing) {
            local.value_ptr.* = try self.config.allocator.create(T);
            if (default) |d| {
                @as(*T, @alignCast(@ptrCast(local.value_ptr.*))).* = d;
            }
        }
        return VarResult(T){
            .found_existing = local.found_existing,
            .value_ptr = @alignCast(@ptrCast(local.value_ptr.*)),
        };
    }
}

pub fn controlVar(self: *@This(), id: u64, comptime T: type, program_wide: bool, default: ?T) !VarResult(T) {
    return varImpl(self, id, T, default, &self.channels.controls, if (program_wide) &self.config.program.controls else null);
}

pub fn outChannel(self: *@This(), id: u64) ?*OutputStorage {
    return self.channels.out.get(id) orelse self.config.program.out.get(id);
}

pub fn scratchVar(self: *@This(), id: u64, comptime T: type, default: ?T) !VarResult(T) {
    return varImpl(self, id, T, default, &self.scratch, null);
}

pub fn responseVar(self: *@This(), id: u64, comptime T: type, program_wide: bool, default: ?T) !VarResult(T) {
    return varImpl(self, id, T, default, &self.channels.responses, if (program_wide) &self.config.program.responses else null);
}

//
// Stepping and breakpoint code scaffolding functions
//

/// Shorthand for `std.fmt.allocPrint` with `Processor`'s arena allocator (so it doesn't want to be freed individually)
pub fn print(self: *@This(), comptime fmt: String, args: anytype) !String {
    return std.fmt.allocPrint(self.arena.allocator(), fmt, args);
}

/// Shorthand for `std.fmt.allocPrintZ` with `Processor`'s arena allocator (so it doesn't want to be freed individually)
pub fn printZ(self: *@This(), comptime fmt: String, args: anytype) !ZString {
    return std.fmt.allocPrintZ(self.arena.allocator(), fmt, args);
}

const ForLoop = analyzer.syntax.Extractor(.statement, struct {
    keyword_for: analyzer.syntax.Token(.keyword_for),
    condition_list: analyzer.syntax.ConditionList,
    block: analyzer.syntax.Block,
});

/// Stores the information about important language entities in the upper layers of currently traversed syntax tree
pub const TraverseContext = struct {
    /// Parent function
    function: ?Function,
    /// Will be either the root `Processor` Inserts array or the `wrapped_expr` Inserts array
    inserts: Inserts,
    /// A flag to set when an instrument wants to make changes to the source code that corresponds to this contexts
    instrumented: bool = false,
    /// The nearest parent block node
    block: NodeId,
    /// The nearest parent statement node
    statement: ?analyzer.parse.Span,
    scope: *sema.Scope,

    pub const Function = struct {
        name: String,
        return_type: String,
        syntax: analyzer.syntax.FunctionDeclaration,
    };

    /// The returned `Context` has a new `scope` field which sould be deinitialized using the `Context.nestedDeinit()` method.
    pub fn nested(self: @This(), allocator: std.mem.Allocator) !@This() {
        var nested_context = self;
        nested_context.scope = try allocator.create(sema.Scope);
        nested_context.scope.* = sema.Scope{
            .parent = self.scope,
            .function_counter = self.scope.function_counter,
        };
        return nested_context;
    }

    /// The returned `Context` has a standalone `inserts` field, which must be deinited using the `Context.inExpressionDeinit()` method.
    pub fn inExpression(self: @This(), allocator: std.mem.Allocator) @This() {
        std.debug.assert(self.statement != null); // Expression nodes must be in a statement context
        var wrapped_context = TraverseContext{
            .scope = self.scope,
            .inserts = .{},
            .block = self.block,
            .function = self.function,
            .statement = self.statement,
        };
        wrapped_context.inserts.init(allocator);
        return wrapped_context;
    }

    /// Deinitialize the `scope` field
    pub fn nestedDeinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.scope.deinit(allocator);
        allocator.destroy(self.scope);
    }

    /// Deinitialize the `inserts` field
    pub fn inExpressionDeinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.inserts.deinit(allocator);
    }
};

pub fn extractFunction(tree: analyzer.parse.Tree, node: Processor.NodeId, source: String) Error!TraverseContext.Function {
    const func = analyzer.syntax.FunctionDeclaration.tryExtract(tree, node) orelse return Error.InvalidTree;
    const name_token = func.get(.identifier, tree) orelse return Error.InvalidTree;
    const return_type_specifier = func.get(.specifier, tree) orelse return Error.InvalidTree;
    const return_type_span = tree.nodeSpan(return_type_specifier.getNode());
    return .{
        .name = name_token.text(source, tree),
        .return_type = source[return_type_span.start..return_type_span.end],
        .syntax = func,
    };
}

pub fn processExpression(self: *@This(), node: NodeId, context: *TraverseContext) FnErrorSet(@TypeOf(processNode))!?String {
    var wrapped_ctx = context.inExpression(self.config.allocator);
    defer wrapped_ctx.inExpressionDeinit(self.config.allocator);

    const tree = self.parsed.tree;

    const wrapped_span = tree.nodeSpan(node);
    const wrapped_orig_str = wrapped_span.text(self.config.source);
    const wrapped_type = try self.processNode(node, context);
    var applied = try wrapped_ctx.inserts.applyToOffseted(self.config.source, tree.nodeSpan(node).start, self.config.allocator);
    const wrapped_str = if (applied) |*s|
        try s.toOwnedSlice(self.config.allocator)
    else
        wrapped_orig_str;

    defer if (wrapped_str.ptr != wrapped_orig_str.ptr) self.config.allocator.free(wrapped_str);

    var result_var: ?u64 = null;

    if (wrapped_ctx.instrumented) if (context.statement) |ss| {
        const temp_rand = self.rand.next();
        const parent_span = tree.nodeSpan(tree.parent(node).?);
        // insert the wrapped code before the original statement. Assign its result into a temporary var
        try self.insertEnd(
            if (wrapped_type) |w_t|
                try self.print(
                    "{s} {s}{x:8}={s};",
                    .{ w_t, templates.temp, temp_rand, wrapped_str },
                )
            else
                try self.print("{s};\n", .{wrapped_str}),
            ss.start,
            0,
        );

        // replace the expression with the temp result variable
        try self.insertEnd(
            try self.print("{s}{x:8}", .{ templates.temp, temp_rand }),
            parent_span.start,
            parent_span.length(),
        );

        result_var = temp_rand;
    } else try self.addDiagnostic(Error.InvalidTree, @src(), tree.nodeSpan(node), @errorReturnTrace());

    return wrapped_type;
}

/// Returns the result of the last child processed
fn processAllChildren(self: *@This(), node: NodeId, context: *TraverseContext) FnErrorSet(@TypeOf(processNode))!?String {
    std.debug.assert(self.parsed.tree.tag(node).isSyntax());
    const children = self.parsed.tree.children(node);
    var result: ?String = null;
    for (children.start..children.end) |child| {
        result = try self.processNode(@intCast(child), context);
    }
    return result;
}

fn processInstruments(self: *@This(), node: NodeId, context: *TraverseContext) !void {
    for (self.config.instruments_any) |instrument| {
        if (instrument.instrument) |i| i(self, node, context) catch |err| {
            try self.addDiagnostic(err, @src(), self.parsed.tree.nodeSpan(node), @errorReturnTrace());
        };
    }
    const tag = self.parsed.tree.tag(node);
    if (self.config.instruments_scoped.getPtr(tag)) |scoped| {
        for (scoped.items) |instrument| {
            log.debug("Instrumenting {s} at {d} by {x}", .{ @tagName(tag), self.parsed.tree.nodeSpanExtreme(node, .start), instrument.id });
            if (instrument.instrument) |i| i(self, node, context) catch |err| {
                try self.addDiagnostic(err, @src(), self.parsed.tree.nodeSpan(node), @errorReturnTrace());
            };
        }
    }
}

const IfBranch = analyzer.syntax.Extractor(.if_branch, struct {
    /// maybe else-if
    keyword_else: analyzer.syntax.Token(.keyword_else),
    keyword_if: analyzer.syntax.Token(.keyword_if),
    condition_list: analyzer.syntax.ConditionList,
    block: analyzer.syntax.Block,
});

/// Process a tree node recursively. Depth-first traversal.
///
/// Returns the type of the processed expression.
fn processNode(self: *@This(), node: NodeId, context: *TraverseContext) !?String {
    const tree = self.parsed.tree;
    const source = self.config.source;
    switch (tree.tag(node)) { // TODO serialize the recursive traversal
        .if_branch => {
            // if(a(ahoj) == 1) {
            //
            // } else if(a(ahoj) == 2) {
            //  // we must wrap the elseif
            // }

            const cond = tree.nodeSpan(node);
            const siblings = tree.children(tree.parent(node).?);
            var close_pos = cond.end;
            for (node..siblings.end) |sibling| {
                const s_tag = tree.tag(sibling);
                if (s_tag == .if_branch or s_tag == .else_branch) {
                    close_pos = tree.nodeSpanExtreme(@intCast(sibling), .end);
                }
            }
            const is_else_if = tree.tag(tree.children(node).start) == .keyword_else;
            const after_else_kw: u32 = cond.start + @as(u32, if (is_else_if) 4 else 0); // e l s e
            try self.insertStart("{", after_else_kw);
            try self.insertEnd("}", close_pos, 0);
            const previous = context.statement;
            context.statement = .{ // now we are in a new statement context
                .start = after_else_kw,
                .end = close_pos,
            };
            const if_branch = IfBranch.tryExtract(tree, node) orelse return Error.InvalidTree;
            // Process the condition list
            _ = try self.processAllChildren(if_branch.get(.condition_list, tree).?.node, context);
            // Process the block
            _ = try self.processAllChildren(if_branch.get(.block, tree).?.node, context);
            context.statement = previous;
        },
        .statement => {
            const previous = context.statement;
            const children = tree.children(node);
            switch (tree.tag(children.start)) {
                .keyword_for, .keyword_while, .keyword_do => {
                    for (children.start + 1..children.end) |child| {
                        if (tree.tag(child) == .block) {
                            const s = tree.nodeSpan(@intCast(child));
                            context.statement = s;
                            // wrap in parenthesis
                            try self.insertStart("{", s.start);
                            try self.insertEnd("}", s.end, 0);
                        }
                    }
                },
                else => context.statement = tree.nodeSpan(node),
            }
            _ = try self.processAllChildren(node, context);
            context.statement = previous; // Pop out from the statement context
        },
        .keyword_for => {
            if (ForLoop.tryExtract(tree, node)) |for_loop| {
                const cond: analyzer.syntax.ConditionList = for_loop.get(.condition_list, tree).?;
                var it = cond.iterator();
                var nested = try context.nested(self.config.allocator);
                defer nested.nestedDeinit(self.config.allocator);
                while (it.next(tree)) |s| {
                    _ = try nested.scope.fill(self.config.allocator, tree, s.getNode(), source);
                }
                _ = try self.processNode(for_loop.get(.block, tree).?.node, &nested);
            }
        },
        .expression_sequence => {
            var in_expr = context.inExpression(self.config.allocator);
            defer in_expr.inExpressionDeinit(self.config.allocator);

            try self.processInstruments(node, &in_expr);
            return try self.processAllChildren(node, &in_expr);
        },
        .arguments_list => {
            if (analyzer.syntax.ArgumentsList.tryExtract(tree, node)) |args| {
                var args_it = args.iterator();
                var i: usize = 0;
                const span = tree.nodeSpan(node);

                while (args_it.next(tree)) |a| { // process the arguments as "wrapped expressions"
                    defer i += 1;
                    const expr = a.get(.expression, tree) orelse {
                        log.err("Expression node not found under argument {d}", .{i + 1});
                        try self.addDiagnostic(Error.InvalidTree, @src(), span, null);
                        continue;
                    };

                    _ = try self.processExpression(expr.node, context);
                }
            }
        },
        .call => {
            if (analyzer.syntax.Call.tryExtract(tree, node)) |call| {
                const name = call.get(.identifier, tree).?.text(source, tree);

                var result_type: ?String = null;
                // process all the arguments as "wrapped expressions"
                if (call.get(.arguments, tree)) |args| {
                    _ = try self.processNode(args.node, context);
                }

                if (context.scope.functions.get(name)) |f| { // user function
                    result_type = tree.nodeSpan(f.symbol.type.getNode()).text(source);
                } else {
                    for (self.config.spec.functions) |func| {
                        const hash = std.hash.CityHash32.hash;
                        if (std.mem.eql(u8, func.name, name)) { // TODO better than linear scan
                            switch (hash(func.return_type)) { // builtin function
                                h: {
                                    break :h hash("genType");
                                }, h: {
                                    break :h hash("genDType");
                                } => {
                                    // return the type of the first parameter
                                    result_type = try self.processNode((call.get(.arguments, tree) orelse {
                                        try self.addDiagnostic(Error.NoArguments, @src(), tree.nodeSpan(node), null);
                                        return null;
                                    }).node, context);
                                },
                                else => {},
                            }
                        }
                    }
                }
                try self.processInstruments(node, context);
                return result_type;
            }
        },
        .block => {
            var nested = try context.nested(self.config.allocator);
            defer nested.nestedDeinit(self.config.allocator);
            _ = try self.processAllChildren(node, &nested);
        },
        .function_declaration => {
            context.function = try extractFunction(tree, node, source);
            _ = try self.processNode(context.function.?.syntax.get(.block, tree).?.node, context);
        },
        .declaration => {
            if (try context.scope.fill(self.config.allocator, tree, node, source)) |ext| {
                switch (ext) {
                    .variable => |decl| { // Process all the variable initializations as "wrapped expressions"
                        var it: analyzer.syntax.Variables.Iterator = decl.get(.variables, tree).?.iterator();
                        while (it.next(tree)) |init| {
                            const previous = context.statement;
                            if (previous == null) { // Top-level declarations can stand alone without statement. TODO process them even here?
                                context.statement = tree.nodeSpan(node);
                            }
                            var wrapped_ctx = context.inExpression(self.config.allocator);
                            defer wrapped_ctx.inExpressionDeinit(self.config.allocator);

                            _ = try self.processNode(init.node, &wrapped_ctx);
                            context.statement = previous;
                        }
                    },
                    else => {}, // functions are filled in the pre-pass
                }
            }
        },
        else => |tag| _ = if (tag.isSyntax()) try self.processAllChildren(node, context),
    }
    try self.processInstruments(node, context);
    return null;
}

/// Do not pass compile-time strings to this function, as they are not copied
pub fn insertStartFree(self: *@This(), string: String, offset: usize) std.mem.Allocator.Error!void {
    return self.inserts.insertStartFree(string, offset);
}

/// Do not pass compile-time strings to this function, as they are not copied
pub fn insertEndFree(self: *@This(), string: String, offset: usize, consume_next: u32) std.mem.Allocator.Error!void {
    return self.inserts.insertEndFree(string, offset, consume_next);
}

pub fn insertStart(self: *@This(), string: String, offset: usize) std.mem.Allocator.Error!void {
    return self.inserts.insertStart(string, offset);
}

pub fn insertEnd(self: *@This(), string: String, offset: usize, consume_next: u32) std.mem.Allocator.Error!void {
    return self.inserts.insertEnd(string, offset, consume_next);
}

/// Gets processor's result and frees the working memory
pub fn apply(self: *@This()) !Result {
    var parts = try self.inserts.applyTo(self.config.source, self.config.allocator) orelse {
        try self.addDiagnostic(try self.print("Instrumentation was requested but no inserts were generated for stage {s}", .{@tagName(self.config.shader_stage)}), null, null, null);
        return Result{ .length = 0, .channels = self.toOwnedChannels(), .source = null, .spirv = null };
    };
    try parts.append(self.config.allocator, 0); // null-terminate the string

    const len = parts.items.len;
    return Result{
        .length = len,
        .channels = self.toOwnedChannels(),
        .source = @ptrCast((try parts.toOwnedSlice(self.config.allocator)).ptr),
        .spirv = null,
    };
}

/// NOTE: When an error union is passed as `value`, the diagnostic is added only if the error has occured (so if you want to include it forcibly, try or catch it before calling this function)
fn addDiagnostic(self: *@This(), value: anytype, source: ?std.builtin.SourceLocation, span: ?analyzer.parse.Span, trace: ?*std.builtin.StackTrace) std.mem.Allocator.Error!switch (@typeInfo(@TypeOf(value))) {
    .error_union => |err_un| err_un.payload,
    else => void,
} {
    const err_name_or_val = switch (@typeInfo(@TypeOf(value))) {
        .error_union => if (value) |success| {
            return success;
        } else |err| @errorName(err),
        .error_set => @errorName(value),
        else => value,
    };

    if (echo_diagnostics) {
        if (trace) |t| {
            log.debug("Diagnostic {s} at {}", .{ err_name_or_val, t });
        } else if (source) |s| {
            log.debug("Diagnostic {s} at {s}:{d}:{d} ({s})", .{ err_name_or_val, s.file, s.line, s.column, s.fn_name });
        } else {
            log.debug("Diagnostic {s}", .{err_name_or_val});
        }
    }
    try self.channels.diagnostics.append(self.config.allocator, .{
        .d = analyzer.parse.Diagnostic{
            .message = err_name_or_val,
            .span = span orelse .{ .start = 0, .end = 0 },
        },
        .free = switch (@typeInfo(@TypeOf(value))) {
            .pointer => |p| p.size == .slice,
            else => false,
        },
    });
}

/// A data structure for storing a collection of "insert" operations to be applied to a source code.
pub const Inserts = struct {
    pub const TaggedString = struct {
        free: bool,
        string: String,
    };
    pub const Insert = struct {
        /// offset in the original non-instrumented source code
        offset: usize,
        consume_next: u32 = 0,
        inserts: std.DoublyLinkedList(TaggedString),

        pub fn order(a: @This(), b: @This()) std.math.Order {
            return std.math.order(a.offset, b.offset);
        }
    };
    pub const Treap = std.Treap(Insert, Insert.order);
    inserts: Treap = .{},

    node_pool: std.heap.MemoryPool(Treap.Node) = undefined,
    lnode_pool: std.heap.MemoryPool(std.DoublyLinkedList(TaggedString).Node) = undefined,

    pub fn init(self: *@This(), allocator: std.mem.Allocator) void {
        self.node_pool = std.heap.MemoryPool(Treap.Node).init(allocator);
        self.lnode_pool = std.heap.MemoryPool(std.DoublyLinkedList(TaggedString).Node).init(allocator);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        // deinit contents
        var it = self.inserts.inorderIterator();
        while (it.current) |node| : (_ = it.next()) {
            while (node.key.inserts.pop()) |item| {
                if (item.data.free) {
                    allocator.free(item.data.string);
                }
            }
        }

        // deinit the wrapping nodes
        self.node_pool.deinit();
        self.lnode_pool.deinit();
    }

    /// Used for variable watches (needto be executed before a breakpoint)
    pub fn insertStart(self: *@This(), string: String, offset: usize) std.mem.Allocator.Error!void {
        try self.insertStartImpl(string, offset, false);
    }

    /// Used for variable watches (needto be executed before a breakpoint).
    /// The `string` will be freed after the `Inserts` is deinitialized.
    pub fn insertStartFree(self: *@This(), string: String, offset: usize) std.mem.Allocator.Error!void {
        try self.insertStartImpl(string, offset, true);
    }

    fn insertStartImpl(self: *@This(), string: String, offset: usize, free: bool) std.mem.Allocator.Error!void {
        var entry = self.inserts.getEntryFor(.{ .offset = offset, .inserts = std.DoublyLinkedList(TaggedString){} });
        const new_lnode = try self.lnode_pool.create();
        new_lnode.* = .{ .data = .{ .string = string, .free = free } };
        if (entry.node) |node| {
            node.key.inserts.prepend(new_lnode);
        } else {
            const new_node = try self.node_pool.create();
            entry.key.inserts.prepend(new_lnode);
            entry.set(new_node);
        }
    }

    /// Used for breakpoints (after a breakpoint no action should occur)
    /// Consume next `consume_next` characters after the inserted string
    pub fn insertEnd(self: *@This(), string: String, offset: usize, consume_next: u32) std.mem.Allocator.Error!void {
        try self.insertEndImpl(string, offset, consume_next, false);
    }
    /// Used for breakpoints (after a breakpoint no action should occur).
    /// Consume next `consume_next` characters after the inserted string.
    /// The `string` will be freed after the `Inserts` is deinitialized.
    pub fn insertEndFree(self: *@This(), string: String, offset: usize, consume_next: u32) std.mem.Allocator.Error!void {
        try self.insertEndImpl(string, offset, consume_next, true);
    }

    fn insertEndImpl(self: *@This(), string: String, offset: usize, consume_next: u32, free: bool) std.mem.Allocator.Error!void {
        var entry = self.inserts.getEntryFor(Insert{ .offset = offset, .consume_next = consume_next, .inserts = std.DoublyLinkedList(TaggedString){} });
        const new_lnode = try self.lnode_pool.create();
        new_lnode.* = .{ .data = .{ .string = string, .free = free } };
        if (entry.node) |node| {
            node.key.inserts.append(new_lnode);
            node.key.consume_next += consume_next;
        } else {
            const new_node = try self.node_pool.create();
            entry.key.inserts.append(new_lnode);
            entry.set(new_node);
        }
        if (builtin.mode == .Debug) if (entry.node) |node| {
            if (node.prev()) |prev| {
                if (prev.key.offset + prev.key.consume_next > offset) {
                    log.warn("Inserting '{s}' at {d} into overlapping '{s}' at {d} (consumes {d}, overlap by {d})", .{
                        string,
                        offset,
                        prev.key.inserts.last.?.data.string,
                        prev.key.offset,
                        prev.key.consume_next,
                        prev.key.offset + prev.key.consume_next - offset,
                    });
                }
            }
        };
    }

    pub fn applyTo(self: *@This(), source: String, allocator: std.mem.Allocator) !?std.ArrayListUnmanaged(u8) {
        return self.applyToOffseted(source, 0, allocator);
    }

    /// Apply the inserts to the source code which has cut the first `offset` characters. Useful when processing only a part of the source code.
    pub fn applyToOffseted(self: *@This(), source: String, offset: usize, allocator: std.mem.Allocator) !?std.ArrayListUnmanaged(u8) {
        var parts = try std.ArrayListUnmanaged(u8).initCapacity(allocator, source.len + 1 - offset);

        var it = self.inserts.inorderIterator(); //Why can't I iterate on const Treap?
        if (it.current == null) {
            parts.deinit(allocator);
            return null;
        } else {
            var previous: ?*Treap.Node = null;
            while (it.next()) |node| : (previous = node) { //for each insert
                const inserts = node.key.inserts;

                const prev_offset =
                    if (previous) |prev| blk: {
                        if (prev.key.offset > node.key.offset) {
                            if (it.next()) |nexter| {
                                log.debug("Nexter at {d}, cons {d}: {s}", .{ nexter.key.offset, nexter.key.consume_next, nexter.key.inserts.first.?.data.string });
                            }
                            // write the rest of code
                            try parts.appendSlice(allocator, source[prev.key.offset + prev.key.consume_next - offset ..]);
                            break;
                        }
                        const prev_combined = prev.key.offset + prev.key.consume_next;
                        if (prev_combined > node.key.offset) {
                            log.warn("Previous insert '{s}' at {d} consumes {d} and overlaps by {d} this: '{s}'", .{
                                prev.key.inserts.last.?.data.string,
                                prev.key.offset,
                                prev.key.consume_next,
                                prev_combined - node.key.offset,
                                node.key.inserts.first.?.data.string,
                            });
                        }
                        break :blk prev_combined;
                    } else 0;

                try parts.appendSlice(allocator, source[@min(prev_offset, node.key.offset) - offset .. node.key.offset - offset]);

                var inserts_iter = inserts.first;
                while (inserts_iter) |inserts_node| : (inserts_iter = inserts_node.next) { //for each part to insert at the same offset
                    const to_insert = inserts_node.data;
                    try parts.appendSlice(allocator, to_insert.string);
                }
            } else {
                // write the rest of code
                try parts.appendSlice(allocator, source[previous.?.key.offset + previous.?.key.consume_next - offset ..]);
            }
        }
        return parts;
    }
};

/// Specifies an interface for accessing storage into which shaders can write its outputs
// TODO deinit on new instrumentation (or deinit the ReadbacK? I don't know what I meant...)
pub const OutputStorage = struct {
    location: OutputStorage.Location,

    //
    // Readback hints
    //
    /// Size specification hint for the consuming client instrument
    size: usize = 0,
    /// Output channels are meant to be read back for use by the instrument clients each time the shader is executed. Set this flag to true to disable the automatic readback.
    lazy: bool = false,
    /// This can be specified for the backend instrument clients to not read the whole buffer, but only a part of it.
    readback_offset: usize = 0,

    /// Does not copy name
    fn nextInterface(
        config: *Processor.Config,
        format: Location.Format,
        fit_into_component: ?OutputStorage.Location,
        component: ?usize,
    ) !OutputStorage {
        switch (config.shader_stage) {
            .gl_fragment, .vk_fragment, .gl_vertex, .vk_vertex => {
                if (fit_into_component) |another_stor| {
                    if (another_stor == .interface and component != null) {
                        return OutputStorage{ .location = .{ .interface = .{ .location = another_stor.interface.location, .component = component.?, .format = format } } };
                    }
                }
                // these can have output interfaces
                var candidate: usize = 0;
                for (config.used_interface.items) |loc| {
                    if (loc > candidate) {
                        if (loc >= config.used_interface.items.len) {
                            try config.used_interface.append(config.allocator, candidate);
                        } else {
                            try config.used_interface.insert(config.allocator, loc, candidate);
                        }
                        return OutputStorage{ .location = .{ .interface = .{ .location = candidate, .format = format } } };
                    }
                    candidate = loc + 1;
                }
                if (candidate < config.max_interface) {
                    try config.used_interface.append(config.allocator, candidate);
                    return OutputStorage{ .location = .{ .interface = .{ .location = candidate, .format = format } } };
                }
            },
            else => {
                // other stages cannot have direct output interfaces
            },
        }
        return Error.OutOfStorage;
    }

    /// Does not copy name
    fn nextBuffer(
        config: *Processor.Config,
    ) !OutputStorage {
        if (config.support.buffers) {
            var binding_i: usize = 0;
            for (0.., config.used_buffers.items) |i, used| {
                if (used > binding_i) {
                    try config.used_buffers.insert(config.allocator, i, binding_i);
                    return OutputStorage{ .location = .{ .buffer = .{ .binding = binding_i } } };
                }
                binding_i = used + 1;
            }
            if (binding_i < config.max_buffers) {
                try config.used_buffers.append(config.allocator, binding_i);
                return OutputStorage{ .location = .{ .buffer = .{ .binding = binding_i } } };
            }
        }
        return Error.OutOfStorage;
    }

    /// Does not copy name
    fn nextPreferBuffer(
        config: *Processor.Config,
        format: Location.Format,
        fit_into: ?OutputStorage.Location,
        component: ?usize,
    ) !OutputStorage {
        return nextBuffer(config) catch nextInterface(config, format, fit_into, component);
    }

    pub const Location = union(enum) {
        /// binding number (for SSBOs)
        buffer: Buffer,
        /// output interface location (attachment, transform feedback varying). Not available for all stages, but is more compatible (GLES...)
        interface: Interface,

        pub const Buffer = struct {
            binding: usize,
            offset: usize = 0,
        };
        pub const Interface = struct {
            location: usize,
            component: usize = 0,
            format: Format,
            /// readback offset in pixels
            x: usize = 0,
            y: usize = 0,
        };

        pub const Format = enum { @"4U8", @"4F8", @"4I8", @"4U16", @"4I16", @"4F16", @"4U32", @"4I32", @"4F32", @"3U8", @"3F8", @"3I8", @"3U16", @"3I16", @"3F16", @"3U32", @"3I32", @"3F32", @"2U8", @"2F8", @"2I8", @"2U16", @"2I16", @"2F16", @"2U32", @"2I32", @"2F32", @"1U8", @"1F8", @"1I8", @"1U16", @"1I16", @"1F16", @"1U32", @"1I32", @"1F32" };
    };
};

pub const VariableInstrumentation = struct {
    symbol: sema.Symbol,
    /// Multiple variables can be stored in the same storage
    offset: usize,
    stride: usize,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.symbol.deinit(allocator);
    }

    pub fn copy(self: @This(), allocator: std.mem.Allocator) !void {
        self.symbol = try self.symbol.copy(allocator);
    }
};

fn FnErrorSet(comptime f: type) type {
    return @typeInfo(@typeInfo(f).@"fn".return_type.?).error_union.error_set;
}
