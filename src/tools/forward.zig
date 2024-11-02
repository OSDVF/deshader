// Copyright (C) 2024  Ondřej Sabela
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
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

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
