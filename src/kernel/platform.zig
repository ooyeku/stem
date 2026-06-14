const std = @import("std");
const builtin = @import("builtin");

pub const Pid = std.process.Child.Id;

/// Sentinel "no PID set" value for `Pid` — type differs by OS.
/// POSIX: `pid_t = i32`, so the zero PID is `0`.
/// Windows: `Pid = HANDLE = *anyopaque`. `*anyopaque` doesn't
/// allow address zero, so we use `INVALID_HANDLE_VALUE` (all-ones)
/// as the "no PID yet" marker — matches the Win32 convention for
/// "this handle hasn't been opened."
/// Use this anywhere you'd write `0` to mean "no PID yet."
pub fn nullPid() Pid {
    if (builtin.os.tag == .windows) {
        return @ptrFromInt(std.math.maxInt(usize));
    } else {
        return 0;
    }
}

/// Returns true when `pid` equals `nullPid()`. Equivalent of the
/// POSIX `pid == 0` check, lifted to handle the Windows HANDLE case.
pub fn pidIsNull(pid: Pid) bool {
    if (builtin.os.tag == .windows) {
        return @intFromPtr(pid) == std.math.maxInt(usize);
    } else {
        return pid == 0;
    }
}

/// Render a `Pid` as a `u64` for logging / status messages.
/// POSIX: returns the integer PID widened to u64.
/// Windows: returns the HANDLE's pointer address (which is how Win32
/// process handles are conventionally displayed in diagnostics).
pub fn pidToDisplay(pid: Pid) u64 {
    if (builtin.os.tag == .windows) {
        return @intCast(@intFromPtr(pid));
    } else {
        return @intCast(pid);
    }
}

/// Cross-platform environment-variable lookup.
///
/// Zig 0.16's `std.process.Environ.getPosix` is — by spec — POSIX-only;
/// on Windows it tries to call `GlobalBlock.view()` which doesn't exist
/// and the build fails. Every place in stem that previously called
/// `env.getPosix(key)` should now call `platform.getEnv(allocator,
/// environ_block, key)` so the right backend gets picked per OS.
///
/// Returns an owned slice (caller frees) so the same shape works for
/// both backends:
/// * POSIX: dups the borrowed value out of the environ block.
/// * Windows: routes through `std.process.getEnvVarOwned`, which
///   talks to `GetEnvironmentVariableW` and returns an allocated
///   slice already.
///
/// `null` means the variable isn't set. Errors propagate (typically
/// `OutOfMemory`).
pub fn getEnv(
    allocator: std.mem.Allocator,
    environ_block: std.process.Environ.Block,
    key: []const u8,
) !?[]u8 {
    const env: std.process.Environ = .{ .block = environ_block };
    // `getAlloc` is the cross-platform Environ accessor — on Windows
    // it dispatches through `createMap → putWindowsBlock` (reads the
    // PEB), on POSIX it walks the block normally. Avoids the broken
    // `getPosix → GlobalBlock.view()` path that doesn't compile on
    // Windows in Zig 0.16.
    const owned = env.getAlloc(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return null,
        error.InvalidWtf8 => return null,
        else => return err,
    };
    return owned;
}

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

/// Return the `std.process.spawn` process-group setting that makes a spawned
/// POSIX child become the leader of a new process group. Its descendants then
/// inherit that group, letting stem terminate the whole LSP subtree with one
/// group signal. Windows has no equivalent here without Job Objects, so it
/// leaves process-group handling disabled.
pub fn childProcessGroupForSpawn() ?std.posix.pid_t {
    if (builtin.os.tag == .windows) return null;
    return 0;
}

pub fn killProcessTree(pid: Pid) void {
    killProcessTreeWith(pid, false);
}

pub fn killProcessTreeForce(pid: Pid) void {
    killProcessTreeWith(pid, true);
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

fn killProcessTreeWith(pid: Pid, force: bool) void {
    if (builtin.os.tag == .windows) {
        killProcessWith(pid, force);
        return;
    }

    if (pid <= 0) return;
    const sig = if (force) std.posix.SIG.KILL else std.posix.SIG.INT;
    _ = std.posix.kill(-pid, sig) catch {
        _ = std.posix.kill(pid, sig) catch {};
    };
}

test "getProcessId: returns a positive id that's stable within a process" {
    const a = getProcessId();
    const b = getProcessId();
    try std.testing.expect(a > 0);
    try std.testing.expectEqual(a, b);
}

test "childProcessGroupForSpawn requests an isolated process group on POSIX" {
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(@as(?std.posix.pid_t, null), childProcessGroupForSpawn());
    } else {
        try std.testing.expectEqual(@as(?std.posix.pid_t, 0), childProcessGroupForSpawn());
    }
}
