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

//! Utility functions for supporting semantic analysis of the AST.

const std = @import("std");
const analyzer = @import("glsl_analyzer");
const log = @import("common").logging.DeshaderLog;
const decls = @import("../declarations.zig");

const String = []const u8;

pub const types = struct {
    pub const @"bool" = "bool";
    pub const double = "double";
    pub const float = "float";
    pub const int = "int";
    pub const uint = "uint";
    pub const uint64 = "uint64_t";
    pub const int64_t = "int64_t";
};

/// The smallest possible data type that can contain this number. Doesn't need to be precisely
/// the same as GLSL spec would say because this function is only used for type resolution of expressions
pub fn numberType(number: String) String {
    // TODO support smaller types than 32bit
    // TODO support hexadecimal floating point literals (does any GLSL compiler support them?)
    var i: usize = number.len;
    const len = while (i > 0) { // reverse iterate the number string and find non-digit
        i -= 1;
        if (!std.ascii.isDigit(number[i])) break i;
    } else number.len;

    if (std.mem.indexOfScalar(u8, number, '.') != null) {
        // decimal
        if (len > 8) { // 32bit float is roughly 7 decimal points (+ the dot)
            return types.double;
        }
        return types.float;
    } else {
        // integer

        // TODO short types
        // detect format
        return if (len > 1)
            if (number[0] == '0') // (hexa)decimal
                if (number[1] == 'x' or number[1] == 'X')
                    //hexadecimal
                    if (len - 2 > 8) types.uint64 else types.uint
                else
                // octal
                if (len > 10 or std.fmt.parseInt(u64, number[0..len], 8) catch 0 > std.math.maxInt(u32))
                    types.uint64
                else
                    types.uint
            else if (len > 10 or std.fmt.parseInt(u64, number[0..len], 10) catch 0 > std.math.maxInt(u32))
                types.uint64
            else
                types.uint
        else
            types.uint;
    }
}

pub fn resolveBuiltinFunction(
    allocator: std.mem.Allocator,
    name: String,
    parameters: []const Symbol.Type,
    first_arg: ?Symbol.Content,
    spec: *const analyzer.Spec,
) !?Symbol.Content {
    for (spec.functions) |builtin| {
        if (std.mem.eql(u8, builtin.name, name)) {
            //if (builtin.parameters.len == overload.parameters.len) {// TODO optional parameters to builtins
            return Symbol.Content{
                .type = resolveGenReturnType(builtin, parameters),
            };
            //}
        }
    }

    for (spec.types) |builtin| { // type initializers return the type :)
        if (std.mem.eql(u8, builtin.name, name)) {
            return Symbol.Content{
                .type = try Symbol.Type.parse(allocator, name),
                .constant = if (first_arg) |a|
                    a.constant
                else
                    null,
            };
        }
    }
    return null;
}

/// Map generic types to the actual types according to the passed arguments
/// TODO for now it just returns the first passed argument type.
fn resolveGenReturnType(
    builtin: analyzer.Spec.Function,
    arguments: []const Symbol.Type,
) Symbol.Type {
    const gen_types = .{
        "",
        "B",
        "D",
        "F16",
        "F32",
        "F",
        "I16",
        "I32",
        "I64",
        "I",
        "U16",
        "U32",
        "U64",
        "U",
    };
    const gen_special = .{
        "bvec",
        "vec",
        "mat",
        "dmat",
    };
    if (builtin.return_type.len >= 7 and strEql(builtin.return_type[0..3], "gen")) {
        inline for (gen_types) |g| {
            const as_slice: String = g;
            if (builtin.return_type.len == 7 + as_slice.len and strEql(builtin.return_type[3 .. 3 + as_slice.len], g)) {
                if (strEql(builtin.return_type[0 .. 7 + as_slice.len], "Type")) {
                    // TODO check if this always works
                    return arguments[0];
                }
            }
        }
    } else if (builtin.return_type[0] == 'g' and strEql(builtin.return_type[1..3], "vec")) {
        // TODO check if this always works
        return arguments[0];
    }
    inline for (gen_special) |g| {
        if (strEql(builtin.return_type, g)) {
            return arguments[0];
        }
    }

    // No builtin function returns arrays
    return .{ .basic = builtin.return_type };
}

