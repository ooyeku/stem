const std = @import("std");
const platform = @import("../../kernel/platform.zig");
const Transport = @import("../../lsp/transport.zig");
const protocol = @import("../../kernel/protocol.zig");
const lsp_client = @import("../../lsp/client.zig");
const pathToUri = lsp_client.pathToUri;
const fileUriToPath = lsp_client.fileUriToPath;
const supervisor_mod = @import("supervisor.zig");
const safe = @import("../../kernel/safe.zig");
const log = std.log.scoped(.LSP);

pub const RequestKind = enum {
    initialize,
    hover,
    format,
    definition,
    references,
    completion,
    document_symbols,
    workspace_symbols,
    code_action,
    signature_help,
    inlay_hint,
};

/// LSP position encoding. Defaults to utf16 (the LSP-spec default) unless the
/// server agreed to utf-8 via the `general.positionEncodings` capability we
/// advertise in `initialize`. stem stores byte offsets internally; when the
/// negotiated encoding is utf16, callers must convert before sending and
/// after receiving — see `byteColToUtf16` / `utf16ColToByte`.
pub const PositionEncoding = enum { utf8, utf16 };

/// Convert a byte column offset within a UTF-8 line to a UTF-16 code-unit
/// column offset. Fast-paths the all-ASCII case.
pub fn byteColToUtf16(line: []const u8, byte_col: usize) usize {
    const limit = @min(byte_col, line.len);
    // ASCII fast path: every byte is one code unit and one code point.
    var ascii = true;
    for (line[0..limit]) |b| {
        if (b >= 0x80) {
            ascii = false;
            break;
        }
    }
    if (ascii) return limit;

    var i: usize = 0;
    var u16_count: usize = 0;
    while (i < limit) {
        const b = line[i];
        if (b < 0x80) {
            i += 1;
            u16_count += 1;
        } else if (b < 0xC0) {
            // Continuation byte mid-character; treat as 1 to advance.
            i += 1;
        } else if (b < 0xE0) {
            i += 2;
            u16_count += 1;
        } else if (b < 0xF0) {
            i += 3;
            u16_count += 1;
        } else {
            i += 4;
            u16_count += 2; // surrogate pair in utf-16
        }
    }
    return u16_count;
}

/// Inverse of `byteColToUtf16`. Given a line and a UTF-16 code-unit column,
/// return the byte offset that lands on (or just past) the same code point.
pub fn utf16ColToByte(line: []const u8, utf16_col: usize) usize {
    var ascii = true;
    for (line) |b| {
        if (b >= 0x80) {
            ascii = false;
            break;
        }
    }
    if (ascii) return @min(utf16_col, line.len);

    var i: usize = 0;
    var u16_count: usize = 0;
    while (i < line.len) {
        if (u16_count >= utf16_col) return i;
        const b = line[i];
        if (b < 0x80) {
            i += 1;
            u16_count += 1;
        } else if (b < 0xC0) {
            i += 1;
        } else if (b < 0xE0) {
            i += 2;
            u16_count += 1;
        } else if (b < 0xF0) {
            i += 3;
            u16_count += 1;
        } else {
            i += 4;
            u16_count += 2;
        }
    }
    return line.len;
}

