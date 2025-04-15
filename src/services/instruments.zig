const std = @import("std");
const analyzer = @import("glsl_analyzer");
const log = @import("common").log;
const shaders = @import("shaders.zig");
const debug = @import("debug.zig");
const decls = @import("../declarations/shaders.zig");

const Processor = @import("processor.zig");

const String = []const u8;
const CString = []const u8;

pub const Error = error{ InvalidStep, FunctionNotInScope };

pub const Step = struct {
    pub var step_identifier: String = "_step_";
    pub const tag = analyzer.parse.Tag.call;
    pub const id: u64 = 0x57e9;
    pub const sync_id: u64 = 0x51c;

    pub const breakpoints_id: u64 = 0x0b5ea7;

    pub const Controls = struct {
        breakpoints: std.AutoHashMapUnmanaged(usize, void) = .empty,
        desired_step: ?u32 = null,
        /// Index for the step counter to check for.
        /// Set to non-null value to enable stepping.
        /// Same numbering as for `desired_step`, but is checked only on places with breakpoints.
        desired_bp: u32 = 0,
    };

    /// Client debugger state. Program-wide. Does not directly affect the instrumentation
    pub const Responses = struct {
        /// If source stepping is ongoing, this is the global index of the currently reached step.
        /// Can be used for the purpose of advancing target step index with `desired_step = reached_step.id + 1`.
        reached_step: ?struct {
            /// The step's index in the `SourcePart.possibleSteps'. The shader can be found in `offsets[offset]`.
            step: u32,
            /// Index into `Responses.offsets`
            offset: u32,
        } = null,
        /// Uses service's allocator
        offsets: std.ArrayListUnmanaged(StepOffset) = .empty,

        /// Computes the part index and an offset into its `steps` array from the global step index returned by instrumented shader invocation.
        pub fn localStepOffset(self: *const @This(), global_step: usize) !StepOffset {
            for (self.offsets.items) |offset| {
                if (global_step <= offset.offset) {
                    return offset;
                }
            }
            return Error.InvalidStep;
        }

        pub const LocalStep = struct {
            part: *shaders.Shader.SourcePart,
            step: shaders.Shader.SourcePart.Step,
        };
        pub fn localStep(self: *const @This(), global_step: usize) !LocalStep {
            const offset = try self.localStepOffset(global_step);
            return LocalStep{
                .part = offset.part,
                .step = offset.part.possible_steps.?.get(global_step - offset.offset),
            };
        }
    };

    pub const StepOffset = struct {
        part: *shaders.Shader.SourcePart,
        /// Offset of the step indexes array in respect to the global step counter for this `SourcePart`
        offset: usize,
    };

    const Guarded = std.AutoHashMapUnmanaged(Processor.NodeId, void);

    const hit_storage = Processor.templates.prefix ++ "global_hit_id";
    const was_hit = Processor.templates.prefix ++ "global_was_hit";
    const step_counter = Processor.templates.prefix ++ "step_counter";
    const local_was_hit = Processor.templates.prefix ++ "was_hit";
    pub const sync_storage = Processor.templates.prefix ++ "global_sync";

    pub const desired_bp = Processor.templates.prefix ++ "desired_bp";
    pub const desired_step = Processor.templates.prefix ++ "desired_step";

    pub fn controls(channels: *Processor.Channels) ?*Controls {
        return channels.getControl(*Controls, id);
    }

    pub fn responses(channels: *Processor.Channels) ?*Responses {
        return channels.getResponse(*Responses, id);
    }

    fn guarded(processor: *Processor) !*Guarded {
        const gop = try processor.scratchVar(id, Guarded, null);
        if (!gop.found_existing) {
            @branchHint(.cold);
            const new = processor.config.allocator.create(Guarded) catch return error.OutOfMemory;
            new.* = Guarded.empty;
            gop.value_ptr.* = new;
        }
        return @alignCast(@ptrCast(gop.value_ptr.*));
    }

    //
    //#region External interface
    //
    pub fn disableBreakpoints(service: *shaders, shader_ref: shaders.Shader.StageRef) !void {
        const shader: *std.ArrayListUnmanaged(shaders.Shader.SourcePart) = service.Shaders.all.get(shader_ref) orelse return error.TargetNotFound;
        const state = service.state.getPtr(shader_ref) orelse return error.NotInstrumented;
        const c = controls(&shader.program.?.channels).?;

        c.desired_bp = std.math.maxInt(u32); // TODO shader uses u32. Would 64bit be a lot slower?

        state.dirty = true;
    }

    /// Continue to next breakpoint hit or end of the shader
    pub fn @"continue"(service: *shaders, shader_ref: shaders.Shader.StageRef) !void {
        const shader = service.Shaders.all.get(shader_ref) orelse return error.TargetNotFound;
        const state = service.state.getPtr(shader_ref) orelse return error.NotInstrumented;
        const c = controls(&shader.items[0].program.?.channels).?;
        const r = responses(&shader.items[0].program.?.channels).?;

        c.desired_bp = (if (r.reached_step) |s| s.offset else 0) +% 1;
        if (c.desired_step) |_| {
            c.desired_step = std.math.maxInt(u32);
        }

        for (shader.items) |*s| {
            s.b_dirty = true;
        }
        state.dirty = true;
    }

    /// Increments the desired step (or also desired breakpoint) selector for the shader `shader_ref`.
    pub fn advanceStepping(service: *shaders, shader_ref: shaders.Shader.StageRef, target: ?u32) !void {
        const shader: *std.ArrayListUnmanaged(shaders.Shader.SourcePart) = service.Shaders.all.get(shader_ref) orelse return error.TargetNotFound;

        const state = service.state.getPtr(shader_ref) orelse return error.NotInstrumented;
        const r = responses(&shader.items[0].program.?.channels).?;
        const c = controls(&shader.items[0].program.?.channels).?;
        const next = (if (r.reached_step) |s| s.offset else 0) +% 1;
        if (c.desired_step == null) {
            // invalidate instrumentated code because stepping was previously disabled
            state.dirty = true;
        }

        if (target) |t| {
            c.desired_step = t;
            c.desired_bp = t;
        } else {
            c.desired_step = next; //TODO limits
            c.desired_bp = next;
        }

        for (shader.items) |*s| {
            s.b_dirty = true;
        }
    }

    pub fn disableStepping(service: *shaders, shader_ref: shaders.Shader.StageRef) !void {
        const state = service.state.getPtr(shader_ref) orelse return error.NotInstrumented;
        const shader: *std.ArrayListUnmanaged(shaders.Shader.SourcePart) = service.Shaders.all.get(shader_ref) orelse return error.TargetNotFound;
        const c = controls(&shader.program.?.channels).?;

        if (c.desired_step) {
            c.desired_step = null;
            state.dirty = true;
        }
    }
    //#endregion

    //
    //#region Instrumentation primitives/helpers
    //

    /// Index into the global hit indication storage for the current thread
    fn bufferIndexer(processor: *Processor, comptime component: String) String {
        return if (processor.channels.out.get(id).?.location == .buffer) switch (processor.config.shader_stage) {
            .gl_vertex => if (processor.vulkan) "[gl_VertexIndex/2][(gl_VertexIndex%2)*2+" ++ component ++ "]" else "[gl_VertexID/2][(gl_VertexID%2)*2+" ++ component ++ "]",
            .gl_tess_control => "[gl_InvocationID/2*][(gl_InvocationID%2)*2+" ++ component ++ "]",
            .gl_fragment, .gl_tess_evaluation, .gl_mesh, .gl_task, .gl_compute, .gl_geometry => "[" ++ Processor.templates.global_thread_id ++ "/2][(" ++ Processor.templates.global_thread_id ++ "%2)*2+" ++ component ++ "]",
            else => unreachable,
        } else "[" ++ component ++ "]";
    }

    fn checkAndHit(processor: *Processor, comptime cond: String, cond_args: anytype, step_id: usize, comptime ret: String, ret_args: anytype, comptime append: String, args: anytype) !String {
        const name = StepStorageName{ .processor = processor };
        return try processor.print("if((" ++ step_counter ++ "++>={s})" ++ cond ++ "){{{s}{s}={d};{s}{s}=" ++ step_counter ++ ";{s}=true;return " ++ ret ++ ";}}" ++ append, //
            .{desired_step} ++ cond_args ++ .{ name, bufferIndexer(processor, "0"), step_id, name, bufferIndexer(processor, "1"), local_was_hit } ++ ret_args ++ args);
    }

    /// Inserts a guard to break the function `func` if a step or breakpoint was hit already. Should be inserted after a call to any user function.s
    fn guard(processor: *Processor, is_void: bool, func: Processor.Processor.TraverseContext.Function, pos: usize) !void {
        try processor.insertEnd(try processor.print(
            "if(" ++ local_was_hit ++ ")return {s}{s};",
            if (is_void) .{ "", "" } else .{ func.return_type, "(0)" }, //TODO in ESSL struct must be initialized
        ), pos, 0);
    }

    fn advanceAndCheck(processor: *Processor, step_id: usize, func: Processor.Processor.TraverseContext.Function, is_void: bool, has_bp: bool, comptime append: String, args: anytype) !String {
        const bp_cond = "||(" ++ step_counter ++ ">{s})";
        const return_init = "{s}(0)";
        return // TODO initialize structs for returning
        if (has_bp)
            if (is_void)
                checkAndHit(processor, bp_cond, .{desired_bp}, step_id, "", .{}, append, args)
            else
                checkAndHit(processor, bp_cond, .{desired_bp}, step_id, return_init, .{func.return_type}, append, args)
        else if (is_void)
            checkAndHit(processor, "", .{}, step_id, "", .{}, append, args)
        else
            checkAndHit(processor, "", .{}, step_id, return_init, .{func.return_type}, append, args);
    }

    /// Recursively add the functionality: break the caller function after a call to a function with the `name`
    pub fn addGuardsRecursive(processor: *Processor, func: Processor.TraverseContext.Function) (std.mem.Allocator.Error || Error || Processor.Error)!usize {
        const tree = processor.parsed.tree;
        const source = processor.config.source;
        // find references (function calls) to this function
        const calls = processor.parsed.calls.get(func.name) orelse return 0; // skip if the function is never called
        var processed: usize = calls.items.len;
        for (calls.items) |node| { // it is a .call AST node
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
                                const g = try guarded(processor);
                                for (branches.items) |branch| {
                                    if (!g.contains(branch)) {
                                        try guard(processor, is_parent_void, parent_func, branch + 1);
                                        try g.put(processor.config.allocator, branch, {});
                                    }
                                }
                            } else try guard(processor, is_parent_void, parent_func, statement.end);

                            processed += try addGuardsRecursive(processor, parent_func);
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
    pub fn deinit(state: *shaders.State) anyerror!void {
        if (controls(&state.params.context.program.channels)) |c| {
            defer c.breakpoints.deinit(state.params.allocator);
        }
        if (responses(&state.params.context.program.channels)) |r| {
            defer r.offsets.deinit(state.params.allocator);
        }
    }

    /// Formatter for inserting the step counter into a string
    const StepStorageName = struct {
        processor: *Processor,
        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            const step_storage = self.processor.channels.out.get(id).?;
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
        const step_storage = StepStorageName{ .processor = processor };
        try processor.insertStart(try processor.print("{}{s}=0u;{}{s}=0u;\n", .{
            step_storage,
            bufferIndexer(processor, "0"),
            step_storage,
            bufferIndexer(processor, "1"),
        }), processor.parsed.tree.nodeSpanExtreme(main, .start) + 1);
    }

    /// Creates a buffer for outputting the index of breakpoint which each thread has hit
    /// For some shader stages, it also creates thread indexer variable `global_id`
    pub fn setup(processor: *Processor) anyerror!void {
        const step_storage = try processor.addStorage(
            id,
            processor.channels.totalThreadsCount() * 2,
            .PreferBuffer,
            .@"2U32",
            null,
            null,
        );

        if (processor.config.support.buffers) {
            const sync = try processor.addStorage(sync_id, 1, .Buffer, .@"1U32", null, null);
            // Declare just the hit synchronisation variable and rely on atomic operations https://stackoverflow.com/questions/56340333/glsl-about-coherent-qualifier
            try processor.insertStart(try processor.print(
                \\layout(std{d}, binding={d}) buffer DeshaderSync {{
            ++ "uint " ++ sync_storage ++ ";\n" ++ //
                \\}};
            , .{
                @as(u16, if (processor.parsed.version >= 430) 430 else 140), //stdXXX
                sync.location.buffer.binding,
            }), processor.after_version);
        }

        switch (step_storage.location) {
            // -- Beware of spaces --
            .buffer => |buffer| {
                // Declare the global hit storage
                try processor.insertStart(try processor.print(
                    \\layout(std{d}, binding={d}) buffer DeshaderStepping {{
                ++ "uvec4 " ++ hit_storage ++ "[{d}];\n" ++
                    \\}};
                    \\
                ++ "uint " ++ step_counter ++ "=0u;\n" //
                ++ "bool " ++ local_was_hit ++ "=false;\n", .{
                    @as(u16, if (processor.parsed.version >= 430) 430 else 140), //stdXXX
                    buffer.binding,
                    processor.threads_total / 2,
                }), processor.after_version);
            },
            .interface => |location| {
                try processor.insertStart( //
                    "uint " ++ step_counter ++ "=0u;\n" //
                    ++ "bool " ++ local_was_hit ++ "=false;\n", processor.after_version);

                const storage_name = StepStorageName{ .processor = processor };

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
        try processor.insertEnd("uniform uint " ++ desired_step ++ ";\n", processor.after_version, 0);
        try processor.insertEnd("uniform uint " ++ desired_bp ++ ";\n", processor.after_version, 0);
    }

    pub fn setupDone(processor: *Processor) anyerror!void {
        const g = try guarded(processor);
        g.deinit(processor.config.allocator);
        processor.config.allocator.destroy(g);
    }

    /// Adds "source code stepping" instrumentation to the given source code
    pub fn instrument(processor: *Processor, node: Processor.NodeId, context: *Processor.TraverseContext) anyerror!void {
        const c = controls(&processor.config.program).?;
        const tree = processor.parsed.tree;
        const source = processor.config.source;
        if (analyzer.syntax.Call.tryExtract(tree, node)) |call_ex| {
            const name = call_ex.get(.identifier, tree).?.text(source, tree);
            // _step_(id, ?wrapped_code)
            if (std.mem.eql(u8, name, step_identifier)) {
                var span = tree.nodeSpan(node);
                const step_args: analyzer.syntax.ArgumentsList = call_ex.get(.arguments, tree) orelse return Error.InvalidStep;
                const context_func = context.function orelse return Error.InvalidStep;
                var args_it = step_args.iterator();

                const step_arg: analyzer.syntax.Argument = args_it.next(tree) orelse return Error.InvalidStep; // get the first argument
                const step_arg_expr: analyzer.syntax.Expression = step_arg.get(.expression, tree) orelse return Error.InvalidStep; // extract the expression node construct from the argument
                // step hit records are 1-based, 0 is reserved for no hit
                const step_id = try std.fmt.parseInt(usize, tree.nodeSpan(step_arg_expr.node).text(source), 0);

                // Apply the step/breakpoint instrumentation
                const parent_is_void = std.mem.eql(u8, context_func.return_type, "void");
                const has_breakpoint = c.breakpoints.contains(step_id);

                // Emit step hit => write to the output debug buffer and return
                if (controls(&processor.config.program).?.desired_step != null or has_breakpoint) {
                    // insert the step's check'n'break
                    try processor.insertEnd(
                        try advanceAndCheck(processor, step_id, context_func, parent_is_void, has_breakpoint, "", .{}),
                        span.start,
                        span.length(),
                    );
                } else {
                    // just remove the __step__() identifier
                    try processor.insertEnd(
                        "",
                        span.start,
                        span.length(),
                    );
                }

                // generate: break the execution after returning from a function if something was hit
                _ = try addGuardsRecursive(processor, context_func);
                context.instrumented = true;
            }
        }
    }

    //#endregion

    /// Instrumentation preprocessing
    /// TODO relies on the result being empty
    pub fn preprocess(processor: *Processor, source_parts: []*shaders.Shader.SourcePart, result: *std.ArrayListUnmanaged(u8)) anyerror!void {
        _ = try processor.controlVar(id, Controls, true, Controls{});
        const r = try processor.responseVar(id, Responses, true, Responses{});

        // The id of the first step for each part
        var step_offset: usize = if (r.value_ptr.*.offsets.getLastOrNull()) |last|
            last.offset + (try last.part.possibleSteps()).len
        else
            0;
        for (source_parts) |part| {
            try r.value_ptr.*.offsets.append(processor.config.allocator, StepOffset{
                .part = part,
                .offset = step_offset,
            });
            step_offset += try preprocessPart(part, step_offset, result, processor.config.allocator);
        }
    }

    /// Fill `marked` with the insturmented version of the source part
    /// Returns the number of steps in the part
    fn preprocessPart(part: *shaders.Shader.SourcePart, step_offset: usize, marked: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !usize {
        const part_steps = try part.possibleSteps();
        const part_source = part.getSource().?;
        var prev_offset: usize = 0;

        for (part_steps.items(.offset), part_steps.items(.wrap_next), 0..) |offset, wrap, index| {
            // insert the previous part
            try marked.appendSlice(allocator, part_source[prev_offset..offset]);

            const eol = std.mem.indexOfScalar(u8, part_source[offset..], '\n') orelse part_source.len;
            const line = part_source[offset..][0..eol];

            if (parsePragmaDeshader(line)) { //ignore pragma deshader (hide Deshader from the API)
                prev_offset += line.len;
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
    pub const id: u64 = 0x57ac7ace;
    const storage_name = Processor.templates.prefix ++ "stack_trace";
    const cursor_name = storage_name ++ Processor.templates.cursor;
    /// Each stage has its own thread selector (just for maintaining user selection state persistence per state)
    pub const thread_selector_name = Processor.templates.prefix ++ "selected_thread";

    pub const default_max_entries = 32;
    /// Type of one stack trace entry (function handle)
    pub const StackTraceT = u32;

    pub fn maxEntries(channels: *Processor.Result.Channels, allocator: std.mem.Allocator) !*usize {
        // Stored as a raw numeric value instead of a pointer
        return @ptrCast((try channels.controls.getOrPutValue(allocator, id, @ptrFromInt(default_max_entries))).value_ptr);
    }

    pub fn threadSelector(stage: decls.Stage) String {
        return switch (stage) { // convert runtime value to comptime string
            inline else => |s| comptime thread_selector_name ++ "_" ++ s.toString(),
        };
    }

    pub fn setup(processor: *Processor) anyerror!void {
        const max: usize = (try maxEntries(&processor.channels, processor.config.allocator)).*;
        const stack_trace = try processor.addStorage(
            id,
            max * @sizeOf(StackTraceT),
            .PreferBuffer,
            .@"4U32",
            null,
            null,
        );

        try processor.insertStart(try processor.print(
            \\layout(binding={d}) restrict writeonly buffer DeshaderStackTrace {{
        ++ "    uint " ++ storage_name ++ "[];" ++
            \\}};
        ++ "uint " ++ cursor_name ++ "=0u;\n", .{
            stack_trace.location.buffer.binding,
        }), processor.after_version);

        try processor.insertEnd(try processor.print("uniform uint {s};\n", .{threadSelector(processor.config.shader_stage)}), processor.after_version, 0);
    }

    /// Insert a stack trace manipulation before and after a function call
    pub fn instrument(processor: *Processor, node: Processor.NodeId, context: *Processor.TraverseContext) anyerror!void {
        const tree = processor.parsed.tree;
        if (analyzer.syntax.Call.tryExtract(tree, node)) |call_ex| {
            const name = call_ex.get(.identifier, tree).?.text(processor.config.source, tree);
            if (std.mem.eql(u8, name, Step.step_identifier)) {
                return;
            }

            const func = context.scope.functions.get(name) orelse return Error.FunctionNotInScope;
            // Before a user function is called, insert its id into the STACK_TRACE.
            // if the function is called inside an expr, the stack trace must be manipulated in the set-off expression
            try context.inserts.insertStart(
                try processor.print("({s} == " ++ Processor.templates.global_thread_id ++ " ? " //
                ++ storage_name ++ "[" ++ cursor_name ++ "++]={d}:" ++ cursor_name ++ ",", .{
                    threadSelector(processor.config.shader_stage),
                    func.id,
                }),
                tree.nodeSpanExtreme(node, .start),
            );

            // the call expression wil be enclosed between (stack_trace_push, call, stack_trace_pop)

            // pop the stack trace after it is exited
            try context.inserts.insertEnd(
                try processor.print(",{s} == " ++ Processor.templates.global_thread_id ++ " ? " //
                ++ storage_name ++ "[--" ++ cursor_name ++ "]=0:" ++ cursor_name ++ ")", .{
                    threadSelector(processor.config.shader_stage),
                }),
                tree.nodeSpanExtreme(node, .end),
                0,
            );
            context.instrumented = true;
        }
    }

    pub fn stackTrace(allocator: std.mem.Allocator, args: debug.StackTraceArguments) !debug.StackTraceResponse {
        const levels = args.levels orelse 1;
        var result = std.ArrayListUnmanaged(debug.StackFrame){};
        const locator = shaders.Running.Locator.parse(args.threadId);
        const service = try locator.service();

        const shader = service.Shaders.all.get(locator.shader()) orelse return error.TargetNotFound;
        const r = Step.responses(&shader.items[0].program.?.channels).?;
        if (r.reached_step) |global_step| {
            // Find the currently executing step position
            const local = try r.localStep(global_step.step);

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

    /// Log storage length (shared for all shader stages when using buffers). The values is not in this instrument frontend, but should be instead used in the backend.
    pub fn maxLength(channels: *Processor.Result.Channels, allocator: std.mem.Allocator) !*usize {
        // Stored as a raw numeric value instead of a pointer
        return @ptrCast((try channels.controls.getOrPutValue(allocator, id, @ptrFromInt(default_max_length))).value_ptr);
    }

    pub fn setup(processor: *Processor) anyerror!void {
        if (processor.config.support.buffers) {
            const storage = try processor.addStorage(
                id,
                (try maxLength(&processor.channels, processor.config.allocator)).*,
                .PreferBuffer,
                .@"4U32",
                null,
                null,
            );
            try processor.insertStart(try processor.print(
                \\layout(binding={d}) restrict writeonly buffer DeshaderLog {{
            ++ "uint " ++ cursor_name ++ ";\n" //
            ++ "uint " ++ storage_name ++ "[];\n" ++ //
                \\}};
            , .{
                storage.location.buffer.binding,
            }), processor.after_version);
        }
    }
};

pub const Variables = struct {
    const id: u64 = 0xa1ab1e5;
    const another: u64 = 0xa1ab1e50;
    const actual = 0xac7a1;
    /// Watches, locals, scopes
    const storage_name = Processor.templates.prefix ++ "variables";

    pub const default_max_size = 32;

    /// Variable storage size (shared for all shader stages when using buffers)
    pub fn maxSize(channels: *Processor.Result.Channels, allocator: std.mem.Allocator) !*usize {
        // Stored as a raw numeric value instead of a pointer
        return @ptrCast((try channels.controls.getOrPutValue(allocator, id, @ptrFromInt(default_max_size))).value_ptr);
    }

    pub fn actualSize(channels: *Processor.Result.Channels) !*usize {
        return @ptrCast((try channels.controls.getOrPut(actual)).value_ptr);
    }

    pub fn setup(processor: *Processor) anyerror!void {
        const size = try maxSize(&processor.channels, processor.config.allocator).*;
        const storage = try processor.addStorage(
            id,
            0,
            .PreferBuffer,
            .@"4U32",
            if (processor.parsed.version >= 440 and processor.config.shader_stage.isFragment()) if (processor.channels.out.get(Step.id)) |s| s.location else null else null,
            1,
        );

        switch (storage.location) {
            .buffer => |buffer| {
                storage.size = size;

                try processor.insertStart(
                    try processor.print(
                        \\layout(binding={d}) restrict buffer DeshaderVariables {{
                    ++ "uint {s}[];\n" ++ //
                        \\}};
                    , .{
                        buffer.binding,
                        storage_name,
                    }),
                    processor.after_version,
                );
            },
            .interface => |location| {
                if (processor.config.shader_stage.isFragment()) {
                    if (processor.parsed.version >= 130) {
                        try processor.insertStart(try if (location.component != 0)
                            processor.print(
                                \\layout(location={d},component={d}) out uvec{d} {s}0;
                            , .{ location.location, location.component, 4 - location.component, storage_name })
                        else
                            processor.print("layout(location={d}) out uvec4 {s};\n", .{ location.location, storage_name }), processor.last_interface_decl);
                    } // else gl_FragData is implicit
                } else {
                    try processor.insertStart(try processor.print("layout(location={d}) out uvec4 " ++ storage_name ++ ";\n", .{location.location}), processor.last_interface_decl);
                }

                const interface_size: isize = processor.channels.totalThreadsCount() * 4 * @sizeOf(u32);
                const remainig: isize = size - interface_size;
                if (remainig > 0) {
                    storage.size = remainig;
                    var i: usize = 0;
                    while (remainig > 0) : (remainig -= (4 * @sizeOf(u32))) {
                        defer i += 1;
                        const stor = try processor.addStorage(
                            another + i,
                            0,
                            .PreferBuffer,
                            .@"4U32",
                            null,
                            null,
                        );
                        switch (stor.location) {
                            .interface => |interface| {
                                try processor.insertStart(try processor.print("layout(location={d}) out uvec4 {s}{d};", .{ interface.location, storage_name, i }), processor.last_interface_decl);
                                stor.size = interface_size;
                            },
                            .buffer => |buffer| {
                                try processor.insertStart(try processor.print(
                                    \\layout(binding={d}) restrict buffer DeshaderVariables{s} {{
                                ++ "uint {s}{d}[];\n" ++ //
                                    \\}};
                                , .{
                                    buffer.binding,
                                    i,
                                    storage_name,
                                    i,
                                }), processor.after_version);

                                stor.size = remainig;
                                break;
                            },
                        }
                    }
                }
            },
        }

        try processor.insertStart("uint {s}" ++ storage_name ++ Processor.templates.cursor ++ "=0u;\n", processor.after_version);
    }
};
