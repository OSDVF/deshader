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
const decls = @import("../declarations.zig");
const shaders = @import("shaders.zig");
const sema = @import("sema.zig");

const String = []const u8;
const CString = [*:0]const u8;
const ZString = [:0]const u8;
// TODO this sould be a hashmap keyed by NodeIds
const CompoundResult = sema.Symbol.Content;

pub const NodeId = u32;

pub const Error = error{
    InvalidTree,
    OutOfStorage,
    NoArguments,
    /// Type resolution failed for expression that requires it
    Resolution,
};
pub const Parsed = struct {
    arena_state: std.heap.ArenaAllocator.State,
    tree: analyzer.parse.Tree,
    ignored: []const analyzer.parse.Token,
    diagnostics: []const analyzer.parse.Diagnostic,

    /// Maps function names to the list of their calls sorted ascending by position in the code
    calls: std.StringHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(NodeId, void)),
    /// GLSL version
    version: u16,
    /// Is this an OpenGL ES shader?
    es: bool,
    last_directive_end: usize,

    // List of enabled extensions
    extensions: []const []const u8,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.arena_state.promote(allocator).deinit();
    }

    pub fn parseSource(
        allocator: std.mem.Allocator,
        text: []const u8,
    ) (std.fmt.ParseIntError || std.mem.Allocator.Error || analyzer.parse.Parser.Error)!@This() {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        var diagnostics = std.ArrayList(analyzer.parse.Diagnostic).init(arena_allocator);

        var ignored = std.ArrayList(analyzer.parse.Token).init(arena_allocator);
        defer ignored.deinit();

        var calls = std.StringHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(NodeId, void)).empty;
        errdefer {
            var it = calls.valueIterator();
            while (it.next()) |v| {
                v.deinit(arena_allocator);
            }
            calls.deinit(arena_allocator);
        }

        const tree = try analyzer.parse.parse(arena_allocator, text, .{
            .ignored = &ignored,
            .diagnostics = &diagnostics,
            .calls = &calls,
        });

        var extensions = std.ArrayList([]const u8).init(arena_allocator);
        errdefer extensions.deinit();

        var version: u16 = 0;
        var es = false;
        var last_directive: usize = 0;

        for (ignored.items) |token| {
            const line = text[token.start..token.end];
            switch (analyzer.parse.parsePreprocessorDirective(line) orelse continue) {
                .extension => |extension| {
                    const name = extension.name;
                    try extensions.append(line[name.start..name.end]);

                    if (token.end > last_directive) {
                        last_directive = token.end;
                    }
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
                    if (token.end > last_directive) {
                        last_directive = token.end;
                    }
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
            .last_directive_end = last_directive,
        };
    }
};

pub const Result = struct {
    /// The new source code with the inserted instrumentation or null if no changes were made by the instrumentation
    source: ?CString,
    length: usize,
    spirv: ?String,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.source) |s| {
            allocator.free(s[0 .. self.length - 1 :0]);
        }
    }
};

/// Payload of function prototypes for manipulating the shader code
pub const Instrument = struct {
    pub const ID = u64;
    id: ID,
    // named nodeType in the thesis
    tag: ?analyzer.parse.Tag,
    /// An array of IDs of instruments that should have their `instrument` method called before this one
    dependencies: ?[]const ID,

    collect: ?*const fn () void, //TODO
    constructors: ?*const fn (processor: *Processor, main: NodeId) anyerror!void,
    deinitProgram: ?*const fn (program: *decls.instrumentation.Program) anyerror!void,
    deinitStage: ?*const fn (stage: *decls.types.Stage) anyerror!void,
    instrument: ?*const fn (
        processor: *Processor,
        node: NodeId,
        result: ?*const decls.instrumentation.Expression,
        context: *TraverseContext,
    ) anyerror!void,
    preprocess: ?*const fn (processor: *Processor, source_parts: []*shaders.Shader.SourcePart, result: *std.ArrayListUnmanaged(u8)) anyerror!void,
    /// Called when a new instrumentation is created for a program that has been already instrumented
    renewProgram: ?*const fn (state: *decls.instrumentation.Program) anyerror!void,
    /// Called when a new instrumentation is created for a stage that has been already instrumented
    renewStage: ?*const fn (state: *decls.types.Stage) anyerror!void,
    setup: ?*const fn (processor: *Processor) anyerror!void,
    /// Runs after the end of tree traversal. Can be used to destroy scratch variables
    finally: ?*const fn (processor: *Processor) anyerror!void,
};

// TODO create Channels mixin
/// Physically are the channels always stored in one of program's stage's `Channels` and thes maps inside this struct contains references only.
pub const ProgramChannels = struct {
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

    pub fn renew(self: *@This()) void {
        self.out.clearRetainingCapacity();
    }
};

/// Output channels and control variables that can be modified by the platform specific (backend) code (e.g. to set the selected thread location).
/// `out` variables are flushed every time a new instrumentation is created. `controls` and `responses` survive every re-instrumentation and are
/// flushed only when the source code is modified externally. Backend should also deinit all readbacks when a re-instrumentation is performed.
pub const StageChannels = struct {
    /// Filled with storages created by the individual instruments
    /// Do not access this from instruments directly. Use `Processor.outChannel` instead.
    out: std.AutoArrayHashMapUnmanaged(u64, *OutputStorage) = .empty,
    /// Filled with control variables created by the individual instruments (e.g. desired step)
    controls: std.AutoArrayHashMapUnmanaged(u64, *anyopaque) = .empty,
    /// Provided for storing `result` variables from the platform backend instrument clients (e.g. reached step)
    responses: std.AutoArrayHashMapUnmanaged(u64, *anyopaque) = .empty,

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
    }

    pub fn getOrCreateControl(self: *@This(), allocator: std.mem.Allocator, comptime T: type, id: u64, default_value: T) !*T {
        return if (self.controls.get(id)) |p| @alignCast(@ptrCast(p)) else blk: {
            const p = try self.allocator.create(T);
            p.* = default_value;
            try self.controls.put(allocator, id, p);
            break :blk p;
        };
    }

    pub fn getControl(self: @This(), comptime T: type, id: u64) ?T {
        return if (self.controls.get(id)) |p| @alignCast(@ptrCast(p)) else null;
    }

    pub fn getResponse(self: @This(), comptime T: type, id: u64) ?T {
        return if (self.responses.get(id)) |p| @alignCast(@ptrCast(p)) else null;
    }

    pub fn renew(self: *@This()) void {
        self.out.clearRetainingCapacity();
        self.diagnostics.clearRetainingCapacity();
    }
};

