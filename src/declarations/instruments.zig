pub const NodeId = u32;
pub const InstrumentId = u64;

pub const Instrumentation = opaque {};
/// Will be `PlatformParamsGL` or `PlatformParamsVulkan` depending on the backend.
pub const Platform = opaque {};
pub const Processor = opaque {};
pub const Readbacks = opaque {};
pub const Service = opaque {};
pub const State = opaque {};
pub const TraverseContext = opaque {};

pub const Readback = struct {
    data: []u8,
    /// Handle to the storage created in the backend API.
    /// For example: GL_BUFFER or GL_TEXTURE
    ref: u64, // 64bit because Vulkan always uses 64bit handles
};

/// Stateless instrument processor which is used for operating with shader source code.
pub const InstrumentProcessor = struct {
    instrument: ?*const fn (processor: *Processor, node: NodeId, context: *TraverseContext) anyerror!void,
    constructors: ?*const fn (processor: *Processor, main: NodeId) anyerror!void,
    setup: ?*const fn (processor: *Processor) anyerror!void,
    collect: ?*const fn () void, //TODO
};

/// The stateful instrument service which is specific to the backend. Operates within the draw loop.
pub const InstrumentClient = struct {
    deinit: ?*const fn (state: *State) void,
    onBeforeDraw: ?*const fn (service: *Service, instrumentation: *Instrumentation) anyerror!void,
    /// `platform` can be `PlatformParamsGL` or `PlatformParamsVK`
    onResult: ?*const fn (service: *Service, instrumentation: *const Instrumentation, readbacks: *const Readbacks, platform: *const Platform) anyerror!void,
    onRestore: ?*const fn (service: *Service) anyerror!void,
};

pub const PlatformParamsGL = struct {
    /// Framebuffer which has all the debugging outputs attached
    fbo: c_uint = undefined,

    pub fn toOpaque(self: *const @This()) *const Platform {
        return @ptrCast(self);
    }
};

pub const PlatformParamsVK = struct {
    pub fn toOpaque(self: *const @This()) *const Platform {
        return @ptrCast(self);
    }
};
