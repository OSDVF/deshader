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

//! # Deshader Instrumentation
//! The instrumentation process consists of several intercomunicting "layers":
//!
//! - Shader Processor (this file)
//! - Runtime Frontend (`shaders`)
//! - Runtime Backend ([`interceptors.gl_shaders`](../interceptors/gl_shaders.zig))

const std = @import("std");
const analyzer = @import("glsl_analyzer");
const log = @import("common").log;
const decls = @import("../declarations/shaders.zig");
const shaders = @import("shaders.zig");

const String = []const u8;
const CString = [*:0]const u8;
const ZString = [:0]const u8;

pub const Error = error{ InvalidStep, InvalidTree, OutOfStorage };
pub const ParseInfo = struct {
    arena_state: std.heap.ArenaAllocator.State,
    tree: analyzer.parse.Tree,
    ignored: []const analyzer.parse.Token,
    diagnostics: []const analyzer.parse.Diagnostic,

    /// sorted ascending by position in the code
    calls: std.StringHashMap(std.ArrayList(u32)),
    version: u16,
    version_span: analyzer.parse.Span,
    step_identifier: String = "_step_",

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

        var calls = std.StringHashMap(std.ArrayList(u32)).init(arena.allocator());
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
        var version_span = analyzer.parse.Span{ .start = 0, .end = 0 };

        for (ignored.items) |token| {
            const line = text[token.start..token.end];
            switch (analyzer.parse.parsePreprocessorDirective(line) orelse continue) {
                .extension => |extension| {
                    const name = extension.name;
                    try extensions.append(line[name.start..name.end]);
                },
                .version => |version_token| {
                    version = try std.fmt.parseInt(u16, line[version_token.number.start..version_token.number.end], 10);
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
            .version_span = version_span,
        };
    }
};

pub const Result = struct {
    /// The new source code with the inserted instrumentation or null if no changes were made by the instrumentation
    source: ?CString,
    length: usize,
    outputs: Outputs,
    spirv: ?String,

    /// Actually it can be modified by the platform specific code (e.g. to set the selected thread location)
    pub const Outputs = struct {
        /// Can only be a SSBO
        log_storage: ?OutputStorage = null,
        /// Contains `uvec2` - the reached step ID and offset.
        step_storage: ?OutputStorage = null,
        stack_trace: ?OutputStorage = null,
        variables_storage: ?OutputStorage = null,
        another_variables_storage: ?OutputStorage = null,
        /// Each group has the dimensions of `group_dim`
        group_dim: []usize = undefined,
        /// Number of groups in each grid dimension
        group_count: ?[]usize = null,
        /// Will be assigned from Processor input parameters.
        /// maps part -> offset in stops array
        parts_offsets: ?[]const usize = null,

        desired_bp_ident: ZString = undefined,
        desired_step_ident: ZString = undefined,
        thread_selector_ident: ZString = undefined,

        /// Required size of variables storage per thread (in bytes)
        required_variables_size: usize = 0,

        variables: ?[]VariableInstrumentation = null,
        diagnostics: std.ArrayListUnmanaged(analyzer.parse.Diagnostic) = .{},

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (self.variables) |vars| {
                for (vars) |*v| {
                    v.deinit(allocator);
                }
                allocator.free(vars);
            }
            for (self.diagnostics.items) |d| {
                allocator.free(d.message);
            }
            self.diagnostics.deinit(allocator);
            if (self.step_storage) |*bp| {
                bp.deinit(allocator);
            }
            allocator.free(self.group_dim);
            if (self.parts_offsets) |po| {
                allocator.free(po);
            }
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

        /// Computes the part index and an offset into its `steps` array from the global step index returned by instrumented shader invocation.
        pub fn localStepOffset(self: @This(), global_step: usize) struct { part: usize, offset: ?usize } {
            var reached_part: usize = 0;
            const local_offset = if (self.parts_offsets) |pos| for (pos, 0..) |offset, part_index| {
                if (global_step <= offset) {
                    reached_part = part_index;
                    break offset;
                }
            } else 0 else null;

            return .{ .part = reached_part, .offset = local_offset };
        }
    };

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.source) |s| {
            allocator.free(s[0 .. self.length - 1 :0]);
        }
        self.outputs.deinit(allocator);
    }

    /// Frees the source buffer and returns the Output object
    pub fn toOwnedOutputs(self: *@This(), allocator: std.mem.Allocator) Outputs {
        if (self.source) |s| {
            allocator.free(s[0 .. self.length - 1 :0]); // Include the null-terminator (asserting :0 adds one to the length)
        }
        return self.outputs;
    }
};