pub const LSPServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    lang: []const u8,
    /// The workspace root for this server. Set by LSPManager before `start()`
    /// is called; `start()` reads it to build the `rootUri` for `initialize`.
    current_root_path: ?[]u8 = null,

    /// Optional path to a directory where parsed semantic tokens get
    /// serialized after each `textDocument/semanticTokens/full` response.
    /// On the next launch, `tryLoadCachedTokens` reads them back so the
    /// editor renders LSP-quality highlighting *instantly* while the real
    /// server is still indexing. Null means caching is disabled.
    token_cache_dir: ?[]u8 = null,

    to_server: Transport.MemPipe,
    from_server: Transport.MemPipe,

    server_thread: ?std.Thread = null,
    reader_thread: ?std.Thread = null,
    server_running: std.atomic.Value(bool) = .{ .raw = false },
    server_healthy: std.atomic.Value(bool) = .{ .raw = true },
    /// Set by `stop()` before tearing down pipes; checked by `sendRaw` so an
    /// in-flight writer doesn't race the teardown.
    shutdown: std.atomic.Value(bool) = .{ .raw = false },

    /// Guards `next_request_id` and `pending_requests`. The
    /// `pending_semantic_requests` map is a separate URI-carrying map under
    /// `file_tokens_mutex`.
    request_mutex: std.Io.Mutex = .init,
    next_request_id: i64 = 1,
    /// Reader thread sets to true when the server's `initialize` response
    /// arrives; the start() path waits on this via `init_event`.
    is_initialized: std.atomic.Value(bool) = .{ .raw = false },
    /// Position encoding negotiated with the server during initialize. LSP
    /// default is utf16; we ask for utf8 first. Read-only after `start()`
    /// returns, so no synchronization needed for steady-state reads.
    position_encoding: PositionEncoding = .utf16,
    /// Event fired when the initialize response arrives OR when the reader
    /// thread exits (so start() can bail without deadlocking). Reset before
    /// each new start() call. The caller distinguishes init-ok vs init-failed
    /// via `is_initialized` after the wait returns.
    init_event: std.Io.Event = .unset,

    /// Optional pointer to an external "abort all" flag set by the manager
    /// during shutdown. When non-null and set, `start()`'s init wait bails
    /// immediately with `error.LSPInitAborted` instead of waiting out the
    /// full init timeout — that's the difference between a 100 ms quit and
    /// a 30 s quit when the user closes the editor mid-init.
    external_shutdown: ?*std.atomic.Value(bool) = null,

    /// LSP requests currently in flight, keyed by the JSON-RPC id, with the
    /// kind of request (initialize / hover / definition / ...). On response,
    /// the reader thread looks up the id, pops the entry, and dispatches.
    pending_requests: std.AutoHashMapUnmanaged(i64, RequestKind) = .empty,
    /// Semantic-tokens requests are still tracked in their own map because
    /// each one needs to carry the URI through to the response (a single
    /// kind enum isn't enough). Guarded by `file_tokens_mutex` to share the
    /// lock with the result write.
    pending_semantic_requests: std.AutoHashMapUnmanaged(i64, []u8) = .empty,

    hover_result: ?[]u8 = null,
    hover_mutex: std.Io.Mutex = .init,

    format_result: ?[]const TextEdit = null,
    format_mutex: std.Io.Mutex = .init,

    definition_result: ?Location = null,
    definition_mutex: std.Io.Mutex = .init,

    references_result: ?[]Location = null,
    references_mutex: std.Io.Mutex = .init,

    completion_result: ?[]CompletionItem = null,
    completion_mutex: std.Io.Mutex = .init,

    document_symbols_result: ?[]DocumentSymbol = null,
    document_symbols_mutex: std.Io.Mutex = .init,

    workspace_symbols_result: ?[]WorkspaceSymbol = null,
    workspace_symbols_mutex: std.Io.Mutex = .init,

    /// `textDocument/codeAction` last-response slot. The set of
    /// returned actions is small (typically 1–10) and short-lived
    /// (one user request → one apply or dismiss), so a single-slot
    /// last-response model is fine.
    code_action_result: ?[]CodeAction = null,
    code_action_mutex: std.Io.Mutex = .init,

    /// `textDocument/signatureHelp` last-response slot. Polled by
    /// Insert-mode tick after a `(` / `,` triggers a request.
    signature_help_result: ?SignatureHelp = null,
    signature_help_mutex: std.Io.Mutex = .init,

    /// `textDocument/inlayHint` results, keyed by URI. Unlike the
    /// other request kinds the response is per-file and cached for
    /// the lifetime of the visible window — the renderer reads from
    /// this map every frame the LSP hint flag is on. Caller cancels
    /// by sending a new request for the same URI (replaces the
    /// previous list).
    inlay_hints: std.StringHashMapUnmanaged([]InlayHint) = .empty,
    inlay_hints_mutex: std.Io.Mutex = .init,
    /// Tracks which URI a pending inlay-hint request was for so the
    /// response handler knows which slot to fill. Mirrors
    /// `pending_semantic_requests`.
    pending_inlay_requests: std.AutoHashMapUnmanaged(i64, []u8) = .empty,

    file_tokens: std.StringHashMapUnmanaged(FileTokens) = .empty,
    file_tokens_mutex: std.Io.Mutex = .init,

    /// Diagnostics for every file the server has reported on, keyed by URI.
    /// Each `publishDiagnostics` for a URI replaces that URI's list (a server
    /// can clear by sending an empty list). Owned slices, freed in deinit
    /// and in the publish handler.
    diagnostics: std.StringHashMapUnmanaged([]Diagnostic) = .empty,
    diagnostics_mutex: std.Io.Mutex = .init,

    last_request_times: std.StringHashMapUnmanaged(i64) = .empty,

    last_response_time: std.atomic.Value(i64) = .{ .raw = 0 },
    pending_request_count: std.atomic.Value(u32) = .{ .raw = 0 },

    on_tokens_ready: ?*const fn () void = null,
    on_diagnostics: ?*const fn (uri: []const u8, diagnostics: []const Diagnostic) void = null,

    pub const FileTokens = struct {
        tokens: std.ArrayListUnmanaged(protocol.SyntaxToken),
        last_updated: i64,

        pub fn deinit(self: *FileTokens, allocator: std.mem.Allocator) void {
            self.tokens.deinit(allocator);
        }
    };

    pub const TextEdit = struct {
        start_line: u32,
        start_col: u32,
        end_line: u32,
        end_col: u32,
        new_text: []const u8,
    };

    pub const Location = struct {
        file_path: []const u8,
        line: u32,
        col: u32,
    };

    pub const Diagnostic = struct {
        start_line: u32,
        start_col: u32,
        end_line: u32,
        end_col: u32,
        severity: Severity,
        message: []const u8,

        pub const Severity = enum { err, warning, info, hint };
    };

    pub const CompletionItem = struct {
        label: []const u8,
        kind: Kind,
        detail: ?[]const u8,

        pub const Kind = enum {
            text,
            method,
            function,
            constructor,
            field,
            variable,
            class,
            interface,
            module,
            property,
            unit,
            value,
            enumMember,
            keyword,
            snippet,
            color,
            file,
            reference,
            folder,
            enumValue,
            constant,
            struct_type,
            event,
            operator,
            type_parameter,
        };
    };

    pub const WorkspaceSymbol = struct {
        /// Symbol name. Owned.
        name: []const u8,
        kind: DocumentSymbol.SymbolKind,
        /// Absolute file path. Owned.
        file_path: []const u8,
        line: u32,
        col: u32,
        /// Optional container — class / module. Owned.
        container_name: ?[]const u8 = null,
    };

    pub const DocumentSymbol = struct {
        name: []const u8,
        kind: SymbolKind,
        line: u32,
        col: u32,
        end_line: u32,
        end_col: u32,
        container_name: ?[]const u8,

        pub const SymbolKind = enum(u8) {
            file = 1,
            module = 2,
            namespace = 3,
            package = 4,
            class = 5,
            method = 6,
            property = 7,
            field = 8,
            constructor = 9,
            enumType = 10,
            interface = 11,
            function = 12,
            variable = 13,
            constant = 14,
            string = 15,
            number = 16,
            boolean = 17,
            array = 18,
            object = 19,
            key = 20,
            null_type = 21,
            enumMember = 22,
            struct_type = 23,
            event = 24,
            operator = 25,
            type_parameter = 26,
        };
    };

    /// `textDocument/codeAction` result. We store a minimal subset:
    /// the human-readable title (shown in the picker) and the raw
    /// JSON of the `edit` and `command` fields so apply-time logic
    /// can re-parse without forcing every server's CodeAction shape
    /// through a single typed schema. Memory: every field is owned
    /// and freed in `freeCodeActions`.
    pub const CodeAction = struct {
        title: []const u8,
        /// Optional `kind` string (e.g. "quickfix", "refactor.extract").
        /// Used only for grouping/labeling; null when the action is a
        /// raw `Command` (no `kind` field).
        kind: ?[]const u8 = null,
        /// Serialized JSON of the `WorkspaceEdit` returned by the
        /// server, or null if this action is purely a `Command`.
        edit_json: ?[]const u8 = null,
        /// Serialized JSON of the `Command` field, or null if the
        /// action only carries an `edit`.
        command_json: ?[]const u8 = null,
    };

    /// `textDocument/signatureHelp` result. We collapse the LSP shape
    /// (signatures[], activeSignature, activeParameter) to a single
    /// active-signature view — most servers return one and the popup
    /// only renders the active one anyway. `parameters` is the list
    /// of param-label strings extracted from the active signature.
    pub const SignatureHelp = struct {
        /// Full signature label, e.g. "foo(x: int, y: int) -> int".
        label: []const u8,
        /// Param labels, in order. Used by the renderer to bold/underline
        /// the active one.
        parameters: [][]const u8,
        /// 0-based index of the parameter currently being typed.
        /// Out-of-range means "no parameter highlighted".
        active_parameter: u32 = 0,
    };

    /// `textDocument/inlayHint` result. We flatten the label to a
    /// single string — multi-part labels (LabelPart[]) are joined
    /// with empty separators because we don't render hover/edit
    /// targets per part.
    pub const InlayHint = struct {
        line: u32,
        col: u32,
        label: []const u8,
        /// 1 = type, 2 = parameter. `null` means the server didn't
        /// specify; renderer treats unset as "other" / default style.
        kind: ?u8 = null,
        padding_left: bool = false,
        padding_right: bool = false,
    };

    const SemanticTokenType = enum(u32) {
        namespace = 0,
        type = 1,
        class = 2,
        enumType = 3,
        interface = 4,
        structType = 5,
        typeParameter = 6,
        parameter = 7,
        variable = 8,
        property = 9,
        enumMember = 10,
        event = 11,
        function = 12,
        method = 13,
        macro = 14,
        keyword = 15,
        modifier = 16,
        comment = 17,
        string = 18,
        number = 19,
        regexp = 20,
        operator = 21,
        decorator = 22,
        builtin = 23,
        label = 24,
        keywordLiteral = 25,
        _,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, lang: []const u8) !*LSPServer {
        const self = try allocator.create(LSPServer);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .lang = try allocator.dupe(u8, lang),
            .to_server = Transport.MemPipe.init(allocator, io),
            .from_server = Transport.MemPipe.init(allocator, io),
        };
        return self;
    }

    pub fn deinit(self: *LSPServer) void {
        self.stop();

        self.allocator.free(self.lang);
        if (self.current_root_path) |p| self.allocator.free(p);
        if (self.token_cache_dir) |p| self.allocator.free(p);

        self.file_tokens_mutex.lockUncancelable(self.io);
        var it = self.file_tokens.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.file_tokens.deinit(self.allocator);
        var req_it = self.pending_semantic_requests.valueIterator();
        while (req_it.next()) |uri_ptr| {
            self.allocator.free(uri_ptr.*);
        }
        self.pending_semantic_requests.deinit(self.allocator);
        self.pending_requests.deinit(self.allocator);
        var debounce_it = self.last_request_times.keyIterator();
        while (debounce_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.last_request_times.deinit(self.allocator);
        self.file_tokens_mutex.unlock(self.io);

        self.hover_mutex.lockUncancelable(self.io);
        if (self.hover_result) |h| self.allocator.free(h);
        self.hover_mutex.unlock(self.io);

        self.format_mutex.lockUncancelable(self.io);
        if (self.format_result) |edits| {
            for (edits) |e| self.allocator.free(e.new_text);
            self.allocator.free(edits);
        }
        self.format_mutex.unlock(self.io);

        self.definition_mutex.lockUncancelable(self.io);
        if (self.definition_result) |loc| self.allocator.free(loc.file_path);
        self.definition_mutex.unlock(self.io);

        self.references_mutex.lockUncancelable(self.io);
        if (self.references_result) |refs| {
            for (refs) |r| self.allocator.free(r.file_path);
            self.allocator.free(refs);
        }
        self.references_mutex.unlock(self.io);

        self.completion_mutex.lockUncancelable(self.io);
        if (self.completion_result) |items| {
            for (items) |item| {
                self.allocator.free(item.label);
                if (item.detail) |d| self.allocator.free(d);
            }
            self.allocator.free(items);
        }
        self.completion_mutex.unlock(self.io);

        self.diagnostics_mutex.lockUncancelable(self.io);
        var diag_it = self.diagnostics.iterator();
        while (diag_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |d| self.allocator.free(d.message);
            self.allocator.free(entry.value_ptr.*);
        }
        self.diagnostics.deinit(self.allocator);
        self.diagnostics_mutex.unlock(self.io);

        self.document_symbols_mutex.lockUncancelable(self.io);
        if (self.document_symbols_result) |symbols| {
            for (symbols) |sym| {
                self.allocator.free(sym.name);
                if (sym.container_name) |c| self.allocator.free(c);
            }
            self.allocator.free(symbols);
        }
        self.document_symbols_mutex.unlock(self.io);

        self.workspace_symbols_mutex.lockUncancelable(self.io);
        if (self.workspace_symbols_result) |syms| {
            for (syms) |sym| {
                self.allocator.free(sym.name);
                self.allocator.free(sym.file_path);
                if (sym.container_name) |c| self.allocator.free(c);
            }
            self.allocator.free(syms);
        }
        self.workspace_symbols_mutex.unlock(self.io);

        self.code_action_mutex.lockUncancelable(self.io);
        if (self.code_action_result) |acts| {
            for (acts) |a| freeCodeActionInner(self.allocator, a);
            self.allocator.free(acts);
        }
        self.code_action_mutex.unlock(self.io);

        self.signature_help_mutex.lockUncancelable(self.io);
        if (self.signature_help_result) |sh| freeSignatureHelpInner(self.allocator, sh);
        self.signature_help_mutex.unlock(self.io);

        self.inlay_hints_mutex.lockUncancelable(self.io);
        var inlay_it = self.inlay_hints.iterator();
        while (inlay_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |h| self.allocator.free(h.label);
            self.allocator.free(entry.value_ptr.*);
        }
        self.inlay_hints.deinit(self.allocator);
        var inlay_pend_it = self.pending_inlay_requests.valueIterator();
        while (inlay_pend_it.next()) |uri_ptr| self.allocator.free(uri_ptr.*);
        self.pending_inlay_requests.deinit(self.allocator);
        self.inlay_hints_mutex.unlock(self.io);

        self.to_server.deinit();
        self.from_server.deinit();

        self.allocator.destroy(self);
    }

    fn freeCodeActionInner(allocator: std.mem.Allocator, a: CodeAction) void {
        allocator.free(a.title);
        if (a.kind) |k| allocator.free(k);
        if (a.edit_json) |e| allocator.free(e);
        if (a.command_json) |c| allocator.free(c);
    }

    fn freeSignatureHelpInner(allocator: std.mem.Allocator, sh: SignatureHelp) void {
        allocator.free(sh.label);
        for (sh.parameters) |p| allocator.free(p);
        allocator.free(sh.parameters);
    }

    pub fn stop(self: *LSPServer) void {
        if (!self.server_running.load(.acquire)) return;

        log.info("[LSP STOP] Stopping {s} server...", .{self.lang});

        // Tell writers to bail out before tearing down pipes.
        self.shutdown.store(true, .release);

        _ = self.sendShutdown() catch |err| {
            log.info("[LSP STOP] Shutdown request failed for {s}: {}", .{ self.lang, err });
        };
        self.sendExit() catch |err| {
            log.info("[LSP STOP] Exit notification failed for {s}: {}", .{ self.lang, err });
        };

        self.to_server.close();
        self.from_server.close();

        // Bounded joins: closing the pipes should normally make the reader
        // and server threads exit promptly, but a misbehaving external LSP
        // child can refuse to terminate even after `exit` was sent. Don't
        // let that hang the editor — give each join 2 s, then detach. The
        // detached thread will continue until the LSP process actually
        // dies (which happens at-latest when *our* process exits).
        var leaked_threads = false;
        if (self.reader_thread) |t| {
            if (!supervisor_mod.joinTimeout(self.allocator, self.io, t, 2000)) {
                log.warn("[LSP STOP] {s} reader thread did not exit in 2s; detaching", .{self.lang});
                leaked_threads = true;
            }
            self.reader_thread = null;
        }
        if (self.server_thread) |t| {
            if (!supervisor_mod.joinTimeout(self.allocator, self.io, t, 2000)) {
                log.warn("[LSP STOP] {s} server thread did not exit in 2s; detaching", .{self.lang});
                leaked_threads = true;
            }
            self.server_thread = null;
        }

        // If we detached threads, the old MemPipes are still being touched
        // by them, so we cannot deinit-and-reuse. Allocate fresh pipes and
        // leave the old ones to be cleaned up by the OS at process exit.
        if (!leaked_threads) {
            self.to_server.deinit();
            self.from_server.deinit();
        }
        self.to_server = Transport.MemPipe.init(self.allocator, self.io);
        self.from_server = Transport.MemPipe.init(self.allocator, self.io);

        self.server_running.store(false, .release);
        self.is_initialized.store(false, .release);
        // Allow a future start() to use sendRaw again.
        self.shutdown.store(false, .release);
        log.info("[LSP STOP] {s} server stopped successfully", .{self.lang});
    }

    pub fn start(self: *LSPServer, comptime run_fn: anytype, extra_args: anytype) !void {
        if (self.server_running.load(.acquire)) {
            log.info("[LSP START] {s} server already running, skipping start", .{self.lang});
            return;
        }

        log.info("[LSP START] Starting {s} server...", .{self.lang});
        self.server_running.store(true, .release);

        // Read the workspace root set by LSPManager before this call.
        const root_path = self.current_root_path;
        if (root_path) |p| log.info("[LSP START] {s} root path: {s}", .{ self.lang, p });

        self.server_healthy.store(true, .release);
        self.is_initialized.store(false, .release);
        std.Io.Event.reset(&self.init_event);

        // If this start() returns an error, leave the LSPServer in a quiesced
        // state: threads joined (or detached), pipes drained, flags cleared.
        // Otherwise a half-started server confuses the supervisor.
        errdefer self.quiesceAfterFailedStart();

        self.server_thread = std.Thread.spawn(.{}, run_fn, .{
            self.allocator,
            &self.to_server,
            &self.from_server,
        } ++ extra_args) catch |err| {
            log.err("[LSP ERROR] Failed to spawn {s} server thread: {}", .{ self.lang, err });
            return err;
        };

        self.reader_thread = std.Thread.spawn(.{}, readResponses, .{self}) catch |err| {
            log.err("[LSP ERROR] Failed to spawn {s} reader thread: {}", .{ self.lang, err });
            return err;
        };

        const root_uri = if (root_path) |p| blk: {
            break :blk pathToUri(self.allocator, self.io, p) catch null;
        } else null;
        defer if (root_uri) |u| self.allocator.free(u);

        // Reserve and register the init id *before* sending, so a fast
        // response can't arrive before the reader knows what id to expect.
        const init_id = self.nextRequestId();
        try self.setPending(.initialize, init_id);
        self.sendInitializeWithId(init_id, root_uri) catch |err| {
            log.err("[LSP ERROR] Failed to send initialize request for {s}: {}", .{ self.lang, err });
            _ = self.takePending(init_id);
            return err;
        };
        log.info("[LSP START] Sent initialize request for {s}, waiting for response...", .{self.lang});

        // Bounded wait for initialize, in short ticks so we can also notice
        // an external "the editor is shutting down" signal and bail without
        // sitting out the full init timeout. The init_event also gets set
        // by the reader thread's defer when it dies, so a crashed server
        // wakes us promptly too.
        const init_deadline_ms = std.Io.Clock.real.now(self.io).toMilliseconds() + init_timeout_seconds * 1000;
        // The reader thread fires `init_event` the moment the
        // initialize response arrives, so the common case wakes us
        // immediately. The tick is a safety net for missed events or
        // a crashed reader — keep it short so the worst-case latency
        // between server-ready and us-noticing stays in the tens of
        // milliseconds, not a tenth of a second.
        const tick_ms: i64 = 25;
        while (!self.is_initialized.load(.acquire)) {
            if (self.external_shutdown) |flag| {
                if (flag.load(.acquire)) {
                    log.info("[LSP START] {s} init wait aborted by external shutdown", .{self.lang});
                    return error.LSPInitAborted;
                }
            }
            if (!self.server_healthy.load(.acquire)) {
                log.err("[LSP START] {s} server died before initialize completed", .{self.lang});
                return error.LSPInitFailed;
            }
            const now = std.Io.Clock.real.now(self.io).toMilliseconds();
            if (now >= init_deadline_ms) {
                log.err("[LSP START] {s} server did not initialize within {d}s — aborting", .{ self.lang, init_timeout_seconds });
                return error.LSPInitTimeout;
            }
            const remaining = init_deadline_ms - now;
            const this_tick = @min(remaining, tick_ms);
            const tick_timeout = std.Io.Timeout{ .duration = .{
                .raw = .fromMilliseconds(this_tick),
                .clock = .boot,
            } };
            std.Io.Event.waitTimeout(&self.init_event, self.io, tick_timeout) catch |err| switch (err) {
                error.Timeout => continue, // poll the flags again
                else => return err,
            };
            // init_event fired — loop body re-checks is_initialized.
        }
        log.info("[LSP START] {s} server initialized successfully. Sending initialized notification.", .{self.lang});

        try self.sendInitialized();
        log.info("[LSP START] {s} server is now fully operational", .{self.lang});
    }

    /// How long start() will wait for the server's initialize response. Capped
    /// to bound worst-case freezes; the user can still pre-spawn or restart
    /// once it returns.
    const init_timeout_seconds: i64 = 30;

    /// If start() returned an error, this returns the server to a state where
    /// `server_running == false`, `is_initialized == false`, and any threads
    /// we spawned have been wound down. Idempotent.
    fn quiesceAfterFailedStart(self: *LSPServer) void {
        self.shutdown.store(true, .release);
        self.to_server.close();
        self.from_server.close();
        var leaked_threads = false;
        if (self.reader_thread) |t| {
            if (!supervisor_mod.joinTimeout(self.allocator, self.io, t, 2000)) leaked_threads = true;
            self.reader_thread = null;
        }
        if (self.server_thread) |t| {
            if (!supervisor_mod.joinTimeout(self.allocator, self.io, t, 2000)) leaked_threads = true;
            self.server_thread = null;
        }
        if (!leaked_threads) {
            self.to_server.deinit();
            self.from_server.deinit();
        }
        self.to_server = Transport.MemPipe.init(self.allocator, self.io);
        self.from_server = Transport.MemPipe.init(self.allocator, self.io);
        self.server_running.store(false, .release);
        self.is_initialized.store(false, .release);
        self.shutdown.store(false, .release);
    }

    fn readResponses(self: *LSPServer) void {
        @import("../thread_name.zig").set("stem-lsp-read");
        log.info("[LSP READER] {s} response reader thread started", .{self.lang});
        defer {
            self.server_healthy.store(false, .release);
            // Wake any thread blocked in start() waiting for initialize. The
            // waiter then sees is_initialized==false and bails.
            std.Io.Event.set(&self.init_event, self.io);
            log.info("[LSP READER] {s} response reader thread exiting (server unhealthy)", .{self.lang});
        }

        var read_buffer: [4096]u8 = undefined;
        var header_buf: [256]u8 = undefined;
        var content_buf = std.ArrayListUnmanaged(u8).empty;
        defer content_buf.deinit(self.allocator);

        while (true) {
            var header_len: usize = 0;
            var header_overflow = false;
            while (true) {
                const n = self.from_server.read(read_buffer[0..1]) catch return;
                if (n == 0) return;

                if (header_len >= header_buf.len) {
                    // Header too long for our buffer — drop the connection
                    // rather than silently desyncing the framing parser.
                    log.err("[LSP] {s} header overflow ({d} bytes without CRLF CRLF); aborting reader", .{ self.lang, header_len });
                    header_overflow = true;
                    break;
                }
                header_buf[header_len] = read_buffer[0];
                header_len += 1;

                if (header_len >= 4 and
                    header_buf[header_len - 4] == '\r' and
                    header_buf[header_len - 3] == '\n' and
                    header_buf[header_len - 2] == '\r' and
                    header_buf[header_len - 1] == '\n')
                {
                    break;
                }
            }
            if (header_overflow) return;

            const header_str = header_buf[0..header_len];
            var content_length: usize = 0;
            var saw_content_length = false;
            var lines = std.mem.splitSequence(u8, header_str, "\r\n");
            while (lines.next()) |line| {
                if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                    const value_start = (std.mem.indexOf(u8, line, ":") orelse continue) + 1;
                    const value = std.mem.trim(u8, line[value_start..], " ");
                    content_length = std.fmt.parseInt(usize, value, 10) catch {
                        log.err("[LSP] {s} unparseable Content-Length: {s}; aborting reader", .{ self.lang, value });
                        return;
                    };
                    saw_content_length = true;
                }
            }

            if (!saw_content_length) {
                log.err("[LSP] {s} message header had no Content-Length; aborting reader", .{self.lang});
                return;
            }
            if (content_length == 0) {
                // No body to read for this message — just continue.
                continue;
            }

            content_buf.clearRetainingCapacity();
            content_buf.ensureTotalCapacity(self.allocator, content_length) catch {
                // We can't allocate; drain the body so the next header is aligned.
                var drained: usize = 0;
                while (drained < content_length) {
                    const to_read = @min(read_buffer.len, content_length - drained);
                    const n = self.from_server.read(read_buffer[0..to_read]) catch return;
                    if (n == 0) return;
                    drained += n;
                }
                continue;
            };

            var read_total: usize = 0;
            while (read_total < content_length) {
                const to_read = @min(read_buffer.len, content_length - read_total);
                const n = self.from_server.read(read_buffer[0..to_read]) catch return;
                if (n == 0) return;
                content_buf.appendSlice(self.allocator, read_buffer[0..n]) catch return;
                read_total += n;
            }

            if (content_buf.items.len == content_length) {
                self.handleServerMessage(content_buf.items) catch |err| {
                    log.warn("[LSP] {s} failed to handle server message: {}", .{ self.lang, err });
                };
            }
        }
    }

    fn handleServerMessage(self: *LSPServer, json: []const u8) !void {
        log.info("RX: {s}", .{json});
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json, .{}) catch |err| {
            log.err("[LSP ERROR] {s} failed to parse JSON response: {}", .{ self.lang, err });
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            log.err("[LSP ERROR] {s} received non-object JSON response", .{self.lang});
            return;
        }

        if (root.object.get("error")) |err_val| {
            if (err_val == .object) {
                const code = if (err_val.object.get("code")) |c| (if (c == .integer) c.integer else 0) else 0;
                const message = if (err_val.object.get("message")) |m| (if (m == .string) m.string else "unknown error") else "unknown error";
                log.err("[LSP ERROR] {s} server returned error: code={d}, message={s}", .{ self.lang, code, message });
            }
        }

        if (root.object.get("id")) |id_val| {
            if (id_val == .integer) {
                const id = id_val.integer;

                // First check the semantic-tokens map (URI-carrying, separate
                // lock). Semantic tokens flow through their own bookkeeping
                // because each response needs the URI it was originally for.
                //
                // CRITICAL: remove + own the URI inside the same lock window
                // we used to look it up. Previously we did `.get(id)`, unlocked,
                // and then used the borrowed slice — but the core thread's
                // `requestSemanticTokens` stale-cleanup can fire between unlock
                // and use, fetchRemove the same id, and free the bytes we're
                // about to read. The user-visible symptom was a segfault when
                // toggling between 10+ open files (which is exactly when the
                // map's count > 10 stale-cleanup branch trips).
                self.file_tokens_mutex.lockUncancelable(self.io);
                const owned_uri: ?[]u8 = if (self.pending_semantic_requests.fetchRemove(id)) |kv| kv.value else null;
                self.file_tokens_mutex.unlock(self.io);

                if (owned_uri) |uri| {
                    defer self.allocator.free(uri);
                    self.last_response_time.store(std.Io.Clock.real.now(self.io).toMilliseconds(), .release);
                    _ = self.pending_request_count.fetchSub(1, .monotonic);

                    if (root.object.get("result")) |res| {
                        self.handleSemanticTokensResult(res, uri) catch |err| {
                            log.warn("[LSP] {s} failed to handle semantic tokens result: {}", .{ self.lang, err });
                        };
                    }
                    return;
                }

                // Look up and remove this id from the unified pending map.
                const kind = self.takePending(id) orelse return;
                log.info("RX response id={d} kind={s}", .{ id, @tagName(kind) });
                const result = root.object.get("result");

                switch (kind) {
                    .initialize => {
                        // Pull the negotiated position encoding from
                        // serverCapabilities. LSP spec default is utf16
                        // when omitted; we always advertise utf-8 first.
                        if (result) |r| {
                            if (r == .object) {
                                if (r.object.get("capabilities")) |caps| {
                                    if (caps == .object) {
                                        if (caps.object.get("positionEncoding")) |pe| {
                                            if (pe == .string) {
                                                if (std.mem.eql(u8, pe.string, "utf-8")) {
                                                    self.position_encoding = .utf8;
                                                } else if (std.mem.eql(u8, pe.string, "utf-16")) {
                                                    self.position_encoding = .utf16;
                                                } else if (std.mem.eql(u8, pe.string, "utf-32")) {
                                                    // Not supported; warn and fall back.
                                                    log.warn("[LSP] {s} negotiated utf-32 (unsupported), treating as utf-16", .{self.lang});
                                                    self.position_encoding = .utf16;
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        log.info("[LSP] {s} negotiated positionEncoding={s}", .{ self.lang, @tagName(self.position_encoding) });
                        self.is_initialized.store(true, .release);
                        std.Io.Event.set(&self.init_event, self.io);
                    },
                    .hover => if (result) |r| {
                        self.handleHoverResult(r) catch |err| log.warn("[LSP] hover handler: {}", .{err});
                    },
                    .format => if (result) |r| {
                        self.handleFormatResult(r) catch |err| log.warn("[LSP] format handler: {}", .{err});
                    },
                    .definition => if (result) |r| {
                        self.handleDefinitionResult(r) catch |err| log.warn("[LSP] definition handler: {}", .{err});
                    },
                    .references => if (result) |r| {
                        self.handleReferencesResult(r) catch |err| log.warn("[LSP] references handler: {}", .{err});
                    },
                    .completion => if (result) |r| {
                        self.handleCompletionResult(r) catch |err| log.warn("[LSP] completion handler: {}", .{err});
                    },
                    .document_symbols => if (result) |r| {
                        self.handleDocumentSymbolsResult(r) catch |err| log.warn("[LSP] document symbols handler: {}", .{err});
                    },
                    .workspace_symbols => if (result) |r| {
                        self.handleWorkspaceSymbolsResult(r) catch |err| log.warn("[LSP] workspace symbols handler: {}", .{err});
                    },
                    .code_action => if (result) |r| {
                        self.handleCodeActionResult(r) catch |err| log.warn("[LSP] code action handler: {}", .{err});
                    },
                    .signature_help => if (result) |r| {
                        self.handleSignatureHelpResult(r) catch |err| log.warn("[LSP] signature help handler: {}", .{err});
                    },
                    .inlay_hint => {
                        const uri_owned = blk: {
                            self.inlay_hints_mutex.lockUncancelable(self.io);
                            defer self.inlay_hints_mutex.unlock(self.io);
                            if (self.pending_inlay_requests.fetchRemove(id)) |kv| {
                                break :blk kv.value;
                            }
                            break :blk null;
                        };
                        if (uri_owned) |uri| {
                            defer self.allocator.free(uri);
                            if (result) |r| {
                                self.handleInlayHintResult(r, uri) catch |err| log.warn("[LSP] inlay hint handler: {}", .{err});
                            }
                        }
                    },
                }
                return;
            }
        }

        if (root.object.get("method")) |method_val| {
            if (method_val == .string) {
                const method = method_val.string;
                if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
                    self.handleDiagnostics(root) catch |err| {
                        log.warn("[LSP] {s} failed to handle diagnostics: {}", .{ self.lang, err });
                    };
                }
            }
        }
    }

    fn sendRaw(self: *LSPServer, json: []const u8) !void {
        if (self.shutdown.load(.acquire)) return error.LSPShuttingDown;
        log.info("TX: {s}", .{json});
        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{json.len}) catch unreachable;
        _ = try self.to_server.write(header);
        _ = try self.to_server.write(json);
    }

    fn nextRequestId(self: *LSPServer) i64 {
        self.request_mutex.lockUncancelable(self.io);
        defer self.request_mutex.unlock(self.io);
        const id = self.next_request_id;
        self.next_request_id += 1;
        return id;
    }

    fn sendRequest(self: *LSPServer, method: []const u8, params_json: ?[]const u8) !i64 {
        const id = self.nextRequestId();
        try self.sendRequestWithId(id, method, params_json);
        return id;
    }

    fn sendRequestWithId(self: *LSPServer, id: i64, method: []const u8, params_json: ?[]const u8) !void {
        var message: std.Io.Writer.Allocating = .init(self.allocator);
        defer message.deinit();
        const writer = &message.writer;
        try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\"", .{ id, method });
        if (params_json) |p| {
            try writer.writeAll(",\"params\":");
            try writer.writeAll(p);
        }
        try writer.writeAll("}");
        try self.sendRaw(message.written());
    }

    fn sendNotification(self: *LSPServer, method: []const u8, params_json: ?[]const u8) !void {
        var message: std.Io.Writer.Allocating = .init(self.allocator);
        defer message.deinit();
        const writer = &message.writer;
        try writer.print("{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\"", .{method});
        if (params_json) |p| {
            try writer.writeAll(",\"params\":");
            try writer.writeAll(p);
        }
        try writer.writeAll("}");
        try self.sendRaw(message.written());
    }

    fn sendInitialize(self: *LSPServer, root_uri: ?[]const u8) !i64 {
        const id = self.nextRequestId();
        try self.sendInitializeWithId(id, root_uri);
        return id;
    }

    fn sendInitializeWithId(self: *LSPServer, id: i64, root_uri: ?[]const u8) !void {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const writer = &params.writer;

        try writer.writeAll("{\"processId\":");
        try writer.print("{d}", .{platform.getProcessId()});

        if (root_uri) |uri| {
            try writer.writeAll(",\"rootUri\":\"");
            try writer.writeAll(uri);
            try writer.writeAll("\"");

            try writer.writeAll(",\"workspaceFolders\":[{\"uri\":\"");
            try writer.writeAll(uri);
            try writer.writeAll("\",\"name\":\"project\"}]");
        } else {
            try writer.writeAll(",\"rootUri\":null,\"workspaceFolders\":null");
        }

        if (std.mem.eql(u8, self.lang, "zig")) {
            try writer.writeAll(",\"initializationOptions\":{");
            try writer.writeAll("\"enable_build_runner\":false,");
            try writer.writeAll("\"warn_style\":true,");
            try writer.writeAll("\"highlight_global_var_declarations\":true");
            try writer.writeAll("}");
        } else if (std.mem.eql(u8, self.lang, "rust")) {}

        try writer.writeAll(",\"capabilities\":{");
        // Ask servers to use UTF-8 byte offsets instead of the LSP default of
        // UTF-16 code units, so the line/character values we send are byte
        // offsets into the file (which is what we have internally). Servers
        // that don't support utf-8 should fall back to utf-16 — that's still
        // a known mismatch but matches today's behavior.
        try writer.writeAll("\"general\":{\"positionEncodings\":[\"utf-8\",\"utf-16\"]},");
        try writer.writeAll("\"textDocument\":{");
        try writer.writeAll("\"synchronization\":{\"didSave\":true},");
        try writer.writeAll("\"completion\":{\"completionItem\":{\"\":[\"documentation\",\"detail\",\"additionalTextEdits\"]}},");
        try writer.writeAll("\"hover\":{\"contentFormat\":[\"markdown\",\"plaintext\"]},");
        try writer.writeAll("\"publishDiagnostics\":{},");
        try writer.writeAll("\"semanticTokens\":{");
        try writer.writeAll("\"dynamicRegistration\":false,");
        try writer.writeAll("\"requests\":{\"range\":true,\"full\":true},");
        try writer.writeAll("\"tokenTypes\":[");
        try writer.writeAll("\"namespace\",\"type\",\"class\",\"enum\",\"interface\",\"struct\",\"typeParameter\",\"parameter\",\"variable\",\"property\",\"enumMember\",\"event\",\"function\",\"method\",\"macro\",\"keyword\",\"modifier\",\"comment\",\"string\",\"number\",\"regexp\",\"operator\",\"decorator\",\"builtin\",\"label\",\"keywordLiteral\"");
        try writer.writeAll("],\"tokenModifiers\":[],\"formats\":[\"relative\"]}");
        try writer.writeAll("},");
        // Declare that we can dynamically grow the workspace via
        // `workspace/didChangeWorkspaceFolders` so the server keeps a single
        // process across multiple project roots instead of forcing us to
        // restart on every root change.
        try writer.writeAll("\"workspace\":{\"workspaceFolders\":true,\"configuration\":false}");
        try writer.writeAll("}}");

        try self.sendRequestWithId(id, "initialize", params.written());
    }

    fn sendInitialized(self: *LSPServer) !void {
        try self.sendNotification("initialized", "{}");
    }

    pub fn sendDidOpen(self: *LSPServer, uri: []const u8, language_id: []const u8, version: i64, text: []const u8) !void {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const writer = &params.writer;
        try writer.writeAll("{\"textDocument\":{\"uri\":\"");
        try writer.writeAll(uri);
        try writer.writeAll("\",\"languageId\":\"");
        try writer.writeAll(language_id);
        try writer.print("\",\"version\":{d},\"text\":\"", .{version});
        try writeJsonEscapedString(writer, text);
        try writer.writeAll("\"}}");
        try self.sendNotification("textDocument/didOpen", params.written());
    }

    pub fn sendDidChange(self: *LSPServer, uri: []const u8, version: i64, text: []const u8) !void {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const writer = &params.writer;
        try writer.writeAll("{\"textDocument\":{\"uri\":\"");
        try writer.writeAll(uri);
        try writer.print("\",\"version\":{d}", .{version});
        try writer.writeAll("},\"contentChanges\":[{\"text\":\"");
        try writeJsonEscapedString(writer, text);
        try writer.writeAll("\"}]}");
        try self.sendNotification("textDocument/didChange", params.written());
    }

    pub fn sendDidSave(self: *LSPServer, uri: []const u8) !void {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const writer = &params.writer;
        try writer.writeAll("{\"textDocument\":{\"uri\":\"");
        try writer.writeAll(uri);
        try writer.writeAll("\"}}");
        try self.sendNotification("textDocument/didSave", params.written());
    }

    pub fn sendDidClose(self: *LSPServer, uri: []const u8) !void {
        self.file_tokens_mutex.lockUncancelable(self.io);
        if (self.file_tokens.fetchRemove(uri)) |kv| {
            self.allocator.free(kv.key);
            var entry = kv.value;
            entry.deinit(self.allocator);
        }
        // Also drop the debounce entry — otherwise `last_request_times`
        // grows unboundedly over a session as files are opened and closed.
        if (self.last_request_times.fetchRemove(uri)) |kv| {
            self.allocator.free(kv.key);
        }
        self.file_tokens_mutex.unlock(self.io);

        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const writer = &params.writer;
        try writer.writeAll("{\"textDocument\":{\"uri\":\"");
        try writer.writeAll(uri);
        try writer.writeAll("\"}}");
        try self.sendNotification("textDocument/didClose", params.written());
    }

    /// Send `workspace/didChangeWorkspaceFolders` to update the server's set
    /// of known roots. Both `added` and `removed` are local filesystem paths
    /// (not URIs); we convert here.
    pub fn sendDidChangeWorkspaceFolders(self: *LSPServer, added: []const u8, removed: []const []const u8) !void {
        if (!self.is_initialized.load(.acquire)) return error.LSPNotInitialized;

        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const writer = &params.writer;

        const added_uri = try pathToUri(self.allocator, self.io, added);
        defer self.allocator.free(added_uri);

        try writer.writeAll("{\"event\":{\"added\":[{\"uri\":\"");
        try writer.writeAll(added_uri);
        try writer.writeAll("\",\"name\":\"");
        const basename = std.fs.path.basename(added);
        try writeJsonEscapedString(writer, basename);
        try writer.writeAll("\"}],\"removed\":[");
        var first = true;
        for (removed) |r| {
            if (!first) try writer.writeAll(",");
            first = false;
            const ru = try pathToUri(self.allocator, self.io, r);
            defer self.allocator.free(ru);
            try writer.writeAll("{\"uri\":\"");
            try writer.writeAll(ru);
            try writer.writeAll("\",\"name\":\"");
            try writeJsonEscapedString(writer, std.fs.path.basename(r));
            try writer.writeAll("\"}");
        }
        try writer.writeAll("]}}");
        try self.sendNotification("workspace/didChangeWorkspaceFolders", params.written());
    }

    fn sendShutdown(self: *LSPServer) !i64 {
        return try self.sendRequest("shutdown", null);
    }

    fn sendExit(self: *LSPServer) !void {
        try self.sendNotification("exit", null);
    }

    pub fn requestSemanticTokens(self: *LSPServer, uri: []const u8) !void {
        const now = std.Io.Clock.real.now(self.io).toMilliseconds();
        const debounce_ms: i64 = 100;

        self.file_tokens_mutex.lockUncancelable(self.io);

        if (self.last_request_times.get(uri)) |last_time| {
            if (now - last_time < debounce_ms) {
                self.file_tokens_mutex.unlock(self.io);
                log.info("[LSP DEBOUNCE] Skipping semantic token request for {s} (too soon)", .{uri});
                return;
            }
        }

        // Bound the pending-request map. We don't have wall-clock
        // timestamps per request, so use the request id ordering as
        // a proxy for "oldest" — when the map grows past the cap,
        // collect the lowest ids and evict them. Capped at 32 in
        // flight (one cycle of rapid buffer switching never exceeds
        // this in practice; an old hard limit of 10 was tripping
        // every time on workspaces with more than a handful of files).
        const max_in_flight: usize = 32;
        if (self.pending_semantic_requests.count() > max_in_flight) {
            var stale_ids = std.ArrayListUnmanaged(i64).empty;
            defer stale_ids.deinit(self.allocator);
            var req_it = self.pending_semantic_requests.iterator();
            while (req_it.next()) |entry| {
                stale_ids.append(self.allocator, entry.key_ptr.*) catch {};
            }
            // Sort ascending and drop the oldest until we're back under cap.
            std.mem.sort(i64, stale_ids.items, {}, std.sort.asc(i64));
            const to_drop = stale_ids.items.len -| max_in_flight;
            for (stale_ids.items[0..to_drop]) |stale_id| {
                if (self.pending_semantic_requests.fetchRemove(stale_id)) |kv| {
                    self.allocator.free(kv.value);
                    log.info("[LSP CLEANUP] Removed stale pending request id={d}", .{stale_id});
                }
            }
        }

        // Dupe-before-put: keeps `last_request_times` from ever
        // holding the caller's borrowed slice as a key (which would
        // dangle as soon as the caller's stack frame unwinds).
        const lrt_key = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(lrt_key);
        const gop = try self.last_request_times.getOrPut(self.allocator, lrt_key);
        if (gop.found_existing) {
            self.allocator.free(lrt_key);
        }
        gop.value_ptr.* = now;

        // Build params and reserve the id while still holding the lock, then
        // register the pending entry BEFORE we send. Otherwise a fast response
        // could arrive between send and put and be silently dropped.
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const w = &params.writer;
        try w.writeAll("{\"textDocument\":{\"uri\":\"");
        try w.writeAll(uri);
        try w.writeAll("\"}}");

        const id = self.nextRequestId();
        // Dupe under an errdefer that fires until the put() takes ownership.
        const uri_copy = try self.allocator.dupe(u8, uri);
        var uri_owned = false;
        errdefer if (!uri_owned) self.allocator.free(uri_copy);

        try self.pending_semantic_requests.put(self.allocator, id, uri_copy);
        uri_owned = true; // map now owns the slice.

        self.file_tokens_mutex.unlock(self.io);

        _ = self.pending_request_count.fetchAdd(1, .monotonic);
        self.sendRequestWithId(id, "textDocument/semanticTokens/full", params.written()) catch |err| {
            // Roll back the pending entry on send failure. The fetchRemove
            // returns the duped slice — free it here, *then* return.
            // We do NOT re-trigger the errdefer because uri_owned is true.
            self.file_tokens_mutex.lockUncancelable(self.io);
            if (self.pending_semantic_requests.fetchRemove(id)) |kv| {
                self.allocator.free(kv.value);
            }
            self.file_tokens_mutex.unlock(self.io);
            return err;
        };
    }

    /// Set a pending_* request id under the request mutex. The id is registered
    /// Register a pending request id under the request mutex. The id is
    /// registered before `sendRequest` returns so the reader thread can route
    /// the response even if it arrives between send and assignment.
    fn setPending(self: *LSPServer, kind: RequestKind, id: i64) !void {
        self.request_mutex.lockUncancelable(self.io);
        defer self.request_mutex.unlock(self.io);
        try self.pending_requests.put(self.allocator, id, kind);
    }

    /// Look up and pop a pending request id, returning the kind if it was
    /// registered. Reader thread uses this to dispatch a response.
    fn takePending(self: *LSPServer, id: i64) ?RequestKind {
        self.request_mutex.lockUncancelable(self.io);
        defer self.request_mutex.unlock(self.io);
        if (self.pending_requests.fetchRemove(id)) |kv| return kv.value;
        return null;
    }

    pub fn requestHover(self: *LSPServer, uri: []const u8, line: u32, col: u32) !void {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const w = &params.writer;
        try w.writeAll("{\"textDocument\":{\"uri\":\"");
        try w.writeAll(uri);
        try w.writeAll("\"},\"position\":{\"line\":");
        try w.print("{d}", .{line});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{col});
        try w.writeAll("}}");
        // Reserve the id and stamp pending_* before the send so a fast response
        // doesn't race the assignment.
        const id = self.nextRequestId();
        try self.setPending(.hover, id);
        try self.sendRequestWithId(id, "textDocument/hover", params.written());
    }

    pub fn requestFormatting(self: *LSPServer, uri: []const u8) !void {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const w = &params.writer;
        try w.writeAll("{\"textDocument\":{\"uri\":\"");
        try w.writeAll(uri);
        try w.writeAll("\"},\"options\":{\"tabSize\":4,\"insertSpaces\":true}}");
        const id = self.nextRequestId();
        try self.setPending(.format, id);
        try self.sendRequestWithId(id, "textDocument/formatting", params.written());
    }

    /// Range version of `requestFormatting` — `textDocument/rangeFormatting`.
    /// The response shape is identical (`TextEdit[]`) so it reuses the same
    /// `.format` pending kind and result slot.
    pub fn requestRangeFormatting(self: *LSPServer, uri: []const u8, start_line: u32, start_col: u32, end_line: u32, end_col: u32) !void {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const w = &params.writer;
        try w.writeAll("{\"textDocument\":{\"uri\":\"");
        try w.writeAll(uri);
        try w.writeAll("\"},\"range\":{\"start\":{\"line\":");
        try w.print("{d}", .{start_line});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{start_col});
        try w.writeAll("},\"end\":{\"line\":");
        try w.print("{d}", .{end_line});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{end_col});
        try w.writeAll("}},\"options\":{\"tabSize\":4,\"insertSpaces\":true}}");
        const id = self.nextRequestId();
        try self.setPending(.format, id);
        try self.sendRequestWithId(id, "textDocument/rangeFormatting", params.written());
    }

    pub fn requestDefinition(self: *LSPServer, uri: []const u8, line: u32, col: u32) !void {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const w = &params.writer;
        try w.writeAll("{\"textDocument\":{\"uri\":\"");
        try w.writeAll(uri);
        try w.writeAll("\"},\"position\":{\"line\":");
        try w.print("{d}", .{line});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{col});
        try w.writeAll("}}");
        const id = self.nextRequestId();
        try self.setPending(.definition, id);
        try self.sendRequestWithId(id, "textDocument/definition", params.written());
    }

    pub fn requestReferences(self: *LSPServer, uri: []const u8, line: u32, col: u32) !void {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const w = &params.writer;
        try w.writeAll("{\"textDocument\":{\"uri\":\"");
        try w.writeAll(uri);
        try w.writeAll("\"},\"position\":{\"line\":");
        try w.print("{d}", .{line});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{col});
        try w.writeAll("},\"context\":{\"includeDeclaration\":true}}");
        const id = self.nextRequestId();
        try self.setPending(.references, id);
        try self.sendRequestWithId(id, "textDocument/references", params.written());
    }

    pub fn requestCompletion(self: *LSPServer, uri: []const u8, line: u32, col: u32) !void {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const w = &params.writer;
        try w.writeAll("{\"textDocument\":{\"uri\":\"");
        try w.writeAll(uri);
        try w.writeAll("\"},\"position\":{\"line\":");
        try w.print("{d}", .{line});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{col});
        try w.writeAll("}}");
        const id = self.nextRequestId();
        try self.setPending(.completion, id);
        try self.sendRequestWithId(id, "textDocument/completion", params.written());
    }

    pub fn requestDocumentSymbols(self: *LSPServer, uri: []const u8) !void {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const w = &params.writer;
        try w.writeAll("{\"textDocument\":{\"uri\":\"");
        try w.writeAll(uri);
        try w.writeAll("\"}}");
        const id = self.nextRequestId();
        try self.setPending(.document_symbols, id);
        try self.sendRequestWithId(id, "textDocument/documentSymbol", params.written());
    }

    /// LSP `workspace/symbol` — workspace-wide fuzzy match against the
    /// server's symbol table. `query` may be empty (servers return
    /// everything, or a server-defined subset).
    pub fn requestWorkspaceSymbol(self: *LSPServer, query: []const u8) !void {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const w = &params.writer;
        try w.writeAll("{\"query\":\"");
        try writeJsonEscapedString(w, query);
        try w.writeAll("\"}");
        const id = self.nextRequestId();
        try self.setPending(.workspace_symbols, id);
        try self.sendRequestWithId(id, "workspace/symbol", params.written());
    }

    /// `textDocument/codeAction`. We always ask for the full set
    /// (no `context.only` filter) because filtering is a server-
    /// side optimization; the picker is the final filter.
    pub fn requestCodeAction(self: *LSPServer, uri: []const u8, start_line: u32, start_col: u32, end_line: u32, end_col: u32) !void {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const w = &params.writer;
        try w.writeAll("{\"textDocument\":{\"uri\":\"");
        try w.writeAll(uri);
        try w.writeAll("\"},\"range\":{\"start\":{\"line\":");
        try w.print("{d}", .{start_line});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{start_col});
        try w.writeAll("},\"end\":{\"line\":");
        try w.print("{d}", .{end_line});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{end_col});
        try w.writeAll("}},\"context\":{\"diagnostics\":[]}}");
        const id = self.nextRequestId();
        try self.setPending(.code_action, id);
        try self.sendRequestWithId(id, "textDocument/codeAction", params.written());
    }

    pub fn requestSignatureHelp(self: *LSPServer, uri: []const u8, line: u32, col: u32) !void {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const w = &params.writer;
        try w.writeAll("{\"textDocument\":{\"uri\":\"");
        try w.writeAll(uri);
        try w.writeAll("\"},\"position\":{\"line\":");
        try w.print("{d}", .{line});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{col});
        try w.writeAll("}}");
        const id = self.nextRequestId();
        try self.setPending(.signature_help, id);
        try self.sendRequestWithId(id, "textDocument/signatureHelp", params.written());
    }

    /// `textDocument/inlayHint`. Unlike the other requests this one
    /// carries the URI through the pending map (similar to semantic
    /// tokens) so the response handler can route hints to the right
    /// file's slot.
    pub fn requestInlayHint(self: *LSPServer, uri: []const u8, start_line: u32, end_line: u32) !void {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const w = &params.writer;
        try w.writeAll("{\"textDocument\":{\"uri\":\"");
        try w.writeAll(uri);
        try w.writeAll("\"},\"range\":{\"start\":{\"line\":");
        try w.print("{d}", .{start_line});
        try w.writeAll(",\"character\":0},\"end\":{\"line\":");
        try w.print("{d}", .{end_line});
        try w.writeAll(",\"character\":0}}}");
        const id = self.nextRequestId();
        try self.setPending(.inlay_hint, id);

        const uri_dup = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(uri_dup);
        self.inlay_hints_mutex.lockUncancelable(self.io);
        try self.pending_inlay_requests.put(self.allocator, id, uri_dup);
        self.inlay_hints_mutex.unlock(self.io);

        try self.sendRequestWithId(id, "textDocument/inlayHint", params.written());
    }

    pub fn handleSemanticTokensResult(self: *LSPServer, result: std.json.Value, uri: []const u8) !void {
        if (result != .object) return;
        const obj = result.object;
        const data_val = obj.get("data") orelse return;
        if (data_val != .array) return;

        const arr = data_val.array.items;
        log.info("Received semantic tokens: {d} items for {s}", .{ arr.len, uri });

        // Dupe the URI *before* getOrPut so the map never observes
        // a borrowed slice as its key. The previous pattern (put
        // then conditionally overwrite key_ptr.* with a dupe) left
        // the map holding the caller's borrowed slice as the key if
        // the dupe failed with OOM — subsequent lookups would
        // dereference freed memory.
        const key_dup = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(key_dup);

        self.file_tokens_mutex.lockUncancelable(self.io);
        defer self.file_tokens_mutex.unlock(self.io);

        const gop = try self.file_tokens.getOrPut(self.allocator, key_dup);
        if (gop.found_existing) {
            // Map already has its own duped key for this URI.
            self.allocator.free(key_dup);
        } else {
            gop.value_ptr.* = .{
                .tokens = .empty,
                .last_updated = std.Io.Clock.real.now(self.io).toMilliseconds(),
            };
        }

        gop.value_ptr.tokens.clearRetainingCapacity();
        gop.value_ptr.last_updated = std.Io.Clock.real.now(self.io).toMilliseconds();

        var line: u32 = 0;
        var col: u32 = 0;

        var i: usize = 0;
        while (i + 4 < arr.len) : (i += 5) {
            const d_line = toU32(arr[i]) orelse break;
            const d_start = toU32(arr[i + 1]) orelse break;
            const length = toU32(arr[i + 2]) orelse break;
            const token_type_idx = toU32(arr[i + 3]) orelse break;

            // Still advance the (line, col) cursor for malformed token-type
            // indices so subsequent delta-encoded tokens align correctly.
            // Use saturating add so adversarial deltas can't overflow into
            // a panic — at worst we render a token at the end of u32 space,
            // which clips harmlessly.
            if (d_line == 0) {
                col +|= d_start;
            } else {
                line +|= d_line;
                col = d_start;
            }

            // Drop tokens with an out-of-range token-type index instead of
            // silently relabeling them as namespace.
            if (token_type_idx >= @typeInfo(SemanticTokenType).@"enum".fields.len) continue;
            const tok_type = mapTokenType(token_type_idx);

            // best-effort: dropping a syntax token on OOM only degrades highlighting for one span
            gop.value_ptr.tokens.append(self.allocator, .{
                .line = line,
                .start_col = col,
                .length = length,
                .token_type = tok_type,
            }) catch {};
        }

        log.info("Parsed {d} tokens for {s}. Notifying listeners.", .{ gop.value_ptr.tokens.items.len, uri });
        if (self.on_tokens_ready) |cb| cb();

        // Persist to disk so the next launch can prefill highlighting
        // before the LSP has finished indexing. Best-effort.
        self.writeTokenCache(uri, gop.value_ptr.tokens.items) catch |err| {
            log.debug("token cache write failed for {s}: {}", .{ uri, err });
        };
    }

    // ----- Persistent semantic-token cache -----
    //
    // File layout (little-endian throughout):
    //   [0..4)  magic = "STEM"
    //   [4]     version = 1
    //   [5..21) file mtime nanoseconds (i128 LE)
    //   [21..29) token count (u64 LE)
    //   then N × Token where Token = { line:u32, col:u32, len:u32, kind:u8 }
    //
    // The mtime is the on-disk mtime at the moment we received these
    // tokens. On load, we re-stat and skip the cache if the file was
    // modified since (i.e., the cached tokens are stale).
    const TOKEN_CACHE_MAGIC: [4]u8 = .{ 'Y', 'A', 'P', 'T' };
    const TOKEN_CACHE_VERSION: u8 = 1;

    fn tokenCachePath(self: *LSPServer, uri: []const u8) ?[]u8 {
        const dir = self.token_cache_dir orelse return null;
        var h = std.hash.Wyhash.init(0);
        h.update(self.lang);
        h.update("\x00");
        h.update(uri);
        const hash = h.final();
        return std.fmt.allocPrint(self.allocator, "{s}/{x:0>16}.tok", .{ dir, hash }) catch null;
    }

    fn uriToFilePath(uri: []const u8) ?[]const u8 {
        const prefix = "file://";
        if (!std.mem.startsWith(u8, uri, prefix)) return null;
        return uri[prefix.len..];
    }

    fn fileMtimeNs(self: *LSPServer, file_path: []const u8) ?i128 {
        var f = std.Io.Dir.openFileAbsolute(self.io, file_path, .{}) catch return null;
        defer f.close(self.io);
        const st = f.stat(self.io) catch return null;
        return @intCast(st.mtime.toNanoseconds());
    }

    fn writeTokenCache(self: *LSPServer, uri: []const u8, tokens: []const protocol.SyntaxToken) !void {
        if (self.token_cache_dir == null) return;
        const file_path = uriToFilePath(uri) orelse return;
        const mtime_ns = self.fileMtimeNs(file_path) orelse return;
        const cache_path = self.tokenCachePath(uri) orelse return;
        defer self.allocator.free(cache_path);

        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{cache_path});
        defer self.allocator.free(tmp_path);

        const total_bytes: usize = 4 + 1 + 16 + 8 + tokens.len * 13;
        const buf = try self.allocator.alloc(u8, total_bytes);
        defer self.allocator.free(buf);

        @memcpy(buf[0..4], &TOKEN_CACHE_MAGIC);
        buf[4] = TOKEN_CACHE_VERSION;
        std.mem.writeInt(i128, buf[5..21], mtime_ns, .little);
        std.mem.writeInt(u64, buf[21..29], tokens.len, .little);
        var off: usize = 29;
        for (tokens) |t| {
            std.mem.writeInt(u32, buf[off..][0..4], t.line, .little);
            off += 4;
            std.mem.writeInt(u32, buf[off..][0..4], t.start_col, .little);
            off += 4;
            std.mem.writeInt(u32, buf[off..][0..4], t.length, .little);
            off += 4;
            buf[off] = @intFromEnum(t.token_type);
            off += 1;
        }

        var file = std.Io.Dir.createFileAbsolute(self.io, tmp_path, .{}) catch return;
        errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
        defer file.close(self.io);
        try file.writePositionalAll(self.io, buf, 0);
        std.Io.Dir.renameAbsolute(tmp_path, cache_path, self.io) catch |err| {
            std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            return err;
        };
    }

    /// Load cached tokens into `file_tokens` if the cache exists and the
    /// file's mtime hasn't moved since the cache was written. Returns true
    /// if we filled the map; the caller can then fire `on_tokens_ready` so
    /// the UI renders the cached highlighting immediately.
    pub fn tryLoadCachedTokens(self: *LSPServer, uri: []const u8) bool {
        if (self.token_cache_dir == null) return false;
        const file_path = uriToFilePath(uri) orelse return false;
        const cur_mtime = self.fileMtimeNs(file_path) orelse return false;
        const cache_path = self.tokenCachePath(uri) orelse return false;
        defer self.allocator.free(cache_path);

        var f = std.Io.Dir.openFileAbsolute(self.io, cache_path, .{}) catch return false;
        defer f.close(self.io);
        const size = f.length(self.io) catch return false;
        if (size < 29) return false;

        const buf = self.allocator.alloc(u8, @intCast(size)) catch return false;
        defer self.allocator.free(buf);
        const read_n = f.readPositionalAll(self.io, buf, 0) catch return false;
        const data = buf[0..read_n];

        if (data.len < 29) return false;
        if (!std.mem.eql(u8, data[0..4], &TOKEN_CACHE_MAGIC)) return false;
        if (data[4] != TOKEN_CACHE_VERSION) return false;
        const cached_mtime = std.mem.readInt(i128, data[5..21], .little);
        if (cached_mtime != cur_mtime) return false;
        const count = std.mem.readInt(u64, data[21..29], .little);

        if (count > (std.math.maxInt(usize) - 29) / 13) return false;
        const expected_size: usize = 29 + count * 13;
        if (data.len < expected_size) return false;

        // Same dupe-before-put pattern as the live-result handler.
        const key_dup = self.allocator.dupe(u8, uri) catch return false;
        errdefer self.allocator.free(key_dup);

        self.file_tokens_mutex.lockUncancelable(self.io);
        defer self.file_tokens_mutex.unlock(self.io);

        const gop = self.file_tokens.getOrPut(self.allocator, key_dup) catch {
            self.allocator.free(key_dup);
            return false;
        };
        if (gop.found_existing) {
            self.allocator.free(key_dup);
        } else {
            gop.value_ptr.* = .{
                .tokens = .empty,
                .last_updated = std.Io.Clock.real.now(self.io).toMilliseconds(),
            };
        }
        gop.value_ptr.tokens.clearRetainingCapacity();
        gop.value_ptr.tokens.ensureTotalCapacity(self.allocator, count) catch return false;

        var off: usize = 29;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const line = std.mem.readInt(u32, data[off..][0..4], .little);
            off += 4;
            const col = std.mem.readInt(u32, data[off..][0..4], .little);
            off += 4;
            const length = std.mem.readInt(u32, data[off..][0..4], .little);
            off += 4;
            const kind_u8 = data[off];
            off += 1;
            const token_type: protocol.SyntaxToken.TokenType = safe.intToEnum(protocol.SyntaxToken.TokenType, kind_u8) orelse continue;
            gop.value_ptr.tokens.append(self.allocator, .{
                .line = line,
                .start_col = col,
                .length = length,
                .token_type = token_type,
            }) catch return false;
        }

        log.info("Loaded {d} cached tokens for {s}", .{ gop.value_ptr.tokens.items.len, uri });
        if (self.on_tokens_ready) |cb| cb();
        return true;
    }

    pub fn copyVisibleTokens(self: *LSPServer, allocator: std.mem.Allocator, uri: []const u8, first_line: usize, last_line: usize) ![]protocol.SyntaxToken {
        self.file_tokens_mutex.lockUncancelable(self.io);
        defer self.file_tokens_mutex.unlock(self.io);

        const file_entry = self.file_tokens.get(uri) orelse return &.{};

        var out = try allocator.alloc(protocol.SyntaxToken, file_entry.tokens.items.len);
        var n: usize = 0;
        for (file_entry.tokens.items) |t| {
            if (t.line >= first_line and t.line < last_line) {
                out[n] = t;
                n += 1;
            }
        }
        return allocator.realloc(out, n);
    }

    pub fn handleHoverResult(self: *LSPServer, result: std.json.Value) !void {
        log.info("handleHoverResult called", .{});
        if (result == .null) return;
        if (result != .object) return;

        const contents = result.object.get("contents") orelse return;
        var hover_text = std.ArrayListUnmanaged(u8).empty;
        defer hover_text.deinit(self.allocator);
        hover_text.ensureTotalCapacity(self.allocator, 256) catch return;

        if (contents == .object) {
            if (contents.object.get("value")) |v| {
                if (v == .string) try hover_text.appendSlice(self.allocator, v.string);
            }
        } else if (contents == .string) {
            try hover_text.appendSlice(self.allocator, contents.string);
        } else if (contents == .array) {
            for (contents.array.items, 0..) |item, i| {
                if (i > 0) try hover_text.appendSlice(self.allocator, "\n\n");
                if (item == .string) {
                    try hover_text.appendSlice(self.allocator, item.string);
                } else if (item == .object) {
                    if (item.object.get("value")) |v| {
                        if (v == .string) try hover_text.appendSlice(self.allocator, v.string);
                    }
                }
            }
        }

        if (hover_text.items.len > 0) {
            var valid_slice = hover_text.items;
            if (std.mem.indexOfScalar(u8, valid_slice, 0)) |null_idx| {
                valid_slice = valid_slice[0..null_idx];
            }
            var clean = std.ArrayListUnmanaged(u8).empty;
            defer clean.deinit(self.allocator);
            clean.ensureTotalCapacity(self.allocator, valid_slice.len) catch return;

            for (valid_slice) |b| {
                if (b == '\n' or b == '\t' or (b >= 32 and b != 127)) {
                    clean.appendAssumeCapacity(b);
                }
            }
            const trimmed = std.mem.trimEnd(u8, clean.items, " \t\r\n");

            self.hover_mutex.lockUncancelable(self.io);
            defer self.hover_mutex.unlock(self.io);
            const new_hover = try self.allocator.dupe(u8, trimmed);
            if (self.hover_result) |old| self.allocator.free(old);
            self.hover_result = new_hover;
            log.info("handleHoverResult stored: {s}", .{trimmed});
        }
    }

    fn handleFormatResult(self: *LSPServer, result: std.json.Value) !void {
        if (result == .null) return;
        if (result != .array) return;

        var edits = std.ArrayListUnmanaged(TextEdit).empty;
        errdefer {
            for (edits.items) |e| self.allocator.free(e.new_text);
            edits.deinit(self.allocator);
        }

        for (result.array.items) |edit| {
            if (edit != .object) continue;
            const range = edit.object.get("range") orelse continue;
            if (range != .object) continue;

            const range_start = range.object.get("start") orelse continue;
            const range_end = range.object.get("end") orelse continue;
            if (range_start != .object or range_end != .object) continue;

            const start_line = toU32(range_start.object.get("line") orelse continue) orelse continue;
            const start_col = toU32(range_start.object.get("character") orelse continue) orelse continue;
            const end_line = toU32(range_end.object.get("line") orelse continue) orelse continue;
            const end_col = toU32(range_end.object.get("character") orelse continue) orelse continue;

            const new_text_val = edit.object.get("newText") orelse continue;
            if (new_text_val != .string) continue;
            const new_text = try self.allocator.dupe(u8, new_text_val.string);

            try edits.append(self.allocator, .{
                .start_line = start_line,
                .start_col = start_col,
                .end_line = end_line,
                .end_col = end_col,
                .new_text = new_text,
            });
        }

        const owned = edits.toOwnedSlice(self.allocator) catch |err| {
            // OOM during finalize — free what we collected and surface.
            for (edits.items) |e| self.allocator.free(e.new_text);
            edits.deinit(self.allocator);
            return err;
        };
        self.format_mutex.lockUncancelable(self.io);
        if (self.format_result) |old| {
            for (old) |e| self.allocator.free(e.new_text);
            self.allocator.free(old);
        }
        self.format_result = owned;
        self.format_mutex.unlock(self.io);
    }

    fn handleDefinitionResult(self: *LSPServer, result: std.json.Value) !void {
        var location_val: ?std.json.Value = null;
        if (result == .object) location_val = result;
        if (result == .array and result.array.items.len > 0) location_val = result.array.items[0];

        if (location_val == null) return;
        const loc = location_val.?;
        if (loc != .object) return;

        const uri_val = loc.object.get("uri") orelse return;
        if (uri_val != .string) return;

        const range = loc.object.get("range") orelse return;
        if (range != .object) return;
        const range_start = range.object.get("start") orelse return;
        if (range_start != .object) return;

        const line = toU32(range_start.object.get("line") orelse return) orelse return;
        const col = toU32(range_start.object.get("character") orelse return) orelse return;

        const uri = uri_val.string;
        const file_path = try fileUriToPath(self.allocator, uri);

        self.definition_mutex.lockUncancelable(self.io);
        if (self.definition_result) |old| self.allocator.free(old.file_path);
        self.definition_result = .{ .file_path = file_path, .line = line, .col = col };
        self.definition_mutex.unlock(self.io);
    }

    fn handleReferencesResult(self: *LSPServer, result: std.json.Value) !void {
        // LSP returns `null` when the server has no references for
        // the symbol (or doesn't know what's at the cursor). Treat
        // that as an explicit empty result so the UI handler can
        // surface "No references found" rather than spinning on a
        // never-arriving response. Non-array, non-null payloads are
        // genuinely malformed — drop them with the empty result too.
        if (result == .null or result != .array) {
            self.references_mutex.lockUncancelable(self.io);
            if (self.references_result) |old| {
                for (old) |r| self.allocator.free(r.file_path);
                self.allocator.free(old);
            }
            self.references_result = try self.allocator.alloc(Location, 0);
            self.references_mutex.unlock(self.io);
            return;
        }

        var locations = std.ArrayListUnmanaged(Location).empty;
        errdefer {
            for (locations.items) |loc| self.allocator.free(loc.file_path);
            locations.deinit(self.allocator);
        }

        for (result.array.items) |item| {
            if (item != .object) continue;
            const uri_val = item.object.get("uri") orelse continue;
            if (uri_val != .string) continue;
            const range = item.object.get("range") orelse continue;
            if (range != .object) continue;
            const range_start = range.object.get("start") orelse continue;
            if (range_start != .object) continue;
            const line = toU32(range_start.object.get("line") orelse continue) orelse continue;
            const col = toU32(range_start.object.get("character") orelse continue) orelse continue;

            const uri = uri_val.string;
            const file_path = try fileUriToPath(self.allocator, uri);

            try locations.append(self.allocator, .{
                .file_path = file_path,
                .line = line,
                .col = col,
            });
        }

        const owned = locations.toOwnedSlice(self.allocator) catch |err| {
            for (locations.items) |l| self.allocator.free(l.file_path);
            locations.deinit(self.allocator);
            return err;
        };
        self.references_mutex.lockUncancelable(self.io);
        if (self.references_result) |old| {
            for (old) |r| self.allocator.free(r.file_path);
            self.allocator.free(old);
        }
        self.references_result = owned;
        self.references_mutex.unlock(self.io);
    }

    pub fn handleCompletionResult(self: *LSPServer, result: std.json.Value) !void {
        var items_array: []const std.json.Value = undefined;
        if (result == .array) {
            items_array = result.array.items;
        } else if (result == .object) {
            if (result.object.get("items")) |items_val| {
                if (items_val == .array) items_array = items_val.array.items else return;
            } else return;
        } else return;

        var completions = std.ArrayListUnmanaged(CompletionItem).empty;
        errdefer {
            for (completions.items) |item| {
                self.allocator.free(item.label);
                if (item.detail) |d| self.allocator.free(d);
            }
            completions.deinit(self.allocator);
        }

        for (items_array) |item| {
            if (item != .object) continue;
            const label_val = item.object.get("label") orelse continue;
            if (label_val != .string) continue;

            var kind: CompletionItem.Kind = .text;
            if (item.object.get("kind")) |kind_val| {
                if (kind_val == .integer) {
                    // LSP CompletionItemKind is 1-based; map only valid values
                    // and fall back to .text for anything out of range.
                    const k = kind_val.integer;
                    const fields_len = @typeInfo(CompletionItem.Kind).@"enum".fields.len;
                    if (k >= 1 and @as(usize, @intCast(k)) <= fields_len) {
                        kind = @enumFromInt(@as(u8, @intCast(k - 1)));
                    }
                }
            }

            var detail: ?[]const u8 = null;
            if (item.object.get("detail")) |detail_val| {
                if (detail_val == .string) detail = try self.allocator.dupe(u8, detail_val.string);
            }

            try completions.append(self.allocator, .{
                .label = try self.allocator.dupe(u8, label_val.string),
                .kind = kind,
                .detail = detail,
            });
        }

        const owned = completions.toOwnedSlice(self.allocator) catch |err| {
            for (completions.items) |item| {
                self.allocator.free(item.label);
                if (item.detail) |d| self.allocator.free(d);
            }
            completions.deinit(self.allocator);
            return err;
        };
        self.completion_mutex.lockUncancelable(self.io);
        if (self.completion_result) |old| {
            for (old) |item| {
                self.allocator.free(item.label);
                if (item.detail) |d| self.allocator.free(d);
            }
            self.allocator.free(old);
        }
        self.completion_result = owned;
        self.completion_mutex.unlock(self.io);
    }

    fn handleDocumentSymbolsResult(self: *LSPServer, result: std.json.Value) !void {
        if (result != .array) return;
        const items_array = result.array.items;

        var symbols = std.ArrayListUnmanaged(DocumentSymbol).empty;
        errdefer {
            for (symbols.items) |sym| {
                self.allocator.free(sym.name);
                if (sym.container_name) |c| self.allocator.free(c);
            }
            symbols.deinit(self.allocator);
        }

        for (items_array) |item| {
            if (item != .object) continue;
            const name_val = item.object.get("name") orelse continue;
            if (name_val != .string) continue;

            var kind: DocumentSymbol.SymbolKind = .function;
            if (item.object.get("kind")) |kind_val| {
                if (kind_val == .integer) {
                    const k = kind_val.integer;
                    if (k >= 1 and k <= 26) {
                        kind = @enumFromInt(@as(u8, @intCast(k)));
                    }
                }
            }

            var line: u32 = 0;
            var col: u32 = 0;
            var end_line: u32 = 0;
            var end_col: u32 = 0;

            if (item.object.get("range")) |range| {
                if (range == .object) {
                    if (range.object.get("start")) |range_start| {
                        if (range_start == .object) {
                            line = toU32(range_start.object.get("line") orelse continue) orelse continue;
                            col = toU32(range_start.object.get("character") orelse continue) orelse continue;
                        }
                    }
                    if (range.object.get("end")) |range_end| {
                        if (range_end == .object) {
                            end_line = toU32(range_end.object.get("line") orelse continue) orelse continue;
                            end_col = toU32(range_end.object.get("character") orelse continue) orelse continue;
                        }
                    }
                }
            } else if (item.object.get("location")) |loc| {
                if (loc == .object) {
                    if (loc.object.get("range")) |loc_range| {
                        if (loc_range == .object) {
                            if (loc_range.object.get("start")) |loc_start| {
                                if (loc_start == .object) {
                                    line = toU32(loc_start.object.get("line") orelse continue) orelse continue;
                                    col = toU32(loc_start.object.get("character") orelse continue) orelse continue;
                                }
                            }
                            if (loc_range.object.get("end")) |loc_end| {
                                if (loc_end == .object) {
                                    end_line = toU32(loc_end.object.get("line") orelse continue) orelse continue;
                                    end_col = toU32(loc_end.object.get("character") orelse continue) orelse continue;
                                }
                            }
                        }
                    }
                }
            }

            var container_name: ?[]const u8 = null;
            if (item.object.get("containerName")) |cn| {
                if (cn == .string and cn.string.len > 0) {
                    container_name = try self.allocator.dupe(u8, cn.string);
                }
            }

            try symbols.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, name_val.string),
                .kind = kind,
                .line = line,
                .col = col,
                .end_line = end_line,
                .end_col = end_col,
                .container_name = container_name,
            });
        }

        log.info("Received {d} document symbols", .{symbols.items.len});

        const owned = symbols.toOwnedSlice(self.allocator) catch |err| {
            for (symbols.items) |sym| {
                self.allocator.free(sym.name);
                if (sym.container_name) |c| self.allocator.free(c);
            }
            symbols.deinit(self.allocator);
            return err;
        };
        self.document_symbols_mutex.lockUncancelable(self.io);
        if (self.document_symbols_result) |old| {
            for (old) |sym| {
                self.allocator.free(sym.name);
                if (sym.container_name) |c| self.allocator.free(c);
            }
            self.allocator.free(old);
        }
        self.document_symbols_result = owned;
        self.document_symbols_mutex.unlock(self.io);
    }

    /// Parse a `workspace/symbol` response. Accepts both the older
    /// `SymbolInformation[]` shape (one flat array, each item with
    /// `location: { uri, range }`) and the newer `WorkspaceSymbol[]`
    /// shape (same envelope; some servers omit `range` and provide
    /// only `uri`). Bad / missing entries are skipped rather than
    /// aborting the whole result.
    fn handleWorkspaceSymbolsResult(self: *LSPServer, result: std.json.Value) !void {
        if (result != .array) return;
        const items = result.array.items;

        var out = std.ArrayListUnmanaged(WorkspaceSymbol).empty;
        errdefer {
            for (out.items) |sym| {
                self.allocator.free(sym.name);
                self.allocator.free(sym.file_path);
                if (sym.container_name) |c| self.allocator.free(c);
            }
            out.deinit(self.allocator);
        }

        for (items) |item| {
            if (item != .object) continue;
            const name_val = item.object.get("name") orelse continue;
            if (name_val != .string or name_val.string.len == 0) continue;

            var kind: DocumentSymbol.SymbolKind = .function;
            if (item.object.get("kind")) |kv| {
                if (kv == .integer) {
                    const k = kv.integer;
                    if (k >= 1 and k <= 26) kind = @enumFromInt(@as(u8, @intCast(k)));
                }
            }

            // Location can be on `location` (SymbolInformation) or
            // directly under the item itself (rare).
            const loc_val = item.object.get("location") orelse continue;
            if (loc_val != .object) continue;
            const uri_val = loc_val.object.get("uri") orelse continue;
            if (uri_val != .string) continue;

            var line: u32 = 0;
            var col: u32 = 0;
            if (loc_val.object.get("range")) |range| {
                if (range == .object) {
                    if (range.object.get("start")) |range_start| {
                        if (range_start == .object) {
                            line = toU32(range_start.object.get("line") orelse continue) orelse 0;
                            col = toU32(range_start.object.get("character") orelse continue) orelse 0;
                        }
                    }
                }
            }

            const file_path = fileUriToPath(self.allocator, uri_val.string) catch continue;
            errdefer self.allocator.free(file_path);
            const name_dup = try self.allocator.dupe(u8, name_val.string);
            errdefer self.allocator.free(name_dup);

            var container_name: ?[]const u8 = null;
            if (item.object.get("containerName")) |cn| {
                if (cn == .string and cn.string.len > 0) {
                    container_name = try self.allocator.dupe(u8, cn.string);
                }
            }

            try out.append(self.allocator, .{
                .name = name_dup,
                .kind = kind,
                .file_path = file_path,
                .line = line,
                .col = col,
                .container_name = container_name,
            });
        }

        log.info("Received {d} workspace symbols", .{out.items.len});

        const owned = out.toOwnedSlice(self.allocator) catch |err| {
            for (out.items) |sym| {
                self.allocator.free(sym.name);
                self.allocator.free(sym.file_path);
                if (sym.container_name) |c| self.allocator.free(c);
            }
            out.deinit(self.allocator);
            return err;
        };

        self.workspace_symbols_mutex.lockUncancelable(self.io);
        if (self.workspace_symbols_result) |old| {
            for (old) |sym| {
                self.allocator.free(sym.name);
                self.allocator.free(sym.file_path);
                if (sym.container_name) |c| self.allocator.free(c);
            }
            self.allocator.free(old);
        }
        self.workspace_symbols_result = owned;
        self.workspace_symbols_mutex.unlock(self.io);
    }

    /// Parse `(Command | CodeAction)[]`. Both shapes share `title`,
    /// so we read that uniformly and stash the raw JSON for whichever
    /// of `edit` / `command` is present. Apply-time code re-parses
    /// just the field it needs.
    fn handleCodeActionResult(self: *LSPServer, result: std.json.Value) !void {
        var owned: std.ArrayListUnmanaged(CodeAction) = .empty;
        errdefer {
            for (owned.items) |a| freeCodeActionInner(self.allocator, a);
            owned.deinit(self.allocator);
        }
        if (result == .array) {
            for (result.array.items) |item| {
                if (item != .object) continue;
                const title_val = item.object.get("title") orelse continue;
                if (title_val != .string) continue;
                const title = try self.allocator.dupe(u8, title_val.string);
                errdefer self.allocator.free(title);

                var kind: ?[]const u8 = null;
                errdefer if (kind) |k| self.allocator.free(k);
                if (item.object.get("kind")) |kv| {
                    if (kv == .string) kind = try self.allocator.dupe(u8, kv.string);
                }

                // Re-serialize the `edit` / `command` sub-objects so
                // the apply path can re-parse them without us having
                // to round-trip the entire LSP `WorkspaceEdit` schema
                // through Zig types. The JSON arenas in this scope
                // own the original strings; we copy out.
                var edit_json: ?[]const u8 = null;
                errdefer if (edit_json) |e| self.allocator.free(e);
                if (item.object.get("edit")) |ev| {
                    var aw: std.Io.Writer.Allocating = .init(self.allocator);
                    defer aw.deinit();
                    try std.json.Stringify.value(ev, .{}, &aw.writer);
                    edit_json = try self.allocator.dupe(u8, aw.written());
                }

                var command_json: ?[]const u8 = null;
                errdefer if (command_json) |c| self.allocator.free(c);
                if (item.object.get("command")) |cv| {
                    var aw: std.Io.Writer.Allocating = .init(self.allocator);
                    defer aw.deinit();
                    try std.json.Stringify.value(cv, .{}, &aw.writer);
                    command_json = try self.allocator.dupe(u8, aw.written());
                }

                try owned.append(self.allocator, .{
                    .title = title,
                    .kind = kind,
                    .edit_json = edit_json,
                    .command_json = command_json,
                });
            }
        }

        const slice = try owned.toOwnedSlice(self.allocator);
        self.code_action_mutex.lockUncancelable(self.io);
        if (self.code_action_result) |old| {
            for (old) |a| freeCodeActionInner(self.allocator, a);
            self.allocator.free(old);
        }
        self.code_action_result = slice;
        self.code_action_mutex.unlock(self.io);
    }

    /// Parse `SignatureHelp`. We flatten to the active signature
    /// only (most servers return one anyway) and extract param
    /// labels as plain strings — multi-part labels with offset
    /// ranges are slice'd through `signature.label[start..end]`.
    fn handleSignatureHelpResult(self: *LSPServer, result: std.json.Value) !void {
        if (result == .null) {
            self.signature_help_mutex.lockUncancelable(self.io);
            if (self.signature_help_result) |old| freeSignatureHelpInner(self.allocator, old);
            self.signature_help_result = null;
            self.signature_help_mutex.unlock(self.io);
            return;
        }
        if (result != .object) return;
        const signatures = result.object.get("signatures") orelse return;
        if (signatures != .array or signatures.array.items.len == 0) return;

        var active_sig: usize = 0;
        if (result.object.get("activeSignature")) |as| {
            if (as == .integer and as.integer >= 0 and @as(usize, @intCast(as.integer)) < signatures.array.items.len) {
                active_sig = @intCast(as.integer);
            }
        }
        var active_param: u32 = 0;
        if (result.object.get("activeParameter")) |ap| {
            if (ap == .integer and ap.integer >= 0) active_param = @intCast(ap.integer);
        }

        const sig = signatures.array.items[active_sig];
        if (sig != .object) return;
        const label_val = sig.object.get("label") orelse return;
        if (label_val != .string) return;
        const label = try self.allocator.dupe(u8, label_val.string);
        errdefer self.allocator.free(label);

        var params_list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (params_list.items) |p| self.allocator.free(p);
            params_list.deinit(self.allocator);
        }
        if (sig.object.get("parameters")) |params| {
            if (params == .array) {
                for (params.array.items) |p| {
                    if (p != .object) continue;
                    const pl = p.object.get("label") orelse continue;
                    // `label` can be either a string or `[start, end]`. Handle both.
                    if (pl == .string) {
                        const dup = try self.allocator.dupe(u8, pl.string);
                        try params_list.append(self.allocator, dup);
                    } else if (pl == .array and pl.array.items.len == 2 and
                        pl.array.items[0] == .integer and pl.array.items[1] == .integer)
                    {
                        const p_start: usize = @intCast(@max(0, pl.array.items[0].integer));
                        const p_end: usize = @intCast(@max(0, pl.array.items[1].integer));
                        if (p_end <= label.len and p_start <= p_end) {
                            const dup = try self.allocator.dupe(u8, label[p_start..p_end]);
                            try params_list.append(self.allocator, dup);
                        }
                    }
                }
            }
        }
        const params_slice = try params_list.toOwnedSlice(self.allocator);

        self.signature_help_mutex.lockUncancelable(self.io);
        if (self.signature_help_result) |old| freeSignatureHelpInner(self.allocator, old);
        self.signature_help_result = .{
            .label = label,
            .parameters = params_slice,
            .active_parameter = active_param,
        };
        self.signature_help_mutex.unlock(self.io);
    }

    /// Parse `InlayHint[]`. Multi-part labels get joined with the
    /// natural concatenation (no separators) because we don't render
    /// individual parts.
    fn handleInlayHintResult(self: *LSPServer, result: std.json.Value, uri: []const u8) !void {
        var owned: std.ArrayListUnmanaged(InlayHint) = .empty;
        errdefer {
            for (owned.items) |h| self.allocator.free(h.label);
            owned.deinit(self.allocator);
        }
        if (result == .array) {
            for (result.array.items) |item| {
                if (item != .object) continue;
                const pos = item.object.get("position") orelse continue;
                if (pos != .object) continue;
                const line_val = pos.object.get("line") orelse continue;
                const char_val = pos.object.get("character") orelse continue;
                if (line_val != .integer or char_val != .integer) continue;
                const line = toU32(line_val) orelse continue;
                const col = toU32(char_val) orelse continue;

                const lbl_val = item.object.get("label") orelse continue;
                var label_buf: std.ArrayListUnmanaged(u8) = .empty;
                errdefer label_buf.deinit(self.allocator);
                if (lbl_val == .string) {
                    try label_buf.appendSlice(self.allocator, lbl_val.string);
                } else if (lbl_val == .array) {
                    for (lbl_val.array.items) |part| {
                        if (part == .object) {
                            if (part.object.get("value")) |v| if (v == .string) try label_buf.appendSlice(self.allocator, v.string);
                        }
                    }
                } else continue;
                const label_owned = try label_buf.toOwnedSlice(self.allocator);

                var kind: ?u8 = null;
                if (item.object.get("kind")) |kv| {
                    if (kv == .integer) kind = @intCast(@as(i64, kv.integer) & 0xFF);
                }
                var pl = false;
                var pr = false;
                if (item.object.get("paddingLeft")) |v| if (v == .bool) {
                    pl = v.bool;
                };
                if (item.object.get("paddingRight")) |v| if (v == .bool) {
                    pr = v.bool;
                };

                try owned.append(self.allocator, .{
                    .line = line,
                    .col = col,
                    .label = label_owned,
                    .kind = kind,
                    .padding_left = pl,
                    .padding_right = pr,
                });
            }
        }
        const slice = try owned.toOwnedSlice(self.allocator);

        self.inlay_hints_mutex.lockUncancelable(self.io);
        defer self.inlay_hints_mutex.unlock(self.io);
        const gop = try self.inlay_hints.getOrPut(self.allocator, uri);
        if (gop.found_existing) {
            for (gop.value_ptr.*) |h| self.allocator.free(h.label);
            self.allocator.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, uri);
        }
        gop.value_ptr.* = slice;
    }

    pub fn handleDiagnostics(self: *LSPServer, root: std.json.Value) !void {
        const params = root.object.get("params") orelse return;
        if (params != .object) return;
        const uri_val = params.object.get("uri") orelse return;
        if (uri_val != .string) return;
        const diagnostics_arr = params.object.get("diagnostics") orelse return;
        if (diagnostics_arr != .array) return;

        // Build the new list first so we don't clobber the existing entry on
        // an OOM partway through.
        var new_list: std.ArrayListUnmanaged(Diagnostic) = .empty;
        errdefer {
            for (new_list.items) |d| self.allocator.free(d.message);
            new_list.deinit(self.allocator);
        }

        for (diagnostics_arr.array.items) |diag| {
            if (diag != .object) continue;
            const range = diag.object.get("range") orelse continue;
            // Adversarial LSP can send `range` as any JSON type — check before
            // calling .object.get, which would panic on a wrong-variant union.
            if (range != .object) continue;
            const range_start = range.object.get("start") orelse continue;
            const range_end = range.object.get("end") orelse continue;
            if (range_start != .object or range_end != .object) continue;

            const start_line = toU32(range_start.object.get("line") orelse continue) orelse continue;
            const start_col = toU32(range_start.object.get("character") orelse continue) orelse continue;
            const end_line = toU32(range_end.object.get("line") orelse continue) orelse continue;
            const end_col = toU32(range_end.object.get("character") orelse continue) orelse continue;

            const message_val = diag.object.get("message") orelse continue;
            if (message_val != .string) continue;
            const message = try self.allocator.dupe(u8, message_val.string);
            errdefer self.allocator.free(message);

            const severity_val = diag.object.get("severity");
            const severity: Diagnostic.Severity = if (severity_val) |sv| blk: {
                const sev_int = toU32(sv) orelse 1;
                break :blk switch (sev_int) {
                    1 => .err,
                    2 => .warning,
                    3 => .info,
                    4 => .hint,
                    else => .err,
                };
            } else .err;
            try new_list.append(self.allocator, .{
                .start_line = start_line,
                .start_col = start_col,
                .end_line = end_line,
                .end_col = end_col,
                .severity = severity,
                .message = message,
            });
        }

        const owned_list = new_list.toOwnedSlice(self.allocator) catch return;

        // Dupe the key BEFORE inserting — otherwise getOrPut stores the
        // borrowed JSON pointer as the slot's key, and if the subsequent
        // dupe were to OOM, the map would hold a pointer to memory that's
        // freed when handleServerMessage returns.
        const key_dup = try self.allocator.dupe(u8, uri_val.string);
        errdefer self.allocator.free(key_dup);

        self.diagnostics_mutex.lockUncancelable(self.io);
        defer self.diagnostics_mutex.unlock(self.io);

        const gop = try self.diagnostics.getOrPut(self.allocator, key_dup);
        if (gop.found_existing) {
            // Already had an owned key for this URI — drop the new dupe and
            // free the old value list.
            self.allocator.free(key_dup);
            for (gop.value_ptr.*) |d| self.allocator.free(d.message);
            self.allocator.free(gop.value_ptr.*);
        }
        // Whether found_existing or not, the key now points at the owned dup
        // (either the just-inserted key_dup, or the pre-existing duped key).
        // In the !found_existing case getOrPut stored key_dup as the key, so
        // it's already correct.
        gop.value_ptr.* = owned_list;

        if (self.on_diagnostics) |cb| cb(uri_val.string, owned_list);
    }

    fn toU32(v: std.json.Value) ?u32 {
        return switch (v) {
            .integer => |iv| if (iv < 0 or iv > std.math.maxInt(u32)) null else @intCast(iv),
            .float => |fv| blk: {
                if (!std.math.isFinite(fv)) break :blk null;
                if (fv < 0 or fv > @as(f64, std.math.maxInt(u32))) break :blk null;
                break :blk @intFromFloat(fv);
            },
            else => null,
        };
    }

    fn mapTokenType(idx: u32) protocol.SyntaxToken.TokenType {
        return switch (@as(SemanticTokenType, @enumFromInt(idx))) {
            .namespace => .namespace,
            .type, .class, .enumType, .interface, .structType, .typeParameter => .type_name,
            .parameter => .parameter,
            .variable => .variable,
            .property => .property,
            .enumMember => .property,
            .event => .variable,
            .function => .function,
            .method => .function,
            .macro => .function,
            .keyword => .keyword,
            .modifier => .keyword,
            .comment => .comment,
            .string => .string,
            .number => .number,
            .regexp => .string,
            .operator => .operator,
            .decorator => .function,
            .builtin => .builtin,
            .label => .variable,
            .keywordLiteral => .keyword,
            else => .other,
        };
    }
};

