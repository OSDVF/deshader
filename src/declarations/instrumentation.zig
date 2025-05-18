const types = @import("types.zig");
const PlatformRef = types.PlatformRef;
const Stage = types.Stage;
// #STUBS START HERE

pub const NodeId = u32;
pub const InstrumentId = u64;
pub const ReadbackId = u64;

/// Will be `PlatformParamsGL` or `PlatformParamsVulkan` depending on the backend.
pub const Platform = opaque {};
pub const Processor = opaque {};
pub const Program = opaque {};
pub const Readbacks = opaque {};
pub const Service = opaque {};
pub const State = opaque {};
pub const TraverseContext = opaque {};

// Must be placed before `Expression` to support translating to C
pub const Type = extern struct {
    basic: [*:0]const u8,
    /// Dimensions of array
    array: ?[*:0]const usize = null,
};

pub const Expression = extern struct {
    type: Type,
    is_constant: bool = false,
    constant: u64 = 0,
};

/// Stateless instrument processor which is used for operating with shader source code.
pub const InstrumentProcessor = extern struct {
    instrument: ?*const fn (processor: *Processor, node: NodeId, result: ?*const Expression, context: *TraverseContext) usize,
    constructors: ?*const fn (processor: *Processor, main: NodeId) usize,
    renewProgram: ?*const fn (program: *Program) usize,
    renewStage: ?*const fn (stage: *Stage) usize,
    setup: ?*const fn (processor: *Processor) usize,
    collect: ?*const fn () void, //TODO
};

/// The stateful instrument service which is specific to the backend. Operates within the draw loop.
pub const InstrumentClient = extern struct {
    deinit: ?*const fn (state: *State) void,
    /// Should be used to update uniforms and other state before the draw call.
    ///
    /// WARNING: `Shader.Program.State.uniforms_dirty` is cleared after every instrument-clients' `onBeforeDraw` callback was called.
    onBeforeDraw: ?*const fn (service: *Service, instrumentation: Result) usize,
    /// `platform` can be `PlatformParamsGL` or `PlatformParamsVK`
    onResult: ?*const fn (
        service: *Service,
        instrumentation: Result,
        readbacks: *const Readbacks,
        platform: *const Platform,
    ) usize,
    onRestore: ?*const fn (service: *Service) usize,
};

pub const PlatformParamsGL = struct {
    /// Framebuffer which has all the debugging outputs attached
    fbo: c_uint,

    pub fn toOpaque(self: *const @This()) *const Platform {
        return @ptrCast(self);
    }
};

pub const PlatformParamsVK = struct {
    pub fn toOpaque(self: *const @This()) *const Platform {
        return @ptrCast(self);
    }
};

pub const Readback = struct {
    data: []u8,
    ref: PlatformRef,
};

/// Result for one `Program` instrumentation
pub const Result = struct {
    /// True if any of the shader stages was re-instrumented (aggregate of `State.dirty`)
    instrumented: bool,
    program: *Program,
};