pub const Processor = @This();
pub const Config = struct {
    pub const Capabilities = struct {
        buffers: bool,
        /// Supports #include directives (ARB_shading_language_include, GOOGL_include_directive)
        include: bool,
        /// Not really a support flag, but an option for the preprocessor to not include any source file multiple times.
        all_once: bool,

        pub const Format = enum { md, json };

        pub fn format(
            self: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            switch (comptime std.meta.stringToEnum(Format, fmt) orelse @compileError("unknown format: '" ++ fmt ++ "'")) {
                .md => {
                    // Markdown table
                    try writer.writeAll(
                        \\ ## Support table for this context
                        \\| Feature | Supported |
                        \\| ------- | --------- |
                    );
                    inline for (@typeInfo(@This()).@"struct".fields) |field| {
                        const supported = @field(self, field.name);
                        try writer.print(
                            \\|{s: ^9}| {s: ^11} |
                            \\
                        , .{
                            field.name,
                            if (supported) "Yes" else "No",
                        });
                    }
                },
                .json => try std.json.fmt(self, .{ .whitespace = .indent_tab }).format(fmt, options, writer),
            }
        }
    };

    /// This allocator will be used for allocating all the output channels, controls and responses. So it should not be a temporary arena allocator.
    allocator: std.mem.Allocator,
    spec: analyzer.Spec,
    source: String,
    support: Capabilities,
    /// Turn of deducing supported features from the declared GLSL source code version and extensions
    force_support: bool,
    group_dim: []const usize,
    groups_count: ?[]const usize,
    /// Program-wide channels, shared between all shader stages. The out channels should be only Buffers
    program: *ProgramChannels,
    instruments_any: []const Instrument,
    instruments_scoped: std.EnumMap(analyzer.parse.Tag, std.ArrayListUnmanaged(Instrument)),
    max_buffers: usize,
    max_interface: usize,
    shader_stage: decls.shaders.StageType,
    single_thread_mode: bool,
    stage: *StageChannels,
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
threads_total: usize = 1, // Product of all threads dimesions sizes
/// Dimensions of the output buffer (vertex count / screen resolution / global threads count)
// SAFETY: assigned in setup()
threads: []usize = undefined,

/// Offset of the last #extension or #version directive (if any was found)
after_directives: usize = 0,
// SAFETY: assigned in setup()
arena: std.heap.ArenaAllocator = undefined,
last_interface_decl: usize = 0,
last_interface_node: NodeId = 0,
last_interface_location: usize = 0,
uses_dual_source_blend: bool = false,
vulkan: bool = false,
// SAFETY: assigned in setup()
parsed: Parsed = undefined,
// SAFETY: assigned in setup()
rand: std.Random.DefaultPrng = undefined,
scratch: std.AutoArrayHashMapUnmanaged(Instrument.ID, *anyopaque) = .empty,

/// Maps offsets in file to the inserted instrumented code fragments (sorted)
/// Both the key and the value are stored as Treap's Key (a bit confusing)
inserts: Inserts = .{}, // Will be inserted many times but iterated only once at applyTo

//
// Instrumentation privitives - identifiers for various storage and control variables
//

/// These are not meant to be used externally because they will be postfixed with a random number or stage name
pub const templates = struct {
    /// Used to filter out the variables that are added by deshader when querying program outputs
    pub const prefix = "deshader_";
    pub const cursor = "cursor";
    const temp = prefix ++ "temp";
    pub const local_thread_counts = prefix ++ "threads";
    /// Provided as a identifier of the current thread in linear one-dimensional space
    pub const linear_thread_id = prefix ++ "linear_id";
    pub const wg_size = Processor.templates.prefix ++ "workgroup_size";
};

const echo_diagnostics = builtin.mode == .Debug;

pub fn deinit(self: *@This()) void {
    self.config.allocator.free(self.threads);
    self.inserts.deinit(self.config.allocator);
    self.scratch.deinit(self.config.allocator);
    self.arena.deinit();
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

    self.parsed = try Parsed.parseSource(self.config.allocator, self.config.source);
    defer self.parsed.deinit(self.config.allocator);
    const tree = self.parsed.tree;
    const source = self.config.source;

    var functions = sema.Scope.Functions.empty;
    defer {
        var it = functions.valueIterator();
        while (it.next()) |v| {
            v.deinit(self.config.allocator);
        }
        functions.deinit(self.config.allocator);
    }
    var root_scope = sema.Scope{
        .functions = &functions,
    };
    defer root_scope.deinit(self.config.allocator);

    var root_ctx = TraverseContext{
        .block = tree.root,
        .function = null,
        .inserts = &self.inserts,
        .scope = &root_scope,
        .statement = null,
    };
    if (!self.config.force_support) {
        if ((self.parsed.version != 0 and self.parsed.version < 400) or (self.parsed.es and self.parsed.version < 310)) {
            self.config.support.buffers = false; // the extension is not supported in older GLSL
        }
    }
    self.after_directives = self.parsed.last_directive_end + 1; // assume there is a line break (it really should because it is a directive)
    self.last_interface_decl = self.after_directives;

    if (self.config.groups_count) |group_count| {
        std.debug.assert(group_count.len == self.config.group_dim.len);

        self.threads = try self.config.allocator.alloc(usize, group_count.len);
        for (self.config.group_dim, group_count, self.threads) |dim, count, *thread| {
            thread.* = dim * count;
        }
    } else {
        self.threads = try self.config.allocator.dupe(usize, self.config.group_dim);
    }
    errdefer self.config.allocator.free(self.threads);
    for (self.threads) |thread| {
        self.threads_total *= thread;
    }

    try self.declareThreadId();

    // Run the setup phase of the instruments
    try self.runAllInstrumentsPhase(tree.root, "setup", .{self});

    // Pre-pass to collect all the functions and resolve some shader characteristics
    // Iterate through top-level declarations
    // Traverse the tree top-down
    if (tree.nodes.len > 1) { // not only the `file` node
        const children = tree.children(tree.root);
        for (children.start..children.end) |n| {
            const node: NodeId = @intCast(n);
            const tag = tree.tag(node);
            switch (tag) {
                .block_declaration => {
                    const decl = analyzer.syntax.BlockDeclaration.tryExtract(tree, node) orelse return Error.InvalidTree;
                    const name = try self.extractNodeTextForce(decl, .specifier);
                    const t = try root_scope.getOrPutType(self.config.allocator, name);

                    if (self.extract(decl, .variable)) |variable| {
                        // The fields scoped inside the block
                        const var_node = variable.node;
                        const var_node_text = tree.nodeSpan(var_node).text(source);
                        var content = try self.resolveNode(var_node, &root_ctx, false) orelse //return Error.Resolution;
                            sema.Symbol.Content{ .type = .{ .basic = sema.types.float } };

                        switch (content.type) {
                            .array => |*array| {
                                array.base = name;
                            },
                            .basic => |*basic| {
                                basic.* = name;
                            },
                        }

                        try root_scope.fillVariable(self.config.allocator, var_node_text, content);
                    }

                    if (self.extract(decl, .fields)) |fields| {
                        var it = fields.iterator();
                        while (it.next(tree)) |field| {
                            const field_spec = try self.resolveNode(try self.extractNodeForce(field, .specifier), &root_ctx, false) orelse
                                //return Error.Resolution;
                                sema.Symbol.Content{ .type = .{ .basic = sema.types.float } };

                            const field_vars = self.extract(field, .variables) orelse return Error.InvalidTree;
                            var it2 = field_vars.iterator();
                            while (it2.next(tree)) |variable| {
                                const var_name = try self.extractNodeTextForce(variable, .name);
                                try t.put(self.config.allocator, var_name, field_spec.type);
                            }
                        }
                    }
                },

                .function_declaration => {
                    const decl = analyzer.syntax.FunctionDeclaration.tryExtract(tree, node) orelse return Error.InvalidTree;
                    const name = decl.get(.identifier, tree).?.text(source, tree);
                    const p = decl.get(.parameters, tree);
                    const parameter_types_list =
                        if (p) |parameters| try self.extractParameters(parameters) else &.{};

                    try functions.put(self.config.allocator, .{
                        .name = name,
                        .parameters = parameter_types_list,
                    }, sema.Symbol{
                        .name = name,
                        .content = try self.resolveNode(try self.extractNodeForce(decl, .specifier), &root_ctx, false) orelse
                            //return Error.Resolution,
                            sema.Symbol.Content{ .type = .{ .basic = sema.types.float } },
                    });

                    if (std.mem.eql(u8, name, "main")) {
                        const block = decl.get(.block, tree).?;

                        // Run the constructors phase of the instruments
                        try self.runAllInstrumentsPhase(node, "constructors", .{ self, block.node });
                    }
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
                                                                    location = std.fmt.parseInt(
                                                                        usize,
                                                                        tree.nodeSpan(assignment.get(.value, tree).?.node).text(source),
                                                                        0,
                                                                    ) catch location;
                                                                },
                                                            }
                                                        }
                                                    },
                                                    .other => |other| {
                                                        if (std.mem.eql(u8, tree.nodeSpan(other.getNode()).text(source), "local_size_variable")) {
                                                            for (self.parsed.ignored) |i| {
                                                                if (std.mem.indexOf(
                                                                    u8,
                                                                    i.text(self.config.source),
                                                                    "ARB_compute_variable_group_size",
                                                                ) != null) {
                                                                    // TODO more precise check
                                                                    log.debug("Found generic size compute shader", .{});
                                                                    break;
                                                                }
                                                            }
                                                        }
                                                    },
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
                            // TODO implicit locations, TODO glBindFragDataLocation
                            self.last_interface_location = location orelse (self.last_interface_location + 1);
                        }
                    }
                },
                else => {},
            }
        }
    }

    if (self.config.support.buffers and (self.parsed.version >= 310 or self.config.force_support)) {
        try self.insertStart(" #extension GL_ARB_shader_storage_buffer_object : require\n", self.after_directives);
        // To support SSBOs as instrumentation output channels
    }

    // Start the instrumentation by processing the root node
    _ = try self.processNode(tree.root, &root_ctx, true);

    //const result = try self.config.allocator.alloc([]const analyzer.lsp.Position, stops.items.len);
    //for (result, stops.items) |*target, src| {
    //    target.* = try self.config.allocator.dupe(analyzer.lsp.Position, src.items);
    //}
    //self.config.stages.steps = result;
    // Run the finally phase of the instruments
    try self.runAllInstrumentsPhase(tree.root, "finally", .{self});
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
            try self.insertStart(
                try self.print(
                    "const uvec2 " ++ templates.local_thread_counts ++ "= uvec2({d}, {d});\n" ++
                        "uint " ++ templates.linear_thread_id ++ " = uint(gl_FragCoord.y) * " ++ templates.local_thread_counts ++
                        ".x + uint(gl_FragCoord.x);\n",
                    .{ self.threads[0], self.threads[1] },
                ),
                self.after_directives,
            );
        },
        .gl_geometry => {
            try self.insertStart(try self.print(
                "const uint " ++ templates.local_thread_counts ++ "= {d};\n" ++
                    "uint " ++ templates.linear_thread_id ++ "= gl_PrimitiveIDIn * " ++ templates.local_thread_counts ++ " + gl_InvocationID;\n",
                .{self.threads[0]},
            ), self.after_directives);
        },
        .gl_tess_evaluation => {
            try self.insertStart(try self.print(
                "ivec2 " ++ templates.local_thread_counts ++ "= ivec2(gl_TessCoord.xy * float({d}-1) + 0.5);\n" ++
                    "uint " ++ templates.linear_thread_id ++ " =" ++ templates.local_thread_counts ++ ".y * {d} + " ++
                    templates.local_thread_counts ++ ".x;\n",
                .{ self.threads[0], self.threads[0] },
            ), self.after_directives);
        },
        .gl_mesh, .gl_task, .gl_compute => {
            try self.insertStart(
                try self.print("uint " ++ templates.linear_thread_id ++
                    "= gl_GlobalInvocationID.z * gl_NumWorkGroups.x * gl_NumWorkGroups.y * " ++ templates.wg_size ++
                    " + gl_GlobalInvocationID.y * gl_NumWorkGroups.x * " ++ templates.wg_size ++ " + gl_GlobalInvocationID.x);\n", .{}),
                self.after_directives,
            );
            if (self.parsed.version < 430) {
                try self.insertStart(
                    try self.print(
                        "const uvec3 " ++ templates.wg_size ++ "= uvec3({d},{d},{d});\n",
                        .{ self.config.group_dim[0], self.config.group_dim[1], self.config.group_dim[2] },
                    ),
                    self.after_directives,
                );
            } else {
                try self.insertStart(
                    "uvec3 " ++ templates.wg_size ++ "= gl_WorkGroupSize;\n",
                    self.after_directives,
                );
            }
        },
        else => {},
    }
}

