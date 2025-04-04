const std = @import("std");

pub fn convert(from: anytype, to: anytype) @TypeOf(to) {
    var result = to;
    inline for (std.meta.fields(@TypeOf(from))) |field| {
        @field(result, field.name) = @field(from, field.name);
    }
    return result;
}