fn writeJsonEscapedString(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

test "byteColToUtf16 ascii fast path" {
    try std.testing.expectEqual(@as(usize, 5), byteColToUtf16("hello world", 5));
    try std.testing.expectEqual(@as(usize, 0), byteColToUtf16("hello", 0));
    try std.testing.expectEqual(@as(usize, 5), byteColToUtf16("hello", 100));
}

// ---------------------------------------------------------------------
// JSON escape golden tests. These nail down the exact wire bytes for
// the strings we feed to LSP servers — if the escape rules drift, a
// language server might reject our `didOpen` payloads.
// ---------------------------------------------------------------------

fn escapeToOwned(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeJsonEscapedString(&aw.writer, s);
    return try allocator.dupe(u8, aw.written());
}

test "writeJsonEscapedString: ascii passthrough" {
    const out = try escapeToOwned(std.testing.allocator, "hello world");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello world", out);
}

test "writeJsonEscapedString: escapes double-quote and backslash" {
    const out = try escapeToOwned(std.testing.allocator, "a\"b\\c");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\\\"b\\\\c", out);
}

test "writeJsonEscapedString: control chars use named or u-escape" {
    const out = try escapeToOwned(std.testing.allocator, "\n\r\t\x01\x1f");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("\\n\\r\\t\\u0001\\u001f", out);
}

