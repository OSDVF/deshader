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

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const file = std.io.getStdOut();
    try generateStubs(allocator, file);
}

pub const GenerateStubsStep = struct {
    step: std.Build.Step,
    output: []const u8,
    short_names: bool,

    /// output path will be copied
    pub fn init(b: *std.Build, output: []const u8, short_names: bool) GenerateStubsStep {
        return @as(
            GenerateStubsStep,
            .{
                .output = b.dupe(output),
                .short_names = short_names,
                .step = std.Build.Step.init(
                    .{
                        .name = "generate_stubs_impl",
                        .makeFn = GenerateStubsStep.makeFn,
                        .owner = b,
                        .id = .custom,
                    },
                ),
            },
        );
    }

    pub fn makeFn(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        const self: *@This() = @fieldParentPtr("step", step);
        const node = options.progress_node.start("Generate Stubs", 1);
        const file = try std.fs.createFileAbsolute(self.output, .{});
        defer file.close();
        try generateStubs(step.owner.allocator, file, self.short_names);
        defer node.end();
        defer self.step.owner.allocator.free(self.output);
    }
};
/// Generates stubs for all function declarations in the main.zig file and writes them to the output file.
///
/// The function takes an allocator and an output file as arguments. It parses the main.zig file using the Zig AST parser,
/// iterates over all root declarations, and for each function declaration, it writes an extern declaration to the output file.
///
/// # Arguments
///
/// - `allocator` : The allocator to use for parsing the main.zig file.
/// - `output` : The output file to write the generated stubs to.
///
/// # Errors
///
/// The function returns an error if there is an issue with parsing the main.zig file or writing to the output file.
pub fn generateStubs(allocator: std.mem.Allocator, output: std.fs.File, short_names: bool) !void {
    // Struct decalrations
    try output.writeAll(@embedFile("../src/declarations/shaders.zig"));
    try output.writeAll(@embedFile("../src/declarations/instruments.zig"));

    // Function declarations
    var tree = try std.zig.Ast.parse(allocator, @embedFile("../src/main.zig"), .zig);
    defer tree.deinit(allocator);

    for (tree.rootDecls()) |rootDecl| {
        const declNode: std.zig.Ast.Node = tree.nodes.get(rootDecl);
        switch (declNode.tag) {
            .fn_decl => {
                const protoStart = tree.tokens.get(tree.nodes.get(declNode.data.lhs).main_token).start;
                var protoEnd = tree.tokens.get(tree.nodes.get(declNode.data.rhs).main_token).start - 1;
                while (tree.source[protoEnd - 1] == ' ') {
                    protoEnd -= 1;
                }
                if (short_names) {
                    var buffer: [1]std.zig.Ast.Node.Index = undefined;
                    const f = tree.fullFnProto(&buffer, declNode.data.lhs);
                    const l_paren = tree.tokens.get(f.?.lparen).start;
                    const func_name = tree.source[protoStart..l_paren];

                    if (std.mem.indexOf(u8, tree.source[protoStart - 7 .. protoStart], "export") != null) {
                        try output.writeAll("pub const ");
                        try output.writeAll(&.{std.ascii.toLower(func_name[11])});
                        try output.writeAll(func_name[12..]);
                        try output.writeAll(" = @extern(*const fn ");
                        try output.writeAll(tree.source[l_paren..protoEnd]);
                        try output.writeAll(", .{.name = \"");
                        try output.writeAll(func_name[3..]);
                        try output.writeAll("\" });\n");
                    }
                } else {
                    if (std.mem.indexOf(u8, tree.source[protoStart - 7 .. protoStart], "export") != null) {
                        try output.writeAll("pub extern ");
                        try output.writeAll(tree.source[protoStart..protoEnd]);
                        try output.writeAll(";\n");
                    }
                }
            },
            else => {},
        }
    }
    try output.setEndPos(try output.getPos());
}
