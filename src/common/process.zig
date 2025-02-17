const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig").DeshaderLog;

const String = []const u8;

const c = @cImport({
    if (builtin.os.tag == .windows) {
        @cInclude("processthreadsapi.h"); // for GetThreadDescription
    } else if (builtin.os.tag == .linux) {}
});

/// Blocks until child process terminates and then cleans up all resources.
pub fn waitNoFail(self: *std.process.Child) !std.process.Child.Term {
    const term = if (builtin.os.tag == .windows)
        try waitWindows(self)
    else
        try waitPosix(self);

    self.id = undefined;

    return term;
}

pub fn wailNoFailReport(process: *std.process.Child) ?std.process.Child.Term {
    if (waitNoFail(process)) |term| {
        switch (term) {
            .Exited => |status| {
                if (status != 0) {
                    log.err("Process {} exited with status {d}", .{ process.id, status });
                }
            },
            .Signal => |signal| {
                log.err("Process {} terminated with signal {d}", .{ process.id, signal });
            },
            .Stopped => |signal| {
                log.err("Process {} stopped with signal {d}", .{ process.id, signal });
            },
            .Unknown => |result| {
                log.err("Process {} terminated with unknown result {d}", .{ process.id, result });
            },
        }
        return term;
    } else |err| {
        log.err("Failed to wait for process {}: {}", .{ process.id, err });
    }
    return null;
}

fn waitpid(pid: std.posix.pid_t, flags: u32) !std.posix.WaitPidResult {
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) {
        const rc = std.posix.system.waitpid(pid, &status, @intCast(flags));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return .{
                .pid = @intCast(rc),
                .status = @bitCast(status),
            },
            .INTR => continue,
            else => |code| {
                log.err("waitpid: {s}", .{@tagName(code)});
                return error.WaitPid;
            },
        }
    }
}

fn cleanupStreams(self: *std.process.Child) void {
    if (self.stdin) |*stdin| {
        stdin.close();
        self.stdin = null;
    }
    if (self.stdout) |*stdout| {
        stdout.close();
        self.stdout = null;
    }
    if (self.stderr) |*stderr| {
        stderr.close();
        self.stderr = null;
    }
}

fn waitWindows(self: *std.process.Child) !std.process.Child.Term {
    if (self.term) |term| {
        cleanupStreams(self);
        return term;
    }

    try waitUnwrappedWindows(self);
    return self.term.?;
}

fn waitPosix(self: *std.process.Child) !std.process.Child.Term {
    if (self.term) |term| {
        cleanupStreams(self);
        return term;
    }

    try waitUnwrapped(self);
    return self.term.?;
}

fn waitUnwrappedWindows(self: *std.process.Child) !void {
    const result = std.os.windows.WaitForSingleObjectEx(self.id, std.os.windows.INFINITE, false);

    self.term = @as(std.process.Child.SpawnError!std.process.Child.Term, x: {
        var exit_code: std.os.windows.DWORD = undefined;
        if (std.os.windows.kernel32.GetExitCodeProcess(self.id, &exit_code) == 0) {
            break :x std.process.Child.std.process.Child.Term{ .Unknown = 0 };
        } else {
            break :x std.process.Child.std.process.Child.Term{ .Exited = @as(u8, @truncate(exit_code)) };
        }
    });

    if (self.request_resource_usage_statistics) {
        self.resource_usage_statistics.rusage = try std.os.windows.GetProcessMemoryInfo(self.id);
    }

    std.posix.close(self.id);
    std.posix.close(self.thread_handle);
    cleanupStreams(self);
    return result;
}

fn waitUnwrapped(self: *std.process.Child) !void {
    const res: std.posix.WaitPidResult = res: {
        if (self.request_resource_usage_statistics) {
            switch (builtin.os.tag) {
                .linux, .macos, .ios => {
                    var ru: std.posix.rusage = undefined;
                    const res = std.posix.wait4(self.id, 0, &ru);
                    self.resource_usage_statistics.rusage = ru;
                    break :res res;
                },
                else => {},
            }
        }

        break :res try waitpid(self.id, 0);
    };
    const status = res.status;
    cleanupStreams(self);
    handleWaitResult(self, status);
}

fn handleWaitResult(self: *std.process.Child, status: u32) void {
    self.term = cleanupAfterWait(self, status);
}