test "writeJsonEscapedString: multi-byte UTF-8 is passed through" {
    // We assume the server tolerates raw UTF-8 in JSON strings (which the
    // spec allows). Verify we don't try to escape every non-ASCII byte.
    const out = try escapeToOwned(std.testing.allocator, "café 漢");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("café 漢", out);
}

test "byteColToUtf16 multibyte" {
    // "café" — 'é' is 2 bytes in UTF-8 but 1 utf-16 code unit.
    const cafe = "café";
    try std.testing.expectEqual(@as(usize, 3), byteColToUtf16(cafe, 3)); // "caf"
    try std.testing.expectEqual(@as(usize, 4), byteColToUtf16(cafe, 5)); // "café" -> 4 utf-16 units

    // Astral codepoint (4-byte UTF-8, surrogate pair in UTF-16).
    const grin = "a\u{1F600}b"; // a + grinning face + b
    try std.testing.expectEqual(@as(usize, 1), byteColToUtf16(grin, 1));
    try std.testing.expectEqual(@as(usize, 3), byteColToUtf16(grin, 5)); // a + surrogate pair
    try std.testing.expectEqual(@as(usize, 4), byteColToUtf16(grin, 6)); // + b
}

test "utf16ColToByte inverse" {
    const cafe = "café";
    try std.testing.expectEqual(@as(usize, 3), utf16ColToByte(cafe, 3));
    try std.testing.expectEqual(@as(usize, 5), utf16ColToByte(cafe, 4));

    const grin = "a\u{1F600}b";
    try std.testing.expectEqual(@as(usize, 1), utf16ColToByte(grin, 1));
    try std.testing.expectEqual(@as(usize, 5), utf16ColToByte(grin, 3));
}

