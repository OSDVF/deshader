/// Both API specific and agnostic declarations that will be included verbatim in the exported deshader.zig header file
const CString = [*:0]const u8;

pub const ExistsBehavior = enum(c_int) {
    /// Link to and existing tag. Does not write any content. When the target tag is deleted, this tag will be deleted too.
    Link = 0,
    /// Do not permit collisions
    Error = 1,
    /// Overwrite contents of the target tag. Removes any targeted previous links to other tags. Tags which pointed to previous content will be linked to the new content.
    Overwrite = 2,
};

/// Non-exhaustive enumeration type
/// Shader language can be graphics API backend agnostic so it is stored separately
pub const LanguageType = enum(c_int) { GLSL = 1, _ };

/// Specifies both shader type and API backend type
pub const Stage = enum(c_int) {
    gl_vertex = 0x8b31,
    gl_fragment = 0x8b30,
    gl_geometry = 0x8dd9,
    gl_tess_control = 0x8e88,
    gl_tess_evaluation = 0x8e87,
    gl_compute = 0x91b9,
    gl_mesh = 0x9559, //nv_mesh_shader
    gl_task = 0x955a,
    vk_vertex = 0x0001,
    vk_tess_control = 0x0002,
    vk_tess_evaluation = 0x0004,
    vk_geometry = 0x0008,
    vk_fragment = 0x0010,
    vk_compute = 0x0020,
    vk_raygen = 0x0100,
    vk_anyhit = 0x0200,
    vk_closesthit = 0x0400,
    vk_miss = 0x0800,
    vk_intersection = 0x1000,
    vk_callable = 0x2000,
    vk_task = 0x4000,
    vk_mesh = 0x8000,
    unknown = 0,

    /// Including the dot
    pub fn toExtension(stage: Stage) []const u8 {
        return switch (stage) {
            .gl_fragment, .vk_fragment => ".frag",
            .gl_vertex, .vk_vertex => ".vert",
            .gl_geometry, .vk_geometry => ".geom",
            .gl_tess_control, .vk_tess_control => ".tesc",
            .gl_tess_evaluation, .vk_tess_evaluation => ".tese",
            .gl_compute, .vk_compute => ".comp",
            .gl_task, .vk_task => ".task",
            .gl_mesh, .vk_mesh => ".mesh",
            .vk_raygen => ".rgen",
            .vk_anyhit => ".rahit",
            .vk_closesthit => ".rchit",
            .vk_intersection => ".rint",
            .vk_miss => ".rmiss",
            .vk_callable => ".rcall",
            else => ".glsl",
        };
    }

    pub fn toString(stage: Stage) []const u8 {
        return stage.toExtension()[1..];
    }

    pub fn isFragment(self: Stage) bool {
        return switch (self) {
            .gl_fragment, .vk_fragment => true,
            else => false,
        };
    }

    pub fn isVertex(self: Stage) bool {
        return switch (self) {
            .gl_vertex, .vk_vertex => true,
            else => false,
        };
    }
};

/// Mutiple shader source codes which are meant to be compiled together as a single shader
/// Used for communicating through ABI boundaries
pub const SourcesPayload = extern struct {
    /// Graphics API level shader reference.
    /// Will be GLuint for OpenGL, pointer to VkShaderModule on Vulkan
    ref: usize = 0,
    /// Shader tag/virtual paths list. Has the size of 'count'.
    /// Paths are copied when stored by Deshader.
    ///
    /// If some physical path mapping will be used, the save function will get the physical path passed.
    ///
    /// If multiple paths are assigned to the same shader source part (for example by `deshaderTagSource`), the client must accept any of
    /// the paths when reading the `SourcesPayload` (for example in `compile` and `save` functions).
    paths: ?[*]?CString = null,
    /// Shader GLSL source code parts. Each of them has different path and context. Has the size of 'count'
    /// Sources are never duplicated or freed
    sources: ?[*]const CString = null,
    /// Source code lengths
    /// is copied when intercepted because opengl specifies source length in 32-bit int
    lengths: ?[*]const usize = null,
    /// User-specified contexts. Can be anything. Has the size of 'count'
    /// Contexts are never duplicated or freed
    contexts: ?[*]?*const anyopaque = null,
    // Count of paths/sources/contexts
    count: usize = 0,
    /// Represents both type of the shader (vertex, fragment, etc) and the graphics backend (GL, VK)
    stage: Stage = @enumFromInt(0), // Default to unknown (_) value
    /// Represents the language of the shader source (GLSL ...)
    language: LanguageType = @enumFromInt(0), // Default to unknown (_) value
    /// (Non-null => user-specified) or default source assignment and compile function to be executed when Deshader inejcts something and wants to apply it
    /// length is the length of the `instrumented` source. If it is 0, then there is no instrumented source.
    /// The instrumented source is also always null-terminated.
    /// Should return 0 when there is no error
    compile: ?*const fn (source: SourcesPayload, instrumented: CString, length: i32) callconv(.C) u8 = null,
    /// Function to execute when user wants to save a source in the Deshader editor
    save: ?*const fn (source: SourcesPayload, physical: ?CString) callconv(.C) u8 = null,

    pub fn toString(self: *const @This()) []const u8 {
        return self.stage.toExtension();
    }
};

/// See `SourcesPayload`
pub const ProgramPayload = extern struct {
    ref: usize = 0,
    path: ?CString = null,
    shaders: ?[*]usize = null,
    count: usize = 0,
    context: ?*const anyopaque = null,
    /// If count is 0, the function will only link the program. Otherwise it will attach the shaders in the order they are stored in the payload.
    link: ?*const fn (self: ProgramPayload) callconv(.C) u8,
};
