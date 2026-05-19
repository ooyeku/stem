const std = @import("std");
const builtin = @import("builtin");

pub const Pid = std.process.Child.Id;

pub fn getProcessId() i64 {
    if (builtin.os.tag == .windows) {
        const kernel32 = struct {
            extern "kernel32" fn GetCurrentProcessId() u32;
        };
        return @intCast(kernel32.GetCurrentProcessId());
    } else {
        return @intCast(std.c.getpid());
    }
}

pub fn killProcess(pid: Pid) void {
    killProcessWith(pid, false);
}

/// Force-terminate `pid`. Skips any chance for the child to clean up
/// — used on stem's own exit path to avoid waiting on misbehaving LSP
/// servers that ignore polite shutdowns. POSIX: SIGKILL. Windows:
/// TerminateProcess (no clean variant exists).
pub fn killProcessForce(pid: Pid) void {
    killProcessWith(pid, true);
}

fn killProcessWith(pid: Pid, force: bool) void {
    if (builtin.os.tag == .windows) {
        const kernel32 = struct {
            const HANDLE = std.os.windows.HANDLE;
            const BOOL = i32;
            extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: u32) BOOL;
            extern "kernel32" fn CloseHandle(hObject: HANDLE) BOOL;
        };
        _ = kernel32.TerminateProcess(pid, 1);
        _ = kernel32.CloseHandle(pid);
    } else {
        const sig = if (force) std.posix.SIG.KILL else std.posix.SIG.INT;
        _ = std.posix.kill(pid, sig) catch {};
    }
}

test "getProcessId: returns a positive id that's stable within a process" {
    const a = getProcessId();
    const b = getProcessId();
    try std.testing.expect(a > 0);
    try std.testing.expectEqual(a, b);
}