// ---------- LSPServer pending_requests / per-URI diagnostics tests ----------

test "takePending returns null for unknown id" {
    const a = std.testing.allocator;
    const TestIo = @import("../../test_utils.zig").TestIo;
    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();

    const server = try LSPServer.init(a, io_ctx.io(), "test");
    defer server.deinit();

    try std.testing.expectEqual(@as(?RequestKind, null), server.takePending(999));
}

test "setPending then takePending round-trip" {
    const a = std.testing.allocator;
    const TestIo = @import("../../test_utils.zig").TestIo;
    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();

    const server = try LSPServer.init(a, io_ctx.io(), "test");
    defer server.deinit();

    try server.setPending(.hover, 42);
    try server.setPending(.definition, 43);

    try std.testing.expectEqual(@as(?RequestKind, .hover), server.takePending(42));
    // Second take of the same id returns null (already removed).
    try std.testing.expectEqual(@as(?RequestKind, null), server.takePending(42));
    try std.testing.expectEqual(@as(?RequestKind, .definition), server.takePending(43));
}

test "setPending preserves multiple kinds independently" {
    const a = std.testing.allocator;
    const TestIo = @import("../../test_utils.zig").TestIo;
    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();

    const server = try LSPServer.init(a, io_ctx.io(), "test");
    defer server.deinit();

    const ids = [_]struct { kind: RequestKind, id: i64 }{
        .{ .kind = .initialize, .id = 1 },
        .{ .kind = .hover, .id = 2 },
        .{ .kind = .format, .id = 3 },
        .{ .kind = .definition, .id = 4 },
        .{ .kind = .references, .id = 5 },
        .{ .kind = .completion, .id = 6 },
        .{ .kind = .document_symbols, .id = 7 },
    };
    for (ids) |e| try server.setPending(e.kind, e.id);
    // Drain in reverse order — assert correct routing for each.
    var i: usize = ids.len;
    while (i > 0) {
        i -= 1;
        const e = ids[i];
        try std.testing.expectEqual(@as(?RequestKind, e.kind), server.takePending(e.id));
    }
}