fn destroyPipe(pipe: [2]std.posix.fd_t) void {
    if (pipe[0] != -1) std.posix.close(pipe[0]);
    if (pipe[0] != pipe[1]) std.posix.close(pipe[1]);
}

const ErrInt = std.meta.Int(.unsigned, @sizeOf(anyerror) * 8);

fn writeIntFd(fd: i32, value: ErrInt) !void {
    const file: std.fs.File = .{ .handle = fd };
    file.writer().writeInt(u64, @intCast(value), .little) catch return error.SystemResources;
}

fn readIntFd(fd: i32) !ErrInt {
    const file: std.fs.File = .{ .handle = fd };
    return @intCast(file.reader().readInt(u64, .little) catch return error.SystemResources);
}

fn cleanupAfterWait(self: *std.process.Child, status: u32) !std.process.Child.Term {
    if (self.err_pipe) |err_pipe| {
        defer destroyPipe(err_pipe);

        if (builtin.os.tag == .linux) {
            var fd = [1]std.posix.pollfd{std.posix.pollfd{
                .fd = err_pipe[0],
                .events = std.posix.POLL.IN,
                .revents = undefined,
            }};

            // Check if the eventfd buffer stores a non-zero value by polling
            // it, that's the error code returned by the child process.
            _ = std.posix.poll(&fd, 0) catch unreachable;

            // According to eventfd(2) the descriptor is readable if the counter
            // has a value greater than 0
            if ((fd[0].revents & std.posix.POLL.IN) != 0) {
                const err_int = try readIntFd(err_pipe[0]);
                return @as(std.process.Child.SpawnError, @errorCast(@errorFromInt(err_int)));
            }
        } else {
            // Write maxInt(ErrInt) to the write end of the err_pipe. This is after
            // waitpid, so this write is guaranteed to be after the child
            // pid potentially wrote an error. This way we can do a blocking
            // read on the error pipe and either get maxInt(ErrInt) (no error) or
            // an error code.
            try writeIntFd(err_pipe[1], std.math.maxInt(ErrInt));
            const err_int = try readIntFd(err_pipe[0]);
            // Here we potentially return the fork child's error from the parent
            // pid.
            if (err_int != std.math.maxInt(ErrInt)) {
                return @as(std.process.Child.SpawnError, @errorCast(@errorFromInt(err_int)));
            }
        }
    }

    return statusToTerm(status);
}

fn statusToTerm(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        std.process.Child.Term{ .Exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        std.process.Child.Term{ .Signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        std.process.Child.Term{ .Stopped = std.posix.W.STOPSIG(status) }
    else
        std.process.Child.Term{ .Unknown = status };
}

pub fn getSelfThreadId() if (builtin.os.tag == .windows) std.os.windows.HANDLE else std.c.pthread_t {
    if (builtin.os.tag == .windows) {
        return std.os.windows.GetCurrentThread();
    } else {
        return std.c.pthread_self();
    }
}

pub fn getSelfThreadName(allocator: std.mem.Allocator) !String {
    var result_buffer: [std.Thread.max_name_len:0]u8 = undefined; // On POSIX, thread names are restricted to 16 bytes
    const thread_id = getSelfThreadId();
    if (builtin.os.tag == .windows) {
        var buffer: [std.Thread.max_name_len:0]std.os.windows.WCHAR = undefined;
        const result = c.GetThreadDescription(thread_id, &buffer);
        if (result == 0) {
            return std.os.windows.unexpectedError(std.os.windows.kernel32.GetLastError());
        }
        defer std.os.windows.kernel32.LocalFree(buffer);
        const len = try std.unicode.wtf16LeToWtf8(&result_buffer, buffer);

        return allocator.dupe(u8, result_buffer[0..len]);
    } else {
        const err = std.c.pthread_getname_np(thread_id, @ptrCast(&result_buffer), @intCast(result_buffer.len + 1)); //including the null terminator
        switch (err) {
            .SUCCESS => return allocator.dupe(u8, result_buffer[0..(std.mem.indexOfScalar(u8, &result_buffer, 0) orelse 0) :0]),
            .RANGE => unreachable,
            else => |e| return std.posix.unexpectedErrno(e),
        }
    }
}
