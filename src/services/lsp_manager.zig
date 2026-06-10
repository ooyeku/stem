const std = @import("std");
const log = std.log.scoped(.LSPManager);
const server_mod = @import("lsp/server.zig");
const LSPServer = server_mod.LSPServer;
const DocumentSymbol = LSPServer.DocumentSymbol;
const WorkspaceSymbol = LSPServer.WorkspaceSymbol;
const zls_embedded = @import("lsp/zls_embedded.zig");
const protocol = @import("../kernel/protocol.zig");
const Installer = @import("lsp/installer.zig").Installer;
const external = @import("lsp/external.zig");
const Transport = @import("../lsp/transport.zig");
const supervisor_mod = @import("lsp/supervisor.zig");
const LSPSupervisor = supervisor_mod.LSPSupervisor;

pub const LSPManager = struct {
    allocator: std.mem.Allocator,

    /// Map of language id → server. Mutated only on the supervisor's worker
    /// thread (or `deinit` after shutdown). Reads from the UI thread must
    /// take `manager_mutex` for the duration they use the *LSPServer pointer.
    servers: std.StringHashMap(*LSPServer),

    open_documents: std.StringHashMap(void),

    /// Protects `servers` and `open_documents`. Held briefly. Long operations
    /// (LSPServer.start, which can wait up to 30s) drop the lock so the UI
    /// thread can still do quick reads (e.g. `getActiveServerStatus`).
    manager_mutex: std.Io.Mutex = .init,

    on_tokens_ready: ?*const fn () void = null,
    on_diagnostics: ?*const fn (uri: []const u8, diagnostics: []const LSPServer.Diagnostic) void = null,

    zig_env: ?ZigEnv = null,

    install_lock: std.Io.Mutex = .init,
    io: std.Io,
    /// Parent process environment block, forwarded to embedded LSP servers so
    /// they can see env vars like ZIG_LIB_DIR / ZIG_GLOBAL_CACHE / PATH.
    environ_block: std.process.Environ.Block,

    supervisor: LSPSupervisor,

    /// Watchdog thread that periodically checks each running server's health
    /// flags and queues a restart on the supervisor when one has died. Held
    /// here so we can join on shutdown.
    watchdog_thread: ?std.Thread = null,
    watchdog_stop: std.atomic.Value(bool) = .{ .raw = false },

    /// Global "the editor is shutting down" flag wired into every LSPServer
    /// we create. When set during `deinit`, in-flight `server.start` init
    /// waits abort immediately (instead of sitting on the 30 s timeout),
    /// which is the difference between a snappy quit and a stalled one.
    global_shutdown: std.atomic.Value(bool) = .{ .raw = false },

    /// Languages whose server is being started (or about to be) right now.
    /// `start_server` commands spawn one thread per language so multiple
    /// servers boot in parallel — without this set, two concurrent starts
    /// for the same lang would race to put the same key in `servers`.
    /// `ensure_and_open` also waits on this set to make sure its didOpen
    /// fires *after* the parallel start finishes for the same lang.
    in_progress_starts: std.StringHashMapUnmanaged(void) = .empty,
    in_progress_mutex: std.Io.Mutex = .init,
    in_progress_cond: std.Io.Condition = .init,

    /// Per-language backoff state for auto-restart. Bumps after every restart
    /// and resets after a healthy steady-state period. Stored on the manager
    /// so the supervisor's worker thread can read/write without sharing state
    /// with the LSPServer (which gets destroyed across restarts).
    restart_state: std.StringHashMapUnmanaged(RestartState) = .empty,
    restart_state_mutex: std.Io.Mutex = .init,

    /// Per-file pending `textDocument/didChange` payloads. Coalesces a
    /// burst of edits within `change_debounce_ms` into a single send.
    /// Without this, fast typing fires one didChange per keystroke per
    /// server — at 23 wired languages, a multi-file session can fan
    /// out to >100 notifications/sec and overwhelm slow LSPs. The
    /// trailing-edge model flushes once the user pauses (drained from
    /// Core's tick handler via `flushPendingChanges`). On
    /// `documentSaved` / `documentClosed` we flush or drop synchronously
    /// so the server isn't left with stale-or-missing content.
    pending_changes: std.StringHashMapUnmanaged(PendingChange) = .empty,
    pending_changes_mutex: std.Io.Mutex = .init,
    change_debounce_ms: i64 = 50,

    pub const RestartState = struct {
        attempts: u32 = 0,
        last_attempt_ms: i64 = 0,
    };

    pub const PendingChange = struct {
        /// Owned by `pending_changes_mutex`; freed on flush or replace.
        content: []u8,
        version: i64,
        queued_at: i64,
    };

    pub const ZigEnv = struct {
        zig_exe: []const u8,
        lib_dir: []const u8,
        global_cache_dir: []const u8,
    };

    pub const Diagnostic = LSPServer.Diagnostic;
    pub const Location = LSPServer.Location;
    pub const CompletionItem = LSPServer.CompletionItem;
    pub const TextEdit = LSPServer.TextEdit;

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ_block: std.process.Environ.Block) LSPManager {
        return .{
            .allocator = allocator,
            .io = io,
            .environ_block = environ_block,
            .servers = std.StringHashMap(*LSPServer).init(allocator),
            .open_documents = std.StringHashMap(void).init(allocator),
            // The supervisor's `ctx` will be filled in via `startSupervisor`
            // once the manager is in its final memory location. Until then
            // the supervisor exists but has no worker thread, so calling
            // `enqueue` returns `error.SupervisorShutdown` — safe.
            .supervisor = LSPSupervisor.init(
                allocator,
                io,
                undefined,
                .{ .execute = supervisorExecute },
            ),
        };
    }

    /// Spawn the supervisor worker thread and the health watchdog. Called
    /// once by Core after the manager is in its final memory location (the
    /// supervisor stores a pointer to the manager as its ctx).
    pub fn startSupervisor(self: *LSPManager) !void {
        self.supervisor.ctx = @ptrCast(self);
        try self.supervisor.start();
        self.watchdog_stop.store(false, .release);
        self.watchdog_thread = try std.Thread.spawn(.{}, watchdogMain, .{self});
    }

    /// Periodic health check. Every `watchdog_interval_ms` we scan each
    /// running server; if its `server_healthy` is false and it's not in a
    /// backoff window, enqueue a restart on the supervisor.
    const watchdog_interval_ms: u64 = 3000;
    /// Cap restart attempts so a server that keeps crashing doesn't pin a
    /// CPU re-starting it forever. After this many attempts in a row, we
    /// stop trying until the user does something (open a new file, run the
    /// "LSP: Restart Server" command, etc.).
    const max_restart_attempts: u32 = 5;
    /// Base backoff in ms. Doubled on each consecutive attempt, capped at
    /// `max_backoff_ms`.
    const base_backoff_ms: i64 = 1_000;
    const max_backoff_ms: i64 = 30_000;
    /// If a server has been healthy for this long, reset the attempt count
    /// — a successful recovery shouldn't burn future budget.
    const recovery_window_ms: i64 = 60_000;

    fn watchdogMain(self: *LSPManager) void {
        @import("thread_name.zig").set("stem-lsp-wd");
        log.info("[LSP WATCHDOG] started", .{});
        defer log.info("[LSP WATCHDOG] exited", .{});

        // Sleep in short slices that re-check `watchdog_stop`, so
        // shutdown is bounded by `slice_ms` rather than the full
        // 3-second interval. A single long sleep makes stem feel
        // glacial when the user hits :q.
        const slice_ms: u64 = 100;
        const slices_per_interval = watchdog_interval_ms / slice_ms;
        while (!self.watchdog_stop.load(.acquire)) {
            var i: u64 = 0;
            while (i < slices_per_interval) : (i += 1) {
                if (self.watchdog_stop.load(.acquire)) return;
                std.Io.sleep(self.io, .fromMilliseconds(slice_ms), .awake) catch return;
            }
            if (self.watchdog_stop.load(.acquire)) return;

            // Snapshot under the manager lock so we don't hold it during the
            // restart enqueue (which itself takes locks).
            self.manager_mutex.lockUncancelable(self.io);
            var unhealthy: std.ArrayListUnmanaged(struct { lang: []u8, root: ?[]u8 }) = .empty;
            defer {
                for (unhealthy.items) |u| {
                    self.allocator.free(u.lang);
                    if (u.root) |r| self.allocator.free(r);
                }
                unhealthy.deinit(self.allocator);
            }

            var it = self.servers.iterator();
            while (it.next()) |entry| {
                const server = entry.value_ptr.*;
                const running = server.server_running.load(.acquire);
                const healthy = server.server_healthy.load(.acquire);
                if (running and !healthy) {
                    const lang = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
                    const root: ?[]u8 = if (server.current_root_path) |p|
                        self.allocator.dupe(u8, p) catch null
                    else
                        null;
                    unhealthy.append(self.allocator, .{ .lang = lang, .root = root }) catch {
                        self.allocator.free(lang);
                        if (root) |r| self.allocator.free(r);
                    };
                }
            }
            self.manager_mutex.unlock(self.io);

            for (unhealthy.items) |entry| {
                if (!self.shouldRetryRestart(entry.lang)) {
                    log.warn("[LSP WATCHDOG] {s} hit max restart attempts; giving up until user intervention", .{entry.lang});
                    continue;
                }
                const lang_dup = self.allocator.dupe(u8, entry.lang) catch continue;
                const root_dup: ?[]u8 = if (entry.root) |r| self.allocator.dupe(u8, r) catch null else null;
                log.info("[LSP WATCHDOG] queueing restart of {s}", .{entry.lang});
                self.supervisor.enqueueDedup(.{ .restart_server = .{ .lang = lang_dup, .root = root_dup } }) catch {
                    self.allocator.free(lang_dup);
                    if (root_dup) |r| self.allocator.free(r);
                };
            }
        }
    }

    /// Returns true if we should attempt another restart for `lang`. Tracks
    /// per-lang attempt counts and applies exponential backoff. Also resets
    /// the count if the server has been healthy in the last
    /// `recovery_window_ms`.
    fn shouldRetryRestart(self: *LSPManager, lang: []const u8) bool {
        const now_ms = std.Io.Clock.real.now(self.io).toMilliseconds();
        self.restart_state_mutex.lockUncancelable(self.io);
        defer self.restart_state_mutex.unlock(self.io);

        const gop = self.restart_state.getOrPut(self.allocator, lang) catch return false;
        if (!gop.found_existing) {
            const key = self.allocator.dupe(u8, lang) catch {
                _ = self.restart_state.remove(lang);
                return false;
            };
            gop.key_ptr.* = key;
            gop.value_ptr.* = .{};
        }

        // Recovery: if it's been healthy for a while since the last attempt,
        // reset the counter so we get a fresh budget.
        if (gop.value_ptr.last_attempt_ms != 0 and
            (now_ms - gop.value_ptr.last_attempt_ms) > recovery_window_ms)
        {
            gop.value_ptr.attempts = 0;
        }

        if (gop.value_ptr.attempts >= max_restart_attempts) return false;

        const since = now_ms - gop.value_ptr.last_attempt_ms;
        // Exponential backoff: 1s, 2s, 4s, 8s, 16s (capped at 30s).
        const backoff = @min(base_backoff_ms * (@as(i64, 1) << @intCast(gop.value_ptr.attempts)), max_backoff_ms);
        if (gop.value_ptr.last_attempt_ms != 0 and since < backoff) return false;

        gop.value_ptr.attempts += 1;
        gop.value_ptr.last_attempt_ms = now_ms;
        return true;
    }

    /// Mark `lang` as "currently starting". Returns true if we claimed the
    /// slot, false if another thread is already starting this lang.
    fn beginStart(self: *LSPManager, lang: []const u8) bool {
        self.in_progress_mutex.lockUncancelable(self.io);
        defer self.in_progress_mutex.unlock(self.io);
        const gop = self.in_progress_starts.getOrPut(self.allocator, lang) catch return false;
        if (gop.found_existing) return false;
        const owned = self.allocator.dupe(u8, lang) catch {
            _ = self.in_progress_starts.remove(lang);
            return false;
        };
        gop.key_ptr.* = owned;
        return true;
    }

    fn endStart(self: *LSPManager, lang: []const u8) void {
        self.in_progress_mutex.lockUncancelable(self.io);
        defer self.in_progress_mutex.unlock(self.io);
        if (self.in_progress_starts.fetchRemove(lang)) |kv| {
            self.allocator.free(kv.key);
        }
        self.in_progress_cond.broadcast(self.io);
    }

    fn waitForStart(self: *LSPManager, lang: []const u8) void {
        self.in_progress_mutex.lockUncancelable(self.io);
        defer self.in_progress_mutex.unlock(self.io);
        while (self.in_progress_starts.contains(lang)) {
            if (self.global_shutdown.load(.acquire)) return;
            self.in_progress_cond.waitUncancelable(self.io, &self.in_progress_mutex);
        }
    }

    /// Worker function used by the parallel-start spawn path. Owns `lang`
    /// and `root` and frees them after the start completes (success or
    /// fail). Set as a thread entry point.
    fn runParallelStart(self: *LSPManager, lang_owned: []u8, root_owned: ?[]u8) void {
        @import("thread_name.zig").set("stem-lsp-start");
        defer self.allocator.free(lang_owned);
        defer if (root_owned) |r| self.allocator.free(r);
        defer self.endStart(lang_owned);

        self.startServerInternal(lang_owned, root_owned) catch |err| {
            log.warn("[LSP parallel-start] {s} failed: {}", .{ lang_owned, err });
        };
    }

    fn supervisorExecute(ctx: *anyopaque, cmd: supervisor_mod.Command) void {
        const self: *LSPManager = @ptrCast(@alignCast(ctx));
        switch (cmd) {
            .start_server => |c| {
                // Spawn the actual start on a fresh thread so multiple LSP
                // servers can initialize in parallel. The worker returns
                // immediately and is free to process the next command (e.g.
                // a start for a different language).
                if (!self.beginStart(c.lang)) return; // already starting
                const lang_dup = self.allocator.dupe(u8, c.lang) catch {
                    self.endStart(c.lang);
                    return;
                };
                const root_dup: ?[]u8 = if (c.root) |r|
                    self.allocator.dupe(u8, r) catch null
                else
                    null;
                const t = std.Thread.spawn(.{}, runParallelStart, .{ self, lang_dup, root_dup }) catch {
                    self.endStart(c.lang);
                    self.allocator.free(lang_dup);
                    if (root_dup) |r| self.allocator.free(r);
                    return;
                };
                t.detach();
            },
            .stop_server => |lang| {
                self.stopServerLangSync(lang);
            },
            .restart_server => |c| {
                self.stopServerLangSync(c.lang);
                self.startServerInternal(c.lang, c.root) catch |err| {
                    log.warn("supervisor: restart {s} failed: {}", .{ c.lang, err });
                };
            },
            .ensure_and_open => |c| {
                self.ensureAndOpenSync(c.lang, c.root, c.file_path, c.content) catch |err| {
                    log.warn("supervisor: ensure-and-open for {s} failed: {}", .{ c.file_path, err });
                };
            },
            .add_workspace_folder => |c| {
                self.addWorkspaceFolderSync(c.lang, c.root) catch |err| {
                    log.warn("supervisor: addWorkspaceFolder {s} for {s} failed: {}", .{ c.root, c.lang, err });
                };
            },
            .deferred_request => |c| {
                self.runDeferredRequestSync(c.lang, c.file_path, c.kind, c.line, c.col) catch |err| {
                    log.warn("supervisor: deferred {s} for {s} failed: {}", .{ @tagName(c.kind), c.file_path, err });
                };
            },
        }
    }

    /// Runs on the supervisor thread, AFTER any preceding `ensure_and_open`
    /// has been processed (FIFO). The document is guaranteed to be opened
    /// on the server by this point, so the textDocument request can fire.
    fn runDeferredRequestSync(self: *LSPManager, lang: []const u8, file_path: []const u8, kind: supervisor_mod.Command.DeferredKind, line: u32, col: u32) !void {
        self.manager_mutex.lockUncancelable(self.io);
        const srv = self.servers.get(lang);
        self.manager_mutex.unlock(self.io);
        const server = srv orelse return; // server died between enqueue and exec

        const uri = try pathToUri(self.allocator, self.io, file_path);
        defer self.allocator.free(uri);

        switch (kind) {
            .hover => try server.requestHover(uri, line, col),
            .completion => try server.requestCompletion(uri, line, col),
            .formatting => try server.requestFormatting(uri),
            .definition => try server.requestDefinition(uri, line, col),
            .references => try server.requestReferences(uri, line, col),
            .document_symbols => try server.requestDocumentSymbols(uri),
        }
    }

    pub fn deinit(self: *LSPManager) void {
        // Fast-exit path. Optimised for "user pressed Space+Q" — every
        // millisecond they wait before getting their terminal back is
        // wasted. The careful, polite shutdown the supervisor runs in
        // steady state (LSP `shutdown` → `exit` → 2 s join × N servers
        // sequentially) used to add up to >10 s with several servers
        // running. The new flow:
        //
        //   1. Set every "stop now" flag.
        //   2. SIGKILL every live LSP child in one parallel sweep —
        //      the kernel reaps them all immediately.
        //   3. Skip the supervisor + watchdog joins; detach them. Their
        //      worker threads will see the killed pipes / flags and
        //      exit on their own as the process tears down.
        //   4. Leak structures still touched by in-flight starts —
        //      we're exiting; the OS reclaims everything in <1 ms.
        self.global_shutdown.store(true, .release);
        self.watchdog_stop.store(true, .release);

        // The LSP children are by far the longest pole. Killing them
        // first unblocks every pump (broken-pipe / EOF on stdio) and
        // every `child.wait` (immediate exit), which in turn unblocks
        // every reader/server thread join inside the per-server
        // shutdown. Effectively turns N × 4 s sequential into <50 ms.
        external.requestGlobalShutdown();

        // Bounded join on the watchdog. With the LSP children already
        // SIGKILLed above, the watchdog's blocking call (`child.wait`
        // / waitTimeout) returns immediately; its next loop iteration
        // observes `watchdog_stop` and exits. 250 ms is plenty under
        // those conditions, and bailing on a true hang is preferable
        // to detaching — a detached thread would read freed `self`
        // state (servers map, watchdog_stop) if the process didn't
        // exit immediately after `deinit` returned.
        if (self.watchdog_thread) |t| {
            if (!supervisor_mod.joinTimeout(self.allocator, self.io, t, 250)) {
                log.warn("LSP watchdog did not exit in 250ms; detaching (process exit imminent)", .{});
            }
            self.watchdog_thread = null;
        }

        // Best-effort supervisor drain. With children dead and global
        // shutdown set, the supervisor's worker exits quickly; the
        // call itself is bounded (existing implementation has its own
        // join timeout).
        self.supervisor.shutdown();

        // Per-server teardown can now run without paying the full
        // graceful-shutdown handshake — the children are gone, the
        // pipes are EOF, the thread joins return immediately.
        var it = self.servers.valueIterator();
        while (it.next()) |server_ptr| {
            var server = server_ptr.*;
            server.deinit();
        }
        self.servers.deinit();

        var doc_it = self.open_documents.keyIterator();
        while (doc_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.open_documents.deinit();

        var rs_it = self.restart_state.keyIterator();
        while (rs_it.next()) |k| self.allocator.free(k.*);
        self.restart_state.deinit(self.allocator);

        // Drop any debounced didChange payloads. The servers are
        // about to die (or already are) — sending the final flush
        // would be wasted work; just free.
        {
            self.pending_changes_mutex.lockUncancelable(self.io);
            defer self.pending_changes_mutex.unlock(self.io);
            var pc_it = self.pending_changes.iterator();
            while (pc_it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.content);
            }
            self.pending_changes.deinit(self.allocator);
        }

        // Drain in-progress parallel starts under a bounded wait.
        // With `global_shutdown` set and the children dead, each start
        // bails out within one init-poll cycle (≤100 ms). 500 ms covers
        // that comfortably; if a start truly hangs, log and leak (the
        // process is exiting in moments). Without the drain, threads
        // still running through `endStart` would write to a freed map.
        self.in_progress_mutex.lockUncancelable(self.io);
        const drain_start_ms = std.Io.Clock.real.now(self.io).toMilliseconds();
        while (self.in_progress_starts.count() > 0) {
            const elapsed = std.Io.Clock.real.now(self.io).toMilliseconds() - drain_start_ms;
            if (elapsed > 500) {
                log.warn("LSP in_progress_starts did not drain in 500ms; leaking {d} entries", .{self.in_progress_starts.count()});
                break;
            }
            self.in_progress_mutex.unlock(self.io);
            std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch break;
            self.in_progress_mutex.lockUncancelable(self.io);
        }
        var ip_it = self.in_progress_starts.keyIterator();
        while (ip_it.next()) |k| self.allocator.free(k.*);
        self.in_progress_starts.deinit(self.allocator);
        self.in_progress_mutex.unlock(self.io);

        if (self.zig_env) |env| {
            self.allocator.free(env.zig_exe);
            self.allocator.free(env.lib_dir);
            self.allocator.free(env.global_cache_dir);
        }
    }

    fn stopServerLangSync(self: *LSPManager, lang: []const u8) void {
        self.manager_mutex.lockUncancelable(self.io);
        const maybe = self.servers.fetchRemove(lang);
        // Also drop any open_documents whose URIs correspond to this lang —
        // a future open will re-send the didOpen via the supervisor.
        if (maybe != null) {
            var pruned: std.ArrayListUnmanaged([]const u8) = .empty;
            defer pruned.deinit(self.allocator);
            var dit = self.open_documents.keyIterator();
            while (dit.next()) |k| {
                if (uriMatchesLang(k.*, lang)) {
                    pruned.append(self.allocator, k.*) catch {};
                }
            }
            for (pruned.items) |k| {
                _ = self.open_documents.fetchRemove(k);
                self.allocator.free(k);
            }
        }
        self.manager_mutex.unlock(self.io);

        if (maybe) |kv| {
            var srv = kv.value;
            srv.stop();
            srv.deinit();
        }
    }

    fn uriMatchesLang(uri: []const u8, lang: []const u8) bool {
        // Match by extension at the end of the URI.
        const exts: []const struct { lang: []const u8, exts: []const []const u8 } = &.{
            .{ .lang = "zig", .exts = &.{".zig"} },
            .{ .lang = "python", .exts = &.{".py"} },
            .{ .lang = "typescript", .exts = &.{ ".ts", ".tsx", ".jsx" } },
            .{ .lang = "javascript", .exts = &.{".js"} },
            .{ .lang = "rust", .exts = &.{".rs"} },
            .{ .lang = "go", .exts = &.{".go"} },
            .{ .lang = "cpp", .exts = &.{ ".c", ".h", ".cpp", ".hpp", ".cc", ".cxx", ".hxx", ".hh" } },
            .{ .lang = "java", .exts = &.{".java"} },
            .{ .lang = "ruby", .exts = &.{ ".rb", ".rake" } },
            .{ .lang = "csharp", .exts = &.{".cs"} },
            .{ .lang = "bash", .exts = &.{ ".sh", ".bash", ".zsh" } },
            .{ .lang = "lua", .exts = &.{".lua"} },
            .{ .lang = "swift", .exts = &.{".swift"} },
            .{ .lang = "r", .exts = &.{ ".r", ".R", ".rmd", ".Rmd" } },
            .{ .lang = "css", .exts = &.{ ".css", ".scss", ".less" } },
            .{ .lang = "html", .exts = &.{ ".html", ".htm" } },
            .{ .lang = "json", .exts = &.{".json"} },
            .{ .lang = "php", .exts = &.{ ".php", ".phtml" } },
            .{ .lang = "perl", .exts = &.{ ".pl", ".pm", ".t" } },
            .{ .lang = "dart", .exts = &.{".dart"} },
            .{ .lang = "elixir", .exts = &.{ ".ex", ".exs" } },
            .{ .lang = "erlang", .exts = &.{ ".erl", ".hrl" } },
            .{ .lang = "haskell", .exts = &.{".hs"} },
            .{ .lang = "kotlin", .exts = &.{ ".kt", ".kts" } },
            .{ .lang = "ocaml", .exts = &.{ ".ml", ".mli" } },
            .{ .lang = "scala", .exts = &.{ ".scala", ".sc" } },
        };
        for (exts) |row| {
            if (!std.mem.eql(u8, row.lang, lang)) continue;
            for (row.exts) |e| {
                if (std.mem.endsWith(u8, uri, e)) return true;
            }
        }
        return false;
    }

    /// Synchronous: ensure a server exists for `lang` with `root`, then send
    /// the didOpen. Called from the supervisor thread.
    fn ensureAndOpenSync(self: *LSPManager, lang: []const u8, root: ?[]const u8, file_path: []const u8, content: []const u8) !void {
        // If a parallel `start_server` is in flight for this lang, wait for
        // it to finish before deciding whether to start one ourselves —
        // otherwise we'd race and either double-start or miss the put.
        self.waitForStart(lang);

        // Decide whether a fresh start, a workspace-folder addition, or a
        // plain didOpen is appropriate.
        self.manager_mutex.lockUncancelable(self.io);
        const existing = self.servers.get(lang);
        const healthy = if (existing) |s|
            s.server_healthy.load(.acquire) and s.server_running.load(.acquire) and s.is_initialized.load(.acquire)
        else
            false;
        const current_root_owned: ?[]u8 = if (existing) |s|
            if (s.current_root_path) |p| self.allocator.dupe(u8, p) catch null else null
        else
            null;
        self.manager_mutex.unlock(self.io);
        defer if (current_root_owned) |p| self.allocator.free(p);

        if (existing == null) {
            try self.startServerInternal(lang, root);
        } else if (!healthy) {
            log.info("[supervisor] {s} server unhealthy, restarting", .{lang});
            self.stopServerLangSync(lang);
            try self.startServerInternal(lang, root);
        } else if (root != null and current_root_owned != null) {
            const new_root_trimmed = std.mem.trimEnd(u8, root.?, "/");
            const cur_trimmed = std.mem.trimEnd(u8, current_root_owned.?, "/");
            if (!std.mem.eql(u8, new_root_trimmed, cur_trimmed)) {
                // Add as additional workspace folder (cheaper than restart).
                self.addWorkspaceFolderSync(lang, root.?) catch |err| {
                    log.warn("[supervisor] addWorkspaceFolder failed, falling back to restart: {}", .{err});
                    self.stopServerLangSync(lang);
                    try self.startServerInternal(lang, root);
                };
            }
        }

        // Send the didOpen + initial token request.
        self.manager_mutex.lockUncancelable(self.io);
        const srv = self.servers.get(lang) orelse {
            self.manager_mutex.unlock(self.io);
            return;
        };
        const uri = try pathToUri(self.allocator, self.io, file_path);
        errdefer self.allocator.free(uri);

        if (self.open_documents.contains(uri)) {
            self.allocator.free(uri);
            self.manager_mutex.unlock(self.io);
            return;
        }
        try self.open_documents.put(uri, {});
        // Drop the lock before the (still fast but pipe-write) send.
        self.manager_mutex.unlock(self.io);

        srv.sendDidOpen(uri, lang, 1, content) catch |err| {
            log.warn("[supervisor] sendDidOpen failed for {s}: {}", .{ file_path, err });
            return;
        };

        // Prefill highlighting from the on-disk token cache (if any) so the
        // user sees LSP-quality colors immediately instead of waiting for
        // the server to index. The real `semanticTokens/full` response
        // arrives later and overwrites with the fresh data.
        _ = srv.tryLoadCachedTokens(uri);

        srv.requestSemanticTokens(uri) catch |err| {
            log.warn("[supervisor] requestSemanticTokens on open failed: {}", .{err});
        };
    }

    /// Send `workspace/didChangeWorkspaceFolders` to add `root` to the
    /// running server. Most modern LSPs (gopls, pyright, tsserver,
    /// rust-analyzer, zls) accept this and avoid the cost of a restart.
    fn addWorkspaceFolderSync(self: *LSPManager, lang: []const u8, root: []const u8) !void {
        self.manager_mutex.lockUncancelable(self.io);
        const srv = self.servers.get(lang);
        self.manager_mutex.unlock(self.io);
        if (srv) |s| try s.sendDidChangeWorkspaceFolders(root, &.{});
    }

    /// Stop ALL running servers. Asynchronous: each lang's stop is queued on
    /// the supervisor so the caller (UI thread) doesn't block on
    /// thread-joins. Use `waitForSupervisorIdle` if you need to be sure
    /// they're done (e.g. during shutdown).
    pub fn stopServer(self: *LSPManager) void {
        log.info("[LSP MANAGER] Stopping all LSP servers (async)...", .{});
        self.manager_mutex.lockUncancelable(self.io);
        var langs = std.ArrayList([]u8).initCapacity(self.allocator, 4) catch return;
        defer langs.deinit(self.allocator);
        var it = self.servers.keyIterator();
        while (it.next()) |k| {
            const owned = self.allocator.dupe(u8, k.*) catch continue;
            langs.append(self.allocator, owned) catch {
                self.allocator.free(owned);
            };
        }
        self.manager_mutex.unlock(self.io);

        for (langs.items) |lang_owned| {
            self.supervisor.enqueue(.{ .stop_server = lang_owned }) catch {
                self.allocator.free(lang_owned);
            };
        }
    }

    /// Stop a single language's server. Asynchronous: the actual stop runs on
    /// the supervisor's worker thread.
    pub fn stopServerLang(self: *LSPManager, lang: []const u8) void {
        log.info("[LSP MANAGER] Stopping {s} server (async)...", .{lang});
        const lang_owned = self.allocator.dupe(u8, lang) catch return;
        self.supervisor.enqueueDedup(.{ .stop_server = lang_owned }) catch {
            self.allocator.free(lang_owned);
        };
    }

    /// Resolve `~/.stem/cache/tokens`, creating it on demand. Returned slice
    /// is owned by the caller (typically transferred to an LSPServer that
    /// frees it in deinit).
    fn computeTokenCacheDir(self: *LSPManager) !?[]u8 {
        const platform = @import("../kernel/platform.zig");
        const home = (try platform.getEnv(self.allocator, self.environ_block, "HOME")) orelse
            (try platform.getEnv(self.allocator, self.environ_block, "USERPROFILE")) orelse return null;
        defer self.allocator.free(home);
        const dir = try std.fs.path.join(self.allocator, &.{ home, ".stem", "cache", "tokens" });
        std.Io.Dir.cwd().createDirPath(self.io, dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                self.allocator.free(dir);
                return null;
            },
        };
        return dir;
    }

    pub fn isServerHealthy(self: *LSPManager, lang: []const u8) bool {
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        if (self.servers.get(lang)) |server| {
            return server.server_healthy.load(.monotonic) and server.server_running.load(.acquire);
        }
        return false;
    }

    /// Returns true when the server for this file's language is initialized
    /// AND we've already sent the didOpen for this file. Used by callers
    /// like hover/completion that need both to be true before issuing the
    /// request. Cheap — just a couple of map lookups.
    pub fn isDocumentReady(self: *LSPManager, file_path: []const u8) bool {
        const lang = getLangFromPath(file_path) orelse return false;
        const uri = pathToUri(self.allocator, self.io, file_path) catch return false;
        defer self.allocator.free(uri);

        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        const srv = self.servers.get(lang) orelse return false;
        if (!srv.is_initialized.load(.acquire)) return false;
        if (!srv.server_healthy.load(.acquire)) return false;
        return self.open_documents.contains(uri);
    }

    /// Bounded poll: returns true if the document becomes ready within
    /// `timeout_ms`, false on timeout. Caller-initiated waits (e.g. hover
    /// triggered by the user) tolerate a short wait since pre-spawn usually
    /// makes this instant; first-cold-hover may pay up to `timeout_ms`.
    pub fn waitDocumentReady(self: *LSPManager, file_path: []const u8, timeout_ms: i64) bool {
        const start_ms = std.Io.Clock.real.now(self.io).toMilliseconds();
        while (true) {
            if (self.isDocumentReady(file_path)) return true;
            const elapsed = std.Io.Clock.real.now(self.io).toMilliseconds() - start_ms;
            if (elapsed >= timeout_ms) return false;
            std.Io.sleep(self.io, .fromMilliseconds(25), .awake) catch return false;
        }
    }

    /// Async public API: enqueue a start command. Returns immediately. Safe
    /// to call even if a server is already running (a no-op start is cheap).
    pub fn startServer(self: *LSPManager, lang: []const u8, root_path: ?[]const u8) !void {
        const lang_owned = try self.allocator.dupe(u8, lang);
        errdefer self.allocator.free(lang_owned);
        const root_owned: ?[]u8 = if (root_path) |p| try self.allocator.dupe(u8, p) else null;
        errdefer if (root_owned) |p| self.allocator.free(p);
        try self.supervisor.enqueueDedup(.{ .start_server = .{ .lang = lang_owned, .root = root_owned } });
    }

    /// Synchronous workhorse. Called from the supervisor thread. The UI
    /// thread must not call this directly — use `startServer` instead.
    fn startServerInternal(self: *LSPManager, lang: []const u8, root_path: ?[]const u8) !void {
        self.manager_mutex.lockUncancelable(self.io);
        const exists = self.servers.get(lang) != null;
        self.manager_mutex.unlock(self.io);
        if (exists) {
            log.info("[LSP MANAGER] {s} server already registered, skipping start", .{lang});
            return;
        }

        log.info("[LSP MANAGER] Starting {s} server with root_path={s}", .{ lang, root_path orelse "null" });

        if (std.mem.eql(u8, lang, "zig")) {
            self.startEmbeddedZLS(root_path) catch |err| {
                log.err("Failed to start ZLS: {}", .{err});
                log.info("[LSP ERROR] Failed to start ZLS: {}", .{err});
                return err;
            };
            log.info("[LSP MANAGER] ZLS (zig) server started successfully", .{});
        } else if (std.mem.eql(u8, lang, "python")) {
            self.startPyright(root_path) catch |err| {
                log.err("Failed to start Pyright: {}", .{err});
                log.info("[LSP ERROR] Failed to start Pyright: {}", .{err});
                return err;
            };
            log.info("[LSP MANAGER] Pyright (python) server started successfully", .{});
        } else if (std.mem.eql(u8, lang, "javascript") or std.mem.eql(u8, lang, "typescript")) {
            self.startTypeScriptLS(root_path) catch |err| {
                log.err("Failed to start TypeScript LS: {}", .{err});
                log.info("[LSP ERROR] Failed to start TypeScript LS: {}", .{err});
                return err;
            };
            log.info("[LSP MANAGER] TypeScript LS server started successfully", .{});
        } else if (std.mem.eql(u8, lang, "go")) {
            self.startGopls(root_path) catch |err| {
                log.err("Failed to start gopls: {}", .{err});
                log.info("[LSP ERROR] Failed to start gopls: {}", .{err});
                return err;
            };
            log.info("[LSP MANAGER] gopls (go) server started successfully", .{});
        } else if (std.mem.eql(u8, lang, "rust")) {
            self.startRustAnalyzer(root_path) catch |err| {
                log.err("Failed to start rust-analyzer: {}", .{err});
                return err;
            };
            log.info("[LSP MANAGER] rust-analyzer (rust) server started successfully", .{});
        } else if (std.mem.eql(u8, lang, "cpp") or std.mem.eql(u8, lang, "c")) {
            self.startClangd(root_path) catch |err| {
                log.err("Failed to start clangd: {}", .{err});
                return err;
            };
            log.info("[LSP MANAGER] clangd (C/C++) server started successfully", .{});
        } else if (std.mem.eql(u8, lang, "ruby")) {
            self.startRubyLsp(root_path) catch |err| {
                log.err("Failed to start ruby-lsp: {}", .{err});
                return err;
            };
            log.info("[LSP MANAGER] ruby-lsp (ruby) server started successfully", .{});
        } else if (std.mem.eql(u8, lang, "csharp")) {
            self.startOmniSharp(root_path) catch |err| {
                log.err("Failed to start OmniSharp: {}", .{err});
                return err;
            };
            log.info("[LSP MANAGER] OmniSharp (C#) server started successfully", .{});
        } else if (std.mem.eql(u8, lang, "java")) {
            self.startJdtls(root_path) catch |err| {
                log.err("Failed to start jdtls: {}", .{err});
                return err;
            };
            log.info("[LSP MANAGER] jdtls (Java) server started successfully", .{});
        } else if (std.mem.eql(u8, lang, "bash")) {
            self.startBashLanguageServer(root_path) catch |err| {
                log.err("Failed to start bash-language-server: {}", .{err});
                return err;
            };
            log.info("[LSP MANAGER] bash-language-server started successfully", .{});
        } else if (std.mem.eql(u8, lang, "lua")) {
            self.startLuaLanguageServer(root_path) catch |err| {
                log.err("Failed to start lua-language-server: {}", .{err});
                return err;
            };
            log.info("[LSP MANAGER] lua-language-server started successfully", .{});
        } else if (std.mem.eql(u8, lang, "swift")) {
            self.startSourcekitLsp(root_path) catch |err| {
                log.err("Failed to start sourcekit-lsp: {}", .{err});
                return err;
            };
            log.info("[LSP MANAGER] sourcekit-lsp started successfully", .{});
        } else if (std.mem.eql(u8, lang, "r")) {
            self.startRLanguageServer(root_path) catch |err| {
                log.err("Failed to start R languageserver: {}", .{err});
                return err;
            };
            log.info("[LSP MANAGER] R languageserver started successfully", .{});
        } else if (std.mem.eql(u8, lang, "css")) {
            self.startCssLanguageServer(root_path) catch |err| {
                log.err("Failed to start vscode-css-language-server: {}", .{err});
                return err;
            };
        } else if (std.mem.eql(u8, lang, "html")) {
            self.startHtmlLanguageServer(root_path) catch |err| {
                log.err("Failed to start vscode-html-language-server: {}", .{err});
                return err;
            };
        } else if (std.mem.eql(u8, lang, "json")) {
            self.startJsonLanguageServer(root_path) catch |err| {
                log.err("Failed to start vscode-json-language-server: {}", .{err});
                return err;
            };
        } else if (std.mem.eql(u8, lang, "php")) {
            self.startIntelephense(root_path) catch |err| {
                log.err("Failed to start intelephense: {}", .{err});
                return err;
            };
        } else if (std.mem.eql(u8, lang, "perl")) {
            self.startPerlNavigator(root_path) catch |err| {
                log.err("Failed to start perlnavigator: {}", .{err});
                return err;
            };
        } else if (std.mem.eql(u8, lang, "dart")) {
            self.startDartLanguageServer(root_path) catch |err| {
                log.err("Failed to start dart language-server: {}", .{err});
                return err;
            };
        } else if (std.mem.eql(u8, lang, "elixir")) {
            self.startElixirLs(root_path) catch |err| {
                log.err("Failed to start elixir-ls: {}", .{err});
                return err;
            };
        } else if (std.mem.eql(u8, lang, "erlang")) {
            self.startErlangLs(root_path) catch |err| {
                log.err("Failed to start erlang_ls: {}", .{err});
                return err;
            };
        } else if (std.mem.eql(u8, lang, "haskell")) {
            self.startHaskellLanguageServer(root_path) catch |err| {
                log.err("Failed to start haskell-language-server: {}", .{err});
                return err;
            };
        } else if (std.mem.eql(u8, lang, "kotlin")) {
            self.startKotlinLanguageServer(root_path) catch |err| {
                log.err("Failed to start kotlin-language-server: {}", .{err});
                return err;
            };
        } else if (std.mem.eql(u8, lang, "ocaml")) {
            self.startOcamlLsp(root_path) catch |err| {
                log.err("Failed to start ocamllsp: {}", .{err});
                return err;
            };
        } else if (std.mem.eql(u8, lang, "scala")) {
            self.startMetals(root_path) catch |err| {
                log.err("Failed to start metals: {}", .{err});
                return err;
            };
        } else {
            log.info("[LSP MANAGER] Unknown language '{s}', no LSP server available", .{lang});
        }
    }

    fn startEmbeddedZLS(self: *LSPManager, root_path: ?[]const u8) !void {
        if (self.zig_env == null) {
            self.zig_env = detectZigEnv(self.allocator, self.io) catch null;
        }

        var server = try LSPServer.init(self.allocator, self.io, "zig");
        errdefer server.deinit();
        server.external_shutdown = &self.global_shutdown;
        server.on_tokens_ready = self.on_tokens_ready;
        server.token_cache_dir = self.computeTokenCacheDir() catch null;
        server.on_diagnostics = self.on_diagnostics;
        if (root_path) |p| {
            if (server.current_root_path) |old| self.allocator.free(old);
            server.current_root_path = try self.allocator.dupe(u8, p);
        }

        try server.start(zls_embedded.runEmbeddedZLS, .{self.environ_block});
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        try self.servers.put("zig", server);
    }

    fn startPyright(self: *LSPManager, root_path: ?[]const u8) !void {
        log.info("LSPManager: startPyright called", .{});
        var installer = Installer.init(self.allocator, self.io, self.environ_block);

        self.install_lock.lockUncancelable(self.io);
        const script_path = installer.ensurePyright(false) catch |err| {
            self.install_lock.unlock(self.io);
            return err;
        };
        self.install_lock.unlock(self.io);

        var server = try LSPServer.init(self.allocator, self.io, "python");
        errdefer server.deinit();
        server.external_shutdown = &self.global_shutdown;
        server.on_tokens_ready = self.on_tokens_ready;
        server.token_cache_dir = self.computeTokenCacheDir() catch null;
        server.on_diagnostics = self.on_diagnostics;
        if (root_path) |p| {
            if (server.current_root_path) |old| self.allocator.free(old);
            server.current_root_path = try self.allocator.dupe(u8, p);
        }

        try server.start(runPyrightThread, .{ script_path, self.environ_block });
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        try self.servers.put("python", server);
    }

    fn runPyrightThread(allocator: std.mem.Allocator, input: *Transport.MemPipe, output: *Transport.MemPipe, script_path: []const u8, environ_block: std.process.Environ.Block) void {
        defer allocator.free(script_path);
        const args = [_][]const u8{ "node", script_path, "--stdio" };
        log.info("Starting Pyright node process: {s} {s}", .{ "node", script_path });
        external.runExternalServer(allocator, input, output, "node", &args, environ_block) catch |err| {
            log.info("Pyright server failed: {}", .{err});
        };
    }

    fn startTypeScriptLS(self: *LSPManager, root_path: ?[]const u8) !void {
        log.info("LSPManager: startTypeScriptLS called with root_path={s}", .{root_path orelse "null"});
        var installer = Installer.init(self.allocator, self.io, self.environ_block);

        self.install_lock.lockUncancelable(self.io);
        const script_path = installer.ensureTypeScriptLS(false) catch |err| {
            self.install_lock.unlock(self.io);
            return err;
        };
        self.install_lock.unlock(self.io);

        var server = try LSPServer.init(self.allocator, self.io, "typescript");
        errdefer server.deinit();
        server.external_shutdown = &self.global_shutdown;
        server.on_tokens_ready = self.on_tokens_ready;
        server.token_cache_dir = self.computeTokenCacheDir() catch null;
        server.on_diagnostics = self.on_diagnostics;
        if (root_path) |p| {
            if (server.current_root_path) |old| self.allocator.free(old);
            server.current_root_path = try self.allocator.dupe(u8, p);
        }

        try server.start(runTypeScriptLSThread, .{ script_path, self.environ_block });
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        try self.servers.put("typescript", server);
    }

    fn runTypeScriptLSThread(allocator: std.mem.Allocator, input: *Transport.MemPipe, output: *Transport.MemPipe, script_path: []const u8, environ_block: std.process.Environ.Block) void {
        defer allocator.free(script_path);
        const args = [_][]const u8{ "node", script_path, "--stdio" };
        log.info("Starting TypeScript LS node process: {s} {s}", .{ "node", script_path });
        external.runExternalServer(allocator, input, output, "node", &args, environ_block) catch |err| {
            log.info("TypeScript LS server failed: {}", .{err});
        };
    }

    fn startGopls(self: *LSPManager, root_path: ?[]const u8) !void {
        log.info("LSPManager: startGopls called with root_path={s}", .{root_path orelse "null"});
        var installer = Installer.init(self.allocator, self.io, self.environ_block);

        self.install_lock.lockUncancelable(self.io);
        const binary_path = installer.ensureGopls(false) catch |err| {
            self.install_lock.unlock(self.io);
            return err;
        };
        self.install_lock.unlock(self.io);

        var server = try LSPServer.init(self.allocator, self.io, "go");
        errdefer server.deinit();
        server.external_shutdown = &self.global_shutdown;
        server.on_tokens_ready = self.on_tokens_ready;
        server.token_cache_dir = self.computeTokenCacheDir() catch null;
        server.on_diagnostics = self.on_diagnostics;
        if (root_path) |p| {
            if (server.current_root_path) |old| self.allocator.free(old);
            server.current_root_path = try self.allocator.dupe(u8, p);
        }

        try server.start(runGoplsThread, .{ binary_path, self.environ_block });
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        try self.servers.put("go", server);
    }

    fn runGoplsThread(allocator: std.mem.Allocator, input: *Transport.MemPipe, output: *Transport.MemPipe, binary_path: []const u8, environ_block: std.process.Environ.Block) void {
        defer allocator.free(binary_path);
        const args = [_][]const u8{binary_path};
        log.info("Starting gopls process: {s}", .{binary_path});
        external.runExternalServer(allocator, input, output, binary_path, &args, environ_block) catch |err| {
            log.info("gopls server failed: {}", .{err});
        };
    }

    fn startRustAnalyzer(self: *LSPManager, root_path: ?[]const u8) !void {
        log.info("LSPManager: startRustAnalyzer called with root_path={s}", .{root_path orelse "null"});
        var installer = Installer.init(self.allocator, self.io, self.environ_block);

        self.install_lock.lockUncancelable(self.io);
        const binary_path = installer.ensureRustAnalyzer(false) catch |err| {
            self.install_lock.unlock(self.io);
            return err;
        };
        self.install_lock.unlock(self.io);

        var server = try LSPServer.init(self.allocator, self.io, "rust");
        errdefer server.deinit();
        server.external_shutdown = &self.global_shutdown;
        server.on_tokens_ready = self.on_tokens_ready;
        server.token_cache_dir = self.computeTokenCacheDir() catch null;
        server.on_diagnostics = self.on_diagnostics;
        if (root_path) |p| {
            if (server.current_root_path) |old| self.allocator.free(old);
            server.current_root_path = try self.allocator.dupe(u8, p);
        }

        try server.start(runRustAnalyzerThread, .{ binary_path, self.environ_block });
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        try self.servers.put("rust", server);
    }

    fn runRustAnalyzerThread(allocator: std.mem.Allocator, input: *Transport.MemPipe, output: *Transport.MemPipe, binary_path: []const u8, environ_block: std.process.Environ.Block) void {
        defer allocator.free(binary_path);
        const args = [_][]const u8{binary_path};
        log.info("Starting rust-analyzer process: {s}", .{binary_path});
        external.runExternalServer(allocator, input, output, binary_path, &args, environ_block) catch |err| {
            log.info("rust-analyzer server failed: {}", .{err});
        };
    }

    fn startClangd(self: *LSPManager, root_path: ?[]const u8) !void {
        log.info("LSPManager: startClangd called with root_path={s}", .{root_path orelse "null"});
        var installer = Installer.init(self.allocator, self.io, self.environ_block);

        self.install_lock.lockUncancelable(self.io);
        const binary_path = installer.ensureClangd(false) catch |err| {
            self.install_lock.unlock(self.io);
            return err;
        };
        self.install_lock.unlock(self.io);

        var server = try LSPServer.init(self.allocator, self.io, "cpp");
        errdefer server.deinit();
        server.external_shutdown = &self.global_shutdown;
        server.on_tokens_ready = self.on_tokens_ready;
        server.token_cache_dir = self.computeTokenCacheDir() catch null;
        server.on_diagnostics = self.on_diagnostics;
        if (root_path) |p| {
            if (server.current_root_path) |old| self.allocator.free(old);
            server.current_root_path = try self.allocator.dupe(u8, p);
        }

        try server.start(runClangdThread, .{ binary_path, self.environ_block });
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        try self.servers.put("cpp", server);
    }

    fn runClangdThread(allocator: std.mem.Allocator, input: *Transport.MemPipe, output: *Transport.MemPipe, binary_path: []const u8, environ_block: std.process.Environ.Block) void {
        defer allocator.free(binary_path);
        const args = [_][]const u8{binary_path};
        log.info("Starting clangd process: {s}", .{binary_path});
        external.runExternalServer(allocator, input, output, binary_path, &args, environ_block) catch |err| {
            log.info("clangd server failed: {}", .{err});
        };
    }

    fn startRubyLsp(self: *LSPManager, root_path: ?[]const u8) !void {
        log.info("LSPManager: startRubyLsp called with root_path={s}", .{root_path orelse "null"});
        var installer = Installer.init(self.allocator, self.io, self.environ_block);

        self.install_lock.lockUncancelable(self.io);
        const binary_path = installer.ensureRubyLsp(false) catch |err| {
            self.install_lock.unlock(self.io);
            return err;
        };
        self.install_lock.unlock(self.io);

        var server = try LSPServer.init(self.allocator, self.io, "ruby");
        errdefer server.deinit();
        server.external_shutdown = &self.global_shutdown;
        server.on_tokens_ready = self.on_tokens_ready;
        server.token_cache_dir = self.computeTokenCacheDir() catch null;
        server.on_diagnostics = self.on_diagnostics;
        if (root_path) |p| {
            if (server.current_root_path) |old| self.allocator.free(old);
            server.current_root_path = try self.allocator.dupe(u8, p);
        }

        try server.start(runRubyLspThread, .{ binary_path, self.environ_block });
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        try self.servers.put("ruby", server);
    }

    fn runRubyLspThread(allocator: std.mem.Allocator, input: *Transport.MemPipe, output: *Transport.MemPipe, binary_path: []const u8, environ_block: std.process.Environ.Block) void {
        defer allocator.free(binary_path);
        const args = [_][]const u8{binary_path};
        log.info("Starting ruby-lsp process: {s}", .{binary_path});
        external.runExternalServer(allocator, input, output, binary_path, &args, environ_block) catch |err| {
            log.info("ruby-lsp server failed: {}", .{err});
        };
    }

    fn startOmniSharp(self: *LSPManager, root_path: ?[]const u8) !void {
        log.info("LSPManager: startOmniSharp called with root_path={s}", .{root_path orelse "null"});
        var installer = Installer.init(self.allocator, self.io, self.environ_block);

        self.install_lock.lockUncancelable(self.io);
        const binary_path = installer.ensureOmniSharp(false) catch |err| {
            self.install_lock.unlock(self.io);
            return err;
        };
        self.install_lock.unlock(self.io);

        var server = try LSPServer.init(self.allocator, self.io, "csharp");
        errdefer server.deinit();
        server.external_shutdown = &self.global_shutdown;
        server.on_tokens_ready = self.on_tokens_ready;
        server.token_cache_dir = self.computeTokenCacheDir() catch null;
        server.on_diagnostics = self.on_diagnostics;
        if (root_path) |p| {
            if (server.current_root_path) |old| self.allocator.free(old);
            server.current_root_path = try self.allocator.dupe(u8, p);
        }

        try server.start(runOmniSharpThread, .{ binary_path, self.environ_block });
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        try self.servers.put("csharp", server);
    }

    fn runOmniSharpThread(allocator: std.mem.Allocator, input: *Transport.MemPipe, output: *Transport.MemPipe, binary_path: []const u8, environ_block: std.process.Environ.Block) void {
        defer allocator.free(binary_path);
        // OmniSharp wants `-lsp` to speak the LSP protocol (it also has a
        // legacy STDIO protocol that isn't compatible).
        const args = [_][]const u8{ binary_path, "-lsp" };
        log.info("Starting OmniSharp process: {s}", .{binary_path});
        external.runExternalServer(allocator, input, output, binary_path, &args, environ_block) catch |err| {
            log.info("OmniSharp server failed: {}", .{err});
        };
    }

    fn startJdtls(self: *LSPManager, root_path: ?[]const u8) !void {
        log.info("LSPManager: startJdtls called with root_path={s}", .{root_path orelse "null"});
        var installer = Installer.init(self.allocator, self.io, self.environ_block);

        self.install_lock.lockUncancelable(self.io);
        const launcher_jar = installer.ensureJdtls(false) catch |err| {
            self.install_lock.unlock(self.io);
            return err;
        };
        self.install_lock.unlock(self.io);

        var server = try LSPServer.init(self.allocator, self.io, "java");
        errdefer server.deinit();
        server.external_shutdown = &self.global_shutdown;
        server.on_tokens_ready = self.on_tokens_ready;
        server.token_cache_dir = self.computeTokenCacheDir() catch null;
        server.on_diagnostics = self.on_diagnostics;
        if (root_path) |p| {
            if (server.current_root_path) |old| self.allocator.free(old);
            server.current_root_path = try self.allocator.dupe(u8, p);
        }

        try server.start(runJdtlsThread, .{ launcher_jar, self.environ_block });
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        try self.servers.put("java", server);
    }

    fn runJdtlsThread(allocator: std.mem.Allocator, input: *Transport.MemPipe, output: *Transport.MemPipe, launcher_jar: []const u8, environ_block: std.process.Environ.Block) void {
        defer allocator.free(launcher_jar);
        // jdtls is launched via `java -jar <launcher>` with a bunch of JVM
        // tuning flags that the upstream docs recommend. We keep it minimal
        // here; users with large projects can override via env JAVA_TOOL_OPTIONS.
        const args = [_][]const u8{
            "java",
            "-Declipse.application=org.eclipse.jdt.ls.core.id1",
            "-Dosgi.bundles.defaultStartLevel=4",
            "-Declipse.product=org.eclipse.jdt.ls.core.product",
            "--add-modules=ALL-SYSTEM",
            "--add-opens=java.base/java.util=ALL-UNNAMED",
            "--add-opens=java.base/java.lang=ALL-UNNAMED",
            "-jar",
            launcher_jar,
        };
        log.info("Starting jdtls: java -jar {s}", .{launcher_jar});
        external.runExternalServer(allocator, input, output, "java", &args, environ_block) catch |err| {
            log.info("jdtls server failed: {} (is Java on PATH?)", .{err});
        };
    }

    fn startBashLanguageServer(self: *LSPManager, root_path: ?[]const u8) !void {
        log.info("LSPManager: startBashLanguageServer called with root_path={s}", .{root_path orelse "null"});
        var installer = Installer.init(self.allocator, self.io, self.environ_block);

        self.install_lock.lockUncancelable(self.io);
        const script_path = installer.ensureBashLanguageServer(false) catch |err| {
            self.install_lock.unlock(self.io);
            return err;
        };
        self.install_lock.unlock(self.io);

        var server = try LSPServer.init(self.allocator, self.io, "bash");
        errdefer server.deinit();
        server.external_shutdown = &self.global_shutdown;
        server.on_tokens_ready = self.on_tokens_ready;
        server.token_cache_dir = self.computeTokenCacheDir() catch null;
        server.on_diagnostics = self.on_diagnostics;
        if (root_path) |p| {
            if (server.current_root_path) |old| self.allocator.free(old);
            server.current_root_path = try self.allocator.dupe(u8, p);
        }

        try server.start(runBashLanguageServerThread, .{ script_path, self.environ_block });
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        try self.servers.put("bash", server);
    }

    fn runBashLanguageServerThread(allocator: std.mem.Allocator, input: *Transport.MemPipe, output: *Transport.MemPipe, script_path: []const u8, environ_block: std.process.Environ.Block) void {
        defer allocator.free(script_path);
        const args = [_][]const u8{ "node", script_path, "start" };
        log.info("Starting bash-language-server: node {s} start", .{script_path});
        external.runExternalServer(allocator, input, output, "node", &args, environ_block) catch |err| {
            log.info("bash-language-server failed: {} (is node on PATH?)", .{err});
        };
    }

    fn startLuaLanguageServer(self: *LSPManager, root_path: ?[]const u8) !void {
        log.info("LSPManager: startLuaLanguageServer called with root_path={s}", .{root_path orelse "null"});
        var installer = Installer.init(self.allocator, self.io, self.environ_block);

        self.install_lock.lockUncancelable(self.io);
        const binary_path = installer.ensureLuaLanguageServer(false) catch |err| {
            self.install_lock.unlock(self.io);
            return err;
        };
        self.install_lock.unlock(self.io);

        var server = try LSPServer.init(self.allocator, self.io, "lua");
        errdefer server.deinit();
        server.external_shutdown = &self.global_shutdown;
        server.on_tokens_ready = self.on_tokens_ready;
        server.token_cache_dir = self.computeTokenCacheDir() catch null;
        server.on_diagnostics = self.on_diagnostics;
        if (root_path) |p| {
            if (server.current_root_path) |old| self.allocator.free(old);
            server.current_root_path = try self.allocator.dupe(u8, p);
        }

        try server.start(runLuaLanguageServerThread, .{ binary_path, self.environ_block });
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        try self.servers.put("lua", server);
    }

    fn runLuaLanguageServerThread(allocator: std.mem.Allocator, input: *Transport.MemPipe, output: *Transport.MemPipe, binary_path: []const u8, environ_block: std.process.Environ.Block) void {
        defer allocator.free(binary_path);
        const args = [_][]const u8{binary_path};
        log.info("Starting lua-language-server: {s}", .{binary_path});
        external.runExternalServer(allocator, input, output, binary_path, &args, environ_block) catch |err| {
            log.info("lua-language-server failed: {}", .{err});
        };
    }

    fn startSourcekitLsp(self: *LSPManager, root_path: ?[]const u8) !void {
        log.info("LSPManager: startSourcekitLsp called with root_path={s}", .{root_path orelse "null"});
        var installer = Installer.init(self.allocator, self.io, self.environ_block);

        self.install_lock.lockUncancelable(self.io);
        const binary_path = installer.ensureSourcekitLsp(false) catch |err| {
            self.install_lock.unlock(self.io);
            return err;
        };
        self.install_lock.unlock(self.io);

        var server = try LSPServer.init(self.allocator, self.io, "swift");
        errdefer server.deinit();
        server.external_shutdown = &self.global_shutdown;
        server.on_tokens_ready = self.on_tokens_ready;
        server.token_cache_dir = self.computeTokenCacheDir() catch null;
        server.on_diagnostics = self.on_diagnostics;
        if (root_path) |p| {
            if (server.current_root_path) |old| self.allocator.free(old);
            server.current_root_path = try self.allocator.dupe(u8, p);
        }

        try server.start(runSourcekitLspThread, .{ binary_path, self.environ_block });
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        try self.servers.put("swift", server);
    }

    fn runSourcekitLspThread(allocator: std.mem.Allocator, input: *Transport.MemPipe, output: *Transport.MemPipe, binary_path: []const u8, environ_block: std.process.Environ.Block) void {
        defer allocator.free(binary_path);
        const args = [_][]const u8{binary_path};
        log.info("Starting sourcekit-lsp: {s}", .{binary_path});
        external.runExternalServer(allocator, input, output, binary_path, &args, environ_block) catch |err| {
            log.info("sourcekit-lsp failed: {}", .{err});
        };
    }

    fn startRLanguageServer(self: *LSPManager, root_path: ?[]const u8) !void {
        log.info("LSPManager: startRLanguageServer called with root_path={s}", .{root_path orelse "null"});
        var installer = Installer.init(self.allocator, self.io, self.environ_block);

        self.install_lock.lockUncancelable(self.io);
        const r_path = installer.ensureRLanguageServer(false) catch |err| {
            self.install_lock.unlock(self.io);
            return err;
        };
        self.install_lock.unlock(self.io);

        var server = try LSPServer.init(self.allocator, self.io, "r");
        errdefer server.deinit();
        server.external_shutdown = &self.global_shutdown;
        server.on_tokens_ready = self.on_tokens_ready;
        server.token_cache_dir = self.computeTokenCacheDir() catch null;
        server.on_diagnostics = self.on_diagnostics;
        if (root_path) |p| {
            if (server.current_root_path) |old| self.allocator.free(old);
            server.current_root_path = try self.allocator.dupe(u8, p);
        }

        try server.start(runRLanguageServerThread, .{ r_path, self.environ_block });
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        try self.servers.put("r", server);
    }

    fn runRLanguageServerThread(allocator: std.mem.Allocator, input: *Transport.MemPipe, output: *Transport.MemPipe, r_path: []const u8, environ_block: std.process.Environ.Block) void {
        defer allocator.free(r_path);
        // The canonical incantation per the languageserver README:
        // `R --slave -e "languageserver::run()"`.
        const args = [_][]const u8{ r_path, "--slave", "-e", "languageserver::run()" };
        log.info("Starting R languageserver: {s} --slave -e \"languageserver::run()\"", .{r_path});
        external.runExternalServer(allocator, input, output, r_path, &args, environ_block) catch |err| {
            log.info("R languageserver failed: {}", .{err});
        };
    }

    // -----------------------------------------------------------------------
    // Generic helpers for the remaining language servers.
    //
    // The pattern is identical for every server:
    //   1. resolve the binary via the installer (auto-install or PATH)
    //   2. construct an LSPServer with the editor's diagnostic hooks
    //   3. spawn the runner thread with the right argv shape
    //
    // We keep one `startGeneric*` per shape (script-via-node, bare
    // binary, binary-with-flag) to avoid 12 near-identical copies.

    fn startGenericServer(
        self: *LSPManager,
        comptime lang_key: []const u8,
        binary_path_owned: []const u8,
        comptime runner: anytype,
        extra: anytype,
    ) !void {
        var server = try LSPServer.init(self.allocator, self.io, lang_key);
        errdefer server.deinit();
        server.external_shutdown = &self.global_shutdown;
        server.on_tokens_ready = self.on_tokens_ready;
        server.token_cache_dir = self.computeTokenCacheDir() catch null;
        server.on_diagnostics = self.on_diagnostics;
        if (extra.root_path) |p| {
            if (server.current_root_path) |old| self.allocator.free(old);
            server.current_root_path = try self.allocator.dupe(u8, p);
        }
        try server.start(runner, .{ binary_path_owned, self.environ_block });
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        try self.servers.put(lang_key, server);
    }

    // CSS / HTML / JSON — all run via `node <script> --stdio`.
    fn runNodeStdioThread(allocator: std.mem.Allocator, input: *Transport.MemPipe, output: *Transport.MemPipe, script_path: []const u8, environ_block: std.process.Environ.Block) void {
        defer allocator.free(script_path);
        const args = [_][]const u8{ "node", script_path, "--stdio" };
        log.info("Starting node {s} --stdio", .{script_path});
        external.runExternalServer(allocator, input, output, "node", &args, environ_block) catch |err| {
            log.info("node-stdio LSP failed: {} (is node on PATH?)", .{err});
        };
    }

    fn startCssLanguageServer(self: *LSPManager, root_path: ?[]const u8) !void {
        var installer = Installer.init(self.allocator, self.io, self.environ_block);
        self.install_lock.lockUncancelable(self.io);
        const p = installer.ensureCssLanguageServer(false) catch |err| {
            self.install_lock.unlock(self.io);
            return err;
        };
        self.install_lock.unlock(self.io);
        try self.startGenericServer("css", p, runNodeStdioThread, .{ .root_path = root_path });
    }

    fn startHtmlLanguageServer(self: *LSPManager, root_path: ?[]const u8) !void {
        var installer = Installer.init(self.allocator, self.io, self.environ_block);
        self.install_lock.lockUncancelable(self.io);
        const p = installer.ensureHtmlLanguageServer(false) catch |err| {
            self.install_lock.unlock(self.io);
            return err;
        };
        self.install_lock.unlock(self.io);
        try self.startGenericServer("html", p, runNodeStdioThread, .{ .root_path = root_path });
    }

    fn startJsonLanguageServer(self: *LSPManager, root_path: ?[]const u8) !void {
        var installer = Installer.init(self.allocator, self.io, self.environ_block);
        self.install_lock.lockUncancelable(self.io);
        const p = installer.ensureJsonLanguageServer(false) catch |err| {
            self.install_lock.unlock(self.io);
            return err;
        };
        self.install_lock.unlock(self.io);
        try self.startGenericServer("json", p, runNodeStdioThread, .{ .root_path = root_path });
    }

    // intelephense (PHP) — node script with `--stdio`.
    fn startIntelephense(self: *LSPManager, root_path: ?[]const u8) !void {
        var installer = Installer.init(self.allocator, self.io, self.environ_block);
        self.install_lock.lockUncancelable(self.io);
        const p = installer.ensureIntelephense(false) catch |err| {
            self.install_lock.unlock(self.io);
            return err;
        };
        self.install_lock.unlock(self.io);
        try self.startGenericServer("php", p, runNodeStdioThread, .{ .root_path = root_path });
    }

    // perlnavigator — node script invoked without flags (it speaks
    // LSP on stdio by default).
    fn runPerlNavigatorThread(allocator: std.mem.Allocator, input: *Transport.MemPipe, output: *Transport.MemPipe, script_path: []const u8, environ_block: std.process.Environ.Block) void {
        defer allocator.free(script_path);
        const args = [_][]const u8{ "node", script_path, "--stdio" };
        log.info("Starting perlnavigator: node {s} --stdio", .{script_path});
        external.runExternalServer(allocator, input, output, "node", &args, environ_block) catch |err| {
            log.info("perlnavigator failed: {} (is node on PATH?)", .{err});
        };
    }

    fn startPerlNavigator(self: *LSPManager, root_path: ?[]const u8) !void {
        var installer = Installer.init(self.allocator, self.io, self.environ_block);
        self.install_lock.lockUncancelable(self.io);
        const p = installer.ensurePerlNavigator(false) catch |err| {
            self.install_lock.unlock(self.io);
            return err;
        };
        self.install_lock.unlock(self.io);
        try self.startGenericServer("perl", p, runPerlNavigatorThread, .{ .root_path = root_path });
    }

    // Dart SDK ships its language server; invoked as `dart language-server`.
    fn runDartLanguageServerThread(allocator: std.mem.Allocator, input: *Transport.MemPipe, output: *Transport.MemPipe, dart_path: []const u8, environ_block: std.process.Environ.Block) void {
        defer allocator.free(dart_path);
        const args = [_][]const u8{ dart_path, "language-server", "--protocol=lsp" };
        log.info("Starting dart language-server: {s}", .{dart_path});
        external.runExternalServer(allocator, input, output, dart_path, &args, environ_block) catch |err| {
            log.info("dart language-server failed: {}", .{err});
        };
    }

    fn startDartLanguageServer(self: *LSPManager, root_path: ?[]const u8) !void {
        var installer = Installer.init(self.allocator, self.io, self.environ_block);
        self.install_lock.lockUncancelable(self.io);
        const p = installer.ensureDartLanguageServer(false) catch |err| {
            self.install_lock.unlock(self.io);
            return err;
        };
        self.install_lock.unlock(self.io);
        try self.startGenericServer("dart", p, runDartLanguageServerThread, .{ .root_path = root_path });
    }

    // The following all speak LSP on stdio when invoked with no
    // arguments — one shared runner with a bare argv suffices.
    fn runBareBinaryThread(allocator: std.mem.Allocator, input: *Transport.MemPipe, output: *Transport.MemPipe, binary_path: []const u8, environ_block: std.process.Environ.Block) void {
        defer allocator.free(binary_path);
        const args = [_][]const u8{binary_path};
        log.info("Starting LSP binary: {s}", .{binary_path});
        external.runExternalServer(allocator, input, output, binary_path, &args, environ_block) catch |err| {
            log.info("LSP binary {s} failed: {}", .{ binary_path, err });
        };
    }

    fn startElixirLs(self: *LSPManager, root_path: ?[]const u8) !void {
        var installer = Installer.init(self.allocator, self.io, self.environ_block);
        const p = installer.ensureElixirLs(false) catch |err| return err;
        try self.startGenericServer("elixir", p, runBareBinaryThread, .{ .root_path = root_path });
    }

    fn startErlangLs(self: *LSPManager, root_path: ?[]const u8) !void {
        var installer = Installer.init(self.allocator, self.io, self.environ_block);
        const p = installer.ensureErlangLs(false) catch |err| return err;
        try self.startGenericServer("erlang", p, runBareBinaryThread, .{ .root_path = root_path });
    }

    fn startHaskellLanguageServer(self: *LSPManager, root_path: ?[]const u8) !void {
        var installer = Installer.init(self.allocator, self.io, self.environ_block);
        const p = installer.ensureHaskellLanguageServer(false) catch |err| return err;
        // `haskell-language-server-wrapper --lsp` is the documented
        // launch incantation; the bare wrapper without `--lsp` prints
        // a config check and exits.
        try self.startGenericServer("haskell", p, runHaskellLsThread, .{ .root_path = root_path });
    }

    fn runHaskellLsThread(allocator: std.mem.Allocator, input: *Transport.MemPipe, output: *Transport.MemPipe, binary_path: []const u8, environ_block: std.process.Environ.Block) void {
        defer allocator.free(binary_path);
        const args = [_][]const u8{ binary_path, "--lsp" };
        log.info("Starting haskell-language-server: {s} --lsp", .{binary_path});
        external.runExternalServer(allocator, input, output, binary_path, &args, environ_block) catch |err| {
            log.info("haskell-language-server failed: {}", .{err});
        };
    }

    fn startKotlinLanguageServer(self: *LSPManager, root_path: ?[]const u8) !void {
        var installer = Installer.init(self.allocator, self.io, self.environ_block);
        const p = installer.ensureKotlinLanguageServer(false) catch |err| return err;
        try self.startGenericServer("kotlin", p, runBareBinaryThread, .{ .root_path = root_path });
    }

    fn startOcamlLsp(self: *LSPManager, root_path: ?[]const u8) !void {
        var installer = Installer.init(self.allocator, self.io, self.environ_block);
        const p = installer.ensureOcamlLsp(false) catch |err| return err;
        try self.startGenericServer("ocaml", p, runBareBinaryThread, .{ .root_path = root_path });
    }

    fn startMetals(self: *LSPManager, root_path: ?[]const u8) !void {
        var installer = Installer.init(self.allocator, self.io, self.environ_block);
        const p = installer.ensureMetals(false) catch |err| return err;
        try self.startGenericServer("scala", p, runBareBinaryThread, .{ .root_path = root_path });
    }

    fn getServer(self: *LSPManager, lang: []const u8) ?*LSPServer {
        return self.servers.get(lang);
    }

    fn getServerForFile(self: *LSPManager, file_path: []const u8) ?*LSPServer {
        const lang = getLangFromPath(file_path) orelse return null;
        return self.servers.get(lang);
    }

    pub fn getLangFromPath(path: []const u8) ?[]const u8 {
        if (std.mem.endsWith(u8, path, ".zig")) return "zig";
        if (std.mem.endsWith(u8, path, ".py")) return "python";
        if (std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".tsx") or std.mem.endsWith(u8, path, ".jsx")) return "typescript";
        if (std.mem.endsWith(u8, path, ".js")) return "javascript";
        if (std.mem.endsWith(u8, path, ".rs")) return "rust";
        if (std.mem.endsWith(u8, path, ".go")) return "go";
        // C and C++: clangd handles both; we report a single "cpp" lang
        // for the LSP so one server services both. Headers (`.h`) are
        // ambiguous; we send them through clangd which figures it out.
        if (std.mem.endsWith(u8, path, ".c") or std.mem.endsWith(u8, path, ".h")) return "cpp";
        if (std.mem.endsWith(u8, path, ".cpp") or std.mem.endsWith(u8, path, ".cc") or
            std.mem.endsWith(u8, path, ".cxx") or std.mem.endsWith(u8, path, ".hpp") or
            std.mem.endsWith(u8, path, ".hxx") or std.mem.endsWith(u8, path, ".hh")) return "cpp";
        if (std.mem.endsWith(u8, path, ".java")) return "java";
        if (std.mem.endsWith(u8, path, ".rb") or std.mem.endsWith(u8, path, ".rake")) return "ruby";
        if (std.mem.endsWith(u8, path, ".cs")) return "csharp";
        if (std.mem.endsWith(u8, path, ".sh") or std.mem.endsWith(u8, path, ".bash") or std.mem.endsWith(u8, path, ".zsh")) return "bash";
        if (std.mem.endsWith(u8, path, ".lua")) return "lua";
        if (std.mem.endsWith(u8, path, ".swift")) return "swift";
        if (std.mem.endsWith(u8, path, ".r") or std.mem.endsWith(u8, path, ".R") or
            std.mem.endsWith(u8, path, ".rmd") or std.mem.endsWith(u8, path, ".Rmd")) return "r";
        if (std.mem.endsWith(u8, path, ".css") or std.mem.endsWith(u8, path, ".scss") or
            std.mem.endsWith(u8, path, ".less")) return "css";
        if (std.mem.endsWith(u8, path, ".html") or std.mem.endsWith(u8, path, ".htm")) return "html";
        if (std.mem.endsWith(u8, path, ".json")) return "json";
        if (std.mem.endsWith(u8, path, ".php") or std.mem.endsWith(u8, path, ".phtml")) return "php";
        if (std.mem.endsWith(u8, path, ".pl") or std.mem.endsWith(u8, path, ".pm") or
            std.mem.endsWith(u8, path, ".t")) return "perl";
        if (std.mem.endsWith(u8, path, ".dart")) return "dart";
        if (std.mem.endsWith(u8, path, ".ex") or std.mem.endsWith(u8, path, ".exs")) return "elixir";
        if (std.mem.endsWith(u8, path, ".erl") or std.mem.endsWith(u8, path, ".hrl")) return "erlang";
        if (std.mem.endsWith(u8, path, ".hs")) return "haskell";
        if (std.mem.endsWith(u8, path, ".kt") or std.mem.endsWith(u8, path, ".kts")) return "kotlin";
        if (std.mem.endsWith(u8, path, ".ml") or std.mem.endsWith(u8, path, ".mli")) return "ocaml";
        if (std.mem.endsWith(u8, path, ".scala") or std.mem.endsWith(u8, path, ".sc")) return "scala";
        return null;
    }

    /// Non-blocking: if a healthy initialized server already has the right
    /// root, send `didOpen` synchronously (a fast MemPipe write). Otherwise
    /// queue the open onto the supervisor so the UI thread doesn't wait for
    /// server boot/restart.
    pub fn documentOpened(self: *LSPManager, file_path: []const u8, content: []const u8) !void {
        log.info("LSPManager: documentOpened {s}", .{file_path});
        const lang = getLangFromPath(file_path) orelse return;

        const uri = try pathToUri(self.allocator, self.io, file_path);
        errdefer self.allocator.free(uri);

        // Fast path: server already exists, healthy, initialized, and either
        // the root matches or there's no root concept. Send the didOpen
        // inline. We hold the manager lock for the entire send to make sure
        // a concurrent supervisor `stop_server` can't tear the server down
        // mid-write.
        self.manager_mutex.lockUncancelable(self.io);
        if (self.open_documents.contains(uri)) {
            self.manager_mutex.unlock(self.io);
            self.allocator.free(uri);
            return;
        }

        const new_root_raw = self.findProjectRoot(file_path, lang) catch null;
        defer if (new_root_raw) |p| self.allocator.free(p);
        const new_root_trim: ?[]const u8 = if (new_root_raw) |p| std.mem.trimEnd(u8, p, "/") else null;

        if (self.servers.get(lang)) |srv| {
            const healthy = srv.server_healthy.load(.acquire) and srv.server_running.load(.acquire) and srv.is_initialized.load(.acquire);
            if (healthy) {
                const cur_trim: ?[]const u8 = if (srv.current_root_path) |p| std.mem.trimEnd(u8, p, "/") else null;
                const roots_match = (new_root_trim == null and cur_trim == null) or
                    (new_root_trim != null and cur_trim != null and std.mem.eql(u8, new_root_trim.?, cur_trim.?));
                if (roots_match) {
                    // Send the didOpen under the manager lock so a concurrent
                    // stop can't deinit the server before send completes.
                    srv.sendDidOpen(uri, lang, 1, content) catch |err| {
                        self.manager_mutex.unlock(self.io);
                        self.allocator.free(uri);
                        return err;
                    };
                    try self.open_documents.put(uri, {});
                    self.manager_mutex.unlock(self.io);
                    srv.requestSemanticTokens(uri) catch |err| {
                        log.warn("requestSemanticTokens on open failed: {}", .{err});
                    };
                    return;
                }
            }
        }
        self.manager_mutex.unlock(self.io);

        // Slow path: queue an ensure_and_open command for the supervisor and
        // return immediately. The didOpen will fire as soon as the server
        // is ready.
        const lang_owned = try self.allocator.dupe(u8, lang);
        errdefer self.allocator.free(lang_owned);
        const root_owned: ?[]u8 = if (new_root_raw) |p| try self.allocator.dupe(u8, p) else null;
        errdefer if (root_owned) |p| self.allocator.free(p);
        const file_owned = try self.allocator.dupe(u8, file_path);
        errdefer self.allocator.free(file_owned);
        const content_owned = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(content_owned);

        self.allocator.free(uri); // supervisor will rebuild from file_path

        self.supervisor.enqueue(.{ .ensure_and_open = .{
            .lang = lang_owned,
            .root = root_owned,
            .file_path = file_owned,
            .content = content_owned,
        } }) catch |err| {
            log.warn("supervisor enqueue failed: {}", .{err});
            return err;
        };
    }

    pub fn documentChanged(self: *LSPManager, file_path: []const u8, content: []const u8, version: i64) !void {
        // Trailing-edge debounce: buffer the latest content for this
        // file and let Core's tick handler flush via
        // `flushPendingChanges` once the user pauses for
        // `change_debounce_ms`. Avoids a per-keystroke didChange
        // storm. The slot is latest-wins so a burst of N edits costs
        // O(1) memory, one final send.
        const now = std.Io.Clock.real.now(self.io).toMilliseconds();
        const content_owned = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(content_owned);

        self.pending_changes_mutex.lockUncancelable(self.io);
        defer self.pending_changes_mutex.unlock(self.io);

        const gop = try self.pending_changes.getOrPut(self.allocator, file_path);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.content);
        } else {
            // Dupe the key so we own it; the caller's slice can vanish.
            const key_owned = self.allocator.dupe(u8, file_path) catch |err| {
                self.allocator.free(content_owned);
                _ = self.pending_changes.remove(file_path);
                return err;
            };
            gop.key_ptr.* = key_owned;
        }
        gop.value_ptr.* = .{
            .content = content_owned,
            .version = version,
            .queued_at = now,
        };
    }

    /// Drain pending didChange entries whose debounce window has
    /// elapsed and send them to the corresponding LSP servers. Called
    /// from Core's tick handler — keeps the hot keystroke path free of
    /// network I/O and per-server JSON encoding work.
    pub fn flushPendingChanges(self: *LSPManager) void {
        const now = std.Io.Clock.real.now(self.io).toMilliseconds();
        self.flushPendingChangesInternal(now, false);
    }

    /// Force-flush every pending change immediately, ignoring the
    /// debounce window. Used by `documentSaved` so the server sees the
    /// final edit before the save notification, and by shutdown paths
    /// where we won't get another tick.
    pub fn flushPendingChangesNow(self: *LSPManager) void {
        const now = std.Io.Clock.real.now(self.io).toMilliseconds();
        self.flushPendingChangesInternal(now, true);
    }

    fn flushPendingChangesInternal(self: *LSPManager, now_ms: i64, force: bool) void {
        // Steal-then-send pattern: collect the entries that are ready
        // under the pending_changes lock, then release it before any
        // network I/O. Holding the lock across `sendDidChange` would
        // serialize every other documentChanged call on the slow path.
        var ready: std.ArrayListUnmanaged(struct {
            path: []const u8,
            content: []const u8,
            version: i64,
        }) = .empty;
        defer ready.deinit(self.allocator);

        {
            self.pending_changes_mutex.lockUncancelable(self.io);
            defer self.pending_changes_mutex.unlock(self.io);

            var it = self.pending_changes.iterator();
            var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
            defer to_remove.deinit(self.allocator);

            while (it.next()) |entry| {
                if (!force and now_ms - entry.value_ptr.queued_at < self.change_debounce_ms) continue;
                ready.append(self.allocator, .{
                    .path = entry.key_ptr.*,
                    .content = entry.value_ptr.content,
                    .version = entry.value_ptr.version,
                }) catch {
                    // OOM during steal — leave entry pending for next tick.
                    return;
                };
                to_remove.append(self.allocator, entry.key_ptr.*) catch {};
            }
            for (to_remove.items) |key| _ = self.pending_changes.remove(key);
        }

        for (ready.items) |entry| {
            defer self.allocator.free(entry.path);
            defer self.allocator.free(entry.content);

            self.manager_mutex.lockUncancelable(self.io);
            const server_opt = self.getServerForFile(entry.path);
            self.manager_mutex.unlock(self.io);
            const server = server_opt orelse continue;
            if (!server.server_running.load(.acquire)) continue;
            const uri = pathToUri(self.allocator, self.io, entry.path) catch continue;
            defer self.allocator.free(uri);

            server.sendDidChange(uri, entry.version, entry.content) catch |err| {
                log.warn("debounced sendDidChange failed for {s}: {}", .{ entry.path, err });
                continue;
            };
            server.requestSemanticTokens(uri) catch |err| {
                log.warn("Failed to request semantic tokens after change for {s}: {}", .{ entry.path, err });
            };
        }
    }

    pub fn documentSaved(self: *LSPManager, file_path: []const u8) !void {
        // Flush any debounced changes first so the server's view of
        // the file matches what we're about to claim is saved. Without
        // this, didSave can arrive before the last didChange and the
        // server formats / lints stale content.
        self.flushPendingChangesNow();

        self.manager_mutex.lockUncancelable(self.io);
        const server_opt = self.getServerForFile(file_path);
        self.manager_mutex.unlock(self.io);
        const server = server_opt orelse return;
        if (!server.server_running.load(.acquire)) return;
        const uri = try pathToUri(self.allocator, self.io, file_path);
        defer self.allocator.free(uri);
        try server.sendDidSave(uri);
    }

    pub fn documentClosed(self: *LSPManager, file_path: []const u8) !void {
        // Drop any pending change for this file — the server is
        // about to be told the document is gone, no point pushing
        // changes it'll discard anyway.
        {
            self.pending_changes_mutex.lockUncancelable(self.io);
            defer self.pending_changes_mutex.unlock(self.io);
            if (self.pending_changes.fetchRemove(file_path)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value.content);
            }
        }

        const uri = try pathToUri(self.allocator, self.io, file_path);
        defer self.allocator.free(uri);

        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);

        if (self.open_documents.fetchRemove(uri)) |kv| {
            self.allocator.free(kv.key);
        }

        if (self.getServerForFile(file_path)) |server| {
            if (server.server_running.load(.acquire)) {
                try server.sendDidClose(uri);
            }
        }
    }

    pub fn requestHover(self: *LSPManager, file_path: []const u8, line: u32, col: u32) !void {
        try self.dispatchRequest(file_path, .hover, line, col);
    }

    /// Common dispatch: take the fast path (send the request inline if the
    /// server is ready) or enqueue a `deferred_request` so the supervisor
    /// runs it after the document has been opened. Either way the UI thread
    /// returns immediately — no waiting on init.
    fn dispatchRequest(self: *LSPManager, file_path: []const u8, kind: supervisor_mod.Command.DeferredKind, line: u32, col: u32) !void {
        const lang = getLangFromPath(file_path) orelse return;

        // Try the fast path under the manager lock.
        self.manager_mutex.lockUncancelable(self.io);
        const maybe_srv = self.servers.get(lang);
        const ready = if (maybe_srv) |s|
            s.is_initialized.load(.acquire) and s.server_healthy.load(.acquire) and s.server_running.load(.acquire)
        else
            false;
        const uri_in_open = if (ready) blk: {
            const u = pathToUri(self.allocator, self.io, file_path) catch break :blk false;
            defer self.allocator.free(u);
            break :blk self.open_documents.contains(u);
        } else false;
        if (ready and uri_in_open) {
            const server = maybe_srv.?;
            const uri = try pathToUri(self.allocator, self.io, file_path);
            defer self.allocator.free(uri);
            switch (kind) {
                .hover => try server.requestHover(uri, line, col),
                .completion => try server.requestCompletion(uri, line, col),
                .formatting => try server.requestFormatting(uri),
                .definition => try server.requestDefinition(uri, line, col),
                .references => try server.requestReferences(uri, line, col),
                .document_symbols => try server.requestDocumentSymbols(uri),
            }
            self.manager_mutex.unlock(self.io);
            return;
        }
        self.manager_mutex.unlock(self.io);

        // Slow path: queue the request. The supervisor will execute it
        // after any preceding `ensure_and_open` finishes, so the doc is
        // guaranteed open by then.
        const lang_dup = try self.allocator.dupe(u8, lang);
        errdefer self.allocator.free(lang_dup);
        const path_dup = try self.allocator.dupe(u8, file_path);
        errdefer self.allocator.free(path_dup);
        try self.supervisor.enqueue(.{ .deferred_request = .{
            .lang = lang_dup,
            .file_path = path_dup,
            .kind = kind,
            .line = line,
            .col = col,
        } });
    }

    pub fn popHoverResult(self: *LSPManager) ?[]u8 {
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        var it = self.servers.valueIterator();
        while (it.next()) |server_ptr| {
            const server = server_ptr.*;
            server.hover_mutex.lockUncancelable(self.io);
            defer server.hover_mutex.unlock(self.io);
            if (server.hover_result) |res| {
                log.info("popHoverResult found: {s}", .{res});
                server.hover_result = null;
                return res;
            }
        }
        return null;
    }

    pub fn requestFormatting(self: *LSPManager, file_path: []const u8) !void {
        try self.dispatchRequest(file_path, .formatting, 0, 0);
    }

    /// Send `textDocument/rangeFormatting`. Unlike `requestFormatting`
    /// this doesn't go through the supervisor's deferred queue — range
    /// formatting is always synchronous user intent ("format this
    /// selection now"), so we either send it immediately or fail. The
    /// response shares the format slot, so `popFormatResult` picks it
    /// up like a full-document format.
    pub fn requestRangeFormatting(self: *LSPManager, file_path: []const u8, start_line: u32, start_col: u32, end_line: u32, end_col: u32) !void {
        const lang = getLangFromPath(file_path) orelse return error.UnsupportedLanguage;

        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);

        const server = self.servers.get(lang) orelse return error.ServerNotRunning;
        if (!server.is_initialized.load(.acquire) or !server.server_running.load(.acquire)) {
            return error.ServerNotReady;
        }
        const uri = try pathToUri(self.allocator, self.io, file_path);
        defer self.allocator.free(uri);
        try server.requestRangeFormatting(uri, start_line, start_col, end_line, end_col);
    }

    /// Send `textDocument/codeAction` for the given range. Same
    /// synchronous fast-path-or-fail model as range formatting —
    /// code actions are always user intent and need an immediate
    /// answer (or a clean error so the caller can fall back).
    pub fn requestCodeAction(self: *LSPManager, file_path: []const u8, start_line: u32, start_col: u32, end_line: u32, end_col: u32) !void {
        const lang = getLangFromPath(file_path) orelse return error.UnsupportedLanguage;
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        const server = self.servers.get(lang) orelse return error.ServerNotRunning;
        if (!server.is_initialized.load(.acquire) or !server.server_running.load(.acquire)) {
            return error.ServerNotReady;
        }
        const uri = try pathToUri(self.allocator, self.io, file_path);
        defer self.allocator.free(uri);
        try server.requestCodeAction(uri, start_line, start_col, end_line, end_col);
    }

    pub fn popCodeActionResult(self: *LSPManager) ?[]LSPServer.CodeAction {
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        var it = self.servers.valueIterator();
        while (it.next()) |server_ptr| {
            const server = server_ptr.*;
            server.code_action_mutex.lockUncancelable(self.io);
            defer server.code_action_mutex.unlock(self.io);
            if (server.code_action_result) |res| {
                server.code_action_result = null;
                return res;
            }
        }
        return null;
    }

    pub fn freeCodeActions(self: *LSPManager, actions: []LSPServer.CodeAction) void {
        for (actions) |a| {
            self.allocator.free(a.title);
            if (a.kind) |k| self.allocator.free(k);
            if (a.edit_json) |e| self.allocator.free(e);
            if (a.command_json) |c| self.allocator.free(c);
        }
        self.allocator.free(actions);
    }

    pub fn requestSignatureHelp(self: *LSPManager, file_path: []const u8, line: u32, col: u32) !void {
        const lang = getLangFromPath(file_path) orelse return error.UnsupportedLanguage;
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        const server = self.servers.get(lang) orelse return error.ServerNotRunning;
        if (!server.is_initialized.load(.acquire) or !server.server_running.load(.acquire)) {
            return error.ServerNotReady;
        }
        const uri = try pathToUri(self.allocator, self.io, file_path);
        defer self.allocator.free(uri);
        try server.requestSignatureHelp(uri, line, col);
    }

    pub fn popSignatureHelpResult(self: *LSPManager) ?LSPServer.SignatureHelp {
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        var it = self.servers.valueIterator();
        while (it.next()) |server_ptr| {
            const server = server_ptr.*;
            server.signature_help_mutex.lockUncancelable(self.io);
            defer server.signature_help_mutex.unlock(self.io);
            if (server.signature_help_result) |res| {
                server.signature_help_result = null;
                return res;
            }
        }
        return null;
    }

    pub fn freeSignatureHelp(self: *LSPManager, sh: LSPServer.SignatureHelp) void {
        self.allocator.free(sh.label);
        for (sh.parameters) |p| self.allocator.free(p);
        self.allocator.free(sh.parameters);
    }

    pub fn requestInlayHint(self: *LSPManager, file_path: []const u8, start_line: u32, end_line: u32) !void {
        const lang = getLangFromPath(file_path) orelse return error.UnsupportedLanguage;
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        const server = self.servers.get(lang) orelse return error.ServerNotRunning;
        if (!server.is_initialized.load(.acquire) or !server.server_running.load(.acquire)) {
            return error.ServerNotReady;
        }
        const uri = try pathToUri(self.allocator, self.io, file_path);
        defer self.allocator.free(uri);
        try server.requestInlayHint(uri, start_line, end_line);
    }

    /// Copy the most-recent inlay hints for `file_path` into the
    /// caller's allocator. Returns an empty slice if no hints have
    /// arrived yet — the caller checks `len == 0` to decide whether
    /// to render anything.
    pub fn copyInlayHints(self: *LSPManager, allocator: std.mem.Allocator, file_path: []const u8) ![]LSPServer.InlayHint {
        const lang = getLangFromPath(file_path) orelse return &.{};
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        const server = self.servers.get(lang) orelse return &.{};

        const uri = try pathToUri(self.allocator, self.io, file_path);
        defer self.allocator.free(uri);

        server.inlay_hints_mutex.lockUncancelable(self.io);
        defer server.inlay_hints_mutex.unlock(self.io);
        const hints = server.inlay_hints.get(uri) orelse return &.{};

        const out = try allocator.alloc(LSPServer.InlayHint, hints.len);
        errdefer allocator.free(out);
        for (hints, 0..) |h, i| {
            out[i] = .{
                .line = h.line,
                .col = h.col,
                .label = try allocator.dupe(u8, h.label),
                .kind = h.kind,
                .padding_left = h.padding_left,
                .padding_right = h.padding_right,
            };
        }
        return out;
    }

    pub fn popFormatResult(self: *LSPManager) ?[]const TextEdit {
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        var it = self.servers.valueIterator();
        while (it.next()) |server_ptr| {
            const server = server_ptr.*;
            server.format_mutex.lockUncancelable(self.io);
            defer server.format_mutex.unlock(self.io);
            if (server.format_result) |res| {
                server.format_result = null;
                return res;
            }
        }
        return null;
    }

    pub fn requestDefinition(self: *LSPManager, file_path: []const u8, line: u32, col: u32) !void {
        try self.dispatchRequest(file_path, .definition, line, col);
    }

    pub fn popDefinitionResult(self: *LSPManager) ?Location {
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        var it = self.servers.valueIterator();
        while (it.next()) |server_ptr| {
            const server = server_ptr.*;
            server.definition_mutex.lockUncancelable(self.io);
            defer server.definition_mutex.unlock(self.io);
            if (server.definition_result) |res| {
                server.definition_result = null;
                return res;
            }
        }
        return null;
    }

    pub fn requestReferences(self: *LSPManager, file_path: []const u8, line: u32, col: u32) !void {
        try self.dispatchRequest(file_path, .references, line, col);
    }

    pub fn popReferencesResult(self: *LSPManager) ?[]Location {
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        var it = self.servers.valueIterator();
        while (it.next()) |server_ptr| {
            const server = server_ptr.*;
            server.references_mutex.lockUncancelable(self.io);
            defer server.references_mutex.unlock(self.io);
            if (server.references_result) |res| {
                server.references_result = null;
                return res;
            }
        }
        return null;
    }

    pub fn freeReferences(self: *LSPManager, refs: []Location) void {
        for (refs) |r| {
            self.allocator.free(r.file_path);
        }
        self.allocator.free(refs);
    }

    pub fn requestCompletion(self: *LSPManager, file_path: []const u8, line: u32, col: u32) !void {
        try self.dispatchRequest(file_path, .completion, line, col);
    }

    pub fn popCompletionResult(self: *LSPManager) ?[]CompletionItem {
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        var it = self.servers.valueIterator();
        while (it.next()) |server_ptr| {
            const server = server_ptr.*;
            server.completion_mutex.lockUncancelable(self.io);
            defer server.completion_mutex.unlock(self.io);
            if (server.completion_result) |res| {
                server.completion_result = null;
                return res;
            }
        }
        return null;
    }

    pub fn freeCompletionItems(self: *LSPManager, items: []CompletionItem) void {
        for (items) |item| {
            self.allocator.free(item.label);
            if (item.detail) |d| self.allocator.free(d);
        }
        self.allocator.free(items);
    }

    pub fn requestDocumentSymbols(self: *LSPManager, file_path: []const u8) !void {
        try self.dispatchRequest(file_path, .document_symbols, 0, 0);
    }

    pub fn popDocumentSymbolsResult(self: *LSPManager) ?[]DocumentSymbol {
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        var it = self.servers.valueIterator();
        while (it.next()) |server_ptr| {
            const server = server_ptr.*;
            server.document_symbols_mutex.lockUncancelable(self.io);
            defer server.document_symbols_mutex.unlock(self.io);
            if (server.document_symbols_result) |res| {
                server.document_symbols_result = null;
                return res;
            }
        }
        return null;
    }

    pub fn freeDocumentSymbols(self: *LSPManager, symbols: []DocumentSymbol) void {
        for (symbols) |sym| {
            self.allocator.free(sym.name);
            if (sym.container_name) |c| self.allocator.free(c);
        }
        self.allocator.free(symbols);
    }

    /// Send a `workspace/symbol` query to the server matching `lang`.
    /// No-ops if there's no running server for that language — the
    /// caller's picker just stays empty.
    pub fn requestWorkspaceSymbol(self: *LSPManager, lang: []const u8, query: []const u8) !void {
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        const server = self.servers.get(lang) orelse return;
        if (!server.is_initialized.load(.acquire)) return;
        try server.requestWorkspaceSymbol(query);
    }

    pub fn popWorkspaceSymbolsResult(self: *LSPManager) ?[]WorkspaceSymbol {
        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        var it = self.servers.valueIterator();
        while (it.next()) |server_ptr| {
            const server = server_ptr.*;
            server.workspace_symbols_mutex.lockUncancelable(self.io);
            defer server.workspace_symbols_mutex.unlock(self.io);
            if (server.workspace_symbols_result) |res| {
                server.workspace_symbols_result = null;
                return res;
            }
        }
        return null;
    }

    pub fn freeWorkspaceSymbols(self: *LSPManager, symbols: []WorkspaceSymbol) void {
        for (symbols) |sym| {
            self.allocator.free(sym.name);
            self.allocator.free(sym.file_path);
            if (sym.container_name) |c| self.allocator.free(c);
        }
        self.allocator.free(symbols);
    }

    pub fn copyVisibleTokens(self: *LSPManager, allocator: std.mem.Allocator, file_path: []const u8, first_line: usize, last_line: usize) ![]protocol.SyntaxToken {
        // Hot path: called per pane per render. Hold the manager lock only
        // for the lookup, then release before the token copy (which takes
        // the server's own file_tokens_mutex). The supervisor can't deinit
        // a server while we're using its pointer here because it would
        // need this same mutex to remove it from the map first.
        self.manager_mutex.lockUncancelable(self.io);
        const server_opt = self.getServerForFile(file_path);
        self.manager_mutex.unlock(self.io);
        const server = server_opt orelse return &.{};

        const uri = try pathToUri(allocator, self.io, file_path);
        defer allocator.free(uri);
        return server.copyVisibleTokens(allocator, uri, first_line, last_line);
    }

    pub fn refreshSemanticTokens(self: *LSPManager, file_path: []const u8) void {
        const lang = getLangFromPath(file_path) orelse return;

        self.manager_mutex.lockUncancelable(self.io);
        const maybe_server = self.servers.get(lang);
        self.manager_mutex.unlock(self.io);
        const server = maybe_server orelse return;

        if (!server.server_healthy.load(.acquire) and server.server_running.load(.acquire)) {
            // Hand off the recovery to the supervisor; this returns
            // immediately so we don't freeze the caller.
            log.info("[LSP AUTO-RECOVERY] {s} server unhealthy, queueing restart...", .{lang});
            const root = if (server.current_root_path) |p|
                self.allocator.dupe(u8, p) catch null
            else
                null;

            const lang_owned = self.allocator.dupe(u8, lang) catch {
                if (root) |r| self.allocator.free(r);
                return;
            };
            self.supervisor.enqueueDedup(.{ .restart_server = .{ .lang = lang_owned, .root = root } }) catch {
                self.allocator.free(lang_owned);
                if (root) |r| self.allocator.free(r);
            };
            return;
        }

        if (server.server_running.load(.acquire) and server.is_initialized.load(.acquire)) {
            const uri = pathToUri(self.allocator, self.io, file_path) catch return;
            defer self.allocator.free(uri);

            self.manager_mutex.lockUncancelable(self.io);
            const already_open = self.open_documents.contains(uri);
            self.manager_mutex.unlock(self.io);

            if (!already_open) {
                log.info("[LSP REFRESH] Document not tracked as open, sending didOpen for {s}", .{file_path});
                const content = std.Io.Dir.cwd().readFileAlloc(self.io, file_path, self.allocator, .limited(10 * 1024 * 1024)) catch |err| {
                    log.warn("[LSP REFRESH] Failed to read file for didOpen: {}", .{err});
                    return;
                };
                defer self.allocator.free(content);

                server.sendDidOpen(uri, lang, 1, content) catch return;
                const uri_dup = self.allocator.dupe(u8, uri) catch return;
                self.manager_mutex.lockUncancelable(self.io);
                defer self.manager_mutex.unlock(self.io);
                self.open_documents.put(uri_dup, {}) catch {
                    self.allocator.free(uri_dup);
                    return;
                };
            }

            server.requestSemanticTokens(uri) catch |err| {
                log.warn("Failed to request semantic tokens on refresh for {s}: {}", .{ uri, err });
            };
        }
    }

    pub fn getActiveServerStatus(self: *LSPManager, allocator: std.mem.Allocator) !?[]u8 {
        var list = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer list.deinit(allocator);

        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        var it = self.servers.valueIterator();
        var first = true;
        while (it.next()) |server_ptr| {
            const server = server_ptr.*;
            if (server.server_running.load(.acquire)) {
                if (!first) try list.appendSlice(allocator, ", ");
                try list.appendSlice(allocator, server.lang);
                first = false;
            }
        }

        if (list.items.len == 0) {
            list.deinit(allocator);
            return null;
        }
        return try list.toOwnedSlice(allocator);
    }

    pub fn getDiagnostics(self: *LSPManager, allocator: std.mem.Allocator) ![]Diagnostic {
        var all_diagnostics = try std.ArrayList(Diagnostic).initCapacity(allocator, 8);
        defer all_diagnostics.deinit(allocator);

        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        var it = self.servers.valueIterator();
        while (it.next()) |server_ptr| {
            const server = server_ptr.*;
            server.diagnostics_mutex.lockUncancelable(self.io);
            defer server.diagnostics_mutex.unlock(self.io);

            var diag_it = server.diagnostics.valueIterator();
            while (diag_it.next()) |list| {
                for (list.*) |d| {
                    try all_diagnostics.append(allocator, .{
                        .start_line = d.start_line,
                        .start_col = d.start_col,
                        .end_line = d.end_line,
                        .end_col = d.end_col,
                        .severity = d.severity,
                        .message = try allocator.dupe(u8, d.message),
                    });
                }
            }
        }
        return all_diagnostics.toOwnedSlice(allocator);
    }

    /// Return diagnostics scoped to a single file path. Caller frees via
    /// `freeDiagnostics`.
    pub fn getDiagnosticsForFile(self: *LSPManager, allocator: std.mem.Allocator, file_path: []const u8) ![]Diagnostic {
        const uri = pathToUri(self.allocator, self.io, file_path) catch return &.{};
        defer self.allocator.free(uri);

        var matches = try std.ArrayList(Diagnostic).initCapacity(allocator, 8);
        defer matches.deinit(allocator);

        self.manager_mutex.lockUncancelable(self.io);
        defer self.manager_mutex.unlock(self.io);
        var it = self.servers.valueIterator();
        while (it.next()) |server_ptr| {
            const server = server_ptr.*;
            server.diagnostics_mutex.lockUncancelable(self.io);
            defer server.diagnostics_mutex.unlock(self.io);

            if (server.diagnostics.get(uri)) |list| {
                for (list) |d| {
                    try matches.append(allocator, .{
                        .start_line = d.start_line,
                        .start_col = d.start_col,
                        .end_line = d.end_line,
                        .end_col = d.end_col,
                        .severity = d.severity,
                        .message = try allocator.dupe(u8, d.message),
                    });
                }
            }
        }
        return matches.toOwnedSlice(allocator);
    }

    pub fn freeDiagnostics(allocator: std.mem.Allocator, diagnostics: []Diagnostic) void {
        for (diagnostics) |d| {
            allocator.free(d.message);
        }
        allocator.free(diagnostics);
    }

    fn detectZigEnv(allocator: std.mem.Allocator, io: std.Io) !?ZigEnv {
        // `zig env` writes a ZON literal by default whose string fields use
        // ad-hoc quoting we can't safely regex over (a path with `"` in it
        // breaks the parser). Use the structured `--json` form instead.
        const result = std.process.run(allocator, io, .{
            .argv = &.{ "zig", "env", "--json" },
        }) catch return null;
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        const ok = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!ok) return null;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const obj = parsed.value.object;

        const exe_val = obj.get("zig_exe") orelse return null;
        const lib_val = obj.get("lib_dir") orelse return null;
        const cache_val = obj.get("global_cache_dir") orelse return null;
        if (exe_val != .string or lib_val != .string or cache_val != .string) return null;

        const zig_exe = try allocator.dupe(u8, exe_val.string);
        errdefer allocator.free(zig_exe);
        const lib_dir = try allocator.dupe(u8, lib_val.string);
        errdefer allocator.free(lib_dir);
        const global_cache_dir = try allocator.dupe(u8, cache_val.string);

        return ZigEnv{ .zig_exe = zig_exe, .lib_dir = lib_dir, .global_cache_dir = global_cache_dir };
    }

    fn pathToUri(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
        return @import("../lsp/client.zig").pathToUri(allocator, io, path);
    }

    /// Walk the workspace shallowly and return every language we can
    /// detect — by project marker (`Cargo.toml` → rust, `go.mod` → go,
    /// etc.) or by file extension within the first two directory
    /// levels. The result feeds `prewarmWorkspaceLanguages` so we
    /// start an LSP server for each language present in the project
    /// *before* the user opens a file of that type. First hover is
    /// then warm instead of paying a cold init delay.
    ///
    /// The walk is bounded (depth 2, ~5k entries) so it stays under
    /// ~100ms even on big monorepos. Common dirs that contain
    /// generated / vendored code are skipped.
    ///
    /// Caller owns the returned slice (and each entry — they're
    /// borrowed from a static table, so don't free the inner
    /// strings; just `free` the outer slice).
    pub fn detectWorkspaceLanguages(self: *LSPManager, root: []const u8) ![]const []const u8 {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.allocator);

        // Project markers — strong signal that a project of this
        // language lives at the workspace root, even if there are no
        // source files directly at top level.
        const Marker = struct { file: []const u8, lang: []const u8 };
        const markers = [_]Marker{
            .{ .file = "Cargo.toml", .lang = "rust" },
            .{ .file = "go.mod", .lang = "go" },
            .{ .file = "build.zig", .lang = "zig" },
            .{ .file = "package.json", .lang = "typescript" }, // ts server covers js too
            .{ .file = "tsconfig.json", .lang = "typescript" },
            .{ .file = "pyproject.toml", .lang = "python" },
            .{ .file = "requirements.txt", .lang = "python" },
            .{ .file = "setup.py", .lang = "python" },
            .{ .file = "Gemfile", .lang = "ruby" },
            .{ .file = "pom.xml", .lang = "java" },
            .{ .file = "build.gradle", .lang = "java" },
            .{ .file = "build.gradle.kts", .lang = "java" },
            .{ .file = "Package.swift", .lang = "swift" },
            .{ .file = "CMakeLists.txt", .lang = "cpp" },
            .{ .file = "Makefile", .lang = "cpp" },
            .{ .file = "DESCRIPTION", .lang = "r" },
            .{ .file = "pubspec.yaml", .lang = "dart" },
            .{ .file = "mix.exs", .lang = "elixir" },
            .{ .file = "rebar.config", .lang = "erlang" },
            .{ .file = "stack.yaml", .lang = "haskell" },
            .{ .file = "cabal.project", .lang = "haskell" },
            .{ .file = "dune-project", .lang = "ocaml" },
            .{ .file = "composer.json", .lang = "php" },
            .{ .file = "build.sbt", .lang = "scala" },
            .{ .file = "cpanfile", .lang = "perl" },
        };
        for (markers) |m| {
            const p = try std.fs.path.join(self.allocator, &.{ root, m.file });
            defer self.allocator.free(p);
            std.Io.Dir.accessAbsolute(self.io, p, .{}) catch continue;
            _ = try seen.getOrPut(self.allocator, m.lang);
        }

        // Extension fan-out — walk root + one level deep, looking at
        // each file's extension. Catches projects without a canonical
        // marker (loose `.lua` scripts, a directory of `.sh` files,
        // etc).
        try self.scanDirForLanguages(root, 0, 2, &seen);

        // Materialise the set.
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer out.deinit(self.allocator);
        var it = seen.keyIterator();
        while (it.next()) |k| try out.append(self.allocator, k.*);
        return out.toOwnedSlice(self.allocator);
    }

    /// Recursive helper for `detectWorkspaceLanguages`. Bounded so
    /// monorepos don't pay a multi-second scan on startup.
    fn scanDirForLanguages(
        self: *LSPManager,
        dir_path: []const u8,
        depth: u32,
        max_depth: u32,
        seen: *std.StringHashMapUnmanaged(void),
    ) !void {
        if (depth > max_depth) return;
        var dir = std.Io.Dir.openDirAbsolute(self.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        var entry_count: u32 = 0;
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            entry_count += 1;
            if (entry_count > 5000) break; // safety cap
            // Skip noisy / generated dirs. Saves time AND avoids
            // detecting wrong languages (e.g. `.ts` files in
            // `node_modules` shouldn't make every Python project
            // think it's also a TypeScript project).
            if (entry.kind == .directory) {
                if (shouldSkipDir(entry.name)) continue;
                if (depth + 1 > max_depth) continue;
                const sub = std.fs.path.join(self.allocator, &.{ dir_path, entry.name }) catch continue;
                defer self.allocator.free(sub);
                self.scanDirForLanguages(sub, depth + 1, max_depth, seen) catch {};
                continue;
            }
            if (entry.kind != .file) continue;
            const lang = getLangFromPath(entry.name) orelse continue;
            _ = seen.getOrPut(self.allocator, lang) catch {};
        }
    }

    fn shouldSkipDir(name: []const u8) bool {
        const skip = [_][]const u8{
            ".git",         ".hg",         ".svn",
            "node_modules", "vendor",      "target",
            "build",        "dist",        "out",
            ".zig-cache",   "zig-cache",   "zig-out",
            ".cache",       ".idea",       ".vscode",
            "__pycache__",  ".venv",       "venv",
            ".tox",         ".mypy_cache", ".pytest_cache",
            ".next",        ".nuxt",       ".gradle",
            "DerivedData",
        };
        for (skip) |s| {
            if (std.mem.eql(u8, s, name)) return true;
        }
        // Skip dot-files / dot-dirs by default — they're usually
        // tooling state, not source.
        return name.len > 0 and name[0] == '.';
    }

    /// One-shot prewarm: discover languages in `root`, kick off a
    /// non-blocking `startServer` for each. Servers spin up in
    /// parallel on the supervisor's worker pool; the call returns
    /// once the starts are queued, not when they finish.
    pub fn prewarmWorkspaceLanguages(self: *LSPManager, root: []const u8) !usize {
        const langs = try self.detectWorkspaceLanguages(root);
        defer self.allocator.free(langs);
        var queued: usize = 0;
        for (langs) |lang| {
            // Don't restart a server we already have running.
            self.manager_mutex.lockUncancelable(self.io);
            const already = self.servers.get(lang) != null;
            self.manager_mutex.unlock(self.io);
            if (already) continue;
            self.startServer(lang, root) catch |err| {
                log.warn("[LSP PREWARM] enqueue failed for {s}: {}", .{ lang, err });
                continue;
            };
            queued += 1;
            log.info("[LSP PREWARM] queued start for {s} at {s}", .{ lang, root });
        }
        return queued;
    }

    pub fn findProjectRoot(self: *LSPManager, file_path: []const u8, lang: []const u8) ![]const u8 {
        const start_dir_raw = std.fs.path.dirname(file_path) orelse return self.allocator.dupe(u8, ".");
        // Resolve symlinks so the walk-up doesn't loop or escape past the
        // intended root via `../` in a symlinked path.
        var realpath_buf: [std.fs.max_path_bytes]u8 = undefined;
        const start_dir = if (std.Io.Dir.realPathFileAbsolute(self.io, start_dir_raw, &realpath_buf)) |n|
            realpath_buf[0..n]
        else |_|
            start_dir_raw;
        var current_dir = try self.allocator.dupe(u8, start_dir);

        if (std.mem.eql(u8, lang, "rust")) {
            return self.findRustProjectRoot(start_dir);
        }

        const markers = if (std.mem.eql(u8, lang, "go"))
            &[_][]const u8{"go.mod"}
        else if (std.mem.eql(u8, lang, "zig"))
            &[_][]const u8{"build.zig"}
        else if (std.mem.eql(u8, lang, "javascript") or std.mem.eql(u8, lang, "typescript"))
            &[_][]const u8{ "package.json", "tsconfig.json", "jsconfig.json" }
        else if (std.mem.eql(u8, lang, "python"))
            &[_][]const u8{ "pyproject.toml", "requirements.txt", ".git" }
        else
            &[_][]const u8{".git"};

        while (true) {
            for (markers) |marker| {
                const marker_path = try std.fs.path.join(self.allocator, &.{ current_dir, marker });
                defer self.allocator.free(marker_path);

                std.Io.Dir.accessAbsolute(self.io, marker_path, .{}) catch {
                    continue;
                };

                log.info("findProjectRoot: Found root at {s} (marker: {s})", .{ current_dir, marker });
                return current_dir;
            }

            const parent = std.fs.path.dirname(current_dir);
            if (parent == null or std.mem.eql(u8, current_dir, parent.?)) {
                self.allocator.free(current_dir);
                break;
            }

            const new_dir = try self.allocator.dupe(u8, parent.?);
            self.allocator.free(current_dir);
            current_dir = new_dir;
        }

        return self.allocator.dupe(u8, start_dir);
    }

    fn findRustProjectRoot(self: *LSPManager, start_dir: []const u8) ![]const u8 {
        var current_dir = try self.allocator.dupe(u8, start_dir);
        var first_cargo_toml: ?[]u8 = null;

        while (true) {
            {
                const lock_path = try std.fs.path.join(self.allocator, &.{ current_dir, "Cargo.lock" });
                defer self.allocator.free(lock_path);

                var exists = true;
                std.Io.Dir.accessAbsolute(self.io, lock_path, .{}) catch {
                    exists = false;
                };

                if (exists) {
                    log.info("findRustProjectRoot: Found workspace root at {s} (Cargo.lock)", .{current_dir});
                    if (first_cargo_toml) |p| self.allocator.free(p);
                    return current_dir;
                }
            }

            {
                const toml_path = try std.fs.path.join(self.allocator, &.{ current_dir, "Cargo.toml" });
                defer self.allocator.free(toml_path);

                var exists = true;
                std.Io.Dir.accessAbsolute(self.io, toml_path, .{}) catch {
                    exists = false;
                };

                if (exists) {
                    if (first_cargo_toml == null) {
                        first_cargo_toml = try self.allocator.dupe(u8, current_dir);
                        log.info("findRustProjectRoot: Found potential root at {s} (Cargo.toml)", .{current_dir});
                    }
                }
            }

            const parent = std.fs.path.dirname(current_dir);
            if (parent == null or std.mem.eql(u8, current_dir, parent.?)) {
                self.allocator.free(current_dir);
                break;
            }

            const new_dir = try self.allocator.dupe(u8, parent.?);
            self.allocator.free(current_dir);
            current_dir = new_dir;
        }

        if (first_cargo_toml) |path| {
            log.info("findRustProjectRoot: Using fallback root at {s}", .{path});
            return path;
        }

        log.info("findRustProjectRoot: No Cargo.toml found, using start dir {s}", .{start_dir});
        return self.allocator.dupe(u8, start_dir);
    }
};