pub fn resolveInfix(op: anytype, left: Symbol.Content, right: ?Symbol.Content) ?Symbol.Content {
    switch (op) {
        .@"*", .@"/", .@"%", .@"+", .@"-", .@"<<", .@">>", .@"&", .@"^", .@"|" => return Symbol.Content{
            .type = left.type,
            .constant = if (left.constant) |l| if (right) |rr| if (rr.constant) |r| switch (op) {
                .@"*" => l * r,
                .@"/" => l / r,
                .@"%" => l % r,
                .@"+" => l + r,
                .@"-" => l - r,
                .@"<<" => if (std.math.cast(u6, r)) |rc| l << rc else null,
                .@">>" => if (std.math.cast(u6, r)) |rc| l >> rc else null,
                .@"&" => l & r,
                .@"^" => l ^ r,
                .@"|" => l | r,
                else => unreachable,
            } else null else null else null,
        },
        else => return Symbol.Content{
            .type = .{
                .basic = types.bool,
            },
            .constant = if (left.constant) |l| if (right) |rr| if (rr.constant) |r| switch (op) {
                .@"<" => if (l < r) 1 else 0, // TODO resolve compouds (arrays, vectors, structures)
                .@">" => if (l > r) 1 else 0,
                .@"<=" => if (l <= r) 1 else 0,
                .@">=" => if (l >= r) 1 else 0,
                .@"==" => if (l == r) 1 else 0,
                .@"!=" => if (l != r) 1 else 0,
                .@"&&" => if (l != 0 and r != 0) 1 else 0,
                .@"^^" => if ((l != 0 or r != 0) and l != r) 1 else 0,
                .@"||" => if (l != 0 or r != 0) 1 else 0,
                else => unreachable,
            } else null else null else null,
        },
    }
}

pub fn resolveNumber(text: String) Symbol.Content {
    return Symbol.Content{
        .type = .{ .basic = numberType(text) },
        .constant = std.fmt.parseUnsigned(u64, text, 0) catch blk: {
            log.err("Failed to parse number {s}", .{text});
            break :blk null;
        },
    };
}

