const std = @import("std");
const analyzer = @import("glsl_analyzer");
const common = @import("common");
const log = common.log;

const sema = @import("sema.zig");
const shaders = @import("shaders.zig");
const storage = @import("storage.zig");
const debug = @import("debug.zig");
const decls = @import("../declarations.zig");

const Processor = @import("processor.zig");

const String = []const u8;

pub const Error = error{ InvalidStep, NoStepNearCall };

/// A simple instrument that adds #pragma debug statements to the top of the shader when enabled
pub const PragmaDebug = struct {
    pub const id: Processor.Instrument.ID = 0xDEB06;

    pub fn isEnabled(channels: anytype) ?*bool {
        return channels.getControl(*bool, id);
    }

    fn createEnabledControl(processor: *Processor) !Processor.VarResult(bool) {
        return processor.controlVar(id, bool, false, true);
    }

    pub fn setup(processor: *Processor) anyerror!void {
        const enabled = try createEnabledControl(processor);

        if (enabled.value_ptr.*) {
            try processor.insertStart("#pragma debug\n", processor.after_directives);
        }
    }
};

/// This instrument is used for stepping and breakpoint logic.
/// Basically all other instruments depend on this one.
pub const Step = struct {
    pub var step_identifier: String = Processor.templates.prefix ++ "step_";
    var warned_about_selection: bool = false;
    pub const tag = analyzer.parse.Tag.call;
    pub const id: Processor.Instrument.ID = 0x57e9;
    pub const sync_id: Processor.OutputStorage.ID = 0x51c;

    pub const Controls = struct {
        /// Step IDs
        breakpoints: std.AutoHashMapUnmanaged(T, void) = .empty,
        /// Index for the step counter to check for. Do not mismatch with step IDs.
        /// Set to non-null value to enable stepping.
        desired_step: ?T = null,
        /// Index for the step counter to check for.
        /// Same numbering as for `desired_step`, but is checked only on places with breakpoints.
        desired_bp: T = 0,
    };

    /// Client debugger state. Program-wide. Does not directly affect the instrumentation
    pub const Responses = struct {
        /// If source stepping is ongoing, this is the global index of the currently reached step.
        /// Can be used for the purpose of advancing target step index with `desired_step = reached.counter + 1`.
        reached: ?ReachedStep = null,
        /// Uses service's allocator
        offsets: std.ArrayListUnmanaged(StepOffset) = .empty,

        /// Computes the part index and an offset into its `steps` array from the global step index returned by instrumented shader invocation.
        pub fn localStepOffset(self: *const @This(), global_step: usize) !StepOffset {
            for (0..self.offsets.items.len) |i| {
                const offset = self.offsets.items[self.offsets.items.len - 1 - i];
                if (global_step >= offset.offset) {
                    return offset;
                }
            }
            return Error.InvalidStep;
        }

        pub const LocalStep = struct {
            part: *shaders.Shader.SourcePart,
            /// Source file step locator
            step: shaders.Shader.SourcePart.Step,
        };
        pub fn localStep(self: *const @This(), global_step: T) !LocalStep {
            const offset = try self.localStepOffset(global_step);
            return LocalStep{
                .part = offset.part,
                .step = offset.part.possible_steps.?.get(global_step - offset.offset),
            };
        }

        pub const ReachedStep = extern struct {
            /// The global step ID (used to identify the step in the space of all shader source codes).
            /// Number of the reached step in corresponding source part (can be found using `Responses.localStep(Responses.reached.id)`).
            id: T,
            /// Linear stage-local step counter (basically simulates instruction pointer)
            counter: T,
        };
    };

    pub const StepOffset = struct {
        part: *shaders.Shader.SourcePart,
        /// Offset of the step IDs array in respect to the global step ID space for this `SourcePart`
        offset: T,
    };

    /// The data type used for step counter and step IDs
    pub const T = u32;
    /// A step point is a call to a function named by the `Step.step_identifier` where the first argument is the global step ID and the second
    /// optional argument is the wrapped expression
    const StepPoint = struct {
        id: T,
        /// if the step is inside an expression, this is the part of the expression that should happen right after the step
        wrapped: ?analyzer.syntax.Expression,
    };
    const Guarded = std.AutoHashMapUnmanaged(Processor.NodeId, void);

    /// Just advance
    const step_advance = "i";
    /// Check for condition
    const step_if = "if_";
    const hit_storage = Processor.templates.prefix ++ "global_hit_id";
    const was_hit = Processor.templates.prefix ++ "global_was_hit";
    /// The step counter is local to a stage but shared across all its threads and basically simulates the instruction pointer.
    const step_counter = Processor.templates.prefix ++ "step_counter";
    const local_was_hit = Processor.templates.prefix ++ "was_hit";
    /// One uint width buffer. Must be initialized to zero.
    /// Should contain the first thread ID that did break the execution.
    const sync_storage = Processor.templates.prefix ++ "global_sync";

    /// Desired global step **ID** (breakpoints are based on the step ID)
    pub const desired_bp = Processor.templates.prefix ++ "desired_bp";
    /// Desired local step counter value (not the step ID)
    pub const desired_step = Processor.templates.prefix ++ "desired_step";

    pub fn controls(channels: *Processor.ProgramChannels) ?*Controls {
        return channels.getControl(*Controls, id);
    }

    pub fn responses(channels: *Processor.ProgramChannels) ?*Responses {
        return channels.getResponse(*Responses, id);
    }

    fn guarded(processor: *Processor) !*Guarded {
        const gop = try processor.scratchVar(id, Guarded, Guarded.empty);
        return @alignCast(@ptrCast(gop.value_ptr));
    }

    //
    //#region External interface
    //
    pub fn disableBreakpoints(service: *shaders, stage_ref: shaders.Shader.Stage.Ref) !void {
        const stage: *shaders.Shader.Stage = service.Shaders.all.get(stage_ref) orelse return error.TargetNotFound;
        const program = stage.program orelse return shaders.Error.NoInstrumentation;
        const state = &((program.state orelse return shaders.Error.NoInstrumentation));
        const c = controls(&state.channels) orelse return shaders.Error.NoInstrumentation;

        c.desired_bp = std.math.maxInt(u32); // TODO shader uses u32. Would 64bit be a lot slower?
        state.uniforms_dirty = true;
    }

    /// Continue to next breakpoint hit or the end of the shader
    pub fn @"continue"(service: *shaders, shader_ref: shaders.Shader.Stage.Ref) !void {
        const stage = service.Shaders.all.get(shader_ref) orelse return storage.Error.TargetNotFound;
        const state: *shaders.Shader.Program.State = (if (stage.program) |p| if (p.state) |*s| s else null else null) orelse
            return shaders.Error.NoInstrumentation;
        const c = controls(&state.channels).?;
        const r = responses(&state.channels).?;

        c.desired_bp = (if (r.reached) |s| s.counter else 0) +% 1;
        if (c.desired_step) |_| {
            c.desired_step = std.math.maxInt(u32);
        }

        state.uniforms_dirty = true;
    }

    /// Increments the desired step (or also desired breakpoint) selector for the shader `shader_ref`.
    pub fn advanceStepping(service: *shaders, shader_ref: shaders.Shader.Stage.Ref) !void {
        const stage: *shaders.Shader.Stage = service.Shaders.all.get(shader_ref) orelse return error.TargetNotFound;

        const state = &((stage.program orelse return shaders.Error.NoInstrumentation).state orelse return shaders.Error.NoInstrumentation);
        const r = responses(&state.channels).?;
        const c = controls(&state.channels).?;
        const next = (if (r.reached) |s| s.counter else 0) +% 1;

        if (c.desired_step == null) {
            stage.invalidate();
        }

        c.desired_step = next; //TODO limits
        c.desired_bp = next;

        state.uniforms_dirty = true;
    }

    pub fn disableStepping(service: *shaders, shader_ref: shaders.Shader.Stage.Ref) !void {
        const shader: *shaders.Shader.Stage = service.Shaders.all.get(shader_ref) orelse return error.TargetNotFound;
        const c = controls(&(shader.program orelse return shaders.Error.NoInstrumentation).channels) orelse return shaders.Error.NoInstrumentation;

        if (c.desired_step) {
            c.desired_step = null;
            shader.invalidate();
        }
    }

    pub fn pause(service: *shaders, shader_ref: shaders.Shader.Stage.Ref) !void {
        // set all the desired steps and breakpoints to 0
        const shader: *shaders.Shader.Stage = service.Shaders.all.get(shader_ref) orelse return error.TargetNotFound;
        const state = &((shader.program orelse return shaders.Error.NoInstrumentation).state orelse return shaders.Error.NoInstrumentation);
        const c = controls(&state.channels) orelse return shaders.Error.NoInstrumentation;

        if (c.desired_step == null) {
            shader.invalidate();
        }

        c.desired_step = 0;
        c.desired_bp = 0;

        state.uniforms_dirty = true;
    }
    //#endregion

    //
    //#region Instrumentation primitives/helpers
    //

    /// Index into the global hit indication storage for the current thread
    fn bufferIndexer(processor: *Processor, comptime component: String) String {
        return if (processor.outChannel(id).?.location == .buffer) switch (processor.config.shader_stage) {
            .gl_vertex => if (processor.vulkan)
                "[gl_VertexIndex/2][(gl_VertexIndex%2)*2+" ++ component ++ "]"
            else
                "[gl_VertexID/2][(gl_VertexID%2)*2+" ++ component ++ "]",
            .gl_tess_control => "[gl_InvocationID/2*][(gl_InvocationID%2)*2+" ++ component ++ "]",
            .gl_fragment, .gl_tess_evaluation, .gl_mesh, .gl_task, .gl_compute, .gl_geometry => //
            "[" ++ Processor.templates.linear_thread_id ++ "/2][(" ++ Processor.templates.linear_thread_id ++ "%2)*2+" ++ component ++ "]",
            else => unreachable,
        } else "[" ++ component ++ "]";
    }

    fn checkAndHit(
        processor: *Processor,
        comptime cond: String,
        cond_args: anytype,
        step_id: usize,
        comptime ret: String,
        ret_args: anytype,
    ) !String {
        return try processor.print(
            "{s}{s}({d}, " ++ (if (cond.len > 0) cond ++ "," else "") ++ ret ++ ")",
            .{
                step_identifier, if (cond.len > 0) step_if else "", step_id + 1,
                    // step hit records are 1-based, 0 is reserved for no hit
            } ++ cond_args ++ ret_args,
        );
    }

    pub fn extractStep(processor: *Processor, call: analyzer.syntax.Call) !StepPoint {
        const step_args: analyzer.syntax.ArgumentsList = call.get(.arguments, processor.parsed.tree) orelse return Error.InvalidStep;
        var args_it = step_args.iterator();

        const step_arg: analyzer.syntax.Argument = args_it.next(processor.parsed.tree) orelse return Error.InvalidStep; // get the first argument
        // extract the expression node construct from the argument
        const step_arg_expr: analyzer.syntax.Expression = step_arg.get(.expression, processor.parsed.tree) orelse return Error.InvalidStep;

        const step_id = try std.fmt.parseInt(T, processor.parsed.tree.nodeSpan(step_arg_expr.node).text(processor.config.source), 0);
        const expr = if (args_it.next(processor.parsed.tree)) |arg|
            arg.get(.expression, processor.parsed.tree)
        else
            null;

        return StepPoint{
            .id = step_id,
            .wrapped = expr,
        };
    }

    /// Inserts a guard to break the function `func` if a step or breakpoint was hit already. Should be inserted after a call to any user function.
    fn guard(
        processor: *Processor,
        is_void: bool,
        func: Processor.Processor.TraverseContext.Function,
        pos: usize,
        context: *Processor.TraverseContext,
    ) !void {
        if (is_void)
            try processor.insertEnd("if(" ++ local_was_hit ++ ") {{" ++
                sync_storage ++ " = " ++ Processor.templates.linear_thread_id ++ ";" ++
                \\ return;
            ++ "}}", pos, 0)
        else {
            const constructor = if (context.scope.visibleType(func.return_type)) |user_type|
                try generateConstructor(processor, user_type, context)
            else
                "0";

            try processor.insertEnd(
                try processor.print(
                    "if(" ++ local_was_hit ++ ") {{" ++
                        sync_storage ++ " = " ++ Processor.templates.linear_thread_id ++ ";" ++
                        "return {s}({s});" ++ "}}",
                    .{ func.return_type, constructor },
                ),
                pos,
                0,
            );
        }
    }

    fn generateConstructor(processor: *Processor, user_type: sema.Scope.Fields, context: *Processor.TraverseContext) !String {
        var constructor = std.ArrayListUnmanaged(u8).empty;
        errdefer constructor.deinit(processor.config.allocator);
        var writer = constructor.writer(processor.config.allocator);

        const fields = user_type.values();
        for (fields, 0..) |field, i| {
            // generate constructor for the struct
            try writeConstructor(writer, field, context);
            if (i < fields.len - 1)
                try writer.writeByte(',');
        }
        return constructor.toOwnedSlice(processor.arena.allocator());
    }

    fn writeConstructor(writer: anytype, t: sema.Symbol.Type, context: *Processor.TraverseContext) !void {
        switch (t) {
            .basic => |basic| {
                try writer.writeAll(basic);
                try writer.writeByte('(');
                if (context.scope.visibleType(basic)) |user_type| {
                    const fields = user_type.values();
                    for (fields, 0..) |field, i| {
                        try writeConstructor(writer, field, context);
                        if (i < fields.len - 1)
                            try writer.writeByte(',');
                    }
                } else {
                    try writer.writeByte('0');
                }
                try writer.writeByte(')');
            },
            .array => |array| {
                try writer.writeAll(array.base);
                for (array.dim) |dim| {
                    try writer.print("[{d}]", .{dim});
                }
                try writer.writeByte('(');
                for (0..array.dim[0]) |i| {
                    try writeConstructor(writer, if (array.dim.len > 1) .{ .array = .{
                        .base = array.base,
                        .dim = array.dim[1..],
                    } } else .{
                        .basic = array.base,
                    }, context);
                    if (i < array.dim[0] - 1)
                        try writer.writeByte(',');
                }
                try writer.writeByte(')');
            },
        }
    }

    /// Increment the virutal step counter (a simulation of instruction counter) and break if the target step is reached.
    fn advanceAndCheck(
        processor: *Processor,
        step_id: usize,
        is_void: bool,
        has_bp: bool,
        context: *Processor.TraverseContext,
    ) !String {
        const bp_cond = "(" ++ step_counter ++ ">={s})";
        const return_init = "{s}({s})";
        return // TODO initialize the empty return type
        if (has_bp)
            if (is_void)
                checkAndHit(processor, bp_cond, .{desired_bp}, step_id, "", .{})
            else
                checkAndHit(
                    processor,
                    bp_cond,
                    .{desired_bp},
                    step_id,
                    return_init,
                    if (context.scope.visibleType(context.function.?.return_type)) |t|
                        .{ context.function.?.return_type, try generateConstructor(processor, t, context) }
                    else
                        .{ context.function.?.return_type, "0" },
                )
        else if (is_void)
            checkAndHit(processor, "", .{}, step_id, "", .{})
        else
            checkAndHit(processor, "", .{}, step_id, return_init, if (context.scope.visibleType(context.function.?.return_type)) |t|
                .{ context.function.?.return_type, try generateConstructor(processor, t, context) }
            else
                .{ context.function.?.return_type, "0" });
    }

    /// Recursively add the functionality: break the caller function after a call to a function with the `name`
    pub fn addGuardsRecursive(
        processor: *Processor,
        func: Processor.TraverseContext.Function,
        context: *Processor.TraverseContext,
    ) (std.mem.Allocator.Error || Error || Processor.Error)!usize {
        const tree = processor.parsed.tree;
        const source = processor.config.source;
        // find references (function calls) to this function
        const calls = processor.parsed.calls.get(func.name) orelse return 0; // skip if the function is never called
        const g = try guarded(processor);
        var processed: usize = calls.count();

        for (calls.keys()) |node| { // it is a .call AST node
            if (g.contains(node)) continue;
            try g.put(processor.config.allocator, node, {});
            //const call = analyzer.syntax.Call.tryExtract(tree, node) orelse return Error.InvalidTree;
            var innermost_statement_span: ?analyzer.parse.Span = null;
            var in_condition_list = false;
            var branches = std.ArrayListUnmanaged(Processor.NodeId){};
            defer branches.deinit(processor.config.allocator);

            // walk up the tree bottom-up to find the caller function
            var parent: ?@TypeOf(tree.root) = tree.parent(node);
            while (parent) |current| : (parent = tree.parent(current)) {
                switch (tree.tag(current)) {
                    .function_declaration => {
                        if (innermost_statement_span) |statement| {
                            const parent_func = try Processor.extractFunction(tree, current, source);
                            const is_parent_void = std.mem.eql(u8, parent_func.return_type, "void");
                            if (branches.items.len > 0) {
                                for (branches.items) |branch| {
                                    if (!g.contains(branch)) {
                                        try guard(processor, is_parent_void, parent_func, branch + 1, context);
                                        try g.put(processor.config.allocator, branch, {});
                                    }
                                }
                            } else try guard(processor, is_parent_void, parent_func, statement.end, context);

                            processed += try addGuardsRecursive(processor, parent_func, context);
                            return processed;
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
                    .declaration => {
                        if (innermost_statement_span == null) {
                            innermost_statement_span = tree.nodeSpan(current);
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
                                                try branches.append(processor.config.allocator, tree.nodeSpanExtreme(@intCast(child), .start));
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

    /// Traverse the tree bottom-up to find the function at this scope
    fn findParentFunc(tree: analyzer.parse.Tree, node: Processor.NodeId) analyzer.syntax.FunctionDeclaration {
        var current = node;
        while (current < tree.nodes.len) : (current = tree.parent(node)) {
            switch (tree.tag(current)) {
                .function_declaration => {
                    return analyzer.syntax.FunctionDeclaration.tryExtract(tree, current);
                },
                else => {
                    // Just continue up
                },
            }
        }
    }
    //#endregion

    //
    //#region Instrumentation frontend interfaces
    //
    pub fn deinitStage(stage: *decls.types.Stage) anyerror!void {
        const s = shaders.Shader.Stage.fromOpaque(stage);
        var channels = &s.program.?.state.?.channels;
        if (controls(channels)) |c| {
            defer c.breakpoints.deinit(s.allocator);
            s.allocator.destroy(c);
            std.debug.assert(channels.controls.swapRemove(id));
        }
        if (responses(channels)) |r| {
            defer r.offsets.deinit(s.allocator);
            s.allocator.destroy(r);
            std.debug.assert(channels.responses.swapRemove(id));
        }
    }

    /// Formatter for inserting the step counter into a string
    const StepStorageName = struct {
        processor: *Processor,
        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            const step_storage = self.processor.outChannel(id).?;
            switch (step_storage.location) {
                .buffer => |_| try writer.writeAll(hit_storage),
                .interface => |i| if (self.processor.parsed.version >= 130 or !self.processor.config.shader_stage.isFragment()) //
                    try writer.writeAll(hit_storage) // will be the step counter
                else
                    try writer.print("gl_FragData[{d}]", .{i.location}),
            }
        }
    };

    pub fn constructors(processor: *Processor, main: Processor.NodeId) anyerror!void {
        const body = processor.parsed.tree.nodeSpanExtreme(main, .start) + 1;

        const step_storage = StepStorageName{ .processor = processor };
        try processor.insertStart(try processor.print("\n{}{s}=0u;{}{s}=0u;\n", .{
            step_storage,
            bufferIndexer(processor, "0"),
            step_storage,
            bufferIndexer(processor, "1"),
        }), body);
        // Insert a check if any previous shader stage did not break already
        try processor.insertStart("if (" ++ sync_storage ++ " != 0) return;", body);
    }

    pub fn renewProgram(program: *decls.instrumentation.Program) anyerror!void {
        const p = shaders.Shader.Program.fromOpaque(program);

        const r = responses(&p.state.?.channels).?;
        r.offsets.clearRetainingCapacity();
        r.reached = null;

        const c = controls(&p.state.?.channels).?;
        c.breakpoints.clearRetainingCapacity();
    }

    /// Creates a buffer for outputting the index of breakpoint which each thread has hit
    /// For some shader stages, it also creates thread indexer variable `global_id`
    pub fn setup(processor: *Processor) anyerror!void {
        const step_storage = try processor.addStorage(
            id,
            .PreferBuffer,
            .@"2U32",
            null,
            null,
        );
        // make the storage fir threads from all stages
        step_storage.size = @max(step_storage.size, processor.threads_total * @sizeOf(Responses.ReachedStep));

        if (processor.config.support.buffers) {
            const sync = try processor.addStorage(sync_id, .Buffer, .@"1U32", null, null);
            sync.size = 1;
            // Declare just the hit synchronisation variable and rely on atomic operations
            // https://stackoverflow.com/questions/56340333/glsl-about-coherent-qualifier
            try processor.insertStart(try processor.print(
                \\layout(std{d}, binding={d}) restrict coherent buffer DeshaderSync {{
            ++ "uint " ++ sync_storage ++ ";\n" ++ //
                \\}};
            , .{
                @as(u16, if (processor.parsed.version >= 430) 430 else 140), //stdXXX
                sync.location.buffer.binding,
            }), processor.after_directives);
        } else if (processor.config.shader_stage.isFragment() and !warned_about_selection) {
            warned_about_selection = true;
            log.warn("Fragment shaders threads cannot be efficiently selected without storage buffer support", .{});
        }

        const storage_name = StepStorageName{ .processor = processor };

        switch (step_storage.location) {
            // -- Beware of spaces --
            .buffer => |buffer| {
                // Declare the global hit storage
                try processor.insertStart(try processor.print(
                    \\layout(std{d}, binding={d}) restrict writeonly buffer DeshaderStepping {{
                ++ "uvec4 " ++ hit_storage ++ "[];\n" ++
                    \\}};
                    \\
                ++ "uint " ++ step_counter ++ "=0u;\n" //
                ++ "bool " ++ local_was_hit ++ "=false;\n", .{
                    @as(u16, if (processor.parsed.version >= 430) 430 else 140), //stdXXX
                    buffer.binding,
                }), processor.after_directives);
            },
            .interface => |location| {
                try processor.insertStart( //
                    "uint " ++ step_counter ++ "=0u;\n" //
                    ++ "bool " ++ local_was_hit ++ "=false;\n", processor.after_directives);

                if (processor.parsed.version >= 130 or !processor.config.shader_stage.isFragment()) {
                    try processor.insertStart(
                        if (processor.parsed.version >= 440) //TODO or check for ARB_enhanced_layouts support
                            try processor.print(
                                \\layout(location={d},component={d}) out
                            ++ " uvec2 {};\n" //
                            , .{ location.location, location.component, storage_name })
                        else
                            try processor.print(
                                \\layout(location={d}) out
                            ++ " uvec2 {};\n" //
                            , .{ location.location, storage_name }),
                        processor.last_interface_decl,
                    );
                }
                // else gl_FragData is implicit
            },
        }

        // step and bp selector uniforms
        try processor.insertEnd("uniform uint " ++ desired_step ++ ";\n", processor.after_directives, 0);
        try processor.insertEnd("uniform uint " ++ desired_bp ++ ";\n", processor.after_directives, 0);

        // #define step adnvance and check macros (for better insturmented code readability)
        try processor.insertEnd(try processor.print(
            "#define {s}{s} (" ++ step_counter ++ "++)\n",
            .{ step_identifier, step_advance },
        ), processor.after_directives, 0);

        try processor.insertEnd(try processor.print(
            "#define {s}{s}(id, cond, ret) if((" ++ step_counter ++ ">=" ++ desired_step ++ ") || cond )" ++
                "{{{s}{s}=id;{s}{s}=" ++ step_counter ++ ";{s}=true;return ret;}}else " ++
                step_counter ++ "++;\n",
            .{
                step_identifier,
                step_if,
                // Store the global step ID as the first component and the step counter as the second component
                storage_name,
                bufferIndexer(processor, "0"),
                storage_name,
                bufferIndexer(processor, "1"),
                local_was_hit,
            },
        ), processor.after_directives, 0);

        try processor.insertEnd(try processor.print(
            "#define {s}(id, ret) if(" ++ step_counter ++ ">=" ++ desired_step ++ ")" ++
                "{{{s}{s}=id;{s}{s}=" ++ step_counter ++ ";{s}=true;return ret;}}else " ++
                step_counter ++ "++;\n",
            .{
                step_identifier,
                // Store the global step ID as the first component and the step counter as the second component
                storage_name,
                bufferIndexer(processor, "0"),
                storage_name,
                bufferIndexer(processor, "1"),
                local_was_hit,
            },
        ), processor.after_directives, 0);
    }

    pub fn finally(processor: *Processor) anyerror!void {
        const g = try guarded(processor);
        g.deinit(processor.config.allocator);
        processor.config.allocator.destroy(g);
    }

    /// Adds "source code stepping" instrumentation to the given source code
    pub fn instrument(
        processor: *Processor,
        node: Processor.NodeId,
        _: ?*const decls.instrumentation.Expression,
        context: *Processor.TraverseContext,
    ) anyerror!void {
        const c = controls(processor.config.program).?;
        const tree = processor.parsed.tree;
        const source = processor.config.source;
        if (analyzer.syntax.Call.tryExtract(tree, node)) |call_ex| {
            const name = call_ex.get(.identifier, tree).?.text(source, tree);
            // _step_(id, ?wrapped_code)
            if (std.mem.eql(u8, name, step_identifier)) {
                var span = tree.nodeSpan(node);
                const context_func = context.function orelse return Error.InvalidStep;
                const step = try extractStep(processor, call_ex);

                // Apply the step/breakpoint instrumentation
                const parent_is_void = std.mem.eql(u8, context_func.return_type, "void");
                const has_breakpoint = c.breakpoints.contains(step.id);

                // Emit step hit => write to the output debug buffer and return
                if (controls(processor.config.program).?.desired_step != null or has_breakpoint) {
                    // insert the step's check'n'break
                    try context.inserts.insertEnd(
                        try advanceAndCheck(processor, step.id, parent_is_void, has_breakpoint, context),
                        span.start,
                        span.length(),
                    );
                } else {
                    // just advance the step counter
                    try context.inserts.insertEnd(
                        try processor.print("{s}{s}{s}", .{
                            step_identifier,                                         step_advance,
                            // not wrapped in expression
                            if (context.inserts == &processor.inserts) ";" else ",",
                        }),
                        span.start,
                        span.length(),
                    );
                }

                // generate: break the execution after returning from a function if something was hit
                _ = try addGuardsRecursive(processor, context_func, context);
                context.instrumented = true;
            }
        }
    }

    //#endregion

    /// Instrumentation preprocessing
    /// TODO relies on the result being empty
    pub fn preprocess(processor: *Processor, source_parts: []*shaders.Shader.SourcePart, result: *std.ArrayListUnmanaged(u8)) anyerror!void {
        const c = try processor.controlVar(id, Controls, true, Controls{});
        const r = try processor.responseVar(id, Responses, true, Responses{});

        // The id of the first step for each part
        var step_id_offset: T = if (r.value_ptr.*.offsets.getLastOrNull()) |last|
            @intCast(last.offset + (try last.part.possibleSteps()).len)
        else
            0;
        for (source_parts) |part| {
            try r.value_ptr.*.offsets.append(processor.config.allocator, StepOffset{
                .part = part,
                .offset = step_id_offset,
            });
            var it = part.step_breakpoints.keyIterator();
            while (it.next()) |b| {
                // report that breakpoints are pending
                try c.value_ptr.*.breakpoints.put(processor.config.allocator, b.* + step_id_offset, {});
            }

            step_id_offset += @intCast(try preprocessPart(part, step_id_offset, result, processor.config.allocator));
        }
    }

    /// Fill `marked` with the insturmented version of the source part
    /// Returns the number of steps in the part
    fn preprocessPart(
        part: *shaders.Shader.SourcePart,
        step_offset: usize,
        marked: *std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,
    ) !usize {
        const part_steps = try part.possibleSteps();
        const part_source = part.getSource().?;
        var prev_offset: usize = 0;

        for (part_steps.items(.offset), part_steps.items(.wrap_next), 0..) |offset, wrap, index| {
            // insert the previous part
            try marked.appendSlice(allocator, part_source[prev_offset..offset]);

            const eol = std.mem.indexOfScalar(u8, part_source[offset..], '\n') orelse part_source.len;
            const line = part_source[offset..][0..eol];

            if (parsePragmaDeshader(line)) { //ignore pragma deshader (hide Deshader from the API)
                //TODO also hide #pragma deshader before the first step
                prev_offset += line.len + 1;
            } else {
                // insert the marker _step_(id, wrapped_code) into the line
                const global_id = step_offset + index;
                const writer = marked.writer(allocator);
                if (wrap > 0) {
                    try writer.print(" {s}({d},{s}) ", .{ step_identifier, global_id, part_source[offset .. offset + wrap] });
                }
                // note the spaces
                try writer.print(" {s}({d}) ", .{ step_identifier, global_id });
                prev_offset = offset + wrap;
            }
        }

        // Insert rest of the source
        try marked.appendSlice(allocator, part_source[prev_offset..]);
        return part_steps.len;
    }

    /// `SourcePart.breakpoints` already contains all breakpoints inserted by pragmas, so the pragmas should be skipped
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
};

/// Stack trace is logged only for the "selected" thread.
pub const StackTrace = struct {
    pub const tag = analyzer.parse.Tag.call;
    pub const id: Processor.Instrument.ID = 0x57ac7ace;
    const storage_name = Processor.templates.prefix ++ "stack_trace";
    const cursor_name = storage_name ++ Processor.templates.cursor;
    /// Each stage has its own thread selector (just for maintaining user selection state persistence per state)
    pub const thread_selector_name = Processor.templates.prefix ++ "selected_thread";

    pub const default_max_entries = 32;
    /// List of global step numbers
    pub const Trace = []Step.T;

    pub fn maxEntries(channels: *Processor.StageChannels, allocator: std.mem.Allocator) !*usize {
        // Stored as a raw numeric value instead of a pointer
        return @ptrCast((try channels.controls.getOrPutValue(allocator, id, @ptrFromInt(default_max_entries))).value_ptr);
    }

    /// Name of the uniform to set to inform this instrument about the selected thread
    pub fn threadSelector(stage: decls.shaders.StageType) String {
        return switch (stage) { // convert runtime value to comptime string
            inline else => |s| comptime thread_selector_name ++ "_" ++ s.toString(),
        };
    }

    pub fn setup(processor: *Processor) anyerror!void {
        const max: usize = (try maxEntries(processor.config.stage, processor.config.allocator)).*;
        const stack_trace = try processor.addStorage(
            id,
            .PreferBuffer,
            .@"4U32",
            null,
            null,
        );
        stack_trace.size = @max(stack_trace.size, max * @sizeOf(Step.T), processor.threads_total * @sizeOf(Step.T));

        try processor.insertStart(try processor.print(
            \\layout(binding={d}) restrict writeonly buffer DeshaderStackTrace {{
        ++ "    uint " ++ storage_name ++ "[];" ++
            \\}};
        ++ "uint " ++ cursor_name ++ "=0u;\n", .{
            stack_trace.location.buffer.binding,
        }), processor.after_directives);

        try processor.insertEnd(
            try processor.print("uniform uint {s};\n", .{threadSelector(processor.config.shader_stage)}),
            processor.after_directives,
            0,
        );
    }

    fn findParentNode(tree: analyzer.parse.Tree, node: Processor.NodeId, needle: analyzer.parse.Tag) ?Processor.NodeId {
        var current = node;
        var t = tree.tag(current);
        while (t != .file) : ({
            if (tree.parent(current)) |p| current = p else return null;
            t = tree.tag(current);
        }) {
            if (t == needle) return current;
        }
        return null;
    }

    /// Insert a stack trace manipulation before and after a function call
    pub fn instrument(
        processor: *Processor,
        node: Processor.NodeId,
        call_return_type: ?*const decls.instrumentation.Expression,
        context: *Processor.TraverseContext,
    ) anyerror!void {
        const tree = processor.parsed.tree;
        if (analyzer.syntax.Call.tryExtract(tree, node)) |call_ex| {
            const call_node = call_ex.get(.identifier, tree).?.node;
            const call_span = tree.token(call_node);
            const name = processor.config.source[call_span.start..call_span.end];
            if (std.mem.eql(u8, name, Step.step_identifier)) {
                return;
            }

            if (call_return_type) |t|
                if (t.is_constant == false)
                    if (try sema.resolveBuiltinFunction(
                        processor.config.allocator,
                        name,
                        &.{},
                        null,
                        &processor.config.spec,
                    ) == null) { // If this is a user function, it has a return type resolved and is not constant
                        //(TODO this will not work when constant propagation is implementd)

                        // Find the nearest step preceeding the call
                        // the steps are ordered by the position in the source code
                        const steps = processor.parsed.calls.get(Step.step_identifier).?.keys();
                        var i = steps.len;
                        // Process steps backwards
                        const step_id = while (i > 0) {
                            i -= 1;
                            const step_node = steps[i];
                            const step_pos = tree.nodeSpanExtreme(step_node, .start);
                            if (step_pos < call_span.start and
                                // check the enclosing statements are the same or next to each other
                                ((findParentNode(tree, call_node, .statement) orelse return Processor.Error.InvalidTree) -
                                    (findParentNode(tree, step_node, .statement) orelse return Processor.Error.InvalidTree)) <= 1)
                                break (Step.extractStep(processor, analyzer.syntax.Call.tryExtract(tree, step_node).?) catch {
                                    log.debug("Failed to extract step from node {d}", .{step_node});
                                    continue;
                                }).id;
                        } else return Error.NoStepNearCall;

                        // Before an user function is called, insert the global step numberinto the stack trace.
                        // if the function is called inside an expr, the stack trace must be manipulated in the set-off expression
                        try context.inserts.insertStart(
                            try processor.print("({s} == " ++ Processor.templates.linear_thread_id ++ " ? " //
                            ++ storage_name ++ "[" ++ cursor_name ++ "++]={d} : " ++ cursor_name ++ ",", .{
                                threadSelector(processor.config.shader_stage),
                                step_id,
                            }),
                            call_span.start,
                        );

                        // the call expression wil be enclosed between (stack_trace_push, call, stack_trace_pop)

                        // pop the stack trace after it is exited
                        try context.inserts.insertEnd(
                            try processor.print(",{s} == " ++ Processor.templates.linear_thread_id ++ " ? " //
                            ++ storage_name ++ "[--" ++ cursor_name ++ "]=0 : " ++ cursor_name ++ ")\n", .{
                                threadSelector(processor.config.shader_stage),
                            }),
                            call_span.end,
                            0,
                        );
                        context.instrumented = true;
                    };
        }
    }

    pub fn stackTrace(allocator: std.mem.Allocator, args: debug.StackTraceArguments) !debug.StackTraceResponse {
        const levels = args.levels orelse 1;
        var result = std.ArrayListUnmanaged(debug.StackFrame){};
        const locator = shaders.Running.Locator.parse(args.threadId);
        const service = try locator.service();

        const stage = service.Shaders.all.get(locator.stage()) orelse return error.TargetNotFound;
        const r = Step.responses(&((stage.program orelse return shaders.Error.NoInstrumentation).state orelse
            return shaders.Error.NoInstrumentation).channels).?;
        if (r.reached) |step| {
            // Find the currently executing step position
            const local = try r.localStep(step.id);

            try result.append(allocator, debug.StackFrame{
                .id = 0,
                .line = local.step.pos.line,
                .column = local.step.pos.character,
                .endColumn = if (local.step.wrap_next > 0) local.step.pos.character + local.step.wrap_next else null,
                .name = "main",
                .path = try service.fullPath(allocator, local.part, false, null),
            });
            if (levels > 1) {
                for (1..levels) |_| {
                    // TODO nesting
                }
            }
        }
        const arr = try result.toOwnedSlice(allocator);

        return debug.StackTraceResponse{
            .stackFrames = arr,
            .totalFrames = if (arr.len > 0) 1 else 0,
        };
    }
};

pub const Log = struct {
    pub const id = 0x106;

    const storage_name = Processor.templates.prefix ++ "log";
    const cursor_name = storage_name ++ Processor.templates.cursor;

    pub const default_max_length = 32;

    /// Log storage length (shared for all shader stages when using buffers). The values is not in this instrument frontend,
    /// but should be instead used in the backend.
    pub fn maxLength(channels: *Processor.StageChannels, allocator: std.mem.Allocator) !*usize {
        // Stored as a raw numeric value instead of a pointer
        return @ptrCast((try channels.controls.getOrPutValue(allocator, id, @ptrFromInt(default_max_length))).value_ptr);
    }

    pub fn setup(processor: *Processor) anyerror!void {
        if (processor.config.support.buffers) {
            const stor = try processor.addStorage(
                id,
                .PreferBuffer,
                .@"4U32",
                null,
                null,
            );
            stor.size = @max(stor.size, (try maxLength(processor.config.stage, processor.config.allocator)).*, processor.threads_total);
            try processor.insertStart(try processor.print(
                \\layout(binding={d}) restrict writeonly buffer DeshaderLog {{
            ++ "uint " ++ cursor_name ++ ";\n" //
            ++ "uint " ++ storage_name ++ "[];\n" ++ //
                \\}};
            , .{
                stor.location.buffer.binding,
            }), processor.after_directives);
        }
    }
};

pub const NormalizeArrays = struct {
    // TODO should preprocess the code so all array declarations have the dimensions next to the type instead of the variable name
};

/// Variables "watching" implementation
pub const Variables = struct {
    //TODO now dumps from all threads. Implement thread selection
    pub const id: Processor.Instrument.ID = 0xa1ab1e5;
    pub const default_max_size = 32;
    pub const default_max_frames = 3;
    /// Name of the uniform array of integers with the length of `Controls.max_frames`. The array should have values from `Controls.dump_frames`.
    pub const frames_name = Processor.templates.prefix ++ "frames";

    pub const tag = analyzer.parse.Tag.call;
    pub const interface_format: Processor.OutputStorage.Location.Format = .@"4U32";

    const another: u64 = 0xa1ab1e50;
    const dependencies = &.{Step.id};
    /// Watches, locals, scopes
    const storage_name = Processor.templates.prefix ++ "variables";

    pub const Controls = struct {
        /// Maximum number of frames to dump. Frames are numbered from the innermost to the outermost.
        ///
        max_frames: usize = default_max_frames,
        /// A set of variable names to dump ("watch")
        filter: std.StringHashMapUnmanaged(void) = .empty,
        /// A list of step IDs at which the variables dump is requested. Muse be kept in sync with `dump_frames`.
        /// Should have at maximum `max_frames` elements.
        dump_steps: std.AutoArrayHashMapUnmanaged(Step.T, void) = .empty,
        /// A list of step counter values at which the variables dump is requested. Must be kept in sync with `dump_steps`.
        /// Should have at maximum `max_frames` elements.
        dump_frames: std.AutoArrayHashMapUnmanaged(Step.T, void) = .empty,
        storage_size: usize = default_max_size,
    };

    pub const Scratch = struct {
        /// Step marker positions in code
        steps: std.AutoHashMapUnmanaged(Step.T, Processor.NodeId) = .empty,
    };

    pub const Responses = struct {
        // TODO precompute all the possible scopes once and reuse them?
        /// Variable scopes and smybols list corresponding to `Controls.dump_steps` and `Controls.dump_frames`
        dump: std.ArrayListUnmanaged(FunctionSnapshot) = .empty,
        /// Did all the variables fit into the storage or would it overflow
        fit: bool = true,
        /// The real storage available for variable readings per shader thread
        real_max_storage: usize = 0,
        storages_count: usize = 0,
        /// At least how many bytes were left unused after the instrument generated all the variables
        unused_storage: usize = 0,
    };

    /// Full snapshot of all variables visible from a certain point in a function.
    /// The scopes are sorted bottom-up from the most nested one to the top-most one.
    pub const FunctionSnapshot = std.ArrayListUnmanaged(sema.Scope.Snapshot);

    /// Index into the global hit indication storage for the current thread
    const BufferIndexer = struct {
        processor: *Processor,
        index: usize,

        pub fn format(
            self: @This(),
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            if (self.processor.outChannel(id).?.location == .buffer) switch (self.processor.config.shader_stage) {
                .gl_vertex => if (self.processor.vulkan)
                    try writer.print("[gl_VertexIndex*{d}]", .{self.index})
                else
                    try writer.print("[gl_VertexID*{d}]", .{self.index}),
                .gl_tess_control => try writer.print("[gl_InvocationID*{d}]", .{self.index}),
                .gl_fragment, .gl_tess_evaluation, .gl_mesh, .gl_task, .gl_compute, .gl_geometry => //
                try writer.print("[" ++ Processor.templates.linear_thread_id ++ "*{d}]", .{self.index}),
                else => unreachable,
            } else try writer.print("[{d}]", .{self.index}); // TODO implement using multiple output storages (`another...`)
        }

        /// Create a copy with a new index
        pub fn i(self: @This(), index: usize) @This() {
            return @This(){
                .processor = self.processor,
                .index = index,
            };
        }
    };

    const MultiIndexer = struct {
        i: ?usize = null,
        /// The upper dimension indexer
        upper: ?*const MultiIndexer = null,

        pub fn format(
            self: @This(),
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            if (self.upper) |n| try writer.print("{}", .{n.*});
            if (self.i) |i| try writer.print("[{d}]", .{i});
        }
    };

    fn checkStorageSize(check: usize, max: usize, variable: String) bool {
        if (check > max) {
            log.debug("Not enough storage for {s}", .{variable});
            return false;
        }
        return true;
    }

    fn controls(processor: *Processor) ?*Controls {
        const from_program = processor.config.program.getControl(*Controls, id);
        std.debug.assert((from_program != null) == isProgramWide(processor));
        // controls are per-stage when the storage is per-stage
        return from_program orelse processor.config.stage.getControl(*Controls, id);
    }

    fn responses(processor: *Processor) ?*Responses {
        const from_program = processor.config.program.getResponse(*Responses, id);
        std.debug.assert((from_program != null) == isProgramWide(processor));
        // responses are per-stage when the storage is per-stage
        return from_program orelse processor.config.stage.getResponse(*Responses, id);
    }

    fn writePrimitive(
        writer: std.ArrayListUnmanaged(u8).Writer,
        variable: String,
        primitive: sema.Type.Normal.Primitive,
        m: ?*const MultiIndexer,
        b: *BufferIndexer,
        wrapped: bool,
    ) !void {
        const has_y = primitive.size_y > 0;
        const y_iter = if (has_y) primitive.size_y else 1;
        const has_x = primitive.size_x > 0;
        const x_iter = if (has_x) primitive.size_x else 1;

        for (0..x_iter) |x| {
            const x_indexer = MultiIndexer{
                .i = if (has_x) x else null,
                .upper = m,
            };
            for (0..y_iter) |y| {
                const y_indexer = MultiIndexer{
                    .i = if (has_y) y else null,
                    .upper = &x_indexer,
                };

                try writeComponent(writer, variable, primitive, y_indexer, b);

                if (wrapped) {
                    if (y < y_iter - 1 or x < x_iter - 1) {
                        try writer.writeAll(",\n");
                    }
                } else {
                    try writer.writeAll(";\n");
                }
            }
        }
    }

    fn writeComponent(
        writer: std.ArrayListUnmanaged(u8).Writer,
        variable: String,
        primitive: sema.Type.Normal.Primitive,
        m: MultiIndexer,
        b: *BufferIndexer,
    ) !void {
        defer b.index += 1;
        try writer.print(storage_name ++ "{} =", .{b});

        switch (primitive.data) {
            .bool => try writer.print("uint({s}{})", .{ variable, m }),

            .uint => try writer.print("{s}{}", .{ variable, m }),

            .int => try writer.print("uint({s}{})", .{ variable, m }),

            .int64_t => {
                try writer.print("unpackUint2x32(uint({s}{}))[0],", .{ variable, m });
                b.index += 1;
                try writer.print(storage_name ++ "{} =", .{b});
                try writer.print("unpackUint2x32(uint({s}{}))[1]", .{ variable, m });
            },

            .uint64_t => {
                try writer.print("unpackUint2x32({s}{}),", .{ variable, m });
                b.index += 1;
                try writer.print(storage_name ++ "{} =", .{b});
                try writer.print("unpackUint2x32({s}{})", .{ variable, m });
            },

            .float => try writer.print("floatBitsToUint({s}{})", .{
                variable, // var name
                m, // vector/matrix indexer
            }) // the data will be aligned to size of uint
            ,

            .double => {
                try writer.print("floatBitsToUint(unpackDouble2x32({s}{})[0]),", .{ variable, m });
                b.index += 1;
                try writer.print(storage_name ++ "{} =", .{b});
                try writer.print("floatBitsToUint(unpackDouble2x32({s}{})[1])", .{ variable, m });
            },
        }
    }

    /// Returns true if the variable write command was issued successfully.
    /// Returns false if the storage is full and the variable could not be written.
    fn writeVariable(
        writer: std.ArrayListUnmanaged(u8).Writer,
        name: String,
        @"type": sema.Type,
        resp: *Responses,
        m: ?*const MultiIndexer,
        b: *BufferIndexer,
        wrapped: bool,
    ) !bool {
        switch (@"type") {
            .array => |array| {
                const dim = array.dim[0];
                const a_size = if (dim == 0) 1 else dim; // TODO what to do if the size is unknown?
                if (array.dim.len > 1) {
                    for (0..a_size) |i| {
                        const a_indexer = MultiIndexer{ .i = i, .upper = m };
                        // Recurse into the array
                        if (!try writeVariable(writer, name, .{ .array = .{
                            .dim = array.dim[1..],
                            .type = array.type,
                        } }, resp, &a_indexer, b, wrapped)) {
                            return false;
                        }
                    }
                } else for (0..a_size) |i| {
                    const a_indexer = MultiIndexer{ .i = i, .upper = m };
                    // Write the underlying type
                    if (!try writeVariable(writer, name, .{ .normal = array.type }, resp, &a_indexer, b, wrapped)) {
                        return false;
                    }

                    if (wrapped) {
                        if (i < a_size - 1) {
                            try writer.writeAll(",\n");
                        }
                    }
                }
            },

            .normal => |normal| switch (normal) {
                .primitive => |primitive| {
                    const total = @max(primitive.size_x, 1) * @max(primitive.size_y, 1);
                    if (!checkStorageSize(total, resp.unused_storage, name)) {
                        return false;
                    }
                    resp.unused_storage -= total;

                    const indexer = MultiIndexer{ .upper = m };
                    try writePrimitive(writer, name, primitive, &indexer, b, wrapped);
                },

                .image => {
                    // Query image size and number of LOD levels
                    if (!checkStorageSize(1, resp.unused_storage, name)) {
                        return false;
                    }
                    resp.unused_storage -= 1;

                    try writer.print(storage_name ++ "{} = imageSize({s},0),\n", .{ b, name });
                    b.index += 1;
                },

                .sampler => {
                    // Query texture size and number of LOD levels

                    if (!checkStorageSize(2, resp.unused_storage, name)) {
                        return false;
                    }
                    resp.unused_storage -= 2;

                    try writer.print(storage_name ++ "{} = textureSize({s},0),\n", .{ b, name });
                    b.index += 1;
                    try writer.print(storage_name ++ "{} = textureQueryLevels({s})", .{ b, name });
                    b.index += 1;
                },

                .@"struct" => {
                    // TODO
                },

                .texture, .void => {},
            },
        }
        return true;
    }

    /// Process the scopes recorded in `instrument()` buttom-up and write the variables to the debug output channel
    pub fn finally(processor: *Processor) anyerror!void {
        const scratch = try processor.scratchVar(id, Scratch, Scratch{});
        defer {
            scratch.value_ptr.steps.deinit(processor.config.allocator);
            processor.config.allocator.destroy(scratch.value_ptr);
        }

        var b = BufferIndexer{
            .processor = processor,
            .index = 0,
        };
        const resp = responses(processor).?;
        const cont = controls(processor).?;
        for (resp.dump.items, 0..) |function_snapshot, frame_index| {
            const step_node: Processor.NodeId = scratch.value_ptr.steps.get(cont.dump_steps.keys()[frame_index]).?;
            const step_span = processor.parsed.tree.nodeSpan(step_node);
            const call = analyzer.syntax.Call.tryExtract(processor.parsed.tree, step_node).?;
            const step = try Step.extractStep(processor, call);

            if (function_snapshot.items.len > 0) {
                const a = processor.arena.allocator();
                // does not need to be deinited when using processor arena
                var command = std.ArrayListUnmanaged(u8).empty;
                var writer = command.writer(a);

                if (step.wrapped) |_| {
                    try writer.print("((" ++ Step.step_counter ++ " == " ++ frames_name ++ "[{d}] - 1) ? (", .{frame_index});
                } else {
                    try writer.print("if(" ++ Step.step_counter ++ " == " ++ frames_name ++ "[{d}] - 1) {{", .{frame_index});
                }
                writing: for (function_snapshot.items) |scope| {
                    var it = scope.filtered.iterator();
                    while (it.next()) |variable| {
                        if (!try writeVariable(writer, variable.key_ptr.*, variable.value_ptr.*, resp, null, &b, step.wrapped != null)) {
                            break :writing;
                        }
                    }
                }
                if (step.wrapped) |_| {
                    try writer.writeAll(") : 0,");
                } else {
                    try writer.writeByte('}');
                }

                try processor.insertStart(command.items, step_span.start);
                if (step.wrapped) |_| {
                    try processor.insertEnd(")", step_span.end, 0);
                }

                if (resp.unused_storage == 0) {
                    break;
                }
            }
        }
    }

    fn getOrCreateControls(processor: *Processor) !Processor.VarResult(Controls) {
        return processor.controlVar(id, Controls, isProgramWide(processor), Controls{});
    }

    fn getOrCreateResponses(processor: *Processor) !Processor.VarResult(Responses) {
        return processor.responseVar(id, Responses, true, Responses{});
    }

    /// A "pre-pass" that fills the `dump` array with the snapshots of scopes
    pub fn instrument(
        processor: *Processor,
        node: Processor.NodeId,
        _: ?*const decls.instrumentation.Expression,
        context: *Processor.TraverseContext,
    ) !void {
        const tree = processor.parsed.tree;
        if (analyzer.syntax.Call.tryExtract(tree, node)) |call| {
            const name = call.get(.identifier, tree).?.text(processor.config.source, tree);
            if (std.mem.eql(u8, name, Step.step_identifier)) {
                const step = try Step.extractStep(processor, call);
                const cont = controls(processor).?;
                if (cont.dump_steps.getIndex(step.id)) |frame_index|
                // variables read is requested at this step
                {
                    const resp = responses(processor).?;
                    const scratch = try processor.scratchVar(id, Scratch, Scratch{});
                    // enumerate and dump scopes and variables
                    var function_snapshot = FunctionSnapshot.empty;

                    var has_variables = false;
                    var scope: ?*sema.Scope = context.scope;
                    while (scope) |s| : (scope = s.parent) {
                        const snapshot = try s.toSnapshot(
                            processor.config.allocator,
                            cont.filter,
                        );
                        if (snapshot.filtered.count() > 0) {
                            has_variables = true;
                        }
                        try function_snapshot.append(processor.config.allocator, snapshot);
                    }

                    try resp.dump.ensureTotalCapacity(processor.config.allocator, frame_index + 1);
                    resp.dump.items[frame_index] = function_snapshot;
                    try scratch.value_ptr.steps.put(processor.config.allocator, @intCast(frame_index), node);

                    if (has_variables) {
                        context.instrumented = true;
                    }
                }
            }
        }
    }

    fn isProgramWide(processor: *Processor) bool {
        return processor.outChannel(id).?.location == .buffer;
    }

    pub fn setup(processor: *Processor) anyerror!void {
        const stor = try processor.addStorage(
            id,
            .PreferBuffer,
            interface_format,
            if (processor.parsed.version >= 440 and processor.config.shader_stage.isFragment())
                if (processor.outChannel(Step.id)) |s| s.location else null
            else
                null,
            1,
        );

        // controls and responses creation must be done after the storage creation for `isProgramWide()` to work
        const c = try getOrCreateControls(processor);
        const r = try getOrCreateResponses(processor);
        _ = try processor.scratchVar(id, Scratch, Scratch{});

        if (r.found_existing) {
            r.value_ptr.dump.clearRetainingCapacity();
        }
        const requested_size = c.value_ptr.storage_size;
        // TODO really figure out the real max storage size
        r.value_ptr.real_max_storage = requested_size;

        switch (stor.location) {
            .buffer => |buffer| {
                stor.size = requested_size * processor.threads_total;

                try processor.insertStart(
                    try processor.print(
                        \\layout(binding={d}) restrict buffer DeshaderVariables {{
                    ++ "uvec4 {s}[];\n" ++ //
                        \\}};
                    , .{
                        buffer.binding,
                        storage_name,
                    }),
                    processor.after_directives,
                );
                r.value_ptr.storages_count = 1;
                r.value_ptr.unused_storage = requested_size;
            },
            .interface => |location| {
                //TODO not tested, just a draft
                if (processor.config.shader_stage.isFragment()) {
                    if (processor.parsed.version >= 130) {
                        try processor.insertStart(
                            try if (location.component != 0)
                                processor.print(
                                    \\layout(location={d},component={d}) out uvec{d} {s}0;
                                , .{ location.location, location.component, 4 - location.component, storage_name })
                            else
                                processor.print("layout(location={d}) out uvec4 {s};\n", .{ location.location, storage_name }),
                            processor.last_interface_decl,
                        );
                    } // else gl_FragData is implicit
                } else {
                    try processor.insertStart(
                        try processor.print("layout(location={d}) out uvec4 " ++ storage_name ++ ";\n", .{location.location}),
                        processor.last_interface_decl,
                    );
                }
                r.value_ptr.storages_count = 1;
                r.value_ptr.unused_storage = interface_format.sizeInBytes();

                const interface_size = processor.threads_total * interface_format.sizeInBytes();
                var remainig_result = std.math.sub(usize, requested_size, interface_size);
                if (remainig_result) |*remainig| { // create storages for the remaining requested data size
                    stor.size = remainig.* * processor.threads_total;
                    var i: usize = 0;
                    while (remainig.* > 0) : (remainig.* -= interface_format.sizeInBytes()) {
                        defer i += 1;
                        const another_stor = try processor.addStorage(
                            another + i,
                            .PreferBuffer,
                            interface_format,
                            null,
                            null,
                        );
                        another_stor.size = blk: switch (another_stor.location) {
                            .interface => |interface| {
                                try processor.insertStart(
                                    try processor.print("layout(location={d}) out uvec4 {s}{d};", .{ interface.location, storage_name, i }),
                                    processor.last_interface_decl,
                                );
                                r.value_ptr.unused_storage += interface_format.sizeInBytes();
                                break :blk interface_size;
                            },
                            .buffer => |buffer| {
                                try processor.insertStart(try processor.print(
                                    \\layout(binding={d}) restrict buffer DeshaderVariables{d} {{
                                ++ "uvec4 " ++ storage_name ++ "{d}[];\n" ++ //
                                    \\}};
                                , .{
                                    buffer.binding,
                                    i,
                                    i,
                                }), processor.after_directives);
                                r.value_ptr.unused_storage += remainig.*;
                                break :blk remainig.* * processor.threads_total;
                            },
                        };
                        r.value_ptr.storages_count += 1;
                    }
                } else |_| {}
            },
        }

        try processor.insertStart(
            try processor.print("uniform uint " ++ frames_name ++ "[{d}];\n", .{c.value_ptr.max_frames}),
            processor.after_directives,
        );
    }
};
