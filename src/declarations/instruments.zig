pub const NodeId = u32;
pub const InstrumentId = u64;

/// Stateless instrument processor which is used for operating with shader source code.
pub const InstrumentProcessor = struct {
    instrument: ?*const fn (processor: *anyopaque, node: NodeId, context: *anyopaque) anyerror!void,
    constructors: ?*const fn (processor: *anyopaque, main: NodeId) anyerror!void,
    setup: ?*const fn (processor: *anyopaque) anyerror!void,
    collect: ?*const fn () void, //TODO
};

/// The stateful instrument service which is specific to the backend. Operates within the draw loop.
pub const InstrumentClient = struct {
    deinit: ?*const fn (service: *anyopaque) void,
    onBeforeDraw: ?*const fn (service: *anyopaque, instrumentation: *anyopaque) anyerror!void,
    /// `platform` can be `PlatformParamsGL` or `PlatformParamsVK`
    onResult: ?*const fn (service: *anyopaque, instrumentation: *const anyopaque, platform: *const anyopaque) anyerror!void,
    onRestore: ?*const fn (service: *anyopaque) anyerror!void,
};

pub const PlatformParamsGL = struct {
    /// Framebuffer which contains all the debugging outputs.
    fbo: c_uint = undefined,
};

pub const PlatformParamsVK = struct {};