pub const Scope = struct {
    /// Maps field name to its type
    const Fields = std.StringArrayHashMapUnmanaged(Symbol.Type);

    parent: ?*Scope = null,
    /// Blocks and structures. Maps type name to its fields
    types: std.StringHashMapUnmanaged(Fields) = .empty,
    /// Maps function overload (name + parameter types) to the function symbol
    functions: *Functions,

    variables: std.StringHashMapUnmanaged(Symbol) = .empty,
    //children: std.ArrayListUnmanaged(*Scope) = .empty,

    /// Create a child scope whose parent field will be initialized to this scope
    pub fn addChild(self: *@This(), allocator: std.mem.Allocator) !*Scope {
        const new = try allocator.create(Scope);
        new.* = Scope{
            .parent = self,
        };
        try self.children.append(allocator, new);
        return new;
    }

    //pub fn fillBlock(
    //    self: *@This(),
    //    allocator: std.mem.Allocator,
    //    block: analyzer.syntax.BlockDeclaration,
    //    tree: analyzer.parse.Tree,
    //    source: String,
    //) !void {
    //    const f = block.get(.fields, tree);
    //
    //    if (block.get(.variable, tree)) |variable| {
    //        // fields are scoped inside the block variable
    //        const t = block.get(.specifier).?;
    //        try self.fillVariable(allocator, tree.nodeSpan(variable.getNode()).text(source), t, null);
    //
    //        const b_fields = try self.getOrPutType(allocator, tree.nodeSpan(t.getNode()).text(source));
    //
    //        if (f) |fields| {
    //            var it = fields.iterator();
    //            while (it.next(tree)) |field| {
    //                const f_type = tree.nodeSpan(field.get(.specifier, tree).?.node).text(source);
    //                var f_it = field.get(.variables, tree).?.iterator();
    //                while (f_it.next(tree)) |v| {
    //                    try b_fields.put(allocator, v.get(.name, tree).?.getIdentifier(tree).?.text(source), f_type);
    //                }
    //            }
    //        }
    //    } else if (f) |fields| {
    //        var it = fields.iterator();
    //        // all fields are global scope
    //        while (it.next(tree)) |field| {
    //            const f_type = tree.nodeSpan(field.get(.specifier, tree).?.node).text(source);
    //            var f_it = field.get(.variables, tree).?.iterator();
    //            while (f_it.next(tree)) |v| {
    //                try self.fillVariable(allocator, v.get(.name, tree).?.getIdentifier(tree).?.text(source), f_type);
    //            }
    //        }
    //    }
    //}

    pub fn fillVariable(self: *@This(), allocator: std.mem.Allocator, name: String, content: Symbol.Content) !void {
        log.debug("fillVariable {s} {}", .{ name, content.type });
        try self.variables.put(allocator, name, Symbol{
            .name = name,
            .content = content,
        });
    }

    pub fn getOrPutType(self: *@This(), allocator: std.mem.Allocator, @"type": String) !*Fields {
        const gop = try self.types.getOrPut(allocator, @"type");
        if (!gop.found_existing) {
            gop.value_ptr.* = Fields.empty;
        }
        return gop.value_ptr;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        // variables do not have owned names by default
        self.variables.deinit(allocator);
    }

    pub fn visibleFunction(self: *const @This(), overload: Symbol.Overload) ?Symbol {
        return self.functions.get(overload) orelse if (self.parent) |p| p.visibleFunction(overload) else null;
    }

    pub fn visibleType(self: *const @This(), name: String) ?Fields {
        return self.types.get(name) orelse if (self.parent) |p| p.visibleType(name) else null;
    }

    pub fn visibleVariable(self: *const @This(), name: String) ?Symbol {
        return self.variables.get(name) orelse if (self.parent) |p| p.visibleVariable(name) else null;
    }

    pub fn resolveFunction(
        self: *const Scope,
        allocator: std.mem.Allocator,
        overload: Symbol.Overload,
        spec: *const analyzer.Spec,
        first_arg: ?Symbol.Content,
    ) !?Symbol.Content {
        if (self.visibleFunction(overload)) |f| {
            return f.content;
        }

        return resolveBuiltinFunction(allocator, overload.name, overload.parameters, first_arg, spec);
    }

    // something.something_else
    pub fn resolveSelection(
        self: *const @This(),
        target: Symbol.Content,
        field: String,
    ) !?Symbol.Content {
        const tar_type = target.type.basic;
        if (self.visibleType(tar_type)) |fields| {
            return Symbol.Content{ .type = fields.get(field) orelse return null };
        } else {
            for (field) |c| {
                switch (c) {
                    'x', 'y', 'z', 'w', 'r', 'g', 'b', 'a', 's', 't', 'p', 'q' => {}, //TODO propagate constants
                    else => return null,
                }
            }
            if (Type.Normal.parseIdentifierNoStruct(tar_type)) |t| switch (t) {
                .primitive => |p| return Symbol.Content{
                    .type = .{ .basic = p.data.makeVector(field.len) },
                },
                else => return null,
            } else return null;
        }
    }

    pub fn resolveType(self: *const @This(), allocator: std.mem.Allocator, name: String, spec: *analyzer.Spec) !?Symbol.Content {
        if (self.visibleType(name)) |_| {
            return .{ .type = .{
                .basic = name,
            } };
        }
        for (spec.types) |builtin| {
            if (std.mem.eql(u8, builtin.name, name)) {
                return Symbol.Content{
                    .type = try Symbol.Type.parse(allocator, builtin.name),
                };
            }
        }
        return null;
    }

    pub fn resolveVariable(
        self: *const @This(),
        allocator: std.mem.Allocator,
        name: String,
        spec: *analyzer.Spec,
    ) !?Symbol.Content {
        if (self.visibleVariable(name)) |symbol| {
            return symbol.content;
        }
        for (spec.variables) |builtin| {
            if (std.mem.eql(u8, builtin.name, name)) {
                return Symbol.Content{
                    .type = try Symbol.Type.parse(allocator, builtin.type),
                };
            }
        }
        return null;
    }

    /// Generate a `Snapshot` of the scope. Will resolve types of all variables.
    pub fn toSnapshot(
        self: *const @This(),
        allocator: std.mem.Allocator,
        /// Pass a set of variable names with more than 0 records to filter the result
        filter: ?std.StringHashMapUnmanaged(void),
    ) !Snapshot {
        var result = Snapshot{};
        try result.all.ensureTotalCapacity(allocator, self.variables.count());
        var it = self.variables.valueIterator();

        while (it.next()) |variable| {
            const t = try Type.parse(allocator, variable.content.type);
            if (filter) |filter_map| if (filter_map.count() > 0) {
                if (filter_map.contains(variable.name)) {
                    try result.filtered.put(allocator, variable.name, t);
                }
            };
            result.all.putAssumeCapacity(variable.name, t);
        }
        if (filter == null) {
            result.filtered = result.all;
        }

        return result;
    }

    pub const Functions = std.HashMapUnmanaged(Symbol.Overload, Symbol, Symbol.Overload.Context, std.hash_map.default_max_load_percentage);

    pub const Snapshot = struct {
        all: Variables = .empty,
        filtered: Variables = .empty,
        types: std.StringArrayHashMapUnmanaged(String) = .empty,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            for (self.all.values()) |variable| {
                variable.deinit(allocator);
            }

            if (self.filtered.entries.bytes != self.all.entries.bytes) {
                self.filtered.deinit(allocator);
            }

            self.all.deinit(allocator);

            for (self.types.values()) |t| {
                allocator.destroy(t);
            }
            self.types.deinit(allocator);
        }

        /// Maps variable names to their types
        pub const Variables = std.StringArrayHashMapUnmanaged(Type);
    };
};

