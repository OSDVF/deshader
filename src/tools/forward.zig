const transitive_procs = @import("transitive_exports");
const options = @import("options");

comptime {
    //
    // Transitively export all Dehsader
    //
    const recursive_procs_decls = @typeInfo(transitive_procs).Struct.decls;

    @setEvalBranchQuota(150000); // Really a lot of functions to export
    for (recursive_procs_decls) |decl| {
        const symbol_name = decl.name;
        const ex_symbol = @extern(*const anyopaque, .{ .name = symbol_name, .library_name = options.deshaderLibName });
        @export(ex_symbol, .{ .name = symbol_name });
    }
} // end comptime