const StoragePreference = enum { Buffer, Interface, PreferBuffer, PreferInterface };

/// Creates a storage slot description for the stage's output interface (XFB / FB) (or program-wide for buffers), and also adds it to result channel
/// collection. If the result channel is a buffer and the program already has a buffer with the same `id`, the existing buffer will be **reused**.
///
/// The caller must keep in mind that this function doesn't "just" create some output storage, but that the storage can be program- or stage- wide and
/// could end up being shared with other stages. (So some branching on these circumstances may be necessary - for example creating another storage
/// with a different `id` if there is need to have it per-stage)
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
        .PreferBuffer => if (self.config.program.out.get(id)) |existing|
            return existing
        else
            OutputStorage.nextPreferBuffer(&self.config, format, fit_into_component, component),

        .Interface => OutputStorage.nextInterface(&self.config, format, fit_into_component, component),
        .PreferInterface => OutputStorage.nextInterface(&self.config, format, fit_into_component, component) catch
            if (self.config.program.out.get(id)) |existing| return existing else OutputStorage.nextBuffer(&self.config),
    };

    const result: *OutputStorage = switch (value.location) {
        .interface => blk: {
            const local = try self.config.stage.out.getOrPut(self.config.allocator, id);
            local.value_ptr.* = try self.config.allocator.create(OutputStorage);
            std.debug.assert(!local.found_existing);
            break :blk local.value_ptr.*;
        },
        .buffer => blk: {
            const global = try self.config.program.out.getOrPut(self.config.allocator, id);
            if (!global.found_existing) {
                const local = try self.config.stage.out.getOrPut(self.config.allocator, id);
                global.value_ptr.* = try self.config.allocator.create(OutputStorage);
                local.value_ptr.* = global.value_ptr.*;
            }
            // THE STORAGE IS REUSED WHEN EXISTING
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

fn varImpl(
    self: *@This(),
    id: u64,
    comptime T: type,
    default: ?T,
    source: *std.AutoArrayHashMapUnmanaged(u64, *anyopaque),
    program_source: ?*std.AutoArrayHashMapUnmanaged(u64, *anyopaque),
) !VarResult(T) {
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
    return varImpl(self, id, T, default, &self.config.stage.controls, if (program_wide) &self.config.program.controls else null);
}

/// Returns the `OutputStorage` for the given ID if it exists in the stage or program output channels.
pub fn outChannel(self: *@This(), id: u64) ?*OutputStorage {
    return self.config.stage.out.get(id) orelse self.config.program.out.get(id);
}

pub fn scratchVar(self: *@This(), id: u64, comptime T: type, default: ?T) !VarResult(T) {
    return varImpl(self, id, T, default, &self.scratch, null);
}

pub fn responseVar(self: *@This(), id: u64, comptime T: type, program_wide: bool, default: ?T) !VarResult(T) {
    return varImpl(self, id, T, default, &self.config.stage.responses, if (program_wide) &self.config.program.responses else null);
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

/// Stores the information about
/// - important language entities in the upper layers of currently traversed syntax tree
/// - the whole scope tree
pub const TraverseContext = struct {
    /// Parent function
    function: ?Function,
    /// Will be either the root `Processor`'s `Inserts` array or the `wrapped_expr` `Inserts array
    inserts: *Inserts,
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
            .functions = self.scope.functions,
            .parent = self.scope,
        };
        return nested_context;
    }

    fn collect(self: *@This(), nested_ctx: *const @This()) void {
        self.instrumented = nested_ctx.instrumented;
    }

    /// The returned `Context` has a standalone `inserts` field, which must be deinited using the `Context.inExpressionDeinit()` method.
    pub fn inExpression(self: @This(), allocator: std.mem.Allocator) !@This() {
        var inserts = try allocator.create(Inserts);
        inserts.* = .{}; // initialize default values
        inserts.init(allocator); // initialize node pool

        return TraverseContext{
            .scope = self.scope,
            .inserts = inserts,
            .instrumented = false, // The expression is instrumented separately (owns own `Inserts`), so this flag is initally false
            .block = self.block,
            .function = self.function,
            .statement = self.statement,
        };
    }

    pub fn inFunction(self: @This(), function: Function, tree: analyzer.parse.Tree, allocator: std.mem.Allocator) !@This() {
        var new = try self.nested(allocator);

        new.block = function.syntax.get(.block, tree).?.node;
        new.function = function;
        new.statement = null;
        return new;
    }

    pub fn functionDeinit(self: *@This(), allocator: std.mem.Allocator, parent: *@This()) void {
        self.nestedDeinit(allocator, parent);
    }

    /// Deinitialize the `scope` field
    pub fn nestedDeinit(self: *@This(), allocator: std.mem.Allocator, parent: *@This()) void {
        parent.collect(self);
        self.scope.deinit(allocator);
        allocator.destroy(self.scope);
    }

    /// Deinitialize the `inserts` field
    pub fn inExpressionDeinit(self: *@This(), allocator: std.mem.Allocator, parent: *@This()) void {
        parent.collect(self);
        self.inserts.deinit(allocator);
        allocator.destroy(self.inserts);
    }
};

fn extract(
    self: *const Processor,
    extractor: anytype,
    comptime field: @TypeOf(extractor).FieldEnum,
) ?std.meta.FieldType(@TypeOf(extractor).Type, field) {
    return extractor.get(field, self.parsed.tree);
}

fn extractNode(self: *const Processor, extractor: anytype, comptime field: @TypeOf(extractor).FieldEnum) ?NodeId {
    return if (self.extract(extractor, field)) |e| if (@hasField(@TypeOf(e), "node")) e.node else e.getNode() else null;
}

fn extractNodeForce(self: *Processor, extractor: anytype, comptime field: @TypeOf(extractor).FieldEnum) !NodeId {
    const extracted = self.extract(extractor, field) orelse {
        _ = try self.addDiagnostic(self.print("Expected {s}", .{@tagName(field)}), @src(), self.parsed.tree.nodeSpan(extractor.node), null);
        return Error.InvalidTree;
    };
    return if (@hasField(@TypeOf(extracted), "node")) extracted.node else extracted.getNode();
}

fn extractNodeSpanForce(self: *Processor, extractor: anytype, comptime field: @TypeOf(extractor).FieldEnum) !NodeId {
    const extracted = self.extract(extractor, field) orelse {
        _ = try self.addDiagnostic(self.print("Expected {s}", .{@tagName(field)}), @src(), self.parsed.tree.nodeSpan(extractor.node), null);
        return Error.InvalidTree;
    };
    return self.parsed.tree.nodeSpan(extracted.node);
}

fn extractNodeTextForce(self: *Processor, extractor: anytype, comptime field: @TypeOf(extractor).FieldEnum) !String {
    const extracted = self.extract(extractor, field) orelse {
        _ = try self.addDiagnostic(self.print("Expected {s}", .{@tagName(field)}), @src(), self.parsed.tree.nodeSpan(extractor.node), null);
        return Error.InvalidTree;
    };
    return self.parsed.tree.nodeSpan(if (@hasField(@TypeOf(extracted), "node")) extracted.node else extracted.getNode()).text(self.config.source);
}

pub fn extractParameters(
    self: *Processor,
    parameters: analyzer.syntax.ParameterList,
) ![]sema.Symbol.Type {
    const tree = self.parsed.tree;
    const source = self.config.source;
    // Allocated in arena because it must be live as long as the functions hashmap
    const allocator = self.arena.allocator();

    const parameters_count = parameters.items.length();
    var params = std.ArrayListUnmanaged(sema.Symbol.Type).empty;
    errdefer params.deinit(allocator);
    try params.ensureTotalCapacity(allocator, parameters_count);

    var it: analyzer.syntax.ListIterator(analyzer.syntax.Parameter) = parameters.iterator();
    var i: usize = 0;
    while (it.next(tree)) |param| : (i += 1) {
        const specifier = param.get(.specifier, tree).?;
        const s_slice = tree.nodeSpan(specifier.getNode()).text(source);
        if (!std.mem.eql(u8, s_slice, "void")) {
            params.appendAssumeCapacity(try sema.Symbol.Type.parse(allocator, s_slice));
        }
    }
    return params.toOwnedSlice(allocator);
}

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

/// Process and resolve inner expressions of the given node and apply the instrumentation `Inserts` immediately.
fn processExpression(
    self: *@This(),
    node: NodeId,
    context: *TraverseContext,
    do_instruments: bool,
    only_children: bool,
) FnErrorSet(@TypeOf(processNode))!?CompoundResult {
    const tree = self.parsed.tree;
    const previous = context.statement;
    if (context.statement != null) // Expression nodes must be in a statement context
    {
        log.warn("Expression node {d} is not in a statement context", .{node});
        context.statement = tree.nodeSpan(tree.parent(node) orelse node);
    }
    defer context.statement = previous;

    var wrapped_ctx = try context.inExpression(self.config.allocator);
    defer wrapped_ctx.inExpressionDeinit(self.config.allocator, context);

    const wrapped_span = tree.nodeSpan(node);
    const wrapped_orig_str = wrapped_span.text(self.config.source);
    const wrapped_result = if (only_children)
        try self.processAllChildren(node, context, do_instruments)
    else
        try self.processNode(node, context, do_instruments);
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
            if (wrapped_result) |w_t|
                try self.print(
                    "{} {s}{x:8}={s};\n",
                    .{ w_t.type, templates.temp, temp_rand, wrapped_str },
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

    return wrapped_result;
}

/// Returns the result of the last child processed
fn processAllChildren(
    self: *@This(),
    node: NodeId,
    context: *TraverseContext,
    do_instruments: bool,
) FnErrorSet(@TypeOf(processNode))!?CompoundResult {
    std.debug.assert(self.parsed.tree.tag(node).isSyntax());
    const children = self.parsed.tree.children(node);
    var result: ?CompoundResult = null;
    for (children.start..children.end) |child| {
        result = try self.processNode(@intCast(child), context, do_instruments);
    }
    return result;
}

fn processInstrumentsImpl(
    self: *@This(),
    node: NodeId,
    result: ?CompoundResult,
    context: *TraverseContext,
    processed: *std.AutoHashMapUnmanaged(Instrument.ID, void),
    instruments: []const Instrument,
) !void {
    for (instruments) |instrument| {
        if (!processed.contains(instrument.id)) {
            _ = try processed.getOrPut(self.config.allocator, instrument.id);
            if (instrument.dependencies) |deps| {
                var deps_array = std.ArrayListUnmanaged(Processor.Instrument).empty;
                defer deps_array.deinit(self.config.allocator);

                for (deps) |dep| {
                    for (self.config.instruments_any) |dep_instr| {
                        if (dep_instr.id == dep) {
                            try deps_array.append(self.config.allocator, dep_instr);
                            break;
                        }
                    } else {
                        var it = self.config.instruments_scoped.iterator();
                        find_id: while (it.next()) |scoped_instrs| {
                            for (scoped_instrs.value.items) |dep_instr| {
                                if (dep_instr.id == dep) {
                                    try deps_array.append(self.config.allocator, dep_instr);
                                    break :find_id;
                                }
                            }
                        }
                    }
                }
                try self.processInstrumentsImpl(node, result, context, processed, deps_array.items);
            }
            if (instrument.instrument) |i| {
                const payload = if (result) |r| try r.toPayload(self.config.allocator) else null;
                defer if (payload) |p| {
                    self.config.allocator.free(std.mem.span(p.type.basic));
                    if (p.type.array) |a| self.config.allocator.free(std.mem.span(a));
                };

                i(self, node, if (payload) |*p| p else null, context) catch |err| {
                    try self.addDiagnostic(err, @src(), self.parsed.tree.nodeSpan(node), @errorReturnTrace());
                };
            }
        }
    }
}

/// This function should be called on every tree's node after the node's type has been resolved.
fn processInstruments(self: *@This(), node: NodeId, result: ?CompoundResult, context: *TraverseContext) !void {
    var processed = std.AutoHashMapUnmanaged(Instrument.ID, void).empty;
    defer processed.deinit(self.config.allocator);

    try self.processInstrumentsImpl(node, result, context, &processed, self.config.instruments_any);
    const tag = self.parsed.tree.tag(node);

    if (self.config.instruments_scoped.getPtr(tag)) |scoped| {
        for (scoped.items) |instrument| {
            if (!processed.contains(instrument.id)) {
                log.debug("Instrumenting {s} at {d} by {x}", .{ @tagName(tag), self.parsed.tree.nodeSpanExtreme(node, .start), instrument.id });
            }
        }
        try self.processInstrumentsImpl(node, result, context, &processed, scoped.items);
    }
}

const BlockOrStatement = union(enum) {
    pub const extractor = analyzer.syntax.UnionExtractorMixin(@This());
    pub const extract = extractor.extract;
    pub const getNode = extractor.getNode;
    pub const match = extractor.match;
    pub const tryExtract = extractor.extractor.tryExtract;

    statement: analyzer.syntax.Statement,
    block: analyzer.syntax.Block,
};

const DoLoop = analyzer.syntax.Extractor(.statement, struct {
    keyword_do: analyzer.syntax.Token(.keyword_do),
    block: BlockOrStatement,
    keyword_while: analyzer.syntax.Token(.keyword_while),
    condition_list: analyzer.syntax.ConditionList,
});

const ForLoop = analyzer.syntax.Extractor(.statement, struct {
    keyword_for: analyzer.syntax.Token(.keyword_for),
    condition_list: analyzer.syntax.ConditionList,
    block: BlockOrStatement,
});

const WhileLoop = analyzer.syntax.Extractor(.statement, struct {
    keyword_while: analyzer.syntax.Token(.keyword_while),
    condition_list: analyzer.syntax.ConditionList,
    block: BlockOrStatement,
});

/// Process a tree node recursively. Depth-first traversal.
/// Performs type resolution and optionally runs instrumentation.
/// Fills the context with variables and scopes.
///
/// Not running instrumentation can be useful if the node's type lies outside of the node itself (e.g. function return type).
/// The instruments can be then run separately by calling `processInstruments`.
fn processNode(self: *@This(), node: NodeId, context: *TraverseContext, do_instruments: bool) FnErrorSet(@TypeOf(resolveNode))!?CompoundResult {
    const result = try self.resolveNode(node, context, do_instruments);
    if (do_instruments)
        try self.processInstruments(node, result, context);
    return result;
}

/// Resolves the type of the given node and optionally runs instrumentation *only on *children** nodes.
/// Fills the context with variables and scopes.
fn resolveNode(self: *@This(), node: NodeId, context: *TraverseContext, do_instruments: bool) !?CompoundResult {
    const tree = self.parsed.tree;
    const source = self.config.source;
    return switch (tree.tag(node)) { // TODO serialize the recursive traversal
        .array, .parenthized => { // array indexing and parenthized expression has three children: open, value, close
            const children = tree.children(node);
            if (children.length() == 3) {
                _ = try self.processNode(children.start, context, do_instruments);
                // return the thing inside
                const result = try self.processNode(children.start + 1, context, do_instruments);
                _ = try self.processNode(children.start + 2, context, do_instruments);

                return result;
            } else return null;
        },
        .selection => {
            const selection = analyzer.syntax.Selection.tryExtract(tree, node) orelse return Error.InvalidTree;
            const target = try self.extractNodeForce(selection, .target);
            const field = try self.extractNodeTextForce(selection, .field);
            const result = if (try self.processNode(target, context, do_instruments)) |target_t|
                try context.scope.resolveSelection(target_t, field)
            else
                null;

            _ = try self.processNode(try self.extractNodeForce(selection, .@"."), context, do_instruments);
            return result;
        },
        .statement => {
            const previous = context.statement;
            // set the context.statement field
            var loop_block: ?struct {
                block: NodeId,
                nested: ?TraverseContext = null,
            } = blk: {
                if (ForLoop.tryExtract(tree, node)) |for_loop| if (self.extractNode(for_loop, .keyword_for)) |for_kw| {
                    _ = try self.processNode(for_kw, context, do_instruments);

                    var nested = try context.nested(self.config.allocator);

                    const cond: analyzer.syntax.ConditionList = self.extract(for_loop, .condition_list) orelse return Error.InvalidTree;
                    _ = try self.processNode(cond.node, &nested, do_instruments);

                    //TODO support breaking execution inside the loop header
                    break :blk if (self.extractNode(for_loop, .block)) |block| .{ .block = block, .nested = nested } else {
                        nested.nestedDeinit(self.config.allocator, context);
                        break :blk null;
                    };
                };

                if (WhileLoop.tryExtract(tree, node)) |while_loop| if (self.extractNode(while_loop, .keyword_while)) |while_kw| {
                    _ = try self.processNode(while_kw, context, do_instruments);
                    _ = try self.processNode(try self.extractNodeForce(while_loop, .condition_list), context, do_instruments);

                    break :blk if (self.extractNode(while_loop, .block)) |block| .{ .block = block } else null;
                };

                if (DoLoop.tryExtract(tree, node)) |do_loop| if (self.extractNode(do_loop, .keyword_do)) |do_kw| {
                    _ = try self.processNode(do_kw, context, do_instruments);
                    _ = try self.processNode(try self.extractNodeForce(do_loop, .keyword_while), context, do_instruments);
                    _ = try self.processNode(try self.extractNodeForce(do_loop, .condition_list), context, do_instruments);

                    break :blk if (self.extractNode(do_loop, .block)) |block| .{ .block = block } else null;
                };

                break :blk null;
            };

            const result = if (loop_block) |*b| blk: {
                const s = tree.nodeSpan(b.block);
                // wrap in parenthesis
                try self.insertStart("{", s.start);
                try self.insertEnd("}", s.end, 0);
                context.statement = s;
                defer if (b.nested) |*n| n.nestedDeinit(self.config.allocator, context);

                break :blk try self.processNode(b.block, if (b.nested) |*n| n else context, do_instruments);
            } else blk: {
                context.statement = tree.nodeSpan(node);
                break :blk try self.processAllChildren(node, context, do_instruments);
            };

            context.statement = previous; // Pop out from the statement context
            return result;
        },
        .struct_specifier => {
            const struct_spec = analyzer.syntax.StructSpecifier.tryExtract(tree, node) orelse return Error.InvalidTree;
            _ = try self.processNode(try self.extractNodeForce(struct_spec, .keyword_struct), context, do_instruments);
            const name = try self.extractNodeTextForce(struct_spec, .name);

            const new_type = try context.scope.getOrPutType(self.config.allocator, name);
            if (self.extract(struct_spec, .fields)) |f| {
                var it = f.get(tree).iterator();
                while (it.next(tree)) |field| {
                    const field_spec = try self.processNode(
                        try self.extractNodeForce(field, .specifier),
                        context,
                        do_instruments,
                    ) orelse //return Error.Resolution;
                        sema.Symbol.Content{ .type = .{ .basic = sema.types.float } };

                    const field_vars = self.extract(field, .variables) orelse return Error.InvalidTree;
                    var it2 = field_vars.iterator();
                    while (it2.next(tree)) |variable| {
                        const var_name = try self.extractNodeTextForce(variable, .name);
                        try new_type.put(self.config.allocator, var_name, field_spec.type);
                    }
                }
            }

            return CompoundResult{ .type = .{
                .basic = name,
            } };
        },
        // expression itself is not a tree node, so we must enumerate all the nodes that shoud be processed as "expressions"
        .argument, .expression_sequence, .initializer => try self.processExpression(node, context, do_instruments, true),

        .prefix => { // TODO propagate constants even if statically imperatively assigned in different statements
            const prefix = analyzer.syntax.PrefixExpression.tryExtract(tree, node) orelse return Error.InvalidTree;
            var t = try self.processNode(try self.extractNodeForce(prefix, .expression), context, do_instruments);
            const op = self.extract(prefix, .op) orelse return Error.InvalidTree;
            _ = try self.processNode(op.getNode(), context, do_instruments);

            if (t) |*ex| if (ex.constant) |cons| {
                ex.constant =
                    switch (op.inner) {
                        .@"+" => cons,
                        .@"-" => 0, // TODO now tracking only unsigned constants
                        .@"!" => if (cons == 0) 1 else 0,
                        .@"~" => ~cons,
                        .@"++" => cons + 1,
                        .@"--" => cons - 1,
                    };
            };

            return t;
        },
        .call => {
            const call = analyzer.syntax.Call.tryExtract(tree, node) orelse return Error.InvalidTree;

            const arguments = call.get(.arguments, tree);

            var first_arg: ?sema.Symbol.Content = null;
            var argument_types = std.ArrayListUnmanaged(sema.Symbol.Type).empty;
            defer argument_types.deinit(self.config.allocator);

            if (arguments) |args| {
                var it = args.iterator();
                var i: usize = 0;
                try argument_types.ensureTotalCapacity(self.config.allocator, args.items.length());
                while (it.next(tree)) |arg| : (i += 1) {
                    const arg_result = try self.processNode(arg.node, context, do_instruments) orelse //return Error.Resolution;
                        sema.Symbol.Content{ .type = .{ .basic = sema.types.float } }; // fall back to float
                    if (i == 0) {
                        first_arg = arg_result;
                    }
                    argument_types.appendAssumeCapacity(arg_result.type);
                }

                _ = try self.processInstruments(args.node, null, context);
            }

            if (call.get(.identifier, tree)) |identifier| {
                const name = identifier.text(source, tree);

                return try context.scope.resolveFunction(
                    self.config.allocator,
                    .{ .name = name, .parameters = argument_types.items },
                    &self.config.spec,
                    first_arg,
                );
            } else
            // the call does not have a simple identifier, so it is probably an array.length() call
            // so fall back to uint
            return sema.Symbol.Content{ .type = .{ .basic = sema.types.uint } };
        },
        .block => { // every code block (including function body) is a scope different than its parent (parameters are also different scope)
            var nested = try context.nested(self.config.allocator);
            defer nested.nestedDeinit(self.config.allocator, context);
            _ = try self.processAllChildren(node, &nested, do_instruments);

            return null;
        },
        .function_declaration => { // when entering a function scope
            const fn_extract = try extractFunction(tree, node, source);
            var fn_context = try context.inFunction(fn_extract, tree, self.config.allocator);
            defer fn_context.functionDeinit(self.config.allocator, context);

            _ = try self.processAllChildren(node, &fn_context, do_instruments);
            return null;
        },
        .parameter => {
            if (analyzer.syntax.Parameter.tryExtract(tree, node)) |par| {
                // Qualifier
                if (self.extractNode(par, .qualifiers)) |q| _ = try self.processNode(q, context, do_instruments);
                // Type specifier
                const t = try self.processNode(try self.extractNodeForce(par, .specifier), context, do_instruments) orelse //return Error.Resolution;
                    sema.Symbol.Content{ .type = .{ .basic = sema.types.float } };

                // Variable name
                if (self.extractNode(par, .variable)) |var_node| {
                    const var_node_text = tree.nodeSpan(var_node).text(source);
                    _ = try self.resolveNode(var_node, context, false);
                    try context.scope.fillVariable(self.config.allocator, var_node_text, t);
                    if (do_instruments)
                        try self.processInstruments(var_node, t, context);
                }
                if (do_instruments)
                    try self.processInstruments(par.node, t, context);

                // Comma
                if (self.extractNode(par, .comma)) |c|
                    _ = try self.processNode(c, context, do_instruments);

                return t;
            } else return Error.InvalidTree;
        },
        .array_specifier => if (analyzer.syntax.ArraySpecifier(analyzer.syntax.Selectable).tryExtract(tree, node)) |array| {
            var result = try self.processNode(array.prefix(tree).?.node, context, do_instruments);
            // process the rest of the array specifier
            var it = array.iterator();
            var i: usize = 0;
            while (it.next(tree)) |a| : (i += 1) {
                const indexer = try self.processNode(a.node, context, do_instruments);
                if (result) |*r| {
                    if (r.type == .array) {
                        r.type.array.dim[i] = if (indexer) |ii| ii.constant orelse 0 else 0;
                    } else {
                        r.type = .{ .array = .{
                            .dim = try self.config.allocator.alloc(usize, array.items.length()),
                            .base = r.type.basic,
                        } };

                        r.type.array.dim[0] = if (indexer) |ii| ii.constant orelse 0 else 0;
                    }
                }
            }

            return result;
        } else return Error.InvalidTree,

        .conditional => {
            const cond = analyzer.syntax.ConditionalExpression.tryExtract(tree, node) orelse return Error.InvalidTree;
            const cond_result = try self.processNode(try self.extractNodeForce(cond, .condition), context, do_instruments);

            _ = try self.processNode(try self.extractNodeForce(cond, .@"?"), context, do_instruments);

            const true_result = try self.processNode(try self.extractNodeForce(cond, .true_expr), context, do_instruments);
            _ = try self.processNode(try self.extractNodeForce(cond, .@":"), context, do_instruments);
            const false_result = try self.processNode(try self.extractNodeForce(cond, .false_expr), context, do_instruments);

            return if (cond_result) |c| if (c.constant) |con|
                if (con != 0) true_result else false_result
            else
                null else null;
        },
        .identifier => // NOT processed when inside selection (see .selection prong)
        try context.scope.resolveVariable(self.config.allocator, tree.token(node).text(source), &self.config.spec) orelse
            try context.scope.resolveType(self.config.allocator, tree.token(node).text(source), &self.config.spec),
        .infix => {
            const infix = analyzer.syntax.InfixExpression.tryExtract(tree, node) orelse return Error.InvalidTree;
            const result = if (infix.get(.op, tree)) |op| if (infix.get(.left, tree)) |left|
                if (try self.processExpression(left.node, context, do_instruments, false)) |left_result|
                    sema.resolveInfix(op.inner, left_result, if (infix.get(.right, tree)) |right|
                        try self.processExpression(right.node, context, do_instruments, false)
                    else
                        null)
                else
                    null
            else
                null else null;

            return result;
        },
        .postfix => {
            const postfix = analyzer.syntax.PostfixExpression.tryExtract(tree, node) orelse return Error.InvalidTree;
            const result = if (postfix.get(.expression, tree)) |ex| try self.processExpression(ex.node, context, do_instruments, false) else null;
            // ignore the operator and return the previous value
            _ = try self.processNode(try self.extractNodeForce(postfix, .op), context, do_instruments);

            return result;
        },
        .number => sema.resolveNumber(tree.token(node).text(source)),
        .declaration => { // TODO can be inside struct
            const declaration = analyzer.syntax.Declaration.tryExtract(tree, node) orelse return Error.InvalidTree;

            const previous = context.statement;
            context.statement = tree.nodeSpan(node);
            defer context.statement = previous;

            // Qualifier
            if (self.extractNode(declaration, .qualifiers)) |qualifiers|
                _ = try self.processNode(qualifiers, context, do_instruments);
            // Type specifier
            var t = try self.processNode(
                try self.extractNodeForce(declaration, .specifier),
                context,
                do_instruments,
            ) orelse //return Error.Resolution;
                sema.Symbol.Content{
                    .type = .{ .basic = sema.types.float },
                };

            // Variables
            if (self.extract(declaration, .variables)) |variables| {
                var it: analyzer.syntax.Variables.Iterator = variables.iterator();
                while (it.next(tree)) |variable| {
                    const var_node = variable.node;
                    const var_node_text = tree.nodeSpan(var_node).text(source);
                    if (try self.resolveNode(var_node, context, false)) |var_result| {
                        if (var_result.constant) |cons| {
                            t.constant = cons;
                        }
                    }

                    try context.scope.fillVariable(self.config.allocator, var_node_text, t);
                    if (do_instruments)
                        try self.processInstruments(var_node, t, context);
                }
                if (do_instruments)
                    try self.processInstruments(variables.getNode(), t, context);
            }

            if (self.extractNode(declaration, .semi)) |semi| {
                _ = try self.processNode(semi, context, do_instruments);
            }
            return t;
        },
        else => |tag| if (tag.isSyntax()) try self.processAllChildren(node, context, do_instruments) else null,
        // .arguments_list => processed inside .call
        // .variable_declaration, .variable_declaration_list => returns constant or just process all children
    };
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
        try self.addDiagnostic(
            try self.print("Instrumentation was requested but no inserts were generated for stage {s}", .{@tagName(self.config.shader_stage)}),
            null,
            null,
            null,
        );
        return Result{ .length = 0, .source = null, .spirv = null };
    };
    try parts.append(self.config.allocator, 0); // null-terminate the string

    const len = parts.items.len;
    return Result{
        .length = len,
        .source = @ptrCast((try parts.toOwnedSlice(self.config.allocator)).ptr),
        .spirv = null,
    };
}

/// NOTE: When an error union is passed as `value`, the diagnostic is added only if the error has occured (so if you want to include it forcibly,
/// try or catch it before calling this function)
fn addDiagnostic(
    self: *@This(),
    value: anytype,
    source: ?std.builtin.SourceLocation,
    span: ?analyzer.parse.Span,
    trace: ?*std.builtin.StackTrace,
) std.mem.Allocator.Error!switch (@typeInfo(@TypeOf(value))) {
    .error_union => |err_un| ?err_un.payload,
    else => void,
} {
    const info = @typeInfo(@TypeOf(value));
    const err_name_or_val = switch (info) {
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
    try self.config.stage.diagnostics.append(self.config.allocator, .{
        .d = analyzer.parse.Diagnostic{
            .message = err_name_or_val,
            .span = span orelse .{ .start = 0, .end = 0 },
        },
        .free = switch (info) {
            .pointer => |p| p.size == .slice,
            else => false,
        },
    });

    switch (info) {
        .error_union => |err_un| if (err_un.payload != void) return value catch null,
        else => {},
    }
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

    /// SAFETY: assigned in init()
    node_pool: std.heap.MemoryPool(Treap.Node) = undefined,
    /// SAFETY: assigned in init()
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
        var entry = self.inserts.getEntryFor(Insert{
            .offset = offset,
            .consume_next = consume_next,
            .inserts = std.DoublyLinkedList(TaggedString){},
        });
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
                                log.debug(
                                    "Nexter at {d}, cons {d}: {s}",
                                    .{ nexter.key.offset, nexter.key.consume_next, nexter.key.inserts.first.?.data.string },
                                );
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
                const from = previous.?.key.offset + previous.?.key.consume_next - offset;
                if (from < source.len) {
                    try parts.appendSlice(allocator, source[from..]);
                }
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
    /// Output channels are meant to be read back for use by the instrument clients each time the shader is executed. Set this flag to true to disable
    /// the automatic readback.
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
                        return OutputStorage{
                            .location = .{ .interface = .{
                                .location = another_stor.interface.location,
                                .component = component.?,
                                .format = format,
                            } },
                        };
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

    pub const ID = u64;

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

        pub const Format = enum {
            @"4U8",
            @"4F8",
            @"4I8",
            @"4U16",
            @"4I16",
            @"4F16",
            @"4U32",
            @"4I32",
            @"4F32",
            @"3U8",
            @"3F8",
            @"3I8",
            @"3U16",
            @"3I16",
            @"3F16",
            @"3U32",
            @"3I32",
            @"3F32",
            @"2U8",
            @"2F8",
            @"2I8",
            @"2U16",
            @"2I16",
            @"2F16",
            @"2U32",
            @"2I32",
            @"2F32",
            @"1U8",
            @"1F8",
            @"1I8",
            @"1U16",
            @"1I16",
            @"1F16",
            @"1U32",
            @"1I32",
            @"1F32",

            /// Converts this GLSL format base type to Zig data type
            pub fn toBaseType(comptime self: @This()) type {
                return switch (self) {
                    .@"1U8", .@"2U8", .@"3U8", .@"4U8" => u8,
                    .@"1I8", .@"2I8", .@"3I8", .@"4I8" => i8,
                    .@"1U16", .@"2U16", .@"3U16", .@"4U16" => u16,
                    .@"1I16", .@"2I16", .@"3I16", .@"4I16" => i16,
                    .@"1F16", .@"2F16", .@"3F16", .@"4F16" => f16,
                    .@"1U32", .@"2U32", .@"3U32", .@"4U32" => u32,
                    .@"1I32", .@"2I32", .@"3I32", .@"4I32" => i32,
                    .@"1F32", .@"2F32", .@"3F32", .@"4F32" => f32,
                };
            }

            /// Converts this GLSL format to Zig data type (vectors are interpreted as arrays)
            pub fn toType(comptime self: @This()) type {
                return switch (self) {
                    .@"1U8", .@"1I8", .@"1F8", .@"1U16", .@"1I16", .@"1F16", .@"1U32", .@"1I32", .@"1F32" => self.toBaseType(),
                    .@"2U8", .@"2I8", .@"2F8", .@"2U16", .@"2I16", .@"2F16", .@"2U32", .@"2I32", .@"2F32" => [2]self.toBaseType(),
                    .@"3U8", .@"3I8", .@"3F8", .@"3U16", .@"3I16", .@"3F16", .@"3U32", .@"3I32", .@"3F32" => [3]self.toBaseType(),
                    .@"4U8", .@"4I8", .@"4F8", .@"4U16", .@"4I16", .@"4F16", .@"4U32", .@"4I32", .@"4F32" => [4]self.toBaseType(),
                };
            }

            /// Returns the raw size of this format data type in bytes
            pub fn sizeInBytes(comptime self: @This()) comptime_int {
                return switch (self) {
                    .@"1U8", .@"1I8", .@"1F8" => 1,
                    .@"2U8", .@"2I8", .@"2F8" => 2,
                    .@"3U8", .@"3I8", .@"3F8" => 3,
                    .@"4U8", .@"4I8", .@"4F8" => 4,
                    .@"1U16", .@"1I16", .@"1F16" => 2,
                    .@"2U16", .@"2I16", .@"2F16" => 4,
                    .@"3U16", .@"3I16", .@"3F16" => 6,
                    .@"4U16", .@"4I16", .@"4F16" => 8,
                    .@"1U32", .@"1I32", .@"1F32" => 4,
                    .@"2U32", .@"2I32", .@"2F32" => 8,
                    .@"3U32", .@"3I32", .@"3F32" => 12,
                    .@"4U32", .@"4I32", .@"4F32" => 16,
                };
            }
        };
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