pub const Type = union(enum) {
    array: Array,
    normal: Normal,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self) {
            .array => |a| a.deinit(allocator),
            .normal => |n| n.deinit(allocator),
        }
    }

    /// Parses the`Symbol`'s 'type' into a `Type` struct.
    pub fn parse( //TODO eliminate parsing at resolution phase and instead parse the full specifier (including []) and then switch at read phase
        allocator: std.mem.Allocator,
        @"type": Symbol.Type,
    ) !Type {
        switch (@"type") {
            .array => |array| {
                return Type{
                    .array = .{
                        .type = try Normal.parseIdentifier(allocator, array.base),
                        .dim = array.dim,
                    },
                };
            },
            .basic => |basic| {
                return .{ .normal = try Normal.parseIdentifier(allocator, basic) };
            },
        }
    }

    pub const Array = struct {
        type: Normal,
        dim: []usize = empty,

        pub const empty: []usize = &.{};

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (self.dim.ptr != empty.ptr) {
                allocator.free(self.dim);
            }
        }
    };

    pub const Normal = union(enum) {
        image: Image,
        primitive: Primitive,
        texture: Image,
        sampler: Sampler,
        /// Inside `Snapshot` the struct name is owned by the allocator that created the snapshot and instances of the same struct
        /// point to the same name in the `types` hashmap
        @"struct": String,
        void: void,

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}

        /// Vector, scalar or matrix
        pub const Primitive = struct {
            data: Data,
            /// 0 => scalar, 2, 3, 4
            size_x: u2 = 0,
            /// 0 => scalar, 2, 3, 4
            size_y: u2 = 0,
        };

        pub const Data = enum {
            uint,
            uint64_t,
            int,
            int64_t,
            float,
            double,
            bool,

            /// Size in bytes for storage in the debug output channel
            pub fn size(self: @This()) usize {
                return switch (self) {
                    .uint, .int, .float => 4,
                    .uint64_t, .int64_t => 8,
                    .double => 8,
                    .bool => 1,
                };
            }

            fn prefix(comptime self: @This()) switch (self) {
                .uint, .int, .double, .bool => *const [1]u8,
                .uint64_t, .int64_t => *const [3]u8,
                .float => *const [0]u8,
            } {
                return switch (self) {
                    .uint => "u",
                    .uint64_t => "u64",
                    .int => "i",
                    .int64_t => "i64",
                    .float => "",
                    .double => "d",
                    .bool => "b",
                };
            }

            fn postfix(comptime vec_size: usize) *const [4]u8 {
                return switch (vec_size) {
                    1, 2, 3, 4 => |s| comptime std.fmt.comptimePrint("vec{d}", .{s}),
                    else => "vec4",
                };
            }

            pub fn makeVector(self: @This(), vec_size: usize) String {
                return switch (@min(vec_size, 4)) {
                    inline else => |s| switch (self) {
                        inline else => |t| comptime prefix(t) ++ postfix(s),
                    },
                };
            }
        };

        pub const Sampler = struct {
            image: Image,
            shadow: bool,

            pub fn parse(suffix: String, data: Data) ?@This() {
                return if (Image.Kind.parse(suffix)) |kind| .{
                    .image = .{
                        .kind = kind,
                        .type = data,
                    },
                    .shadow = std.mem.indexOf(u8, suffix, "Shadow") != null,
                } else null;
            }
        };

        pub const Image = struct {
            kind: Kind,
            type: Data,

            pub const Kind = struct {
                array: bool = false,
                ms: bool = false,
                size: Size,

                pub fn parse(suffix: String) ?@This() {
                    var i: usize = 0;
                    var result: @This() =
                        blk: switch (suffix[0]) {
                            'B' => return .{ .size = .Buffer },
                            'C' => {
                                i += 4; //Cube
                                break :blk .{ .size = .Cube };
                            },
                            '1' => {
                                i += 2;
                                break :blk .{ .size = .@"1D" };
                            },
                            '2' => {
                                if (suffix.len > 2 and suffix[2] == 'R') {
                                    return .{ .size = .@"2DRect" };
                                }
                                i += 2;
                                break :blk .{ .size = .@"2D" };
                            },
                            '3' => {
                                i += 2;
                                break :blk .{ .size = .@"3D" };
                            },
                            else => return null,
                        };

                    result.ms = std.mem.indexOf(u8, suffix[i..], "MS") != null;
                    result.array = std.mem.indexOf(u8, suffix[i..], "Array") != null;
                    return result;
                }

                pub const Size = enum {
                    Buffer,
                    Cube,
                    @"1D",
                    @"2D",
                    @"2DRect",
                    @"3D",
                };
            };
        };

        fn parseMultidim(t: String, d: Data, comptime allow: enum { any, mat, vec }) ?@This() {
            // FSA-like parsing
            switch (hashStr(t[0..3])) {
                h: {
                    break :h hashStr("vec");
                } => {
                    if (allow != .mat) {
                        const size_x = t[3] - '0';
                        return Normal{ .primitive = .{
                            .data = d,
                            .size_x = std.math.cast(u2, size_x) orelse {
                                log.err("Invalid vector size {d} at {s}", .{ size_x, t });
                                return null;
                            },
                            .size_y = 0,
                        } };
                    }
                },
                h: {
                    break :h hashStr("mat");
                } => {
                    if (allow != .vec) {
                        const size_x = t[3] - '0';
                        if (t.len == 5 or (t.len == 6 and t[4] != 'x')) return null;

                        const size_y = if (t.len == 6) t[5] - '0' else size_x;
                        return Normal{ .primitive = .{
                            .data = d,
                            .size_x = std.math.cast(u2, size_x) orelse {
                                log.err("Invalid matrix size {d} at {s}", .{ size_x, t });
                                return null;
                            },
                            .size_y = std.math.cast(u2, size_y) orelse {
                                log.err("Invalid matrix Y size {d} at {s}", .{ size_y, t });
                                return null;
                            },
                        } };
                    }
                },
                else => {},
            }
            return null;
        }

        fn parseExplicit(t: String, prefix: enum { u, i, f }) ?@This() {
            switch (t[0]) {
                '1' => switch (t[1]) {
                    '6' => if (parseMultidim(t[3..], switch (prefix) {
                        .u => .uint,
                        .i => .int,
                        .f => .float,
                    }, .vec)) |m| return m,
                    else => {},
                },
                '3' => if (t[1] == '2' and prefix == .f) if (parseMultidim(t[3..], .float, .vec)) |m| return m,
                '6' => if (t[1] == '4') if (parseMultidim(t[3..], switch (prefix) {
                    .u => .uint64_t,
                    .i => .int64_t,
                    .f => .double,
                }, .vec)) |m| return m,
                else => {},
            }
            return null;
        }

        /// Supports all extension by default:
        /// - https://registry.khronos.org/OpenGL/extensions/NV/NV_gpu_shader5.txt
        /// - https://registry.khronos.org/OpenGL/extensions/EXT/EXT_vertex_attrib_64bit.txt
        /// - https://registry.khronos.org/OpenGL/extensions/ARB/ARB_gpu_shader_int64.txt
        /// - https://registry.khronos.org/OpenGL/extensions/ARB/ARB_gpu_shader_fp64.txt
        /// TODO check if the support is complete
        /// TODO support only if the extensions are enabled
        fn parseIdentifier(
            allocator: std.mem.Allocator,
            identifier: String,
        ) !@This() {

            // if no type was matched, it's a struct
            return parseIdentifierNoStruct(identifier) orelse .{ .@"struct" = try allocator.dupe(u8, identifier) };
        }

        fn parseIdentifierNoStruct(identifier: String) ?@This() {
            // FSA-like parsing
            // TODO some characters are never checked and ignored in the hope that user would never create a type named e.g. sampler3E
            // (- this will be parsed as sampler3D because the last char is not checkd)
            switch (identifier.len) {
                3 => if (strEql(identifier, "int")) {
                    return Normal{ .primitive = .{ .data = .int } };
                },
                4 => switch (identifier[0]) {
                    'u' => {
                        if (strEql(identifier[1..], "int")) {
                            return Normal{ .primitive = .{ .data = .uint } };
                        }
                    },
                    'b' => {
                        if (strEql(identifier[1..], "ool")) {
                            return Normal{ .primitive = .{ .data = .bool } };
                        }
                    },
                    'v' => {
                        if (strEql(identifier[1..], "oid")) {
                            return .{ .void = {} };
                        }
                    },
                    else => { //vecX or matX
                        if (parseMultidim(identifier, .float, .any)) |m| return m;
                    },
                },
                5 => if (strEql(identifier, "float")) {
                    return Normal{ .primitive = .{ .data = .float } };
                } else switch (identifier[0]) {
                    'd' => { //dvecX or dmatX
                        if (parseMultidim(identifier[1..], .double, .any)) |m| return m;
                    },
                    'b' => { //bvecX
                        if (parseMultidim(identifier[1..], .bool, .vec)) |m| return m;
                    },
                    'i' => { // ivecX
                        if (parseMultidim(identifier[1..], .int, .vec)) |m| return m;
                    },
                    'u' => { // uvecX
                        if (parseMultidim(identifier[1..], .uint, .vec)) |m| return m;
                    },
                    else => {},
                },
                6 => switch (identifier[0]) {
                    'd' => {
                        if (strEql(identifier[1..], "ouble")) {
                            return Normal{ .primitive = .{ .data = .double } };
                        }
                    },
                    else => { //matXxY
                        if (strEql(identifier, "int8_t")) return @This(){ .primitive = .{ .data = .int } };
                        if (identifier.len > 2 and strEql(identifier[0..2], "i8")) if (parseMultidim(identifier[2..], .int, .vec)) |m| return m;
                        if (identifier.len > 2 and strEql(identifier[0..2], "u8")) if (parseMultidim(identifier[2..], .uint, .vec)) |m| return m;
                        if (parseMultidim(identifier[1..], .float, .mat)) |m| return m;
                    },
                },
                7 => switch (identifier[0]) {
                    'd' => // dmatXxY
                    if (parseMultidim(identifier[1..], .double, .mat)) |m| return m,

                    'f' => // f64vec2, f32vec3...
                    if (parseExplicit(identifier[1..], .f)) |m|
                        return m,

                    'i' => if (parseExplicit(identifier[1..], .i)) |m|
                        return m
                    else if (strEql(identifier[1..], "mage")) if (Image.Kind.parse(identifier[5..])) |kind|
                        return @This(){ .image = .{ .type = .float, .kind = kind } }
                    else if (strEql(identifier[1..3], "nt")) switch (identifier[4]) {
                        '6' => if (strEql(identifier[5..], "4_t")) return @This(){ .primitive = .{ .data = .int64_t } },
                        '1' => if (strEql(identifier[5..], "6_t")) return @This(){ .primitive = .{ .data = .int } },
                        '3' => if (strEql(identifier[5..], "2_t")) return @This(){ .primitive = .{ .data = .int } },
                        else => {},
                    },

                    'u' => if (parseExplicit(identifier[1..], .u)) |m|
                        return m
                    else if (strEql(identifier[1..], "int8_t"))
                        return @This(){ .primitive = .{ .data = .uint } },

                    else => {},
                },

                8 => if (strEql(identifier, "uint64_t"))
                    return @This(){ .primitive = .{ .data = .uint64_t } }
                else if (strEql(identifier, "uint16_t"))
                    return @This(){ .primitive = .{ .data = .uint } },

                else => {
                    var i: usize = 1;
                    const base: Data = blk: switch (identifier[0]) {
                        'f' => switch (identifier[1]) { //float64_t, f64.., f32..
                            '6' => {
                                i = 3;
                                break :blk .double;
                            },
                            '3' => {
                                i = 3;
                                break :blk .float;
                            },
                            else => if (strEql(identifier[1..5], "loat")) switch (identifier[5]) {
                                '1' => if (strEql(identifier[6..], "6_t")) return @This(){ .primitive = .{ .data = .float } } else .float,
                                '3' => if (strEql(identifier[6..], "2_t")) return @This(){ .primitive = .{ .data = .float } } else .float,
                                '6' => if (strEql(identifier[6..], "4_t")) return @This(){ .primitive = .{ .data = .double } } else .float,
                                else => break :blk .float, //
                            } else .float,
                        },
                        'i' => switch (identifier[1]) {
                            '6' => {
                                i = 3;
                                break :blk .int64_t;
                            },
                            'm' => {
                                i = 0; // image
                                break :blk .float;
                            },

                            else => {
                                i = 2;
                                break :blk .int;
                            },
                        },
                        'u' => switch (identifier[1]) {
                            '6' => {
                                i = 3;
                                break :blk .uint64_t;
                            },
                            else => {
                                i = 2;
                                break :blk .uint;
                            },
                        },
                        else => .float,
                    };
                    if (identifier.len > i) {
                        switch (identifier[i]) {
                            'i' => if (strEql(identifier[i + 1 ..], "mage")) if (Image.Kind.parse(identifier[i + 5 ..])) |kind|
                                return @This(){ .image = .{ .type = base, .kind = kind } },
                            's' => if (strEql(identifier[i + 1 ..], "ampler")) if (Sampler.parse(identifier[i + 7 ..], base)) |sampler|
                                return @This(){ .sampler = sampler },
                            't' => if (strEql(identifier[i + 1 ..], "exture")) if (Image.Kind.parse(identifier[i + 7 ..])) |kind|
                                return @This(){ .texture = .{ .type = base, .kind = kind } },
                            else => {},
                        }
                    }
                },
            }
            return null;
        }
    };
};

