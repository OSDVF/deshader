const std = @import("std");
const builtin = @import("builtin");

const String = []const u8;

pub fn archToVcpkg(t: std.Target.Cpu.Arch) String {
    return switch (t) {
        .x86_64 => "x64",
        .aarch64, .aarch64_be => "arm64",
        .arm, .armeb => "arm",
        .mips64, .mips64el => "mips64",
        .powerpc64le => "ppc64le",
        else => @tagName(t),
    };
}

pub fn archToOSXArch(t: std.Target.Cpu.Arch) String {
    return switch (t) {
        .aarch64, .aarch64_be => "arm64",
        else => @tagName(t),
    };
}

pub fn isNative(t: std.Target) bool {
    return t.os.tag == builtin.target.os.tag and t.cpu.arch == builtin.target.cpu.arch;
}

pub fn targetToVcpkgTriplet(a: std.mem.Allocator, t: std.Target) !String {
    const native = isNative(t);
    return try std.mem.concat(a, u8, &.{ archToVcpkg(t.cpu.arch), "-", switch (t.os.tag) {
        .windows => "windows",
        .macos => "osx",
        .linux => "linux",
        else => @tagName(t.os.tag),
    }, if (native) "" else "-zig" });
}
