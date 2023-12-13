/// Both API specific and agnostic declarations that will be included verbatim in the exported deshader.zig header file
const CString = [*:0]const u8;

pub const ExistsBehavior = enum(c_int) {
    /// Link to and existing tag. Does not write any content. When the target tag is deleted, this tag will be deleted too.
    Link = 0,
    /// Do not permit collisions
    Error = 1,
    /// Overwrite contents of the target tag. Removes any targeted previous links to other tags. Tags which pointed to previous content will be linked to the new content.
    PurgePrevious = 2,
};

/// Non-exhaustive enumeration type
/// Shader language can be graphics API backend agnostic so it is stored separately
pub const LanguageType = enum(c_int) { GLSL = 1, _ };

/// Non-exhaustive enumeration type
/// Specifies both shader type and API backend type
pub const SourceType = enum(c_int) {
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
    _,

    pub fn toExtension(typ: SourceType) []const u8 {
        return switch (typ) {
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
};

/// Mutiple shader source codes which are meant to be compiled together as a single shader
/// Used for communicating through ABI boundaries
pub const SourcesPayload = extern struct {
    /// Graphics API level shader reference.
    /// Will be GLuint for OpenGL, pointer to VkShaderModule on Vulkan
    ref: usize = 0,
    /// Shader tag/virtual path. Has the size of 'count'
    /// Paths are stored duplicated (because they can change over time)
    paths: ?[*]CString = null,
    /// Shader GLSL source code parts. Each of them has different path and context. Has the size of 'count'
    /// Sources are never duplicated or freed
    sources: ?[*]CString = null,
    /// Source code lengths
    /// is copied when intercepted because opengl specifies source length in 32-bit int
    lengths: ?[*]usize = null,
    /// User-specified contexts. Can be anything. Has the size of 'count'
    /// Contexts are never duplicated or freed
    contexts: ?[*]?*const anyopaque = null,
    // Count of paths/sources/contexts
    count: usize = 0,
    /// Represents both type of the shader (vertex, fragment, etc) and the graphics backend (GL, VK)
    type: SourceType = @enumFromInt(0), // Default to unknown (_) value
    /// Represents the language of the shader source (GLSL ...)
    language: LanguageType = @enumFromInt(0), // Default to unknown (_) value
    /// Non-null user-specified or default compile function to be executed when Deshader inejcts something and wants to apply it
    compile: ?*const fn (source: SourcesPayload) callconv(.C) u8 = null,
    /// Function to execute when user wants to save a source in the Deshader editor
    save: ?*const fn (source: SourcesPayload) callconv(.C) u8 = null,

    pub fn toString(self: *const @This()) []const u8 {
        return self.type.toExtension();
    }
};

pub const ProgramPayload = extern struct {
    ref: usize = 0,
    path: ?CString = null,
    shaders: ?[*]usize = null,
    count: usize = 0,
    context: ?*const anyopaque = null,
    link: ?*const fn (ref: usize, path: ?CString, sources: [*]SourcesPayload, count: usize, context: ?*const anyopaque) callconv(.C) u8,
};
