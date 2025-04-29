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

const std = @import("std");
const deshader = @import("deshader");
const header_gen = @import("header_gen");
const options = @import("options");
const Ast = std.zig.Ast;

const Generator = header_gen.HeaderGen(deshader, "deshader", options.h_dir);

/// Dispatch the header generator
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    var gen = Generator.init();

    // Find function argument names
    const allocator = gpa.allocator();
    defer gen.names.deinit(allocator);
    inline for (options.filePaths) |file| {
        const handle = try std.fs.openFileAbsolute(file, .{});
        defer handle.close();
        const content = try handle.readToEndAllocOptions(allocator, 10_000_000, null, 1, 0);
        defer allocator.free(content);
        var ast = try Ast.parse(allocator, content, .zig);
        defer ast.deinit(allocator);

        for (ast.rootDecls()) |decl| {
            var params: [2]Ast.Node.Index = undefined;
            if (ast.fullFnProto(params[0..1], decl)) |proto| {
                // Process global function declarations
                if (proto.name_token) |n| try findFunctionArguments(&ast, proto, try arena_allocator.dupe(u8, ast.tokenSlice(n)), allocator, arena_allocator, &gen);
            } else if (ast.fullVarDecl(decl)) |v| {
                // Process declaration of function pointers in structs
                if (ast.fullContainerDecl(&params, v.ast.init_node)) |c| {
                    for (c.ast.members) |m| {
                        if (ast.fullContainerField(m)) |f| {
                            if (ast.fullPtrType(switch (ast.nodes.items(.tag)[f.ast.type_expr]) {
                                .optional_type => ast.nodes.items(.data)[f.ast.type_expr].lhs,
                                else => f.ast.type_expr,
                            })) |ptr| {
                                if (ast.fullFnProto(params[0..1], ptr.ast.child_type)) |p| {
                                    try findFunctionArguments(
                                        &ast,
                                        p,
                                        try std.mem.join(arena_allocator, ".", &.{ ast.tokenSlice(v.ast.mut_token + 1), ast.tokenSlice(f.ast.main_token) }),
                                        allocator,
                                        arena_allocator,
                                        &gen,
                                    );
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    gen.exec(header_gen.C_Generator(.C));
    gen.exec(header_gen.C_Generator(.Cpp));
}

fn findFunctionArguments(ast: *const Ast, proto: Ast.full.FnProto, fn_name: []const u8, allocator: std.mem.Allocator, arena_allocator: std.mem.Allocator, gen: *Generator) !void {
    var param_names = std.ArrayListUnmanaged([]const u8).empty;
    defer param_names.deinit(arena_allocator);
    // iterate through the parameters
    var it = proto.iterate(ast);
    while (it.next()) |param| {
        if (param.name_token) |name| {
            try param_names.append(arena_allocator, try arena_allocator.dupe(u8, ast.tokenSlice(name)));
        }
    }
    try gen.names.put(allocator, fn_name, try param_names.toOwnedSlice(arena_allocator));
}
