//! TODO
//! Sdílená paměť - dumpuje jen jedno vlákno ze skupiny
//! Lokální paměť - každé vlákno
//! Builtin variables - podle druhu

const std = @import("std");
const analyzer = @import("glsl_analyzer");
const log = @import("../log.zig").DeshaderLog;
const decls = @import("../declarations/shaders.zig");

const String = []const u8;
const CString = [*:0]const u8;

pub const Error = error{ InvalidBreakpoint, InvalidTree, OutOfStorage };
pub const ParseInfo = struct {
    arena_state: std.heap.ArenaAllocator.State,
    tree: analyzer.parse.Tree,
    ignored: []const analyzer.parse.Token,
    diagnostics: []const analyzer.parse.Diagnostic,

    calls: std.StringHashMap(std.ArrayList(u32)),
    version: u16,
    version_span: analyzer.parse.Span,
    breakpoint_identifier: String = "bzumbzumbrekekeke",

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
    pub const Outputs = struct {
        breakpoints: ?OutputStorage = null,
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
            if (self.breakpoints) |*bp| {
                bp.deinit(allocator);
            }
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
    //
    // Configuration "interface"
    //

    /// Is required to be set before init()
    allocator: std.mem.Allocator,
    /// Is required to be set before init()
    free_attachments: *std.ArrayList(u5),
    /// Is required to be set before init()
    used_buffers: *std.ArrayList(usize),
    /// Is required to be set before init()
    used_xfb: u4,
    /// Is required to be set before init()
    max_buffers: usize,
    /// Is required to be set before init()
    shader_type: decls.SourceType,
    /// Is required to be set before init(). Dimensions of the output buffer (vertex count / screen resolution)
    threads: []const usize,

    //
    // Working variables
    //

    threads_total: usize = 0, // Sum of all threads dimesions count
    /// Offset of #version directive (if any was found)
    after_version: usize = 0,
    vulkan: bool = false,
    glsl_version: u16 = 140, // 4.60 -> 460
    bp_storage_ident: String = undefined,
    rand: std.rand.DefaultPrng = undefined,

    /// Maps offsets in file to the inserted instrumented code fragments (sorted)
    /// Both the key and the value are stored as Treap's Key (a bit confusing)
    inserts: Inserts = .{}, // Will be inserted many times but iterated only once at applyTo
    outputs: Result.Outputs = .{},
    node_pool: std.heap.MemoryPool(Inserts.Node) = undefined,
    lnode_pool: std.heap.MemoryPool(std.DoublyLinkedList(String).Node) = undefined,

    pub const prefix = "deshader_";
    const storage_identifier = prefix ++ "hit_id";
    const threads_identifier = prefix ++ "deshader_threads";
    const global_id = prefix ++ "global_id";
    const temp_identifier = prefix ++ "temp";
    const echo_diagnostics = false;

    pub fn deinit(self: *@This()) void {
        _ = self.toOwnedOutputs();
        self.outputs.deinit(self.allocator);
    }

    pub fn toOwnedOutputs(self: *@This()) Result.Outputs {
        // deinit contents
        var it = self.inserts.inorderIterator();
        while (it.current) |node| : (_ = it.next()) {
            while (node.key.inserts.pop()) |item| {
                self.allocator.free(item.data);
            }
        }

        // deinit the wrapping nodes
        self.node_pool.deinit();
        self.lnode_pool.deinit();

        if (self.outputs.breakpoints != null) { // if breakpoints were initialized at some point
            self.allocator.free(self.bp_storage_ident);
        }
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

    /// Should be run on semi-initialized Output (only fields with no default values need to be initialized)
    pub fn setup(self: *@This(), source: String) !void {
        self.rand = std.rand.DefaultPrng.init(@intCast(std.time.timestamp()));
        self.node_pool = std.heap.MemoryPool(Inserts.Node).init(self.allocator);
        self.lnode_pool = std.heap.MemoryPool(std.DoublyLinkedList(String).Node).init(self.allocator);

        var tree_info: ParseInfo = try ParseInfo.parseSource(self.allocator, source);
        defer tree_info.deinit(self.allocator);
        const tree = tree_info.tree;
        // Store GLSL version
        self.glsl_version = tree_info.version;
        self.after_version = tree_info.version_span.end + 1;

        var threads_total: usize = 0;
        for (self.threads) |thread| {
            threads_total += thread;
        }

        //log.debug("{}", .{tree.format(source)});

        // Process breakpoint markers
        if (tree_info.calls.get(tree_info.breakpoint_identifier)) |bps| {
            each_bp: for (1.., bps.items) |hit_id, bp_node_id| {
                //breakpoints should be sorted by their position in text
                //breakpoint hit records are 1-based to reserve 0 for no hit
                log.debug("BP {d} at {s}", .{ hit_id, @tagName(tree.tag(bp_node_id)) });
                const bp_call = analyzer.syntax.Call.tryExtract(tree, bp_node_id) orelse return Error.InvalidTree;
                const bp_call_token = tree.token(bp_call.nodeOf(.identifier, tree).?); //the .call's first child is identifier

                var stat_begin: String = "";
                var stat_delimiter: String = ";";
                var stat_end: String = ";";

                // walk the tree up to determine the context type (inside a function, condition, block)
                var parent = tree.parent(bp_node_id);
                while (parent) |current| : (parent = tree.parent(current)) {
                    const current_tag = tree.tag(current);
                    log.debug("BP in {s}", .{@tagName(current_tag)});
                    switch (current_tag) {
                        .function_declaration => {
                            // found a context
                            const func = try getFunc(tree, current, source);
                            try self.ensureBreakpointsInit(tree_info.breakpoint_identifier);

                            // Emit breakpoint hit => write to the output debug bufffer and return
                            try self.insertEnd(
                                try std.fmt.allocPrint(self.allocator, "{s}{s}={d}{s}return {s}{s}{s}", //
                                    if (std.mem.eql(u8, func.return_type, "void"))
                                    .{ stat_begin, self.bp_storage_ident, hit_id, stat_delimiter, "", "", stat_end }
                                else
                                    .{ stat_begin, self.bp_storage_ident, hit_id, stat_delimiter, func.return_type, "()", stat_end }),
                                bp_call_token.start,
                                @intCast(tree_info.breakpoint_identifier.len + 2),
                            ); //consume `breakpoint_indentifier` and +2 for parentheses

                            if (try self.processFunctionCallsRec(source, tree_info, func) == 0) {
                                // not called
                                continue :each_bp;
                            }

                            break; // break searching for the context type
                        },
                        .expression_sequence, .arguments_list, .condition_list => {
                            // change delimiters to avoid breaking the expression
                            stat_begin = ",";
                            stat_delimiter = ",";
                            stat_end = "";
                        },
                        .file => _ = try self.addDiagnostic(Error.InvalidBreakpoint, @src(), tree.nodeSpan(current)), // cannot break at the top level
                        else => {}, // continue up
                    }
                    // couldn't break at this, so we go further up
                }
            }
        }
    }

    /// Creates a buffer for outputting the index of breakpoint which each thread has hit
    /// For some shader stages, it also creates thread indexer variable `global_id`
    /// Inserts everything after #version directive
    fn ensureBreakpointsInit(self: *@This(), breakpoint_identifier: String) !void {
        if (self.outputs.breakpoints == null) {
            self.outputs.breakpoints = try OutputStorage.nextAvailable(self) orelse return Error.OutOfStorage;
            try self.insertStart(
                try std.fmt.allocPrint(self.allocator, "#define {s}()\n", .{breakpoint_identifier}),
                self.after_version,
            ); // define the breakpoint identifier as an empty macro

            switch (self.outputs.breakpoints.?.type) {
                // -- Beware of spaces --
                .Buffer => |binding| {
                    try self.insertStart(try std.fmt.allocPrint(self.allocator,
                        \\layout(std{d}, binding={d}) restrict buffer DeshaderBreakpoints {{
                    ++ "uint " ++ storage_identifier ++ "[{d}];" ++
                        \\}};
                        \\
                    , .{
                        @as(u16, if (self.glsl_version >= 430) 430 else 140),
                        binding,
                        self.threads_total,
                    }), 0);
                    switch (self.shader_type) {
                        .gl_fragment, .vk_fragment => {
                            try self.insertStart(try std.fmt.allocPrint(
                                self.allocator,
                                "const uvec2 " ++ threads_identifier ++ "= uvec2({d}, {d});\n" ++
                                    "const uint " ++ global_id ++ " = uint(gl_FragCoord.y) * " ++ threads_identifier ++ ".x + uint(gl_FragCoord.x);\n",
                                .{ self.threads[0], self.threads[1] },
                            ), self.after_version);
                        },
                        .gl_geometry => {
                            try self.insertStart(try std.fmt.allocPrint(
                                self.allocator,
                                "const uint " ++ threads_identifier ++ "= {d};\n" ++
                                    "const uint " ++ global_id ++ "= gl_PrimitiveIDIn * " ++ threads_identifier ++ " + gl_InvocationID;\n",
                                .{self.threads[0]},
                            ), self.after_version);
                        },
                        .gl_tess_evaluation => {
                            try self.insertStart(try std.fmt.allocPrint(
                                self.allocator,
                                "const ivec2 " ++ threads_identifier ++ "= ivec2(gl_TessCoord.xy * float({d}-1) + 0.5);\n" ++
                                    "const uint " ++ global_id ++ " =" ++ threads_identifier ++ ".y * {d} + " ++ threads_identifier ++ ".x;\n",
                                .{ self.threads[0], self.threads[0] },
                            ), self.after_version);
                        },
                        .gl_mesh, .gl_task, .gl_compute => try self.insertStart("const uint " ++ global_id ++
                            \\= gl_GlobalInvocationID.z * gl_NumWorkGroups.x * gl_NumWorkGroups.y * gl_WorkGroupSize + gl_GlobalInvocationID.y * gl_NumWorkGroups.x * gl_WorkGroupSize + gl_GlobalInvocationID.x);
                            \\
                        , self.after_version),
                        else => {},
                    }
                },
                .Attachment => |i| {
                    if (self.glsl_version >= 130) {
                        try self.insertStart(try std.fmt.allocPrint(self.allocator,
                            \\layout(location={d}) out
                        ++ " uint " ++ storage_identifier ++ ";\n", .{i}), self.after_version);
                    }
                    // else gl_FragData is implicit
                },
                .TransformFeedback => |xfb_binding| {
                    try self.insertStart(try std.fmt.allocPrint(self.allocator,
                        \\layout(xfb_buffer={d}) out
                    ++ " uint " ++ storage_identifier ++ ";\n", .{xfb_binding}), self.after_version);
                },
            }
            self.bp_storage_ident = switch (self.outputs.breakpoints.?.type) {
                .Buffer => |_| try std.mem.concat(self.allocator, u8, &.{ storage_identifier, try self.indexerForThread() }),
                .Attachment => |i| if (self.glsl_version >= 130) //
                    try self.allocator.dupe(u8, storage_identifier)
                else
                    try std.fmt.allocPrint(self.allocator, "gl_FragData[{d}]", .{i}),
                .TransformFeedback => |_| try self.allocator.dupe(u8, storage_identifier),
            };
        }
    }

    fn indexerForThread(self: *@This()) !String {
        return switch (self.shader_type) {
            .gl_vertex => if (self.vulkan) "[gl_VertexIndex]" else "[gl_VertexID]",
            .gl_tess_control => "[gl_InvocationID]",
            .gl_fragment, .gl_tess_evaluation, .gl_mesh, .gl_task, .gl_compute, .gl_geometry => "[" ++ global_id ++ "]",
            else => unreachable,
        };
    }

    /// Recursively instrument breaking the caller function after a call a function with the `name`
    pub fn processFunctionCallsRec(self: *@This(), source: String, tree_info: ParseInfo, func: Func) (std.mem.Allocator.Error || Error)!usize {
        const tree = tree_info.tree;
        // find references (function calls) to this function
        const calls = tree_info.calls.get(func.name) orelse return 0; // skip if the function is never called
        var processed: usize = calls.items.len;
        try self.ensureBreakpointsInit(tree_info.breakpoint_identifier);
        for (calls.items) |node| { // it is a .call AST node
            //const call = analyzer.syntax.Call.tryExtract(tree, node) orelse return Error.InvalidTree;
            const call_span = tree.nodeSpan(node);

            const is_void = std.mem.eql(u8, func.return_type, "void");
            var in_expression = false;
            var outer_statement_pos: usize = undefined;

            // walk up the tree to find the caller function
            var parent: ?@TypeOf(tree.root) = tree.parent(node);
            while (parent) |current| : (parent = tree.parent(current)) {
                switch (tree.tag(current)) {
                    .function_declaration => {
                        const parent_func = try getFunc(tree, current, source);
                        const is_parent_void = std.mem.eql(u8, parent_func.return_type, "void");

                        if (in_expression) {
                            const temp = self.rand.next();
                            if (!is_void) {
                                // prepare temporary variable to store the return value

                                try self.insertStart(try std.fmt.allocPrint(self.allocator, "{s} {s}{d}={s}();\n", .{
                                    func.return_type,
                                    temp_identifier,
                                    temp,
                                    func.return_type,
                                }), outer_statement_pos);
                            }

                            try self.insertEnd(try std.fmt.allocPrint(
                                self.allocator,
                                ",{s}!=0?return {s}{s}",
                                if (is_parent_void) .{ self.bp_storage_ident, "", "" } else .{ self.bp_storage_ident, parent_func.return_type, "()" },
                            ), call_span.end, 0);
                        } else {
                            try self.insertEnd(try std.fmt.allocPrint(
                                self.allocator,
                                "if({s}!=0)return {s}{s};",
                                if (is_parent_void) .{ self.bp_storage_ident, "", "" } else .{ self.bp_storage_ident, parent_func.return_type, "()" }, //TODO in ESSL struct must be initialized
                            ), call_span.end, 0);
                        }

                        processed += try processFunctionCallsRec(self, source, tree_info, parent_func);
                    },
                    .expression_sequence, .arguments_list, .condition_list => {
                        in_expression = true;
                    },
                    .statement => {
                        outer_statement_pos = tree.nodeSpan(current).end;
                    },
                    .file => return error.InvalidTree,
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
    pub fn insertEnd(self: *@This(), string: String, offset: usize, consume_next: u8) std.mem.Allocator.Error!void {
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
        var parts = try std.ArrayListUnmanaged(u8).initCapacity(self.allocator, source.len + 1);

        var it = self.inserts.inorderIterator(); //Why can't I iterate on const Treap?
        if (it.current == null) {
            try self.addDiagnostic(try std.fmt.allocPrint(self.allocator, "Instrumentation was requested but no inserts were generated for shader {}", .{self.shader_type}), null, null);
            parts.deinit(self.allocator);
            return Result{
                .length = 0,
                .outputs = self.toOwnedOutputs(),
                .source = null,
            };
        } else {
            while (it.current) |node| { //for each insert
                const inserts = node.key.inserts;

                const prev_offset =
                    if (it.previous) |prev|
                blk: {
                    if (prev.key.offset > node.key.offset) {
                        if (it.next()) |nexter| {
                            log.debug("Nexter at {d}, cons {d}: {s}", .{ nexter.key.offset, nexter.key.consume_next, nexter.key.inserts.first.?.data });
                        }
                        // write the rest of code
                        try parts.appendSlice(self.allocator, source[prev.key.offset + prev.key.consume_next ..]);
                        break;
                    }
                    log.debug("Prev at {d}, cons {d}: {s}", .{ prev.key.offset, prev.key.consume_next, prev.key.inserts.first.?.data });
                    break :blk prev.key.offset + prev.key.consume_next;
                } else 0;
                log.debug("Inserting at {d}: {s}", .{ node.key.offset, node.key.inserts.first.?.data });

                try parts.appendSlice(self.allocator, source[prev_offset..node.key.offset]);

                var inserts_iter = inserts.first;
                while (inserts_iter) |inserts_node| : (inserts_iter = inserts_node.next) { //for each part to insert at the same offset
                    const to_insert = inserts_node.data;
                    try parts.appendSlice(self.allocator, to_insert);
                }

                if (it.next() == null) { // write the rest of code
                    try parts.appendSlice(self.allocator, source[node.key.offset + node.key.consume_next ..]);
                }
            }
        }
        try parts.append(self.allocator, 0); // null-terminate the string
        const len = parts.items.len;
        return Result{
            .length = len,
            .outputs = self.toOwnedOutputs(),
            .source = @ptrCast((try parts.toOwnedSlice(self.allocator)).ptr),
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
        try self.outputs.diagnostics.append(self.allocator, analyzer.parse.Diagnostic{
            .message = err_name_or_val,
            .span = span orelse .{ .start = 0, .end = 0 },
        });
    }

    pub const Inserts = std.Treap(Insert, Insert.order);
    pub const Insert = struct {
        /// offset in the original non-instrumented source code
        offset: usize,
        consume_next: u8 = 0,
        inserts: std.DoublyLinkedList(String),

        pub fn order(a: @This(), b: @This()) std.math.Order {
            return std.math.order(a.offset, b.offset);
        }
    };
};

/// Specifies a writable shader output channel
pub const OutputStorage = struct {
    type: OutputStorage.Type,
    /// Handle to the storage created in the host graphics API
    ref: ?usize = null,
    /// Function to free the storage object in the host API
    deinit_host: ?*const fn (self: *@This(), allocator: std.mem.Allocator) void = null,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.deinit_host) |d| d(self, allocator);
    }

    /// used_buffers contains list of used bindings
    pub fn nextAvailable(out: *Processor) !?OutputStorage {
        switch (out.shader_type) {
            .gl_fragment, .vk_fragment => {
                for (0.., out.free_attachments.items) |i, attachment| {
                    _ = out.free_attachments.orderedRemove(i);
                    return OutputStorage{ .type = .{ .Attachment = attachment } };
                }
            },
            .gl_vertex, .vk_vertex => {
                inline for (0..3) |i| {
                    const mask = 1 << i;
                    if (out.used_xfb & mask == 0) {
                        out.used_xfb |= mask;
                        return OutputStorage{ .type = .{ .TransformFeedback = i } };
                    }
                }
            },
            else => unreachable, //TODO other shader stages
        }
        var binding_i: usize = 0;
        for (0.., out.used_buffers.items) |i, used| {
            if (used > binding_i) {
                try out.used_buffers.insert(i, binding_i);
                return OutputStorage{ .type = .{ .Buffer = binding_i } };
            }
            binding_i = used + 1;
        }
        if (binding_i < out.max_buffers) {
            try out.used_buffers.append(binding_i);
            return OutputStorage{ .type = .{ .Buffer = binding_i } };
        }
        return null;
    }

    const Type = union(enum) {
        /// binding number (for SSBOs)
        Buffer: usize,
        /// Framebuffer attachment. Available only for fragment shaders, but is more compatible (WebGL...)
        Attachment: u5,
        /// Transform feedback buffer
        TransformFeedback: usize,
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
    output: OutputStorage,
    /// Multiple variables can be stored in the same storage
    offset: usize,
    stride: usize,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.variable.deinit(allocator);
        self.output.deinit(allocator);
    }
};
