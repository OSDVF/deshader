const std = @import("std");
const deshader = @import("deshader");
const header_gen = @import("header_gen");
const options = @import("options");
pub fn main() !void {
    comptime var gen = header_gen.HeaderGen(deshader, "deshader", options.emitHDir).init();
    gen.exec(header_gen.C_Generator(.C));
    gen.exec(header_gen.C_Generator(.Cpp));
}