test "handleDiagnostics replaces same-URI list" {
    const a = std.testing.allocator;
    const TestIo = @import("../../test_utils.zig").TestIo;
    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();

    const server = try LSPServer.init(a, io_ctx.io(), "test");
    defer server.deinit();

    const payload1 =
        \\{"params":{"uri":"file:///a.zig","diagnostics":[
        \\  {"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":5}},
        \\   "severity":1,"message":"first"}]}}
    ;
    var p1 = try std.json.parseFromSlice(std.json.Value, a, payload1, .{});
    defer p1.deinit();
    try server.handleDiagnostics(p1.value);

    // After first publish, A has 1 diagnostic.
    {
        server.diagnostics_mutex.lockUncancelable(io_ctx.io());
        defer server.diagnostics_mutex.unlock(io_ctx.io());
        const list_a = server.diagnostics.get("file:///a.zig") orelse unreachable;
        try std.testing.expectEqual(@as(usize, 1), list_a.len);
        try std.testing.expectEqualStrings("first", list_a[0].message);
    }

    // Send a second publish for the same URI — should replace.
    const payload2 =
        \\{"params":{"uri":"file:///a.zig","diagnostics":[
        \\  {"range":{"start":{"line":2,"character":0},"end":{"line":2,"character":3}},
        \\   "severity":2,"message":"second"},
        \\  {"range":{"start":{"line":3,"character":0},"end":{"line":3,"character":3}},
        \\   "severity":1,"message":"third"}]}}
    ;
    var p2 = try std.json.parseFromSlice(std.json.Value, a, payload2, .{});
    defer p2.deinit();
    try server.handleDiagnostics(p2.value);

    {
        server.diagnostics_mutex.lockUncancelable(io_ctx.io());
        defer server.diagnostics_mutex.unlock(io_ctx.io());
        const list_a = server.diagnostics.get("file:///a.zig") orelse unreachable;
        try std.testing.expectEqual(@as(usize, 2), list_a.len);
        try std.testing.expectEqualStrings("second", list_a[0].message);
        try std.testing.expectEqualStrings("third", list_a[1].message);
    }
}

