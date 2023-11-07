const CString = [*:0]const u8;

pub const SourcePayload = extern struct {
    /// Shader tag/virtual path
    path: ?CString,
    /// Shader GLSL source code
    source: ?CString,
    /// Graphics API level shader reference.
    /// Will be GLuint for OpenGL, pointer to VkShaderModule on Vulkan
    ref: *const anyopaque,
    /// User-specified context. Can be anything
    context: ?*const anyopaque,
    /// Non-null user-specified or defaultly set compile function
    compile: ?*const fn (ref: *const anyopaque, source: CString, path: CString, context: ?*const anyopaque) callconv(.C) u8,
};

pub const ProgramPayload = extern struct {
    path: ?CString,
    ref: *const anyopaque,
    context: ?*const anyopaque,
    link: *const fn (ref: ?*const anyopaque, sources: [*]SourcePayload, length: usize, context: ?*const anyopaque) callconv(.C) u8,
    program: PipelinePayload,
};

pub const PipelineType = enum(c_int) { Rasterize, Compute, Ray };

pub const PipelinePayload = extern struct {
    type: PipelineType,
    pipeline: extern union {
        Rasterize: RasterizePayload,
        Compute: ComputePayload,
        Ray: RaytracePayload,

        pub const RasterizePayload = extern struct {
            vertex: ?*const anyopaque,
            geometry: ?*const anyopaque,
            tesselation_control: ?*const anyopaque,
            tesselation_evaluation: ?*const anyopaque,
            fragment: ?*const anyopaque,
        };

        pub const ComputePayload = extern struct {
            source: *const anyopaque,
        };

        pub const RaytracePayload = extern struct {
            generation: *const anyopaque,
            any_hit: ?*const anyopaque,
            closest_hit: *const anyopaque,
            intersection: ?*const anyopaque,
            miss: *const anyopaque,
        };
    },
};
