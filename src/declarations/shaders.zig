// Copyright (C) 2025  Ondřej Sabela
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
const types = @import("types.zig");
const PlatformRef = types.PlatformRef;
const Service = types.Service;
// #STUBS START HERE

/// Both API specific and agnostic declarations that will be included verbatim in the exported deshader.zig header file
const CString = [*:0]const u8;

pub const ExistsBehavior = enum(c_int) {
    /// Link to and existing tag. Does not write any content. When the target tag is deleted, this tag will be deleted too.
    Link = 0,
    /// Do not permit collisions
    Error = 1,
    /// Overwrite contents of the target tag. Removes any targeted previous links to other tags.
    /// Tags which pointed to previous content will be linked to the new content.
    Overwrite = 2,
};

/// Non-exhaustive enumeration type
/// Shader language can be graphics API backend agnostic so it is stored separately
pub const LanguageType = enum(c_int) { GLSL = 1, _ };

/// Specifies both shader type and API backend type
pub const StageType = enum(c_int) {
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
    pub fn toExtension(stage: StageType) []const u8 {
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

    pub fn toString(stage: StageType) []const u8 {
        return stage.toExtension()[1..];
    }

    pub fn isFragment(self: StageType) bool {
        return switch (self) {
            .gl_fragment, .vk_fragment => true,
            else => false,
        };
    }

    pub fn isVertex(self: StageType) bool {
        return switch (self) {
            .gl_vertex, .vk_vertex => true,
            else => false,
        };
    }
};

/// Mutiple shader source codes which are meant to be compiled together as a single shader stage.
/// This struct is used for communicating through ABI boundaries.
pub const StagePayload = extern struct {
    /// Graphics API level shader reference.
    /// Will be GLuint for OpenGL, pointer to VkShaderModule on Vulkan.
    ///
    /// Special ref 0 means that this is source part is a named string (not a standalone shader)
    ref: PlatformRef = 0,
    /// Shader tag/virtual paths list. Has the size of 'count'.
    /// Paths are copied when stored by Deshader.
    ///
    /// If some physical path mapping will be used, the save function will get the physical path passed.
    ///
    /// If multiple paths are assigned to the same shader source part (for example by `deshaderTagSource`), the client must accept any of
    /// the paths when reading the `SourcesPayload` (for example in `compile` and `save` functions).
    paths: ?[*]const ?CString = null,
    /// Shader GLSL source code parts. Each of them has different path and context. Has the size of 'count'
    /// Sources are never duplicated or freed
    sources: ?[*]const CString = null,
    /// Source code lengths
    /// is copied when intercepted because opengl specifies source length in 32-bit int
    lengths: ?[*]const usize = null,
    /// User-specified context. Can be anything.
    context: ?*anyopaque = null,
    // Count of paths/sources/contexts
    count: usize = 0,
    /// Represents both type of the shader (vertex, fragment, etc) and the graphics backend (GL, VK)
    stage: StageType = @enumFromInt(0), // Default to unknown (_) value
    /// Represents the language of the shader source (GLSL ...)
    language: LanguageType = @enumFromInt(0), // Default to unknown (_) value
    /// (Non-null => user-specified) or default source assignment and compile function to be executed when
    /// Deshader inejcts something and wants to apply it,
    /// or when Deshader wants to revert instrumented source.
    ///
    /// length is the length of the `instrumented` source. If it is 0, then there is no instrumented source.
    /// The instrumented source is also always null-terminated.
    /// Should return `0` when there is no error.
    compile: ?*const fn (service: *Service, source: StagePayload, instrumented: CString, length: i32) callconv(.c) u8 = null,
    /// Get the instrumented version of the source code. Deshader executes this function when requested by the frontend.
    /// TODO: if the function is not provided, store always the source code somewhere.
    currentSource: ?*const fn (service: *Service, context: ?*anyopaque, ref: PlatformRef, path: ?CString, length: usize) callconv(.c) ?CString = null,
    /// Free the memory returned by `currentSource`
    free: ?*const fn (ref: PlatformRef, context: ?*anyopaque, string: CString) callconv(.c) void = null,
    /// Function to execute when user wants to save a source in the Deshader editor. Set to override the default behavior.
    /// The function must return 0 if there is no error.
    save: ?*const fn (ref: PlatformRef, index: usize, content: CString, length: usize, physical: ?CString) callconv(.c) u8 = null,

    pub fn toString(self: *const @This()) []const u8 {
        return self.stage.toExtension();
    }
};

/// See `SourcesPayload`
pub const ProgramPayload = extern struct {
    ref: PlatformRef = 0,
    path: ?CString = null,
    /// Shaders to be attached to the program
    shaders: ?[*]PlatformRef = null,
    count: usize = 0,
    context: ?*anyopaque = null,
    /// If `ProgramPayload.count` is 0, the function will only link the program.
    /// Otherwise it will attach the shaders in the order they are stored in the payload.
    /// The function must return 0 if there is no error.
    ///
    /// If the program was already linked in the past, the function must also re-set all the uniforms and attributes to their original values.
    link: ?*const fn (service: *Service, self: ProgramPayload) callconv(.c) u8 = null,
};

pub const BreakpointResult = extern struct {
    /// Must be session-unique
    id: usize = 0,
    verified: bool = false,
    message: ?[*:0]const u8 = null,
    line: usize = 0,
    column: usize = 0,
    end_line: usize = 0,
    end_column: usize = 0,
    /// Reason for not being verified 'pending', 'failed'
    reason: ?[*:0]const u8 = null,
};