test "handleDiagnostics keeps different URIs independent" {
    const a = std.testing.allocator;
    const TestIo = @import("../../test_utils.zig").TestIo;
    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();

    const server = try LSPServer.init(a, io_ctx.io(), "test");
    defer server.deinit();

    const a_payload =
        \\{"params":{"uri":"file:///a.zig","diagnostics":[
        \\  {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},
        \\   "severity":1,"message":"a-error"}]}}
    ;
    var pa = try std.json.parseFromSlice(std.json.Value, a, a_payload, .{});
    defer pa.deinit();
    try server.handleDiagnostics(pa.value);

    const b_payload =
        \\{"params":{"uri":"file:///b.zig","diagnostics":[
        \\  {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},
        \\   "severity":2,"message":"b-warning"}]}}
    ;
    var pb = try std.json.parseFromSlice(std.json.Value, a, b_payload, .{});
    defer pb.deinit();
    try server.handleDiagnostics(pb.value);

    // Both URIs should have their lists. Sending an empty list for A
    // should clear ONLY A.
    {
        server.diagnostics_mutex.lockUncancelable(io_ctx.io());
        defer server.diagnostics_mutex.unlock(io_ctx.io());
        try std.testing.expect(server.diagnostics.get("file:///nope.zig") == null);
        try std.testing.expectEqual(@as(usize, 1), server.diagnostics.get("file:///a.zig").?.len);
        try std.testing.expectEqual(@as(usize, 1), server.diagnostics.get("file:///b.zig").?.len);
    }

    const clear_a =
        \\{"params":{"uri":"file:///a.zig","diagnostics":[]}}
    ;
    var pc = try std.json.parseFromSlice(std.json.Value, a, clear_a, .{});
    defer pc.deinit();
    try server.handleDiagnostics(pc.value);

    {
        server.diagnostics_mutex.lockUncancelable(io_ctx.io());
        defer server.diagnostics_mutex.unlock(io_ctx.io());
        try std.testing.expectEqual(@as(usize, 0), server.diagnostics.get("file:///a.zig").?.len);
        try std.testing.expectEqual(@as(usize, 1), server.diagnostics.get("file:///b.zig").?.len);
    }
}

