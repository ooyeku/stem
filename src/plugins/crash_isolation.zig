//! Crash isolation for plugin .dylib/.so calls.
//!
//! Plugins run on their own threads inside the editor process. A segfault
//! anywhere in a plugin would normally take the whole editor down — we
//! lose unsaved buffers, all open LSPs, the user's whole session. That's
//! a single misbehaving plugin holding all of stem hostage.
//!
//! This module gives `pluginMain` a way to wrap each call into plugin
//! code with a setjmp/longjmp-based "checkpoint": if a SIGSEGV or SIGBUS
//! fires while inside the wrapped region, the signal handler longjmps
//! back to the checkpoint, the caller observes a `Crashed` return, and
//! the plugin is marked dead. The editor keeps running.
//!
//! Caveats — the things this DOESN'T protect against:
//!
//!   * Memory corruption that completes "successfully" (bad write to a
//!     valid stem address). The plugin doesn't fault, just silently
//!     corrupts state. Only out-of-process isolation fixes this.
//!   * Locks held by the plugin at crash time. Future code may deadlock
//!     trying to take that lock. We log loudly and mark the plugin dead,
//!     but the user may need to restart stem if the plugin held a shared
//!     mutex.
//!   * Allocations made by the plugin since the checkpoint. They're
//!     leaked. Bounded by per-call allocation volume; acceptable for the
//!     stability win.
//!
//! Out-of-process plugins would address all of these, at the cost of a
//! big refactor and per-call IPC overhead. This module is the pragmatic
//! middle ground.

const std = @import("std");
const builtin = @import("builtin");

/// Generous sigjmp_buf-sized opaque storage. macOS's sigjmp_buf is
/// ~152 bytes (32-bit) / ~304 bytes (64-bit). glibc's is up to 200 bytes
/// for the buffer plus signal mask. 1024 bytes covers any reasonable
/// implementation with room to spare.
pub const JmpBuf = [1024]u8;

/// Per-thread checkpoint slot. The signal handler reads this; if non-null
/// when SIGSEGV/SIGBUS fires, it siglongjmps back to that buffer.
threadlocal var current_checkpoint: ?*JmpBuf = null;
threadlocal var crash_signal: i32 = 0;

// ---------- POSIX setjmp/longjmp interop ----------
//
// macOS exposes `sigsetjmp` as a real function. Linux glibc's
// `sigsetjmp` is a macro that calls `__sigsetjmp`; we have to use that
// directly. Zig `extern "c"` only emits an undefined reference, so it's
// safe to declare both — only the called one needs to link.

extern "c" fn sigsetjmp(env: *JmpBuf, savesigs: c_int) c_int;
extern "c" fn __sigsetjmp(env: *JmpBuf, savesigs: c_int) c_int;
extern "c" fn siglongjmp(env: *JmpBuf, val: c_int) noreturn;

inline fn doSetjmp(env: *JmpBuf) c_int {
    return switch (builtin.target.os.tag) {
        .linux => __sigsetjmp(env, 1),
        else => sigsetjmp(env, 1),
    };
}

// ---------- Signal handler ----------

var installed: std.atomic.Value(bool) = .{ .raw = false };

fn crashHandler(sig: std.c.SIG) callconv(.c) void {
    if (current_checkpoint) |env| {
        crash_signal = @intCast(@intFromEnum(sig));
        // Reset the slot so a faulty siglongjmp can't loop. Caller's
        // `runIsolated` will set it again on the next checkpoint.
        current_checkpoint = null;
        siglongjmp(env, 1);
    }
    // No checkpoint on this thread — restore the default disposition
    // and re-raise so the OS produces a real crash report instead of
    // looping in the handler. NOTE: stem currently doesn't install
    // this handler at all (see manager.zig). Kept here for future
    // out-of-process / wasm-sandbox boundaries that may want it
    // back, scoped to specific call sites with a checkpoint.
    var dfl: std.posix.Sigaction = .{
        .handler = .{ .handler = @ptrFromInt(0) },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig, &dfl, null);
    _ = std.c.raise(sig);
}

/// Install SIGSEGV/SIGBUS handlers. Idempotent — calling more than once
/// is a no-op. Returns true on success, false if the platform doesn't
/// support this (Windows) or sigaction failed.
pub fn install() bool {
    if (builtin.target.os.tag == .windows) return false;
    if (installed.swap(true, .acquire)) return true;

    // SA_ONSTACK so the handler runs on the signal stack if one is
    // installed (it isn't by default, but harmless to request). Don't
    // set SA_NODEFER — we want the signal blocked while in the handler
    // so siglongjmp's mask save/restore works cleanly.
    const sa: std.posix.Sigaction = .{
        .handler = .{ .handler = crashHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.ONSTACK,
    };
    std.posix.sigaction(.SEGV, &sa, null);
    std.posix.sigaction(.BUS, &sa, null);
    return true;
}

pub const Result = enum { ok, crashed };

/// Run `func` with crash protection. If `func` (or anything it calls,
/// including transitively into a plugin .dylib) hits SIGSEGV / SIGBUS,
/// returns `.crashed` instead of unwinding through the signal.
///
/// Typical usage from `pluginMain`:
///
///   ```
///   if (crash_isolation.runIsolated(.{plugin}, callPluginInit) == .crashed) {
///       plugin.state = .failed;
///       return;
///   }
///   ```
///
/// `Func` should be a `fn (Args) void`. Errors must be communicated
/// out-of-band (via the args or shared state) — we can't propagate a
/// Zig error union through longjmp.
pub fn runIsolated(args: anytype, comptime func: anytype) Result {
    if (builtin.target.os.tag == .windows) {
        // No protection available — just call through.
        @call(.auto, func, args);
        return .ok;
    }

    var env: JmpBuf = @splat(0);
    if (doSetjmp(&env) != 0) {
        // We came back via longjmp. The plugin crashed.
        return .crashed;
    }

    const prev = current_checkpoint;
    current_checkpoint = &env;
    defer current_checkpoint = prev;

    @call(.auto, func, args);
    return .ok;
}

/// Last signal that triggered a longjmp on this thread. Useful for log
/// messages — `SEGV` vs `BUS` gives a hint about whether the plugin
/// dereferenced a bad pointer (SEGV) or did unaligned access (BUS).
pub fn lastCrashSignal() i32 {
    return crash_signal;
}

test "runIsolated: clean run returns .ok" {
    const Inc = struct {
        fn run(counter: *u32) void {
            counter.* += 1;
        }
    };
    var n: u32 = 0;
    const res = runIsolated(.{&n}, Inc.run);
    try std.testing.expectEqual(Result.ok, res);
    try std.testing.expectEqual(@as(u32, 1), n);
}

test "runIsolated: checkpoint slot is restored after a clean run" {
    // A nested call shouldn't leave the outer's checkpoint dangling.
    const Outer = struct {
        fn run(_: void) void {
            const Inner = struct {
                fn run2(_: void) void {}
            };
            _ = runIsolated(.{{}}, Inner.run2);
        }
    };
    _ = runIsolated(.{{}}, Outer.run);
    try std.testing.expect(current_checkpoint == null);
}
