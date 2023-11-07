const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const file = std.io.getStdOut();
    try generateStubs(allocator, file);
}

pub const GenerateStubsStep = struct {
    step: std.build.Step,
    output: std.fs.File,

    pub fn init(b: *std.build.Builder, output: std.fs.File) GenerateStubsStep {
        return @as(
            GenerateStubsStep,
            .{
                .output = output,
                .step = std.build.Step.init(
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

    pub fn makeFn(step: *std.build.Step, progressNode: *std.Progress.Node) anyerror!void {
        const self: *@This() = @fieldParentPtr(@This(), "step", step);
        progressNode.activate();
        try generateStubs(step.owner.allocator, self.output);
        progressNode.end();
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
pub fn generateStubs(allocator: std.mem.Allocator, output: std.fs.File) !void {
    // Struct decalrations
    try output.writeAll(@embedFile("../declarations/shaders.zig"));

    // Function declarations
    var tree = try std.zig.Ast.parse(allocator, @embedFile("../main.zig"), .zig);
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
                if (std.mem.indexOf(u8, tree.source[protoStart - 7 .. protoStart], "export") != null) {
                    try output.writeAll("pub extern ");
                    try output.writeAll(tree.source[protoStart..protoEnd]);
                    try output.writeAll(";\n");
                }
            },
            else => {},
        }
    }
}
