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

//! GLSL semantic analysis of the AST.
//! Aside from the glsl_analyzer, this can also bse used to resolve the type of expressions.
//! Also does not depend on the `Workspace` struct.

const std = @import("std");
const analyzer = @import("glsl_analyzer");

const String = []const u8;
const Node = u32;

pub const Scope = struct {
    functions: std.StringHashMapUnmanaged(Function) = .empty,
    variables: std.StringHashMapUnmanaged(Symbol) = .empty,
    parent: ?*Scope = null,
    function_counter: *usize,

    pub fn fill(
        self: *@This(),
        allocator: std.mem.Allocator,
        tree: analyzer.parse.Tree,
        node: Node,
        source: String,
    ) !?analyzer.syntax.ExternalDeclaration {
        if (analyzer.syntax.ExternalDeclaration.tryExtract(tree, node)) |ext| {
            switch (ext) {
                .variable => |decl| {
                    const specifier: analyzer.syntax.TypeSpecifier = decl.get(.specifier, tree).?;
                    var it = decl.get(.variables, tree).?.iterator();
                    while (it.next(tree)) |v| {
                        const name = tree.nodeSpan(v.get(.name, tree).?.getNode()).text(source);
                        try self.variables.put(allocator, name, Symbol{
                            .name = name,
                            .type = specifier,
                        });
                    }
                },
                .function => |decl| {
                    const name = decl.get(.identifier, tree).?.text(source, tree);
                    try self.functions.put(allocator, name, Function{
                        .symbol = Symbol{
                            .name = name,
                            .type = decl.get(.specifier, tree).?,
                        },
                        .id = self.function_counter.*,
                    });
                    self.function_counter.* += 1;
                },
                else => {},
            }
            return ext;
        }
        return null;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.functions.deinit(allocator);
        self.variables.deinit(allocator);
    }

    pub fn localSymbol(self: *const @This(), name: String) ?Symbol {
        if (self.variables.get(name)) |variable| {
            return variable;
        }

        if (self.functions.get(name)) |function| {
            return function.symbol;
        }

        return null;
    }

    pub fn visibleSymbol(self: *const @This(), name: String) ?Symbol {
        if (self.localSymbol(name)) |symbol| {
            return symbol;
        }

        if (self.parent) |parent| {
            return parent.visibleSymbol(name);
        }

        return null;
    }

    pub fn resolveExpression(
        self: *const @This(),
        expr: analyzer.syntax.Expression,
        tree: analyzer.parse.Tree,
        source: String,
    ) ?analyzer.syntax.TypeSpecifier {
        switch (expr) {
            .identifier => |i| {
                const name = i.get(.name).?.text(source, tree);
                if (self.localSymbol(name)) |symbol| {
                    return symbol.type;
                }
            },
        }
        return null;
    }
};