pub const Symbol = struct {
    name: String,
    content: Content,

    pub fn copy(self: @This(), allocator: std.mem.Allocator) !@This() {
        return Symbol{
            .name = try allocator.dupe(u8, self.name),
            .type = self.type,
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.content.deinit(allocator);
    }

    /// Mangles the function name and parameter types into a unique identifier
    pub fn mangle(allocator: std.mem.Allocator, name: String, parameters: []String) !String {
        var result = std.ArrayListUnmanaged(u8).empty;
        errdefer result.deinit(allocator);

        var w = result.writer(allocator);
        w.print("{s}_{d}", .{ name, parameters.len });
        for (parameters) |param| {
            try w.print("_{s}", .{param});
        }
        return result.toOwnedSlice(allocator);
    }

    pub const Content = struct {
        /// Data type or return type
        type: Symbol.Type,
        /// If the expression is a constant, this is the value. Only unsigned numeric constants are supported.
        /// (they are really used only for resolving statically known array sizes)
        constant: ?u64 = null,

        pub fn copy(self: @This(), allocator: std.mem.Allocator) !@This() {
            return .{
                .type = try self.type.copy(allocator),
                .constant = self.constant,
            };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.type.deinit(allocator);
        }

        pub fn toPayload(self: @This(), allocator: std.mem.Allocator) !decls.instrumentation.Expression {
            return .{
                .type = try self.type.toPayload(allocator),
                .is_constant = self.constant != null,
                .constant = if (self.constant) |c| c else 0,
            };
        }
    };

    pub const Type = union(enum) {
        array: Array,
        /// The slice points to the source code or constant memory
        basic: String,

        pub const Array = struct {
            /// The slice points to the source code or constant memory
            base: String,
            dim: []usize,

            pub fn copy(self: @This(), allocator: std.mem.Allocator) !@This() {
                return .{
                    .base = try allocator.dupe(u8, self.base),
                    .dim = try allocator.dupe(usize, self.dim),
                };
            }
        };

        pub fn base(self: @This()) String {
            return switch (self) {
                .array => |array| array.base,
                .basic => |basic| basic,
            };
        }

        pub fn copy(self: @This(), allocator: std.mem.Allocator) !@This() {
            return switch (self) {
                .array => |array| .{
                    .array = try array.copy(allocator),
                },
                .basic => |basic| .{
                    .basic = try allocator.dupe(u8, basic),
                },
            };
        }

        pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
            switch (self.*) {
                .array => |*array| {
                    allocator.free(array.dim);
                },
                .basic => {},
            }
        }

        pub fn format(
            self: @This(),
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            switch (self) {
                .basic => |basic| try writer.writeAll(basic),
                .array => |array| {
                    try writer.writeAll(array.base);
                    for (array.dim) |d| {
                        try writer.print("[{d}]", .{d});
                    }
                },
            }
        }

        /// Some types in the spec have a `[]` suffix to indicate that they are arrays
        pub fn parse(allocator: std.mem.Allocator, identifier: String) !@This() {
            if (std.mem.indexOfScalar(u8, identifier, '[')) |i| {
                return .{
                    .array = .{
                        .base = identifier[0..i], // TODO preprocess the spec to not require doing this
                        .dim = if (std.fmt.parseInt(usize, identifier[i..], 0)) |n|
                            try allocator.dupe(usize, &.{n})
                        else |_|
                            &.{},
                    },
                };
            }
            return .{
                .basic = identifier,
            };
        }

        pub fn toPayload(self: @This(), allocator: std.mem.Allocator) !decls.instrumentation.Type {
            return switch (self) {
                .basic => |basic| {
                    return .{
                        .basic = try allocator.dupeZ(u8, basic),
                    };
                },
                .array => |array| {
                    return .{
                        .basic = try allocator.dupeZ(u8, array.base),
                        .array = try allocator.dupeZ(usize, array.dim),
                    };
                },
            };
        }
    };

    /// Payload for hashing functions with overloads
    pub const Overload = struct {
        name: String,
        parameters: []const Symbol.Type,

        pub const Context = struct {
            // TODO match only by part of the overload
            pub fn hash(_: @This(), key: Overload) u64 {
                var h = std.hash.Wyhash.init(0);
                h.update(key.name);
                for (key.parameters) |p| {
                    switch (p) {
                        .basic => |basic| h.update(basic),
                        .array => |array| {
                            h.update(array.base);
                            h.update(std.mem.sliceAsBytes(array.dim));
                        },
                    }
                }
                return h.final();
            }

            pub const eql = std.hash_map.getAutoEqlFn(Overload, @This());
        };
    };
};

/// For fast switch-branching on strings
fn hashStr(str: String) u32 {
    return std.hash.CityHash32.hash(str);
}

fn strEql(a: String, b: String) bool {
    return std.mem.eql(u8, a, b);
}