pub const Processor = struct {
    pub const Config = struct {
        pub const Support = struct {
            buffers: bool,
            max_variables_size: usize,
            /// Supports #include directives (ARB_shading_language_include, GOOGL_include_directive)
            include: bool,
            /// Not really a support flag, but an option for the preprocessor to not include any source file multiple times.
            all_once: bool,
        };

        allocator: std.mem.Allocator,
        breakpoints: std.AutoHashMapUnmanaged(usize, void),
        support: Support,
        group_dim: []const usize,
        groups_count: ?[]const usize,
        max_buffers: usize,
        max_interface: usize,
        parts: std.ArrayListUnmanaged(*shaders.Shader.SourcePart),
        part_stops: []const usize,
        shader_stage: decls.Stage,
        single_thread_mode: bool,
        stepping: bool,
        used_buffers: *std.ArrayList(usize),
        used_interface: *std.ArrayList(usize),
        uniform_locations: *std.ArrayListUnmanaged(String),
        uniform_names: *std.StringHashMapUnmanaged(usize), //inverse to uniform_locations
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
    last_interface_decl: usize = 0,
    last_interface_node: u32 = 0,
    last_interface_location: usize = 0,
    uses_dual_source_blend: bool = false,
    vulkan: bool = false,
    glsl_version: u16 = 140, // 4.60 -> 460
    rand: std.rand.DefaultPrng = undefined,
    guarded: std.AutoHashMapUnmanaged(u32, void) = .{},

    /// Maps offsets in file to the inserted instrumented code fragments (sorted)
    /// Both the key and the value are stored as Treap's Key (a bit confusing)
    inserts: Inserts = .{}, // Will be inserted many times but iterated only once at applyTo
    outputs: Result.Outputs = .{},
    node_pool: std.heap.MemoryPool(Inserts.Node) = undefined,
    lnode_pool: std.heap.MemoryPool(std.DoublyLinkedList(String).Node) = undefined,

    pub const prefix = "deshader_";
    const step_counter = prefix ++ "step_counter";

    const global_thread_id = prefix ++ "global_id";
    const temp_thread_id = prefix ++ "threads";

    const was_hit = prefix ++ "was_hit";
    const wg_size = prefix ++ "workgroup_size";
    const cursor = "cursor";

    /// These are not meant to be used externally because they will be postfixed with a random number or stage name
    pub const templates = struct {
        const hit_storage = prefix ++ "global_hit_id";
        const log_storage = prefix ++ "log";
        const stack_trace_storage = prefix ++ "stack_trace";
        /// Watches, locals, scopes
        const variables_storage = prefix ++ "variables";
        const temp = prefix ++ "temp";

        // selectors
        const desired_bp = prefix ++ "desired_bp";
        const desired_step = prefix ++ "desired_step";
        const threads_selector = prefix ++ "selected_thread";
    };

    const echo_diagnostics = false;

    pub fn deinit(self: *@This()) void {
        _ = self.toOwnedOutputs();
        self.outputs.deinit(self.config.allocator);
    }

    pub fn toOwnedOutputs(self: *@This()) Result.Outputs {
        self.config.allocator.free(self.threads);
        self.config.parts.deinit(self.config.allocator);

        // deinit contents
        var it = self.inserts.inorderIterator();
        while (it.current) |node| : (_ = it.next()) {
            while (node.key.inserts.pop()) |item| {
                self.config.allocator.free(item.data);
            }
        }

        // deinit the wrapping nodes
        self.node_pool.deinit();
        self.lnode_pool.deinit();

        if (self.outputs.step_storage) |s| {
            self.config.allocator.free(s._name);
        }
        if (self.outputs.log_storage) |s| {
            self.config.allocator.free(s._name);
        }
        if (self.outputs.stack_trace) |s| {
            self.config.allocator.free(s._name);
        }
        if (self.outputs.variables_storage) |s| {
            self.config.allocator.free(s._name);
        }
        if (self.outputs.another_variables_storage) |s| {
            self.config.allocator.free(s._name);
        }

        self.guarded.deinit(self.config.allocator);
        return self.outputs;
    }

    const Func = struct {
        name: String,
        return_type: String,
    };
    fn getFunc(tree: analyzer.parse.Tree, node: u32, source: String) !Func {
        const func = analyzer.syntax.FunctionDeclaration.tryExtract(tree, node) orelse return Error.InvalidTree;
        const name_token = func.get(.identifier, tree) orelse return Error.InvalidTree;
        const return_type_token = func.get(.specifier, tree) orelse return Error.InvalidTree;
        const return_type_span = tree.nodeSpan(return_type_token.getNode());
        return .{ .name = name_token.text(source, tree), .return_type = source[return_type_span.start..return_type_span.end] };
    }

    /// Should be run on semi-initialized `Output` (only fields with no default values need to be initialized)
    pub fn setup(self: *@This(), source: String) !void {
        // TODO explicit uniform locations
        // TODO place outputs with explicit locations at correct place
        self.rand = std.rand.DefaultPrng.init(@intCast(std.time.timestamp()));
        self.node_pool = std.heap.MemoryPool(Inserts.Node).init(self.config.allocator);
        self.lnode_pool = std.heap.MemoryPool(std.DoublyLinkedList(String).Node).init(self.config.allocator);
        self.outputs.group_dim = try self.config.allocator.dupe(usize, self.config.group_dim);
        self.outputs.group_count = if (self.config.groups_count) |g| try self.config.allocator.dupe(usize, g) else null;
        self.outputs.parts_offsets = self.config.part_stops;

        var stops = std.ArrayListUnmanaged(std.ArrayListUnmanaged(analyzer.lsp.Position)){};
        defer {
            for (stops.items) |*s| {
                s.deinit(self.config.allocator);
            }
            stops.deinit(self.config.allocator);
        }

        var tree_info: ParseInfo = try ParseInfo.parseSource(self.config.allocator, source);
        defer tree_info.deinit(self.config.allocator);
        const tree = tree_info.tree;
        // Store GLSL version
        self.glsl_version = tree_info.version;
        if (self.glsl_version < 400) {
            self.config.support.buffers = false; // the extension is not supported in older GLSL
        }
        self.after_version = tree_info.version_span.end + 1; // assume there is a line break
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

        // Scan through the tree to find some top-level characteristics
        var func_decls = std.StringHashMapUnmanaged(analyzer.syntax.FunctionDeclaration){};
        defer func_decls.deinit(self.config.allocator);
        // Iterate through top-level declarations
        var node: u32 = 0;
        while (node < tree.nodes.len) : (node = tree.children(node).end) {
            const tag = tree.tag(node);
            switch (tag) {
                .function_declaration => {
                    if (analyzer.syntax.FunctionDeclaration.tryExtract(tree, node)) |decl| {
                        try func_decls.put(self.config.allocator, decl.get(.identifier, tree).?.text(source, tree), decl);
                    } else log.warn("Could not extract function declaration at node {d}", .{node});
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
                            self.last_interface_location = location orelse (self.last_interface_location + 1); // TODO implicit locations až se vzbudíš
                        }
                    }
                },
                else => {},
            }
        }

        //log.debug("{}", .{tree.format(source)});

        var hit_indicator_initialized = false;
        // Process step markers
        if (tree_info.calls.get(tree_info.step_identifier)) |found_steps| {
            each_step: for (found_steps.items) |step_node_id| {
                // _step_(id, wrapped_code)
                const step_call = analyzer.syntax.Call.tryExtract(tree, step_node_id) orelse {
                    log.err("Could not extract step 'call' at node {d}", .{step_node_id});
                    return Error.InvalidTree;
                };
                const step_args: analyzer.syntax.ArgumentsList = step_call.get(.arguments, tree) orelse return Error.InvalidStep;
                var args_it = step_args.iterator();
                const step_arg: analyzer.syntax.Argument = args_it.next(tree) orelse return Error.InvalidStep;
                const step_arg_expr: analyzer.syntax.Expression = step_arg.get(.expression, tree) orelse return Error.InvalidStep;
                // step hit records are 1-based, 0 is reserved for no hit
                const step_id = try std.fmt.parseInt(usize, tree.nodeSpan(step_arg_expr.node).text(source), 0);

                const wrapped_arg: ?analyzer.syntax.Argument = args_it.next(tree);
                const wrapped_expr: ?analyzer.syntax.Expression = if (wrapped_arg) |a| a.get(.expression, tree) else null;
                var wrapped_type: ?String = null;
                var wrapped_argument_node: ?u32 = null;

                const step_span = tree.nodeSpan(step_node_id);
                const step_span_len = step_span.length();
                // the inner-most statement
                var statement_span: ?analyzer.parse.Span = null;

                // first statement in the current block
                var first_innermost_statement: ?analyzer.parse.Span = null;
                var first_outermost_statement: ?analyzer.parse.Span = null;

                try self.ensureStorageInit();

                // walk the tree up to determine the context type (inside a function, condition, block)
                var parent = tree.parent(step_node_id);
                while (parent) |current| : (parent = tree.parent(current)) {
                    const current_tag = tree.tag(current);
                    log.debug("SP in {s}", .{@tagName(current_tag)});
                    switch (current_tag) {
                        .function_declaration => {
                            // assume context has been found in previous loop iterations
                            const func = try getFunc(tree, current, source);

                            const is_void = std.mem.eql(u8, func.return_type, "void");
                            const has_breakpoint = self.config.breakpoints.contains(step_id);

                            // Initialize hit indicator in the "step storage"
                            if (!hit_indicator_initialized and std.mem.eql(u8, func.name, "main")) {
                                try self.insertStart(try self.print("{s}{s}=0u;{s}{s}=0u;\n", .{
                                    self.outputs.step_storage.?._name,
                                    self.bufferIndexer("0"),
                                    self.outputs.step_storage.?._name,
                                    self.bufferIndexer("1"),
                                }), (first_outermost_statement orelse {
                                    log.err("Step point {d} was not inside a 'block' node", .{step_id});
                                    return Error.InvalidTree;
                                }).start);

                                hit_indicator_initialized = true;
                            }

                            // Emit step hit => write to the output debug bufffer and return
                            if (wrapped_expr) |wrapped| {
                                if (statement_span) |ss| {
                                    const wrapped_span = tree.nodeSpan(wrapped.node);
                                    const wrapped_str = wrapped_span.text(source);
                                    const temp_rand = self.rand.next();
                                    // insert the wrapped code before the original statement. Assign its result into a temporary var
                                    try self.insertEnd(
                                        if (wrapped_type) |w_t|
                                            try self.print(
                                                "{s} {s}{x}={s};",
                                                .{ w_t, templates.temp, temp_rand, wrapped_str },
                                            )
                                        else
                                            try self.print("{s};\n", .{wrapped_str}),
                                        ss.start,
                                        0,
                                    );
                                    if (has_breakpoint or self.config.stepping) {
                                        // the check'n'step/break logic precedes the original exception location
                                        try self.insertEnd(
                                            try self.advanceAndCheck(
                                                step_id,
                                                func,
                                                is_void,
                                                has_breakpoint,
                                                "{s};",
                                                .{wrapped_str},
                                            ),
                                            ss.start,
                                            0,
                                        );
                                    }
                                    // replace the _step_ call with the temp result variable
                                    try self.insertEnd(
                                        try self.print("{s}{x}", .{ templates.temp, temp_rand }),
                                        step_span.start,
                                        step_span_len,
                                    );
                                } else {
                                    log.err("Statement node for step point {d} not found in the tree", .{step_id});
                                    return Error.InvalidTree;
                                }
                            } else { // => no wrapped code
                                // simply insert the step's check'n'break
                                if (self.config.stepping or has_breakpoint) {
                                    try self.insertEnd(
                                        try self.advanceAndCheck(step_id, func, is_void, has_breakpoint, "", .{}),
                                        step_span.start,
                                        step_span_len,
                                    );
                                } else {
                                    // just remove the __step__() identifier
                                    try self.insertEnd(
                                        "",
                                        step_span.start,
                                        step_span_len,
                                    );
                                }
                            }

                            // break the execution after returning from a function if something was hit
                            if (try self.processFunctionCallsRec(source, tree_info, func) == 0) {
                                // this func not called
                                continue :each_step;
                            }

                            break; // break searching for the context type
                        },
                        .block => {
                            first_outermost_statement = tree.nodeSpan(tree.children(current).start + 1);
                            if (first_innermost_statement == null)
                                first_innermost_statement = first_outermost_statement;
                        },
                        .call => {
                            if (wrapped_type == null) {
                                const call = analyzer.syntax.Call.extract(tree, current, {});
                                const name: String = call.get(.identifier, tree).?.text(source, tree);
                                const list: analyzer.syntax.ArgumentsList = call.get(.arguments, tree) orelse continue; // no parameters for function
                                var it = list.iterator();
                                var i: usize = 0;
                                while (it.next(tree)) |arg| : (i += 1) {
                                    if (arg.node == wrapped_argument_node) {
                                        if (func_decls.get(name)) |func| {
                                            const parameters: analyzer.syntax.ParameterList = func.get(.parameters, tree) orelse return Error.InvalidTree;
                                            var j: usize = 0;
                                            var it2 = parameters.iterator();
                                            while (it2.next(tree)) |param| : (j += 1) {
                                                if (i == j) {
                                                    const specifier: analyzer.syntax.TypeSpecifier = param.get(.specifier, tree) orelse return Error.InvalidTree;
                                                    wrapped_type = (specifier.underlyingName(tree) orelse {
                                                        log.warn("Could not resolve parameter {d}'s type of a call to {s} at node {d}", .{ i, name, current });
                                                        continue :each_step;
                                                    }).text(source, tree);
                                                }
                                            }
                                        } else {
                                            log.warn("Could not resolve target of a call to '{s}' at node {d}", .{ name, current });
                                        }
                                    }
                                }
                            }
                        },
                        .condition_list => {
                            if (wrapped_type == null)
                                wrapped_type = "bool";
                        },
                        .argument => {
                            wrapped_argument_node = current;
                        },
                        .if_branch, .else_branch => {
                            if (statement_span == null) {
                                // if(a(ahoj) == 1) {
                                //
                                // } else if(a(ahoj) == 2) {
                                //  // we must wrap the elseif
                                // }

                                const cond = tree.nodeSpan(current);
                                const kw_end_pos: u32 = cond.start + @as(u32, if (current_tag == .if_branch) 2 else 4); // e l s e
                                try self.insertStart("{", kw_end_pos);
                                const close_pos = cond.end;
                                try self.insertEnd("}", close_pos, 0);
                                statement_span = .{
                                    .start = kw_end_pos,
                                    .end = close_pos,
                                };
                            }
                        },
                        .statement => {
                            if (statement_span == null) {
                                const children = tree.children(current);
                                switch (tree.tag(children.start)) {
                                    .keyword_for, .keyword_while, .keyword_do => {
                                        for (children.start + 1..children.end) |child| {
                                            if (tree.tag(child) == .block) {
                                                statement_span = tree.nodeSpan(@intCast(child));
                                                // wrap in parenthesis
                                                try self.insertStart("{", statement_span.?.start);
                                                try self.insertEnd("}", statement_span.?.end, 0);
                                            }
                                        }
                                    },
                                    else => statement_span = tree.nodeSpan(current),
                                }
                            }
                        },
                        .file => _ = try self.addDiagnostic(Error.InvalidStep, @src(), tree.nodeSpan(current)), // cannot break at the top level
                        else => {}, // continue upwards
                    }
                    // couldn't break at this, so we go further up
                }
            }
        }

        //const result = try self.config.allocator.alloc([]const analyzer.lsp.Position, stops.items.len);
        //for (result, stops.items) |*target, src| {
        //    target.* = try self.config.allocator.dupe(analyzer.lsp.Position, src.items);
        //}
        //self.outputs.steps = result;
    }

    /// Creates a buffer for outputting the index of breakpoint which each thread has hit
    /// For some shader stages, it also creates thread indexer variable `global_id`
    /// Inserts everything after #version directive
    fn ensureStorageInit(self: *@This()) !void {
        if (self.outputs.step_storage == null) { // existence of step storage as an indicator of initialization
            self.outputs.step_storage = try OutputStorage.nextAvailable(
                &self.config,
                true,
                "",
                null,
                null,
            ) orelse return Error.OutOfStorage;
            self.outputs.step_storage.?._name = switch (self.outputs.step_storage.?.location) {
                .Buffer => |_| try self.print(templates.hit_storage ++ "{s}", .{self.config.shader_stage.toString()}),
                .Interface => |i| if (self.glsl_version >= 130 or !self.config.shader_stage.isFragment()) //
                    try self.print(templates.hit_storage ++ "{s}", .{self.config.shader_stage.toString()}) // will be the step counter
                else
                    try self.print("gl_FragData[{d}]", .{i.location}),
            };

            if (self.config.support.buffers) {
                self.outputs.log_storage = try OutputStorage.nextAvailable(&self.config, true, try self.print(templates.log_storage ++ "{s}", .{self.config.shader_stage.toString()}), null, null);
            }

            self.outputs.stack_trace = try OutputStorage.nextAvailable(&self.config, true, try self.print(templates.stack_trace_storage ++ "{s}", .{self.config.shader_stage.toString()}), null, null);
            self.outputs.variables_storage = try OutputStorage.nextAvailable(
                &self.config,
                self.config.support.buffers,
                try self.print(templates.variables_storage ++ "{s}", .{self.config.shader_stage.toString()}),
                if (self.glsl_version >= 440 and self.config.shader_stage.isFragment()) self.outputs.step_storage.?.location else null,
                1,
            );
            if (self.outputs.variables_storage) |vs| {
                if (vs.location == .Interface and vs.location.Interface.component != 0) {
                    self.outputs.another_variables_storage = try OutputStorage.nextAvailable(
                        &self.config,
                        self.config.support.buffers,
                        try self.print(templates.variables_storage ++ "{s}", .{self.config.shader_stage.toString()}),
                        null,
                        null,
                    );
                }
            }

            self.outputs.desired_bp_ident = try self.printZ(templates.desired_bp ++ "{s}", .{self.config.shader_stage.toString()});
            self.outputs.desired_step_ident = try self.printZ(templates.desired_step ++ "{s}", .{self.config.shader_stage.toString()});
            self.outputs.thread_selector_ident = try self.printZ(templates.threads_selector ++ "{s}", .{self.config.shader_stage.toString()});
        }
    }

    fn insertStorageDeclarations(self: *@This()) !void {
        const step_storage = self.outputs.step_storage orelse return Error.OutOfStorage;
        if (self.outputs.stack_trace) |st| {
            try self.insertStart(try self.print(
                \\layout(binding={d}) restrict buffer DeshaderStackTrace{s} {{
                \\    uint {s}[];
                \\}};
            ++ "uint {s}" ++ cursor ++ "=0u;\n", .{
                st.location.Buffer,
                self.config.shader_stage.toString(),
                st._name,
                st._name,
            }), self.after_version);
        }

        if (self.outputs.variables_storage) |vs| {
            switch (vs.location) {
                .Buffer => |binding| {
                    try self.insertStart(
                        try self.print(
                            \\layout(binding={d}) restrict buffer DeshaderVariables{s} {{
                        ++ "uint {s}[];\n" ++ //
                            \\}};
                        , .{
                            binding,
                            self.config.shader_stage.toString(),
                            vs._name,
                        }),
                        self.after_version,
                    );
                },
                .Interface => |location| {
                    if (self.config.shader_stage.isFragment()) {
                        if (self.glsl_version >= 130) {
                            try self.insertStart(try if (location.component != 0)
                                self.print(
                                    \\layout(location={d},component={d}) out uvec{d} {s}0;
                                , .{ location.location, location.component, 4 - location.component, vs._name })
                            else
                                self.print("layout(location={d}) out uvec4 {s};\n", .{ location.location, vs._name }), self.last_interface_decl);
                        } // else gl_FragData is implicit
                    } else {
                        try self.insertStart(try self.print("layout(location={d}) out uvec4 {s};\n", .{ location.location, vs._name }), self.last_interface_decl);
                    }
                },
            }

            try self.insertStart(try self.print("uint {s}" ++ cursor ++ "=0u;\n", .{vs._name}), self.after_version);
        }
        if (self.outputs.another_variables_storage) |as| {
            switch (as.location) {
                .Interface => |interface| {
                    try self.insertStart(try self.print("layout(location={d}) out uvec4 {s}1;", .{ interface.location, as._name }), self.last_interface_decl);
                },
                .Buffer => |binding| {
                    try self.insertStart(try self.print(
                        \\layout(binding={d}) restrict buffer DeshaderVariables{s} {{
                    ++ "uint {s}1[];\n" ++ //
                        \\}};
                    , .{
                        binding,
                        self.config.shader_stage.toString(),
                        as._name,
                    }), self.after_version);
                },
            }
        }

        if (self.outputs.log_storage) |ls| {
            try self.insertStart(try self.print(
                \\layout(binding={d}) restrict buffer DeshaderLog{s} {{
            ++ "uint {s}" ++ cursor ++ ";\n" //
            ++ "uint {s}[];\n" ++ //
                \\}};
            , .{
                ls.location.Buffer,
                self.config.shader_stage.toString(),
                ls._name,
                ls._name,
            }), self.after_version);
        }

        switch (step_storage.location) {
            // -- Beware of spaces --
            .Buffer => |binding| {
                // Initialize the global thread id
                switch (self.config.shader_stage) {
                    .gl_fragment, .vk_fragment => {
                        try self.insertStart(try self.print(
                            "const uvec2 " ++ temp_thread_id ++ "= uvec2({d}, {d});\n" ++
                                "uint " ++ global_thread_id ++ " = uint(gl_FragCoord.y) * " ++ temp_thread_id ++ ".x + uint(gl_FragCoord.x);\n",
                            .{ self.threads[0], self.threads[1] },
                        ), self.after_version);
                    },
                    .gl_geometry => {
                        try self.insertStart(try self.print(
                            "const uint " ++ temp_thread_id ++ "= {d};\n" ++
                                "uint " ++ global_thread_id ++ "= gl_PrimitiveIDIn * " ++ temp_thread_id ++ " + gl_InvocationID;\n",
                            .{self.threads[0]},
                        ), self.after_version);
                    },
                    .gl_tess_evaluation => {
                        try self.insertStart(try self.print(
                            "ivec2 " ++ temp_thread_id ++ "= ivec2(gl_TessCoord.xy * float({d}-1) + 0.5);\n" ++
                                "uint " ++ global_thread_id ++ " =" ++ temp_thread_id ++ ".y * {d} + " ++ temp_thread_id ++ ".x;\n",
                            .{ self.threads[0], self.threads[0] },
                        ), self.after_version);
                    },
                    .gl_mesh, .gl_task, .gl_compute => {
                        try self.insertStart(try self.print("uint " ++ global_thread_id ++
                            "= gl_GlobalInvocationID.z * gl_NumWorkGroups.x * gl_NumWorkGroups.y * " ++ wg_size ++ " + gl_GlobalInvocationID.y * gl_NumWorkGroups.x * " ++ wg_size ++ " + gl_GlobalInvocationID.x);\n", .{}), self.after_version);
                        if (self.glsl_version < 430) {
                            try self.insertStart(try self.print("const uvec3 " ++ wg_size ++ "= uvec3({d},{d},{d});\n", .{ self.config.group_dim[0], self.config.group_dim[1], self.config.group_dim[2] }), self.after_version);
                        } else {
                            try self.insertStart(try self.config.allocator.dupe(u8, "uvec3 " ++ wg_size ++ "= gl_WorkGroupSize;\n"), self.after_version);
                        }
                    },
                    else => {},
                }

                // Declare the global hit storage
                try self.insertStart(try self.print(
                    \\layout(std{d}, binding={d}) restrict writeonly buffer Deshader{s} {{
                ++ "uvec4 " ++ templates.hit_storage ++ "{s}[{d}];" ++
                    \\}};
                    \\
                ++ "uint " ++ step_counter ++ "=0u;\n" //
                ++ "bool " ++ was_hit ++ "=false;\n", .{
                    @as(u16, if (self.glsl_version >= 430) 430 else 140),
                    binding,
                    self.config.shader_stage.toString(),
                    self.config.shader_stage.toString(),
                    self.threads_total / 2,
                }), self.after_version);
            },
            .Interface => |location| {
                try self.insertStart(try self.config.allocator.dupe(u8, //
                    "uint " ++ step_counter ++ "=0u;\n" //
                ++ "bool " ++ was_hit ++ "=false;\n"), self.after_version);

                if (self.glsl_version >= 130 or !self.config.shader_stage.isFragment()) {
                    try self.insertStart(
                        try if (self.glsl_version >= 440) //TODO or check for ARB_enhanced_layouts support
                            self.print(
                                \\layout(location={d},component={d}) out
                            ++ " uvec2 {s};\n" //
                            , .{ location.location, location.component, step_storage._name })
                        else
                            self.print(
                                \\layout(location={d}) out
                            ++ " uvec2 {s};\n" //
                            , .{ location.location, step_storage._name }),
                        self.last_interface_decl,
                    );
                }
                // else gl_FragData is implicit
            },
        }

        // step and bp selector uniforms
        try self.insertEnd(try self.print("uniform uint {s};\n", .{self.outputs.desired_step_ident}), self.after_version, 0);
        try self.insertEnd(try self.print("uniform uint {s};\n", .{self.outputs.desired_bp_ident}), self.after_version, 0);
        try self.insertEnd(try self.print("uniform uint {s};\n", .{self.outputs.thread_selector_ident}), self.after_version, 0);

        if (self.config.support.buffers and self.glsl_version >= 400) {
            try self.insertStart(try self.config.allocator.dupe(u8, " #extension GL_ARB_shader_storage_buffer_object : require\n"), self.after_version);
        }
    }

    /// Index into the global hit indication storage for the current thread
    fn bufferIndexer(self: *const @This(), comptime component: String) String {
        return if (self.outputs.step_storage.?.location == .Buffer) switch (self.config.shader_stage) {
            .gl_vertex => if (self.vulkan) "[gl_VertexIndex/2][(gl_VertexIndex%2)*2+" ++ component ++ "]" else "[gl_VertexID/2][(gl_VertexID%2)*2+" ++ component ++ "]",
            .gl_tess_control => "[gl_InvocationID/2*][(gl_InvocationID%2)*2+" ++ component ++ "]",
            .gl_fragment, .gl_tess_evaluation, .gl_mesh, .gl_task, .gl_compute, .gl_geometry => "[" ++ global_thread_id ++ "/2][(" ++ global_thread_id ++ "%2)*2+" ++ component ++ "]",
            else => unreachable,
        } else "[" ++ component ++ "]";
    }

    //
    // Stepping and breakpoint code scaffolding functions
    //

    /// Shorthand for std.fmt.allocPrint
    fn print(self: *@This(), comptime fmt: String, args: anytype) !String {
        return std.fmt.allocPrint(self.config.allocator, fmt, args);
    }

    /// Shorthand for std.fmt.allocPrintZ
    fn printZ(self: *@This(), comptime fmt: String, args: anytype) !ZString {
        return std.fmt.allocPrintZ(self.config.allocator, fmt, args);
    }

    fn checkAndHit(self: *@This(), comptime cond: String, cond_args: anytype, step_id: usize, comptime ret: String, ret_args: anytype, comptime append: String, args: anytype) !String {
        return self.print("if((" ++ step_counter ++ "++>={s})" ++ cond ++ "){{{s}{s}={d};{s}{s}=" ++ step_counter ++ ";{s}=true;return " ++ ret ++ ";}}" ++ append, //
            .{self.outputs.desired_step_ident} ++ cond_args ++ .{ self.outputs.step_storage.?._name, self.bufferIndexer("0"), step_id, self.outputs.step_storage.?._name, self.bufferIndexer("1"), was_hit } ++ ret_args ++ args);
    }

    fn advanceAndCheck(self: *@This(), step_id: usize, func: Func, is_void: bool, has_bp: bool, comptime append: String, args: anytype) !String {
        const bp_cond = "||(" ++ step_counter ++ ">{s})";
        const return_init = "{s}(0)";
        return // TODO initialize structs for returning
        if (has_bp)
            if (is_void)
                self.checkAndHit(bp_cond, .{self.outputs.desired_bp_ident}, step_id, "", .{}, append, args)
            else
                self.checkAndHit(bp_cond, .{self.outputs.desired_bp_ident}, step_id, return_init, .{func.return_type}, append, args)
        else if (is_void)
            self.checkAndHit("", .{}, step_id, "", .{}, append, args)
        else
            self.checkAndHit("", .{}, step_id, return_init, .{func.return_type}, append, args);
    }

    fn guard(self: *@This(), is_parent_void: bool, parent_func: Func, pos: usize) !void {
        try self.insertEnd(try std.fmt.allocPrint(
            self.config.allocator,
            "if(" ++ was_hit ++ ")return {s}{s};",
            if (is_parent_void) .{ "", "" } else .{ parent_func.return_type, "(0)" }, //TODO in ESSL struct must be initialized
        ), pos, 0);
    }

    /// Recursively instrument breaking the caller function after a call a function with the `name`
    pub fn processFunctionCallsRec(self: *@This(), source: String, tree_info: ParseInfo, func: Func) (std.mem.Allocator.Error || Error)!usize {
        const tree = tree_info.tree;
        // find references (function calls) to this function
        const calls = tree_info.calls.get(func.name) orelse return 0; // skip if the function is never called
        var processed: usize = calls.items.len;
        for (calls.items) |node| { // it is a .call AST node
            //const call = analyzer.syntax.Call.tryExtract(tree, node) orelse return Error.InvalidTree;
            var innermost_statement_span: ?analyzer.parse.Span = null;
            var in_condition_list = false;
            var branches = std.ArrayListUnmanaged(u32){};
            defer branches.deinit(self.config.allocator);

            try self.ensureStorageInit();

            // walk up the tree to find the caller function
            var parent: ?@TypeOf(tree.root) = tree.parent(node);
            while (parent) |current| : (parent = tree.parent(current)) {
                switch (tree.tag(current)) {
                    .function_declaration => {
                        if (innermost_statement_span) |statement| {
                            const parent_func = try getFunc(tree, current, source);
                            const is_parent_void = std.mem.eql(u8, parent_func.return_type, "void");
                            if (branches.items.len > 0) {
                                for (branches.items) |branch| {
                                    if (!self.guarded.contains(branch)) {
                                        try self.guard(is_parent_void, parent_func, branch + 1);
                                        try self.guarded.put(self.config.allocator, branch, {});
                                    }
                                }
                            } else try self.guard(is_parent_void, parent_func, statement.end);

                            processed += try processFunctionCallsRec(self, source, tree_info, parent_func);
                        } else {
                            log.err("Function call to {s} node {d} has no innermost statement", .{ func.name, node });
                        }
                    },
                    .block => {
                        if (innermost_statement_span == null) {
                            innermost_statement_span = tree.nodeSpan(tree.children(current).start);
                        }
                    },
                    .statement => {
                        if (innermost_statement_span == null) {
                            const children = tree.children(current);
                            switch (tree.tag(children.start)) {
                                .keyword_for, .keyword_while, .keyword_do => {
                                    for (children.start + 1..children.end) |child| {
                                        if (tree.tag(child) == .block) {
                                            innermost_statement_span = tree.nodeSpan(@intCast(child));
                                        }
                                    }
                                },
                                else => innermost_statement_span = tree.nodeSpan(current),
                            }
                        }
                    },
                    .condition_list => {
                        in_condition_list = true;
                    },
                    .if_branch => {
                        if (innermost_statement_span == null) {
                            const statement = tree.parent(current) orelse {
                                log.err("If branch node {d} has no parent", .{current});
                                continue;
                            };
                            const children = tree.children(statement);
                            for (children.start..children.end) |branch| {
                                switch (tree.tag(branch)) {
                                    .if_branch, .else_branch => {
                                        const branch_children = tree.children(branch);
                                        for (branch_children.start..branch_children.end) |child| {
                                            if (tree.tag(child) == .block) {
                                                try branches.append(self.config.allocator, tree.nodeSpanExtreme(@intCast(child), .start));
                                            }
                                        }
                                    },
                                    else => {},
                                }
                            }
                        }
                    },
                    .file => {
                        log.err("No parent function found for call to {s} at {d}", .{ func.name, tree.nodeSpan(node).start });
                    },
                    else => {}, // continue up
                }
            }
        }
        return processed;
    }

    /// Used for variable watches (needto be executed before a breakpoint)
    pub fn insertStart(self: *@This(), string: String, offset: usize) std.mem.Allocator.Error!void {
        var entry = self.inserts.getEntryFor(.{ .offset = offset, .inserts = std.DoublyLinkedList(String){} });
        const new_lnode = try self.lnode_pool.create();
        new_lnode.* = .{ .data = string };
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
        var entry = self.inserts.getEntryFor(Insert{ .offset = offset, .consume_next = consume_next, .inserts = std.DoublyLinkedList(String){} });
        const new_lnode = try self.lnode_pool.create();
        new_lnode.* = .{ .data = string };
        if (entry.node) |node| {
            node.key.inserts.append(new_lnode);
            node.key.consume_next += consume_next;
        } else {
            const new_node = try self.node_pool.create();
            entry.key.inserts.append(new_lnode);
            entry.set(new_node);
        }
    }

    /// Gets processor's result and frees the working memory
    pub fn applyTo(self: *@This(), source: String) !Result {
        var parts = try std.ArrayListUnmanaged(u8).initCapacity(self.config.allocator, source.len + 1);

        if (self.outputs.step_storage != null) {
            try self.insertStorageDeclarations();
        }

        var it = self.inserts.inorderIterator(); //Why can't I iterate on const Treap?
        if (it.current == null) {
            try self.addDiagnostic(try self.print("Instrumentation was requested but no inserts were generated for stage {s}", .{@tagName(self.config.shader_stage)}), null, null);
            parts.deinit(self.config.allocator);
            return Result{ .length = 0, .outputs = self.toOwnedOutputs(), .source = null, .spirv = null };
        } else {
            var previous: ?*Inserts.Node = null;
            while (it.next()) |node| : (previous = node) { //for each insert
                const inserts = node.key.inserts;

                const prev_offset =
                    if (previous) |prev|
                blk: {
                    if (prev.key.offset > node.key.offset) {
                        if (it.next()) |nexter| {
                            log.debug("Nexter at {d}, cons {d}: {s}", .{ nexter.key.offset, nexter.key.consume_next, nexter.key.inserts.first.?.data });
                        }
                        // write the rest of code
                        try parts.appendSlice(self.config.allocator, source[prev.key.offset + prev.key.consume_next ..]);
                        break;
                    }
                    break :blk prev.key.offset + prev.key.consume_next;
                } else 0;

                try parts.appendSlice(self.config.allocator, source[prev_offset..node.key.offset]);

                var inserts_iter = inserts.first;
                while (inserts_iter) |inserts_node| : (inserts_iter = inserts_node.next) { //for each part to insert at the same offset
                    const to_insert = inserts_node.data;
                    try parts.appendSlice(self.config.allocator, to_insert);
                }
            } else {
                // write the rest of code
                try parts.appendSlice(self.config.allocator, source[previous.?.key.offset + previous.?.key.consume_next ..]);
            }
        }
        try parts.append(self.config.allocator, 0); // null-terminate the string
        const len = parts.items.len;
        return Result{
            .length = len,
            .outputs = self.toOwnedOutputs(),
            .source = @ptrCast((try parts.toOwnedSlice(self.config.allocator)).ptr),
            .spirv = null,
        };
    }

    /// NOTE: When an error union is passed as `value`, the diagnostic is added only if the error has occured (so if you want to include it forcibly, try or catch it before calling this function)
    fn addDiagnostic(self: *@This(), value: anytype, source: ?std.builtin.SourceLocation, span: ?analyzer.parse.Span) std.mem.Allocator.Error!switch (@typeInfo(@TypeOf(value))) {
        .ErrorUnion => |err_un| err_un.payload,
        else => void,
    } {
        const err_name_or_val = switch (@typeInfo(@TypeOf(value))) {
            .ErrorUnion => if (value) |success| {
                return success;
            } else |err| @errorName(err),
            .ErrorSet => @errorName(value),
            else => value,
        };

        if (echo_diagnostics) {
            if (source) |s| {
                log.debug("Diagnostic {s} at {s}:{d}:{d} ({s})", .{ err_name_or_val, s.file, s.line, s.column, s.fn_name });
            } else {
                log.debug("Diagnostic {s}", .{err_name_or_val});
            }
        }
        try self.outputs.diagnostics.append(self.config.allocator, analyzer.parse.Diagnostic{
            .message = err_name_or_val,
            .span = span orelse .{ .start = 0, .end = 0 },
        });
    }

    pub const Inserts = std.Treap(Insert, Insert.order);
    pub const Insert = struct {
        /// offset in the original non-instrumented source code
        offset: usize,
        consume_next: u32 = 0,
        inserts: std.DoublyLinkedList(String),

        pub fn order(a: @This(), b: @This()) std.math.Order {
            return std.math.order(a.offset, b.offset);
        }
    };
};

