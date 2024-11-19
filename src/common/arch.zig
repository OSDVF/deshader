const std = @import("std");

pub fn archToVcpkg(t: std.Target.Cpu.Arch) []const u8 {
    return switch (t) {
        .x86_64 => "x64",
        .aarch64, .aarch64_be, .aarch64_32 => "arm64",
        .arm, .armeb => "arm",
        .mips64, .mips64el => "mips64",
        else => @tagName(t),
    };
}