test "handleDiagnostics tolerates malformed payloads" {
    const a = std.testing.allocator;
    const TestIo = @import("../../test_utils.zig").TestIo;
    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();

    const server = try LSPServer.init(a, io_ctx.io(), "test");
    defer server.deinit();

    // Missing params entirely.
    {
        var p = try std.json.parseFromSlice(std.json.Value, a, "{}", .{});
        defer p.deinit();
        try server.handleDiagnostics(p.value);
    }
    // Missing uri.
    {
        var p = try std.json.parseFromSlice(std.json.Value, a, "{\"params\":{\"diagnostics\":[]}}", .{});
        defer p.deinit();
        try server.handleDiagnostics(p.value);
    }
    // Non-finite severity (NaN) — should not panic.
    const nan_payload =
        \\{"params":{"uri":"file:///x.zig","diagnostics":[
        \\  {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},
        \\   "severity":99,"message":"weird"}]}}
    ;
    var pn = try std.json.parseFromSlice(std.json.Value, a, nan_payload, .{});
    defer pn.deinit();
    try server.handleDiagnostics(pn.value);
    {
        server.diagnostics_mutex.lockUncancelable(io_ctx.io());
        defer server.diagnostics_mutex.unlock(io_ctx.io());
        // severity=99 falls through to .err by the existing switch default.
        const list = server.diagnostics.get("file:///x.zig").?;
        try std.testing.expectEqual(@as(usize, 1), list.len);
    }
}

test "handleInlayHintResult ignores invalid negative positions" {
    const a = std.testing.allocator;
    const TestIo = @import("../../test_utils.zig").TestIo;
    var io_ctx = TestIo.init(a);
    defer io_ctx.deinit();

    const server = try LSPServer.init(a, io_ctx.io(), "test");
    defer server.deinit();

    const payload =
        \\[
        \\  {"position":{"line":-1,"character":0},"label":"bad-line"},
        \\  {"position":{"line":0,"character":-1},"label":"bad-col"},
        \\  {"position":{"line":1,"character":2},"label":"ok"}
        \\]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, payload, .{});
    defer parsed.deinit();

    try server.handleInlayHintResult(parsed.value, "file:///x.zig");

    server.inlay_hints_mutex.lockUncancelable(io_ctx.io());
    defer server.inlay_hints_mutex.unlock(io_ctx.io());
    const hints = server.inlay_hints.get("file:///x.zig").?;
    try std.testing.expectEqual(@as(usize, 1), hints.len);
    try std.testing.expectEqual(@as(u32, 1), hints[0].line);
    try std.testing.expectEqual(@as(u32, 2), hints[0].col);
    try std.testing.expectEqualStrings("ok", hints[0].label);
}

// ---------- Property test ----------

test "byteColToUtf16 / utf16ColToByte property round-trip" {
    // For any valid UTF-8 line and any byte offset that lands on a
    // code-point boundary, byte -> utf16 -> byte must be identity.
    var prng = std.Random.DefaultPrng.init(0x5A1D);
    const rand = prng.random();

    // Pool of strings to cover ASCII, BMP, and supplementary planes.
    const samples = [_][]const u8{
        "",
        "hello world",
        "café au lait",
        "漢字漢字",
        "a\u{1F600}b\u{1F44D}",
        "mixed: A漢\u{1F600}!",
    };

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const line = samples[rand.intRangeLessThan(usize, 0, samples.len)];
        // Find all code-point boundaries.
        var boundaries: std.ArrayListUnmanaged(usize) = .empty;
        defer boundaries.deinit(std.testing.allocator);
        try boundaries.append(std.testing.allocator, 0);
        var i: usize = 0;
        while (i < line.len) {
            const len = std.unicode.utf8ByteSequenceLength(line[i]) catch {
                i += 1;
                continue;
            };
            i += len;
            try boundaries.append(std.testing.allocator, i);
        }

        // Pick a random boundary; round-trip it.
        const idx = if (boundaries.items.len > 1)
            rand.intRangeLessThan(usize, 0, boundaries.items.len)
        else
            0;
        const byte_col = boundaries.items[idx];
        const u16_col = byteColToUtf16(line, byte_col);
        const back = utf16ColToByte(line, u16_col);
        try std.testing.expectEqual(byte_col, back);
    }
}
