const std = @import("std");

// pthread_setname_np has *different signatures* on macOS vs Linux —
// a single-arg form on darwin (the calling thread is implicit) and
// a two-arg form on glibc/musl (thread handle + name, both required).
// Calling the macOS variant on Linux passes the name pointer into
// the `thread` slot, which glibc then dereferences as a pthread
// handle → SIGSEGV at libpthread.so. Branch the extern declaration
// so each platform sees the right ABI.
const setname_impl = switch (@import("builtin").os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => struct {
        extern "c" fn pthread_setname_np(name: [*:0]const u8) c_int;
        fn call(name: [*:0]const u8) void {
            _ = pthread_setname_np(name);
        }
    },
    .linux => struct {
        extern "c" fn pthread_self() ?*anyopaque;
        extern "c" fn pthread_setname_np(thread: ?*anyopaque, name: [*:0]const u8) c_int;
        fn call(name: [*:0]const u8) void {
            _ = pthread_setname_np(pthread_self(), name);
        }
    },
    else => struct {
        fn call(_: [*:0]const u8) void {}
    },
};

/// Set the calling thread's name. Best-effort; on macOS the name
/// shows up in the crash log (via pthread_getname_np in the signal
/// handler), in `lldb thread list`, and in `ps -M`. On Linux it
/// shows up in `/proc/<pid>/task/<tid>/comm` and `ps -L`. Workers
/// call this on entry so a SIGSEGV from a worker is still
/// identifiable when the user's closure was inlined into
/// Thread.entryFn.
pub fn set(name: [*:0]const u8) void {
    if (@import("builtin").os.tag == .windows) return;
    setname_impl.call(name);
}

/// Last "step" tag a worker passed through, read by the crash handler
/// in main.zig. Workers call `markStep("...")` immediately before
/// potentially-faulting C calls (tree-sitter parse, ts_tree_copy, etc)
/// so on crash we know which call was in flight.
///
/// The pointer payload must be a *static* C string — workers should
/// only pass string literals. A non-static pointer would be a race
/// (could be freed before the handler reads it).
pub var last_step: std.atomic.Value(?[*]const u8) = .{ .raw = null };

pub fn markStep(comptime tag: [:0]const u8) void {
    last_step.store(@ptrCast(@constCast(tag.ptr)), .release);
}