/// Specifies a writable shader output channel
pub const OutputStorage = struct {
    /// private for the Processor. Will be freed by the Processor
    _name: String,
    location: OutputStorage.Location,
    /// Handle to the storage created in the host graphics API
    ref: ?usize = null,
    // TODO deinit on new instrumentation
    /// Function to free the storage object in the host API
    deinit_host: ?*const fn (self: *@This(), allocator: std.mem.Allocator) void = null,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.deinit_host) |d| d(self, allocator);
    }

    /// Frees name upon failure, does not copy
    pub fn nextAvailable(
        config: *Processor.Config,
        force_buffer: bool,
        name: String,
        fit_into_component: ?OutputStorage.Location,
        component: ?usize,
    ) !?OutputStorage {
        if (!force_buffer) {
            switch (config.shader_stage) {
                .gl_fragment, .vk_fragment, .gl_vertex, .vk_vertex => {
                    if (fit_into_component) |another_stor| {
                        if (another_stor == .Interface and component != null) {
                            return OutputStorage{ ._name = name, .location = .{ .Interface = .{ .location = another_stor.Interface.location, .component = component.? } } };
                        }
                    }
                    // these can have output interfaces
                    var candidate: usize = 0;
                    for (config.used_interface.items) |loc| {
                        if (loc > candidate) {
                            if (loc >= config.used_interface.items.len) {
                                try config.used_interface.append(candidate);
                            } else {
                                try config.used_interface.insert(loc, candidate);
                            }
                            return OutputStorage{ ._name = name, .location = .{ .Interface = .{ .location = candidate } } };
                        }
                        candidate = loc + 1;
                    }
                    if (candidate < config.max_interface) {
                        try config.used_interface.append(candidate);
                        return OutputStorage{ ._name = name, .location = .{ .Interface = .{ .location = candidate } } };
                    }
                },
                else => {
                    // other stages cannot have direct output interfaces
                },
            }
        }
        if (config.support.buffers) {
            var binding_i: usize = 0;
            for (0.., config.used_buffers.items) |i, used| {
                if (used > binding_i) {
                    try config.used_buffers.insert(i, binding_i);
                    return OutputStorage{ ._name = name, .location = .{ .Buffer = binding_i } };
                }
                binding_i = used + 1;
            }
            if (binding_i < config.max_buffers) {
                try config.used_buffers.append(binding_i);
                return OutputStorage{ ._name = name, .location = .{ .Buffer = binding_i } };
            }
        }
        if (name.len > 0)
            config.allocator.free(name);
        return null;
    }

    const Location = union(enum) {
        /// binding number (for SSBOs)
        Buffer: usize,
        /// output interface location (attachment, transform feedback varying). Not available for all stages, but is more compatible (WebGL...)
        Interface: struct { location: usize, component: usize = 0 },
    };
};
pub const PrimitiveType = struct {
    data_type: enum {
        uint,
        int,
        float,
        bool,
    },
    size_x: u2, //1, 2, 3, 4
    size_y: u2,
};
pub const Type = union(enum) {
    Primitive: PrimitiveType,
    Array: struct {
        type: PrimitiveType,
        size: usize,
    },
    Texture: struct {
        resolution: union(enum) {
            _1D: usize,
            _2D: [2]usize,
            _3D: [3]usize,
            Cube: [2]usize,
        },
        format: enum { R8, R16, R32, RG8, RG16, RG32, RGB8, RGB16, RGB32, RGBA8, RGBA16, RGBA32 },
    },
    Struct: struct {
        name: String,
        members: []Variable,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.members);
        }
    },
};
pub const Variable = struct {
    name: String,
    type: Type,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.type) {
            .Struct => self.type.Struct.deinit(allocator),
            else => {},
        }
    }
};
pub const VariableInstrumentation = struct {
    variable: Variable,
    /// Multiple variables can be stored in the same storage
    offset: usize,
    stride: usize,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.variable.deinit(allocator);
    }
};
