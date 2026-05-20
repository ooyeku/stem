const std = @import("std");

extern "c" fn pthread_setname_np(name: [*:0]const u8) c_int;

/// Set the calling thread's name. Best-effort; on macOS the name
/// shows up in the crash log (via pthread_getname_np in the signal
/// handler), in `lldb thread list`, and in `ps -M`. Workers call
/// this on entry so a SIGSEGV from a worker is still identifiable
/// when the user's closure was inlined into Thread.entryFn.
pub fn set(name: [*:0]const u8) void {
    if (@import("builtin").os.tag == .windows) return;
    _ = pthread_setname_np(name);
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
    last_step.store(@constCast(@ptrCast(tag.ptr)), .release);
}