pub const Type = union(enum) {
    primitive: Primitive,
    array: struct {
        type: Primitive,
        size: usize,
    },
    sampler: Sampler,
    texture: Sampler,
    image: ImageType,
    @"struct": String,

    pub const Primitive = struct {
        data: Data,
        size_x: u2, //1, 2, 3, 4
        size_y: u2,
    };

    pub const Data = enum {
        uint,
        int,
        float,
        double,
        bool,
    };

    pub const Sampler = struct {
        type: ImageType,
        shadow: bool,
        rect: bool,
    };

    pub const ImageType = union(enum) {
        Buffer: void,
        normal: Normal,
        Unknown: void,

        pub const Normal = struct {
            type: Data,
            array: bool,
            ms: bool,
            size: Size,

            pub const Size = union(enum) {
                @"1D": usize,
                @"2D": [2]usize,
                @"3D": [3]usize,
                Cube: [2]usize,
            };
        };
    };

    fn parseMultidim(t: String, d: Data, comptime allow: enum { any, mat, vec }) ?Primitive {
        // FSA-like parsing
        switch (hashStr(t[0..3])) {
            h: {
                break :h hashStr("vec");
            } => {
                if (allow != .mat) {
                    const size_x = t[3] - '0';
                    return Primitive{
                        .data = d,
                        .size_x = size_x,
                        .size_y = 1,
                    };
                }
            },
            h: {
                break :h hashStr("mat");
            } => {
                if (allow != .vec) {
                    const size_x = t[3] - '0';
                    if (t.len == 5 or (t.len == 6 and t[4] != 'x')) return null;

                    const size_y = if (t.len == 6) t[5] - '0' else size_x;
                    return Primitive{
                        .data = d,
                        .size_x = size_x,
                        .size_y = size_y,
                    };
                }
            },
            else => {},
        }
        return null;
    }

    /// Pass the type (2DARRAY, RECTSHADOW, etc.) to this function.
    fn parseImageType(t: String) ?ImageType {
        if (t.len >= 2) {
            var size: ImageType.Normal.Size = undefined;
            var after: usize = undefined;
            if (strEql(t, "BUFFER")) {
                return ImageType{.Buffer};
            } else if (t[1] == 'D') {
                size = switch (t[0]) {
                    '1' => .@"1D",
                    '2' => .@"2D",
                    '3' => .@"3D",
                    else => return null,
                };
                after = 2;
            } else if (strEql(t[0..4], "CUBE")) {
                size = .Cube;
                after = 4;
            } else {
                return null;
            }
        }
    }

    /// Parse type name token into a `Type` struct.
    pub fn fromSpecifier(spec: analyzer.syntax.TypeSpecifier, source: String, tree: analyzer.parse.Tree) @This() {
        const t: String = spec.get(.identifier).?.text(source, tree);
        // FSA-like parsing
        switch (t.len) {
            3 => {
                if (strEql(t, "int")) {
                    return .{ .Primitive = Primitive{
                        .data = .int,
                        .size_x = 1,
                        .size_y = 1,
                    } };
                }
            },
            4 => {
                switch (t[0]) {
                    'u' => {
                        if (strEql(t[1..], "int")) {
                            return .{ .Primitive = Primitive{
                                .data = .uint,
                                .size_x = 1,
                                .size_y = 1,
                            } };
                        }
                    },
                    'b' => {
                        if (strEql(t[1..], "ool")) {
                            return .{ .Primitive = Primitive{
                                .data = .bool,
                                .size_x = 1,
                                .size_y = 1,
                            } };
                        }
                    },
                    'v' => {
                        if (strEql(t[1..], "oid")) {
                            return .{ .ReturnType = .Void };
                        }
                    },
                    else => { //vecX or matX
                        if (parseMultidim(t, .float, .any)) |m| return m;
                    },
                }
            },
            5 => {
                if (strEql(t, "float")) {
                    return .{ .Primitive = Primitive{
                        .data = .float,
                        .size_x = 1,
                        .size_y = 1,
                    } };
                } else switch (t[0]) {
                    'd' => { //dvecX or dmatX
                        if (parseMultidim(t[1..], .double, .any)) |m| return m;
                    },
                    'b' => { //bvecX
                        if (parseMultidim(t[1..], .bool, .vec)) |m| return m;
                    },
                    'i' => { // ivecX
                        if (parseMultidim(t[1..], .int, .vec)) |m| return m;
                    },
                    'u' => { // uvecX
                        if (parseMultidim(t[1..], .uint, .vec)) |m| return m;
                    },
                }
            },
            6 => {
                switch (t[0]) {
                    'd' => {
                        if (strEql(t[1..], "ouble")) {
                            return .{ .Primitive = Primitive{
                                .data = .double,
                                .size_x = 1,
                                .size_y = 1,
                            } };
                        }
                    },
                    else => { //matXxY
                        if (parseMultidim(t[1..], .float, .mat)) |m| return m;
                    },
                }
            },
            7 => {
                switch (t[0]) {
                    'd' => { // dmatXxY
                        if (parseMultidim(t[1..], .double)) |m| return m;
                    },
                    'i' => {
                        if (strEql(t[1..], "mage")) {}
                    },
                }
            },
        }

        // if no type was matched, it's a struct
        return .{ .@"struct" = t };
    }
};

pub const Symbol = struct {
    name: String,
    type: analyzer.syntax.TypeSpecifier,

    pub fn copy(self: @This(), allocator: std.mem.Allocator) !@This() {
        return Symbol{
            .name = try allocator.dupe(u8, self.name),
            .type = self.type,
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const Function = struct {
    symbol: Symbol,
    id: usize,
};

/// For fast switch-branching on strings
fn hashStr(str: String) u32 {
    return std.hash.CityHash32.hash(str);
}

fn strEql(a: String, b: String) bool {
    return std.mem.eql(u8, a, b);
}
