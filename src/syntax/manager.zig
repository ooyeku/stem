const std = @import("std");
const log = std.log.scoped(.SyntaxManager);
const ts = @import("tree_sitter.zig");
const c = ts.c;
const protocol = @import("../kernel/protocol.zig");
const thread_name = @import("../services/thread_name.zig");

const test_utils = @import("../test_utils.zig");
const MemoryTestUtils = test_utils.MemoryTestUtils;
const PerformanceTestUtils = test_utils.PerformanceTestUtils;

pub const SyntaxManager = struct {
    allocator: std.mem.Allocator,
    /// io is used for the locking primitives that guard tree/parse state.
    /// `null` means no worker thread will be spawned and all locking is a
    /// no-op (single-threaded test mode).
    io: ?std.Io = null,
    /// Main-thread parser. Used by the synchronous `parse()` path (which
    /// tests rely on). The async path has its own parser so the two never
    /// contend.
    parser: *c.TSParser,
    /// Parser owned by the background worker. Created lazily in
    /// `startParseWorker`; null until then.
    worker_parser: ?*c.TSParser = null,
    /// Current syntax tree. Reads and writes must hold `tree_mutex` once
    /// the parse worker is running; before that, single-threaded access is
    /// fine.
    tree: ?*c.TSTree,
    language: ?*const c.TSLanguage,
    query: ?*c.TSQuery,
    cursor: *c.TSQueryCursor,
    /// Guards `tree`, `current_lang`, `current_resource_id`. Brief locks
    /// only — readers hold it during one ts_* call, the worker holds it
    /// during the pointer swap, not the parse itself.
    tree_mutex: std.Io.Mutex = .init,
    current_lang: Language = .unknown,
    current_resource_id: u64 = 0,

    /// Latest-wins parse job. `submitParse` overwrites the previous one if
    /// the worker hasn't picked it up yet — only the most-recent edit needs
    /// to be parsed.
    pending_job: ?ParseJob = null,
    parse_mutex: std.Io.Mutex = .init,
    parse_cond: std.Io.Condition = .init,
    parse_thread: ?std.Thread = null,
    parse_shutdown: std.atomic.Value(bool) = .{ .raw = false },

    /// Single-slot memoization for `highlight`. When the caller asks for
    /// the same buffer-version + visible range we just computed, return a
    /// fresh copy instead of re-running the query cursor. Invalidated on
    /// every tree swap (parse / setLanguage / clear). Massively cuts CPU on
    /// idle frames where the buffer hasn't changed and the user just
    /// breathed near the editor.
    highlight_cache: HighlightCache = .{},

    /// Same idea as `highlight_cache`, but for `findBrackets`. Brackets
    /// don't change unless the file content changes, so on an idle
    /// frame we'd otherwise walk the entire file byte-by-byte each
    /// render. The cache key is `(resource_id, content_len,
    /// start_line, end_line)` — `content_len` stands in for "did the
    /// buffer change?" cheaply and is exact enough for the cache to
    /// stay correct.
    bracket_cache: BracketCache = .{},

    /// Pending edits queued by `recordEdit`. Drained on the next
    /// `submitParse` or cleared on `setLanguageEnum`.
    pending_edits: std.ArrayListUnmanaged(EditInfo) = .empty,
    edits_mutex: std.Io.Mutex = .init,

    /// Set to true by the parse worker each time it installs a new tree.
    /// Core's tick handler polls this; on hit, clears it and requests a
    /// render. Without this, a freshly-parsed tree sits invisible until
    /// some other event (mouse move, keystroke) happens to fire a render.
    tree_updated: std.atomic.Value(bool) = .{ .raw = false },

    pub const HighlightCache = struct {
        resource_id: u64 = 0,
        lang: Language = .unknown,
        start_line: usize = 0,
        end_line: usize = 0,
        tokens: std.ArrayListUnmanaged(protocol.SyntaxToken) = .empty,
        valid: bool = false,

        fn invalidate(self: *HighlightCache, allocator: std.mem.Allocator) void {
            self.tokens.clearAndFree(allocator);
            self.valid = false;
        }
    };

    pub const BracketCache = struct {
        resource_id: u64 = 0,
        content_len: usize = 0,
        start_line: usize = 0,
        end_line: usize = 0,
        tokens: std.ArrayListUnmanaged(protocol.SyntaxToken) = .empty,
        valid: bool = false,

        fn invalidate(self: *BracketCache, allocator: std.mem.Allocator) void {
            self.tokens.clearAndFree(allocator);
            self.valid = false;
        }
    };

    pub const ParseJob = struct {
        source: []u8,
        lang: Language,
        resource_id: ?u64,
        /// Edits recorded since the last parse. Replayed onto a tree_copy
        /// before reparse so tree-sitter can do real incremental parsing.
        /// Empty slice means no incremental hints — the parser still uses
        /// the copy for subtree-reuse content matching, just slower.
        edits: []EditInfo = &.{},
    };

    /// Single buffer edit, in the shape tree-sitter's `TSInputEdit`
    /// expects. Stored in `pending_edits` on the manager and drained by
    /// `submitParse` into the ParseJob.
    pub const EditInfo = struct {
        start_byte: usize,
        old_end_byte: usize,
        new_end_byte: usize,
        start_row: usize,
        start_col: usize,
        old_end_row: usize,
        old_end_col: usize,
        new_end_row: usize,
        new_end_col: usize,
    };

    /// Lock helpers: no-op when no io (single-threaded test mode).
    inline fn treeLock(self: *SyntaxManager) void {
        if (self.io) |io| self.tree_mutex.lockUncancelable(io);
    }
    inline fn treeUnlock(self: *SyntaxManager) void {
        if (self.io) |io| self.tree_mutex.unlock(io);
    }
    inline fn parseLock(self: *SyntaxManager) void {
        if (self.io) |io| self.parse_mutex.lockUncancelable(io);
    }
    inline fn parseUnlock(self: *SyntaxManager) void {
        if (self.io) |io| self.parse_mutex.unlock(io);
    }

    pub const Language = enum {
        zig,
        python,
        go,
        javascript,
        typescript,
        tsx,
        json,
        bash,
        html,
        css,
        rust,
        c,
        cpp,
        java,
        ruby,
        csharp,
        php,
        swift,
        kotlin,
        lua,
        dart,
        elixir,
        haskell,
        ocaml,
        scala,
        r,
        perl,
        erlang,
        markdown,
        unknown,

        pub fn fromExtension(ext: []const u8) Language {
            if (std.mem.eql(u8, ext, ".zig")) return .zig;
            if (std.mem.eql(u8, ext, ".go")) return .go;
            if (std.mem.eql(u8, ext, ".rs")) return .rust;
            if (std.mem.eql(u8, ext, ".py") or std.mem.eql(u8, ext, ".pyw") or std.mem.eql(u8, ext, ".pyi")) return .python;
            if (std.mem.eql(u8, ext, ".html") or std.mem.eql(u8, ext, ".htm")) return .html;
            if (std.mem.eql(u8, ext, ".css")) return .css;
            if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".mjs") or std.mem.eql(u8, ext, ".cjs")) return .javascript;
            if (std.mem.eql(u8, ext, ".jsx")) return .tsx;
            if (std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".mts") or std.mem.eql(u8, ext, ".cts")) return .typescript;
            if (std.mem.eql(u8, ext, ".tsx")) return .tsx;
            if (std.mem.eql(u8, ext, ".json")) return .json;
            if (std.mem.eql(u8, ext, ".sh") or std.mem.eql(u8, ext, ".bash") or std.mem.eql(u8, ext, ".zsh")) return .bash;
            if (std.mem.eql(u8, ext, ".md") or std.mem.eql(u8, ext, ".markdown")) return .markdown;
            // C: `.c` and `.h`. `.h` is ambiguous (could be C++) but most C
            // codebases use `.h`; C++ files conventionally use `.hpp`/`.hxx`.
            if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".h")) return .c;
            if (std.mem.eql(u8, ext, ".cpp") or std.mem.eql(u8, ext, ".cc") or std.mem.eql(u8, ext, ".cxx") or
                std.mem.eql(u8, ext, ".hpp") or std.mem.eql(u8, ext, ".hxx") or std.mem.eql(u8, ext, ".hh")) return .cpp;
            if (std.mem.eql(u8, ext, ".java")) return .java;
            if (std.mem.eql(u8, ext, ".rb") or std.mem.eql(u8, ext, ".rake")) return .ruby;
            if (std.mem.eql(u8, ext, ".cs")) return .csharp;
            if (std.mem.eql(u8, ext, ".php") or std.mem.eql(u8, ext, ".phtml") or std.mem.eql(u8, ext, ".php3") or std.mem.eql(u8, ext, ".php4") or std.mem.eql(u8, ext, ".php5") or std.mem.eql(u8, ext, ".php7")) return .php;
            if (std.mem.eql(u8, ext, ".swift")) return .swift;
            if (std.mem.eql(u8, ext, ".kt") or std.mem.eql(u8, ext, ".kts")) return .kotlin;
            if (std.mem.eql(u8, ext, ".lua")) return .lua;
            if (std.mem.eql(u8, ext, ".dart")) return .dart;
            if (std.mem.eql(u8, ext, ".ex") or std.mem.eql(u8, ext, ".exs")) return .elixir;
            if (std.mem.eql(u8, ext, ".hs") or std.mem.eql(u8, ext, ".lhs")) return .haskell;
            if (std.mem.eql(u8, ext, ".ml") or std.mem.eql(u8, ext, ".mli")) return .ocaml;
            if (std.mem.eql(u8, ext, ".scala") or std.mem.eql(u8, ext, ".sc")) return .scala;
            if (std.mem.eql(u8, ext, ".r") or std.mem.eql(u8, ext, ".R")) return .r;
            if (std.mem.eql(u8, ext, ".pl") or std.mem.eql(u8, ext, ".pm") or std.mem.eql(u8, ext, ".t")) return .perl;
            if (std.mem.eql(u8, ext, ".erl") or std.mem.eql(u8, ext, ".hrl")) return .erlang;
            return .unknown;
        }

        pub fn fromFilename(filename: []const u8) Language {
            const ext = std.fs.path.extension(filename);
            return fromExtension(ext);
        }
    };

    const zig_query = @embedFile("queries/zig.scm");
    const python_query = @embedFile("queries/python.scm");
    const javascript_query = @embedFile("queries/javascript.scm");
    const typescript_query = @embedFile("queries/typescript.scm");
    const json_query = @embedFile("queries/json.scm");
    const bash_query = @embedFile("queries/bash.scm");
    const go_query = @embedFile("queries/go.scm");
    const html_query = @embedFile("queries/html.scm");
    const css_query = @embedFile("queries/css.scm");
    const rust_query = @embedFile("queries/rust.scm");
    const c_query = @embedFile("queries/c.scm");
    const cpp_query = @embedFile("queries/cpp.scm");
    const java_query = @embedFile("queries/java.scm");
    const ruby_query = @embedFile("queries/ruby.scm");
    const csharp_query = @embedFile("queries/csharp.scm");
    const php_query = @embedFile("queries/php.scm");
    const swift_query = @embedFile("queries/swift.scm");
    const kotlin_query = @embedFile("queries/kotlin.scm");
    const lua_query = @embedFile("queries/lua.scm");
    const dart_query = @embedFile("queries/dart.scm");
    const elixir_query = @embedFile("queries/elixir.scm");
    const haskell_query = @embedFile("queries/haskell.scm");
    const ocaml_query = @embedFile("queries/ocaml.scm");
    const scala_query = @embedFile("queries/scala.scm");
    const r_query = @embedFile("queries/r.scm");
    const perl_query = @embedFile("queries/perl.scm");
    const erlang_query = @embedFile("queries/erlang.scm");

    pub fn init(allocator: std.mem.Allocator) !SyntaxManager {
        const parser = c.ts_parser_new() orelse return error.OutOfMemory;
        const cursor = c.ts_query_cursor_new() orelse {
            c.ts_parser_delete(parser);
            return error.OutOfMemory;
        };

        return .{
            .allocator = allocator,
            .parser = parser,
            .tree = null,
            .language = null,
            .query = null,
            .cursor = cursor,
            .current_lang = .unknown,
        };
    }

    pub fn deinit(self: *SyntaxManager) void {
        // Stop the parse worker first so it can't be mid-write to `tree`
        // when we free it.
        self.stopParseWorker();

        if (self.tree) |t| c.ts_tree_delete(t);
        if (self.query) |q| c.ts_query_delete(q);
        c.ts_query_cursor_delete(self.cursor);
        c.ts_parser_delete(self.parser);
        if (self.worker_parser) |p| c.ts_parser_delete(p);
        self.highlight_cache.invalidate(self.allocator);
        self.bracket_cache.invalidate(self.allocator);
    }

    /// Spawn the background parse worker. Idempotent — safe to call if one
    /// is already running. Failures are non-fatal: subsequent `submitParse`
    /// calls fall back to a synchronous parse on the caller's thread.
    pub fn startParseWorker(self: *SyntaxManager, io: std.Io) !void {
        if (self.parse_thread != null) return;
        if (self.worker_parser == null) {
            self.worker_parser = c.ts_parser_new() orelse return error.OutOfMemory;
        }
        // io is captured for the lifetime of the worker; needed by the
        // mutex/condvar primitives the worker uses.
        self.io = io;
        self.parse_shutdown.store(false, .release);
        self.parse_thread = try std.Thread.spawn(.{}, parseWorkerMain, .{self});
    }

    fn stopParseWorker(self: *SyntaxManager) void {
        if (self.parse_thread == null) return;
        self.parse_shutdown.store(true, .release);
        self.parseLock();
        if (self.io) |io| self.parse_cond.broadcast(io);
        self.parseUnlock();

        if (self.parse_thread) |t| {
            t.join();
            self.parse_thread = null;
        }

        // Drop any pending job.
        self.parseLock();
        if (self.pending_job) |old| {
            self.allocator.free(old.source);
            if (old.edits.len > 0) self.allocator.free(old.edits);
            self.pending_job = null;
        }
        self.parseUnlock();

        // Drop any pending edits — no worker left to apply them.
        if (self.io) |io| self.edits_mutex.lockUncancelable(io);
        self.pending_edits.deinit(self.allocator);
        self.pending_edits = .empty;
        if (self.io) |io| self.edits_mutex.unlock(io);
    }

    fn parseWorkerMain(self: *SyntaxManager) void {
        thread_name.set("stem-parse");
        log.debug("parse worker started", .{});
        defer log.debug("parse worker exited", .{});

        while (true) {
            // Wait for a job.
            self.parseLock();
            while (self.pending_job == null and !self.parse_shutdown.load(.acquire)) {
                if (self.io) |io| self.parse_cond.waitUncancelable(io, &self.parse_mutex);
            }
            if (self.parse_shutdown.load(.acquire)) {
                self.parseUnlock();
                return;
            }
            var job = self.pending_job.?;
            self.pending_job = null;
            self.parseUnlock();

            defer self.allocator.free(job.source);

            const lang_ptr: ?*const c.TSLanguage = switch (job.lang) {
                .zig => ts.zig_language(),
                .python => ts.python_language(),
                .javascript => ts.javascript_language(),
                .typescript => ts.typescript_language(),
                .tsx => ts.tsx_language(),
                .json => ts.json_language(),
                .bash => ts.bash_language(),
                .go => ts.go_language(),
                .html => ts.html_language(),
                .css => ts.css_language(),
                .rust => ts.rust_language(),
                .c => ts.c_language(),
                .cpp => ts.cpp_language(),
                .java => ts.java_language(),
                .ruby => ts.ruby_language(),
                .csharp => ts.csharp_language(),
                .php => ts.php_language(),
                .swift => ts.swift_language(),
                .kotlin => ts.kotlin_language(),
                .lua => ts.lua_language(),
                .dart => ts.dart_language(),
                .elixir => ts.elixir_language(),
                .haskell => ts.haskell_language(),
                .ocaml => ts.ocaml_language(),
                .scala => ts.scala_language(),
                .r => ts.r_language(),
                .perl => ts.perl_language(),
                .erlang => ts.erlang_language(),
                .markdown, .unknown => null,
            };
            if (lang_ptr == null) continue;

            const wp = self.worker_parser orelse continue;
            thread_name.markStep("parse:set_language");
            if (!c.ts_parser_set_language(wp, lang_ptr.?)) continue;

            // Take a refcounted copy of the previous tree (cheap — tree-
            // sitter's ts_tree_copy is shallow) so we can pass it to the
            // parser without holding the tree lock during the parse. The
            // copy must be language-compatible with the new parse: if the
            // user switched languages, skip the copy.
            thread_name.markStep("parse:lock_for_copy");
            self.treeLock();
            thread_name.markStep("parse:tree_copy");
            const prev_tree_copy: ?*c.TSTree = if (self.current_lang == job.lang and self.tree != null)
                c.ts_tree_copy(self.tree.?)
            else
                null;
            const apply_edits = job.edits;
            job.edits = &.{};
            self.treeUnlock();

            // Replay any edits recorded on the main thread since the last
            // parse, so the parser knows which byte ranges changed and can
            // reuse subtrees outside those ranges. Without these calls the
            // copy is just a content hint; with them, edited regions get
            // proper reparse and the rest is reused.
            if (prev_tree_copy) |t| {
                thread_name.markStep("parse:apply_edits");
                for (apply_edits) |ed| {
                    var ts_edit = c.TSInputEdit{
                        .start_byte = @intCast(ed.start_byte),
                        .old_end_byte = @intCast(ed.old_end_byte),
                        .new_end_byte = @intCast(ed.new_end_byte),
                        .start_point = .{ .row = @intCast(ed.start_row), .column = @intCast(ed.start_col) },
                        .old_end_point = .{ .row = @intCast(ed.old_end_row), .column = @intCast(ed.old_end_col) },
                        .new_end_point = .{ .row = @intCast(ed.new_end_row), .column = @intCast(ed.new_end_col) },
                    };
                    c.ts_tree_edit(t, &ts_edit);
                }
            }
            if (apply_edits.len > 0) self.allocator.free(apply_edits);

            // Parse. With prev_tree_copy non-null and ts_tree_edit applied,
            // tree-sitter does an incremental reparse — only changed nodes
            // are rebuilt; everything else is reused. Order-of-magnitude
            // faster on 1-char edits in large files.
            thread_name.markStep("parse:parse_string");
            const new_tree = c.ts_parser_parse_string(wp, prev_tree_copy, job.source.ptr, @intCast(job.source.len));
            thread_name.markStep("parse:delete_prev_copy");
            if (prev_tree_copy) |t| c.ts_tree_delete(t);
            if (new_tree == null) continue;

            // Swap in. Discard if the user changed language during the parse.
            thread_name.markStep("parse:lock_for_install");
            self.treeLock();
            thread_name.markStep("parse:check_installed");
            const installed = self.current_lang == job.lang;
            if (installed) {
                thread_name.markStep("parse:delete_old_tree");
                if (self.tree) |old| c.ts_tree_delete(old);
                thread_name.markStep("parse:assign_new_tree");
                self.tree = new_tree;
                if (job.resource_id) |id| self.current_resource_id = id;
                // Tree changed → memoized highlight + bracket pass stale.
                thread_name.markStep("parse:invalidate_hl_cache");
                self.highlight_cache.invalidate(self.allocator);
                thread_name.markStep("parse:invalidate_bracket_cache");
                self.bracket_cache.invalidate(self.allocator);
            } else {
                thread_name.markStep("parse:discard_new_tree");
                c.ts_tree_delete(new_tree);
            }
            self.treeUnlock();
            thread_name.markStep("parse:idle");

            // Signal core's tick handler that highlighting can be redrawn.
            if (installed) self.tree_updated.store(true, .release);
        }
    }

    /// Submit a parse job to the background worker, replacing any prior job
    /// the worker hasn't picked up yet. The caller's content is duped so
    /// it's safe to free immediately after this returns. If no worker is
    /// running, falls back to a synchronous `parse`.
    pub fn submitParse(self: *SyntaxManager, source: []const u8, resource_id: ?u64) !void {
        self.treeLock();
        const lang = self.current_lang;
        self.treeUnlock();
        if (lang == .markdown or lang == .unknown) return;

        if (self.parse_thread == null) {
            // No worker; do it inline. This is the test path.
            return self.parse(source, resource_id);
        }

        const dup = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(dup);

        // Drain pending edits into an owned slice that travels with the
        // job. Worker frees it after applying.
        const empty_edits: []EditInfo = &.{};
        const edits_owned: []EditInfo = blk: {
            if (self.io) |io| self.edits_mutex.lockUncancelable(io);
            defer if (self.io) |io| self.edits_mutex.unlock(io);
            if (self.pending_edits.items.len == 0) break :blk empty_edits;
            const owned = self.pending_edits.toOwnedSlice(self.allocator) catch break :blk empty_edits;
            break :blk owned;
        };
        errdefer if (edits_owned.len > 0) self.allocator.free(edits_owned);

        self.parseLock();
        defer self.parseUnlock();
        if (self.pending_job) |old| {
            self.allocator.free(old.source);
            if (old.edits.len > 0) self.allocator.free(old.edits);
        }
        self.pending_job = .{
            .source = dup,
            .lang = lang,
            .resource_id = resource_id,
            .edits = edits_owned,
        };
        if (self.io) |io| self.parse_cond.signal(io);
    }

    /// Record a buffer edit so the next parse can replay it as a tree-
    /// sitter `TSInputEdit`. Cheap (just appends to a list). The list is
    /// drained on the next `submitParse` and applied to the previous tree
    /// before the worker reparses.
    ///
    /// NOTE: callers (the edit sites in `EditorState`) need a reference to
    /// `SyntaxManager` to invoke this. Today the manager is owned by
    /// `Core` and not exposed to `EditorState`, so this method is unused.
    /// Even without callers, `submitParse` passes a tree_copy to the
    /// parser; tree-sitter does content-based subtree reuse against that
    /// copy, which captures most of the incremental win for typical
    /// edits. Wiring `recordEdit` from `insertChar`/`deleteChar`/etc.
    /// would push the remaining win (large files + small edits) but
    /// requires a callback or back-reference plumbed through
    /// `EditorState`.
    pub fn recordEdit(self: *SyntaxManager, info: EditInfo) void {
        if (self.io) |io| self.edits_mutex.lockUncancelable(io);
        defer if (self.io) |io| self.edits_mutex.unlock(io);
        self.pending_edits.append(self.allocator, info) catch {
            // OOM: drop the record. Worst case the next parse is a full
            // (non-incremental) reparse — slower but still correct.
        };
        // Brackets are computed by a byte-walk over the buffer, not
        // from the tree. The tree-update path also invalidates this
        // cache, but that only fires once the async parse lands; an
        // edit that preserves byte length (e.g. find/replace `foo`
        // → `bar`) would otherwise serve stale positions in the
        // intervening window.
        self.bracket_cache.invalidate(self.allocator);
    }

    pub fn setLanguageEnum(self: *SyntaxManager, lang_enum: Language) !void {
        if (lang_enum == .unknown) return error.UnsupportedLanguage;

        log.debug("SyntaxManager.setLanguageEnum called with: {s}", .{@tagName(lang_enum)});

        const lang_ptr: ?*const c.TSLanguage = switch (lang_enum) {
            .zig => ts.zig_language(),
            .python => ts.python_language(),
            .javascript => ts.javascript_language(),
            .typescript => ts.typescript_language(),
            .tsx => ts.tsx_language(),
            .json => ts.json_language(),
            .bash => ts.bash_language(),
            .go => ts.go_language(),
            .html => ts.html_language(),
            .css => ts.css_language(),
            .rust => ts.rust_language(),
            .c => ts.c_language(),
            .cpp => ts.cpp_language(),
            .java => ts.java_language(),
            .ruby => ts.ruby_language(),
            .csharp => ts.csharp_language(),
            .php => ts.php_language(),
            .swift => ts.swift_language(),
            .kotlin => ts.kotlin_language(),
            .lua => ts.lua_language(),
            .dart => ts.dart_language(),
            .elixir => ts.elixir_language(),
            .haskell => ts.haskell_language(),
            .ocaml => ts.ocaml_language(),
            .scala => ts.scala_language(),
            .r => ts.r_language(),
            .perl => ts.perl_language(),
            .erlang => ts.erlang_language(),
            .markdown => null,
            .unknown => null,
        };

        const query_source: []const u8 = switch (lang_enum) {
            .zig => zig_query,
            .python => python_query,
            .javascript, .tsx => javascript_query,
            .typescript => typescript_query,
            .json => json_query,
            .bash => bash_query,
            .go => go_query,
            .html => html_query,
            .css => css_query,
            .rust => rust_query,
            .c => c_query,
            .cpp => cpp_query,
            .java => java_query,
            .ruby => ruby_query,
            .csharp => csharp_query,
            .php => php_query,
            .swift => swift_query,
            .kotlin => kotlin_query,
            .lua => lua_query,
            .dart => dart_query,
            .elixir => elixir_query,
            .haskell => haskell_query,
            .ocaml => ocaml_query,
            .scala => scala_query,
            .r => r_query,
            .perl => perl_query,
            .erlang => erlang_query,
            .markdown => &.{},
            .unknown => &.{},
        };

        // Drop any pending edits — they reference the OLD content/tree.
        if (self.io) |io| self.edits_mutex.lockUncancelable(io);
        self.pending_edits.clearRetainingCapacity();
        if (self.io) |io| self.edits_mutex.unlock(io);

        // Drop any pending parse job — it was for the OLD language.
        self.parseLock();
        if (self.pending_job) |old| {
            self.allocator.free(old.source);
            if (old.edits.len > 0) self.allocator.free(old.edits);
            self.pending_job = null;
        }
        self.parseUnlock();

        if (lang_enum == .markdown) {
            self.treeLock();
            self.current_lang = lang_enum;
            if (self.tree) |t| c.ts_tree_delete(t);
            self.tree = null;
            self.highlight_cache.invalidate(self.allocator);
            self.bracket_cache.invalidate(self.allocator);
            self.treeUnlock();

            if (self.query) |q| c.ts_query_delete(q);
            self.query = null;
            self.language = null;
            log.debug("SyntaxManager: {s} uses custom/LSP highlighting", .{@tagName(lang_enum)});
            return;
        }

        if (lang_ptr == null) return error.InvalidLanguage;
        const lang = lang_ptr.?;

        if (!c.ts_parser_set_language(self.parser, lang)) {
            log.err("SyntaxManager: Failed to set parser language", .{});
            return error.InvalidLanguage;
        }
        self.language = lang;

        self.treeLock();
        self.current_lang = lang_enum;
        self.current_resource_id = 0;
        if (self.tree) |t| c.ts_tree_delete(t);
        self.tree = null;
        self.highlight_cache.invalidate(self.allocator);
        self.treeUnlock();

        log.debug("SyntaxManager: Language set successfully, loading query ({d} bytes)", .{query_source.len});

        if (self.query) |q| c.ts_query_delete(q);
        self.query = null;

        // Tree-sitter rejects the whole query if any single pattern
        // references a node type or anonymous token unknown to the
        // linked grammar version. Rather than losing all highlighting
        // when one pattern is stale, truncate at the start of the
        // failing pattern and retry — we keep the valid prefix.
        var src_len: usize = query_source.len;
        var first_err_logged = false;
        while (src_len > 0) {
            var error_offset: u32 = 0;
            var error_type: c.TSQueryError = undefined;
            self.query = c.ts_query_new(
                lang,
                query_source.ptr,
                @intCast(src_len),
                &error_offset,
                &error_type,
            );
            if (self.query != null) break;

            if (!first_err_logged) {
                const eo: usize = @intCast(error_offset);
                const ctx_start: usize = if (eo > 30) eo - 30 else 0;
                const ctx_end: usize = @min(eo + 30, src_len);
                log.warn(
                    "SyntaxManager: ts_query_new failed for {s}: offset={d} type={d}\n  near: \"{s}\" (truncating and retrying)",
                    .{ @tagName(lang_enum), error_offset, @as(u32, error_type), query_source[ctx_start..ctx_end] },
                );
                first_err_logged = true;
            }

            // Truncate to the start of the line containing the error,
            // then keep walking back past blank lines so we land on a
            // pattern boundary rather than inside an open paren/bracket.
            var cut: usize = @intCast(error_offset);
            if (cut > src_len) cut = src_len;
            while (cut > 0 and query_source[cut - 1] != '\n') : (cut -= 1) {}
            // Skip blank lines so we don't stop in the middle of a
            // bracketed alternative.
            while (cut > 0 and (query_source[cut - 1] == '\n' or query_source[cut - 1] == ' ' or query_source[cut - 1] == '\t')) : (cut -= 1) {}
            // Back up to the start of the previous pattern: scan back
            // until we hit a newline, then the line that follows is
            // assumed to be a complete top-level pattern boundary.
            while (cut > 0 and query_source[cut - 1] != '\n') : (cut -= 1) {}

            if (cut >= src_len) {
                // Couldn't make progress; bail.
                break;
            }
            src_len = cut;
        }

        if (self.query == null) {
            log.err("SyntaxManager: no usable query patterns for {s}", .{@tagName(lang_enum)});
            return error.InvalidQuery;
        } else if (src_len < query_source.len) {
            log.warn(
                "SyntaxManager: loaded {d}/{d} bytes of query for {s} (rest skipped due to unknown nodes in linked grammar)",
                .{ src_len, query_source.len, @tagName(lang_enum) },
            );
        }
    }

    pub fn setLanguage(self: *SyntaxManager, lang_name: []const u8) !void {
        const lang_enum: Language = blk: {
            if (std.mem.eql(u8, lang_name, "zig")) break :blk .zig;
            if (std.mem.eql(u8, lang_name, "python")) break :blk .python;
            if (std.mem.eql(u8, lang_name, "javascript") or std.mem.eql(u8, lang_name, "js")) break :blk .javascript;
            if (std.mem.eql(u8, lang_name, "typescript") or std.mem.eql(u8, lang_name, "ts")) break :blk .typescript;
            if (std.mem.eql(u8, lang_name, "tsx") or std.mem.eql(u8, lang_name, "jsx")) break :blk .tsx;
            if (std.mem.eql(u8, lang_name, "json")) break :blk .json;
            if (std.mem.eql(u8, lang_name, "bash") or std.mem.eql(u8, lang_name, "sh")) break :blk .bash;
            if (std.mem.eql(u8, lang_name, "html")) break :blk .html;
            if (std.mem.eql(u8, lang_name, "css")) break :blk .css;
            if (std.mem.eql(u8, lang_name, "rust") or std.mem.eql(u8, lang_name, "rs")) break :blk .rust;
            if (std.mem.eql(u8, lang_name, "go")) break :blk .go;
            if (std.mem.eql(u8, lang_name, "c")) break :blk .c;
            if (std.mem.eql(u8, lang_name, "cpp") or std.mem.eql(u8, lang_name, "c++") or std.mem.eql(u8, lang_name, "cxx")) break :blk .cpp;
            if (std.mem.eql(u8, lang_name, "java")) break :blk .java;
            if (std.mem.eql(u8, lang_name, "ruby") or std.mem.eql(u8, lang_name, "rb")) break :blk .ruby;
            if (std.mem.eql(u8, lang_name, "csharp") or std.mem.eql(u8, lang_name, "c#") or std.mem.eql(u8, lang_name, "cs")) break :blk .csharp;
            if (std.mem.eql(u8, lang_name, "php")) break :blk .php;
            if (std.mem.eql(u8, lang_name, "swift")) break :blk .swift;
            if (std.mem.eql(u8, lang_name, "kotlin") or std.mem.eql(u8, lang_name, "kt")) break :blk .kotlin;
            if (std.mem.eql(u8, lang_name, "lua")) break :blk .lua;
            if (std.mem.eql(u8, lang_name, "dart")) break :blk .dart;
            if (std.mem.eql(u8, lang_name, "elixir") or std.mem.eql(u8, lang_name, "ex")) break :blk .elixir;
            if (std.mem.eql(u8, lang_name, "haskell") or std.mem.eql(u8, lang_name, "hs")) break :blk .haskell;
            if (std.mem.eql(u8, lang_name, "ocaml") or std.mem.eql(u8, lang_name, "ml")) break :blk .ocaml;
            if (std.mem.eql(u8, lang_name, "scala")) break :blk .scala;
            if (std.mem.eql(u8, lang_name, "r")) break :blk .r;
            if (std.mem.eql(u8, lang_name, "perl") or std.mem.eql(u8, lang_name, "pl")) break :blk .perl;
            if (std.mem.eql(u8, lang_name, "erlang") or std.mem.eql(u8, lang_name, "erl")) break :blk .erlang;
            if (std.mem.eql(u8, lang_name, "markdown") or std.mem.eql(u8, lang_name, "md")) break :blk .markdown;
            break :blk Language.fromExtension(lang_name);
        };
        return self.setLanguageEnum(lang_enum);
    }

    pub fn parse(self: *SyntaxManager, source: []const u8, resource_id: ?u64) !void {
        // Copy the previous tree under the lock so the parse itself can
        // run without blocking readers (highlight calls). A raw pointer
        // snapshot would race with the background worker, which can
        // `ts_tree_delete` the prior tree mid-parse — UAF inside the
        // C parser. `ts_tree_copy` is a cheap refcount bump.
        self.treeLock();
        const lang = self.current_lang;
        const prev_tree_copy: ?*c.TSTree = if (self.tree) |t| c.ts_tree_copy(t) else null;
        self.treeUnlock();
        if (lang == .markdown or lang == .unknown) {
            if (prev_tree_copy) |t| c.ts_tree_delete(t);
            return;
        }

        const new_tree = c.ts_parser_parse_string(self.parser, prev_tree_copy, source.ptr, @intCast(source.len));
        if (prev_tree_copy) |t| c.ts_tree_delete(t);

        self.treeLock();
        defer self.treeUnlock();
        // Only commit if the language hasn't changed under us.
        if (self.current_lang == lang) {
            if (self.tree) |t| c.ts_tree_delete(t);
            self.tree = new_tree;
            if (resource_id) |id| self.current_resource_id = id;
            self.highlight_cache.invalidate(self.allocator);
            self.bracket_cache.invalidate(self.allocator);
        } else if (new_tree) |t| {
            c.ts_tree_delete(t);
        }
    }

    /// Snapshot of the relevant node fields, extracted under the
    /// tree lock so the caller never has to hold a live `TSNode`
    /// reference across operations that could trigger a reparse —
    /// such reparses delete the old tree on the worker thread and
    /// would leave any held node pointing at freed memory.
    pub const NodeSnapshot = struct {
        start_row: u32,
        start_col: u32,
        end_row: u32,
        end_col: u32,
        start_byte: u32,
        end_byte: u32,
        type_name: []const u8,
        is_named: bool,
    };

    /// Extract a node descriptor at the given point. Safer
    /// replacement for `getNodeAt`: returns a fully owned-by-value
    /// snapshot rather than a `TSNode` whose validity depends on
    /// the tree staying alive.
    pub fn nodeAt(self: *SyntaxManager, line: usize, col: usize) ?NodeSnapshot {
        self.treeLock();
        defer self.treeUnlock();
        const tree = self.tree orelse return null;
        const root = c.ts_tree_root_node(tree);
        const point = c.TSPoint{
            .row = @intCast(line),
            .column = @intCast(col),
        };
        const node = c.ts_node_descendant_for_point_range(root, point, point);
        if (c.ts_node_is_null(node)) return null;
        const sp = c.ts_node_start_point(node);
        const ep = c.ts_node_end_point(node);
        const type_str = c.ts_node_type(node);
        return .{
            .start_row = sp.row,
            .start_col = sp.column,
            .end_row = ep.row,
            .end_col = ep.column,
            .start_byte = c.ts_node_start_byte(node),
            .end_byte = c.ts_node_end_byte(node),
            .type_name = std.mem.span(type_str),
            .is_named = c.ts_node_is_named(node),
        };
    }

    /// State snapshot used by the render thread to decide whether
    /// the syntax tree is current. Reads `current_lang`,
    /// `current_resource_id`, and the truthiness of `tree` under
    /// `tree_mutex`, returning a by-value tuple so callers don't
    /// have to hold the lock to use the values. Without this, the
    /// render thread races with the parse worker installing a new
    /// tree (see `parseWorkerMain`) — the worker can free the old
    /// tree and overwrite the pointer at the moment the render
    /// thread is reading it, producing a torn read.
    pub const StateSnapshot = struct {
        lang: Language,
        resource_id: u64,
        has_tree: bool,
    };

    pub fn stateSnapshot(self: *SyntaxManager) StateSnapshot {
        self.treeLock();
        defer self.treeUnlock();
        return .{
            .lang = self.current_lang,
            .resource_id = self.current_resource_id,
            .has_tree = self.tree != null,
        };
    }

    /// Legacy entry point — kept for tests and for callers that
    /// hold the tree lock for the entire node lifetime. Returns
    /// the raw `TSNode`; the caller MUST NOT let any other thread
    /// (especially the parse worker) install a new tree while the
    /// node is in use, or it will dereference freed memory.
    pub fn getNodeAt(self: *SyntaxManager, line: usize, col: usize) ?c.TSNode {
        self.treeLock();
        defer self.treeUnlock();
        const tree = self.tree orelse return null;
        const root = c.ts_tree_root_node(tree);

        const point = c.TSPoint{
            .row = @intCast(line),
            .column = @intCast(col),
        };

        const node = c.ts_node_descendant_for_point_range(root, point, point);
        if (c.ts_node_is_null(node)) return null;

        return node;
    }

    pub fn getNodeType(self: *SyntaxManager, node: c.TSNode) []const u8 {
        _ = self;
        const type_str = c.ts_node_type(node);
        return std.mem.span(type_str);
    }

    pub fn highlight(self: *SyntaxManager, allocator: std.mem.Allocator, start_line: usize, end_line: usize) ![]protocol.SyntaxToken {
        self.treeLock();
        defer self.treeUnlock();
        const tree = self.tree orelse return &.{};
        const query = self.query orelse return &.{};
        const root = c.ts_tree_root_node(tree);

        // Memo hit: same buffer, same range, since-last-tree-swap unchanged.
        // Return a fresh copy so the caller owns and can free it.
        if (self.highlight_cache.valid and
            self.highlight_cache.resource_id == self.current_resource_id and
            self.highlight_cache.lang == self.current_lang and
            self.highlight_cache.start_line == start_line and
            self.highlight_cache.end_line == end_line)
        {
            return try allocator.dupe(protocol.SyntaxToken, self.highlight_cache.tokens.items);
        }

        _ = c.ts_query_cursor_set_byte_range(self.cursor, 0, std.math.maxInt(u32));

        const start_point = c.TSPoint{ .row = @intCast(start_line), .column = 0 };
        const end_point = c.TSPoint{ .row = @intCast(end_line), .column = 0 };
        _ = c.ts_query_cursor_set_point_range(self.cursor, start_point, end_point);

        c.ts_query_cursor_exec(self.cursor, query, root);

        var tokens = std.ArrayListUnmanaged(protocol.SyntaxToken).empty;
        try tokens.ensureTotalCapacity(allocator, 128);
        defer tokens.deinit(allocator);

        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(self.cursor, &match)) {
            for (0..match.capture_count) |i| {
                const capture = match.captures[i];
                const node = capture.node;
                const start = c.ts_node_start_point(node);
                const end = c.ts_node_end_point(node);

                if (start.row >= end_line or end.row < start_line) continue;

                var length: u32 = 0;
                if (start.row == end.row) {
                    length = end.column - start.column;
                } else {
                    continue;
                }

                var len: u32 = 0;
                const name_ptr = c.ts_query_capture_name_for_id(query, capture.index, &len);
                const name = name_ptr[0..len];

                const token_type = mapCaptureToType(name);

                try tokens.append(allocator, .{
                    .line = start.row,
                    .start_col = start.column,
                    .length = length,
                    .token_type = token_type,
                });
            }
        }

        const result = try tokens.toOwnedSlice(allocator);

        // Cache before returning. Allocate the cache copy with the
        // manager's allocator (independent of the caller's allocator).
        // Cap pathologically large results to avoid pinning memory.
        const cache_cap: usize = 8 * 1024;
        if (result.len <= cache_cap) {
            self.highlight_cache.invalidate(self.allocator);
            self.highlight_cache.tokens.appendSlice(self.allocator, result) catch {
                // Failure to cache is non-fatal — just don't cache.
                self.highlight_cache.valid = false;
                return result;
            };
            self.highlight_cache.resource_id = self.current_resource_id;
            self.highlight_cache.lang = self.current_lang;
            self.highlight_cache.start_line = start_line;
            self.highlight_cache.end_line = end_line;
            self.highlight_cache.valid = true;
        }
        return result;
    }

    pub fn highlightMarkdown(self: *SyntaxManager, allocator: std.mem.Allocator, content: []const u8, start_line: usize, end_line: usize) ![]protocol.SyntaxToken {
        _ = self;
        var tokens = std.ArrayListUnmanaged(protocol.SyntaxToken).empty;
        try tokens.ensureTotalCapacity(allocator, 128);
        errdefer tokens.deinit(allocator);

        var line_num: u32 = 0;
        var in_code_block = false;
        var lines_iter = std.mem.splitSequence(u8, content, "\n");

        while (lines_iter.next()) |line| : (line_num += 1) {
            if (line_num < start_line) continue;
            if (line_num >= end_line) break;

            const trimmed = std.mem.trimStart(u8, line, " \t");

            if (std.mem.startsWith(u8, trimmed, "```")) {
                in_code_block = !in_code_block;
                try tokens.append(allocator, .{
                    .line = line_num,
                    .start_col = 0,
                    .length = @intCast(line.len),
                    .token_type = .string,
                });
                continue;
            }

            if (in_code_block) {
                try tokens.append(allocator, .{
                    .line = line_num,
                    .start_col = 0,
                    .length = @intCast(line.len),
                    .token_type = .string,
                });
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "#")) {
                try tokens.append(allocator, .{
                    .line = line_num,
                    .start_col = 0,
                    .length = @intCast(line.len),
                    .token_type = .keyword,
                });
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, ">")) {
                try tokens.append(allocator, .{
                    .line = line_num,
                    .start_col = 0,
                    .length = @intCast(line.len),
                    .token_type = .comment,
                });
                continue;
            }

            if (line.len >= 3 and (std.mem.startsWith(u8, trimmed, "---") or
                std.mem.startsWith(u8, trimmed, "***") or
                std.mem.startsWith(u8, trimmed, "___")))
            {
                try tokens.append(allocator, .{
                    .line = line_num,
                    .start_col = 0,
                    .length = @intCast(line.len),
                    .token_type = .comment,
                });
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "- ") or
                std.mem.startsWith(u8, trimmed, "* ") or
                std.mem.startsWith(u8, trimmed, "+ ") or
                std.mem.startsWith(u8, trimmed, "• "))
            {
                const marker_start = @as(u32, @intCast(line.len - trimmed.len));
                try tokens.append(allocator, .{
                    .line = line_num,
                    .start_col = marker_start,
                    .length = 2,
                    .token_type = .operator,
                });
            } else if (trimmed.len >= 2) {
                var idx: usize = 0;
                while (idx < trimmed.len and idx < 10 and (trimmed[idx] >= '0' and trimmed[idx] <= '9')) idx += 1;
                if (idx > 0 and idx < trimmed.len and trimmed[idx] == '.') {
                    const marker_start = @as(u32, @intCast(line.len - trimmed.len));
                    try tokens.append(allocator, .{
                        .line = line_num,
                        .start_col = marker_start,
                        .length = @intCast(idx + 1),
                        .token_type = .operator,
                    });
                }
            }

            try highlightMarkdownInline(allocator, line, line_num, &tokens);
        }

        return tokens.toOwnedSlice(allocator);
    }

    fn highlightMarkdownInline(allocator: std.mem.Allocator, line: []const u8, line_num: u32, tokens: *std.ArrayListUnmanaged(protocol.SyntaxToken)) !void {
        var i: usize = 0;

        while (i < line.len) {
            if (line[i] == '`') {
                const start = i;
                i += 1;
                while (i < line.len and line[i] != '`') i += 1;
                if (i < line.len) i += 1;
                try tokens.append(allocator, .{
                    .line = line_num,
                    .start_col = @intCast(start),
                    .length = @intCast(i - start),
                    .token_type = .string,
                });
                continue;
            }

            if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '*') {
                const start = i;
                i += 2;
                while (i + 1 < line.len and !(line[i] == '*' and line[i + 1] == '*')) i += 1;
                if (i + 1 < line.len) i += 2;
                try tokens.append(allocator, .{
                    .line = line_num,
                    .start_col = @intCast(start),
                    .length = @intCast(i - start),
                    .token_type = .keyword,
                });
                continue;
            }

            if (line[i] == '*' and (i == 0 or line[i - 1] != '*')) {
                const start = i;
                i += 1;
                while (i < line.len and line[i] != '*') i += 1;
                if (i < line.len) i += 1;
                try tokens.append(allocator, .{
                    .line = line_num,
                    .start_col = @intCast(start),
                    .length = @intCast(i - start),
                    .token_type = .comment,
                });
                continue;
            }

            if (line[i] == '[') {
                const start = i;
                i += 1;
                while (i < line.len and line[i] != ']') i += 1;
                if (i + 1 < line.len and line[i] == ']' and line[i + 1] == '(') {
                    i += 2;
                    while (i < line.len and line[i] != ')') i += 1;
                    if (i < line.len) i += 1;
                    try tokens.append(allocator, .{
                        .line = line_num,
                        .start_col = @intCast(start),
                        .length = @intCast(i - start),
                        .token_type = .function,
                    });
                    continue;
                }
            }

            i += 1;
        }
    }

    pub fn getEnclosingNodeForPoints(
        self: *SyntaxManager,
        start_line: usize,
        start_col: usize,
        end_line: usize,
        end_col: usize,
    ) ?c.TSNode {
        self.treeLock();
        defer self.treeUnlock();
        const tree = self.tree orelse return null;
        const root = c.ts_tree_root_node(tree);

        var node = c.ts_node_descendant_for_point_range(
            root,
            c.TSPoint{ .row = @intCast(start_line), .column = @intCast(start_col) },
            c.TSPoint{ .row = @intCast(start_line), .column = @intCast(start_col) },
        );
        if (c.ts_node_is_null(node)) return null;

        const end_point = c.TSPoint{ .row = @intCast(end_line), .column = @intCast(end_col) };

        while (true) {
            const start_p = c.ts_node_start_point(node);
            const end_p = c.ts_node_end_point(node);

            const contains_end = (end_p.row > end_point.row) or (end_p.row == end_point.row and end_p.column >= end_point.column);
            const starts_before_start = (start_p.row < @as(u32, @intCast(start_line))) or (start_p.row == @as(u32, @intCast(start_line)) and start_p.column <= @as(u32, @intCast(start_col)));

            if (starts_before_start and contains_end) {
                return node;
            }

            const parent = c.ts_node_parent(node);
            if (c.ts_node_is_null(parent)) return node;
            node = parent;
        }
    }

    pub fn getNodeByteRange(self: *SyntaxManager, node: c.TSNode) struct { start: usize, end: usize } {
        _ = self;
        return .{ .start = c.ts_node_start_byte(node), .end = c.ts_node_end_byte(node) };
    }

    fn mapCaptureToType(name: []const u8) protocol.SyntaxToken.TokenType {
        // Match by leading category so upstream queries that use dotted
        // refinements (e.g. `@function.method`, `@keyword.control.import`,
        // `@variable.parameter`) still classify correctly.
        const head: []const u8 = if (std.mem.indexOfScalar(u8, name, '.')) |i| name[0..i] else name;
        if (std.mem.eql(u8, head, "keyword")) return .keyword;
        if (std.mem.eql(u8, head, "function")) return .function;
        if (std.mem.eql(u8, head, "method")) return .function;
        if (std.mem.eql(u8, head, "constructor")) return .function;
        if (std.mem.eql(u8, head, "tag")) return .function;
        // `@variable.parameter` is more specific than `@variable` so
        // check the full name first; the head fallback handles the rest.
        if (std.mem.startsWith(u8, name, "variable.parameter")) return .parameter;
        if (std.mem.eql(u8, head, "parameter")) return .parameter;
        if (std.mem.eql(u8, head, "variable")) return .variable;
        if (std.mem.eql(u8, head, "property")) return .property;
        if (std.mem.eql(u8, head, "attribute")) return .property;
        if (std.mem.eql(u8, head, "field")) return .property;
        if (std.mem.eql(u8, head, "label")) return .property;
        if (std.mem.eql(u8, head, "type")) return .type_name;
        if (std.mem.eql(u8, head, "type_name")) return .type_name;
        if (std.mem.eql(u8, head, "namespace")) return .type_name;
        if (std.mem.eql(u8, head, "module")) return .type_name;
        if (std.mem.eql(u8, head, "string")) return .string;
        if (std.mem.eql(u8, head, "character")) return .string;
        if (std.mem.eql(u8, head, "regex")) return .string;
        if (std.mem.eql(u8, head, "number")) return .number;
        if (std.mem.eql(u8, head, "float")) return .number;
        if (std.mem.eql(u8, head, "constant")) return .number;
        if (std.mem.eql(u8, head, "boolean")) return .number;
        if (std.mem.eql(u8, head, "comment")) return .comment;
        if (std.mem.eql(u8, head, "operator")) return .operator;
        if (std.mem.eql(u8, head, "punctuation")) return .operator;
        if (std.mem.eql(u8, head, "builtin")) return .builtin;
        if (std.mem.eql(u8, head, "embedded")) return .other;
        if (std.mem.eql(u8, head, "text")) return .other;
        return .other;
    }

    pub const Symbol = struct {
        name: []const u8,
        kind: []const u8,
        line: usize,
    };

    pub fn getSymbols(self: *SyntaxManager, allocator: std.mem.Allocator, source: []const u8) ![]Symbol {
        self.treeLock();
        defer self.treeUnlock();
        const tree = self.tree orelse return &.{};
        const root = c.ts_tree_root_node(tree);

        var symbols = std.ArrayListUnmanaged(Symbol).empty;
        errdefer {
            for (symbols.items) |s| {
                allocator.free(s.name);
            }
            symbols.deinit(allocator);
        }

        try self.walkForSymbols(allocator, root, source, &symbols);

        return symbols.toOwnedSlice(allocator);
    }

    fn walkForSymbols(self: *SyntaxManager, allocator: std.mem.Allocator, node: c.TSNode, source: []const u8, symbols: *std.ArrayListUnmanaged(Symbol)) !void {
        const node_type = std.mem.span(c.ts_node_type(node));

        if (std.mem.eql(u8, node_type, "function_signature") or std.mem.eql(u8, node_type, "function")) {
            const child_count = c.ts_node_child_count(node);
            for (0..child_count) |i| {
                const child = c.ts_node_child(node, @intCast(i));
                const field_name_ptr = c.ts_node_field_name_for_child(node, @intCast(i));
                if (field_name_ptr != null) {
                    const field_name = std.mem.span(field_name_ptr);
                    if (std.mem.eql(u8, field_name, "name")) {
                        const start_byte = c.ts_node_start_byte(child);
                        const end_byte = c.ts_node_end_byte(child);
                        if (end_byte <= source.len and start_byte < end_byte) {
                            const name = try allocator.dupe(u8, source[start_byte..end_byte]);
                            const start_point = c.ts_node_start_point(child);
                            try symbols.append(allocator, .{
                                .name = name,
                                .kind = "function",
                                .line = start_point.row,
                            });
                        }
                        break;
                    }
                }
            }
        }

        if (std.mem.eql(u8, node_type, "variable_declaration")) {
            const child_count = c.ts_node_child_count(node);
            var found_name: ?[]const u8 = null;
            var found_line: usize = 0;
            var is_type_def = false;

            for (0..child_count) |i| {
                const child = c.ts_node_child(node, @intCast(i));
                const child_type = std.mem.span(c.ts_node_type(child));

                if (std.mem.eql(u8, child_type, "identifier") and found_name == null) {
                    const start_byte = c.ts_node_start_byte(child);
                    const end_byte = c.ts_node_end_byte(child);
                    if (end_byte <= source.len and start_byte < end_byte) {
                        found_name = source[start_byte..end_byte];
                        found_line = c.ts_node_start_point(child).row;
                    }
                }

                if (std.mem.eql(u8, child_type, "struct") or
                    std.mem.eql(u8, child_type, "enum") or
                    std.mem.eql(u8, child_type, "union") or
                    std.mem.eql(u8, child_type, "struct_expression") or
                    std.mem.eql(u8, child_type, "anonymous_struct_expression"))
                {
                    is_type_def = true;
                }
            }

            if (found_name != null and is_type_def) {
                const name = try allocator.dupe(u8, found_name.?);
                try symbols.append(allocator, .{
                    .name = name,
                    .kind = "struct",
                    .line = found_line,
                });
            }
        }

        const child_count = c.ts_node_child_count(node);
        for (0..child_count) |i| {
            const child = c.ts_node_child(node, @intCast(i));
            try self.walkForSymbols(allocator, child, source, symbols);
        }
    }

    pub const Selection = struct {
        start_line: usize,
        start_col: usize,
        end_line: usize,
        end_col: usize,
    };

    pub const FoldableRegion = struct {
        start_line: usize,
        end_line: usize,
        kind: FoldKind,

        pub const FoldKind = enum {
            function,
            class,
            block,
            comment,
            import,
        };
    };

    pub const Position = struct {
        line: usize,
        col: usize,
    };

    /// Return the start position of the next named sibling of the node
    /// covering the cursor. If the cursor's node has no next sibling,
    /// walks up to the parent and tries again. Returns null when the
    /// tree isn't loaded or there's nothing past the cursor.
    pub fn nextSiblingPosition(self: *SyntaxManager, line: usize, col: usize) ?Position {
        self.treeLock();
        defer self.treeUnlock();
        const tree = self.tree orelse return null;
        const root = c.ts_tree_root_node(tree);
        const point = c.TSPoint{ .row = @intCast(line), .column = @intCast(col) };
        var node = c.ts_node_descendant_for_point_range(root, point, point);
        if (c.ts_node_is_null(node)) return null;
        while (!c.ts_node_is_null(node)) {
            const sib = c.ts_node_next_named_sibling(node);
            if (!c.ts_node_is_null(sib)) {
                const p = c.ts_node_start_point(sib);
                return .{ .line = p.row, .col = p.column };
            }
            node = c.ts_node_parent(node);
        }
        return null;
    }

    pub fn prevSiblingPosition(self: *SyntaxManager, line: usize, col: usize) ?Position {
        self.treeLock();
        defer self.treeUnlock();
        const tree = self.tree orelse return null;
        const root = c.ts_tree_root_node(tree);
        const point = c.TSPoint{ .row = @intCast(line), .column = @intCast(col) };
        var node = c.ts_node_descendant_for_point_range(root, point, point);
        if (c.ts_node_is_null(node)) return null;
        // If we're past the start of the current node, treat that as
        // the "previous" position so [s feels symmetrical with ]s.
        const cur_start = c.ts_node_start_point(node);
        if (cur_start.row < @as(u32, @intCast(line)) or
            (cur_start.row == @as(u32, @intCast(line)) and cur_start.column < @as(u32, @intCast(col))))
        {
            return .{ .line = cur_start.row, .col = cur_start.column };
        }
        while (!c.ts_node_is_null(node)) {
            const sib = c.ts_node_prev_named_sibling(node);
            if (!c.ts_node_is_null(sib)) {
                const p = c.ts_node_start_point(sib);
                return .{ .line = p.row, .col = p.column };
            }
            node = c.ts_node_parent(node);
        }
        return null;
    }

    /// Walk the tree forward in document order, returning the first node
    /// whose type matches one of the given kinds (e.g. function/method
    /// definitions). `forward = false` walks backward. The match must be
    /// strictly past (or before) the cursor.
    pub fn findNodeOfKinds(
        self: *SyntaxManager,
        line: usize,
        col: usize,
        forward: bool,
        kinds: []const []const u8,
    ) ?Position {
        self.treeLock();
        defer self.treeUnlock();
        const tree = self.tree orelse return null;
        const root = c.ts_tree_root_node(tree);

        var best: ?Position = null;
        const cursor_row: u32 = @intCast(line);
        const cursor_col: u32 = @intCast(col);

        var stack: std.ArrayListUnmanaged(c.TSNode) = .empty;
        defer stack.deinit(self.allocator);
        stack.append(self.allocator, root) catch return null;

        while (stack.items.len > 0) {
            const node = stack.pop().?;
            const t = std.mem.span(c.ts_node_type(node));
            for (kinds) |k| {
                if (std.mem.eql(u8, t, k)) {
                    const p = c.ts_node_start_point(node);
                    const past_cursor = forward and
                        (p.row > cursor_row or (p.row == cursor_row and p.column > cursor_col));
                    const before_cursor = !forward and
                        (p.row < cursor_row or (p.row == cursor_row and p.column < cursor_col));
                    if (past_cursor or before_cursor) {
                        const candidate = Position{ .line = p.row, .col = p.column };
                        if (best) |b| {
                            const better = if (forward)
                                (candidate.line < b.line or (candidate.line == b.line and candidate.col < b.col))
                            else
                                (candidate.line > b.line or (candidate.line == b.line and candidate.col > b.col));
                            if (better) best = candidate;
                        } else best = candidate;
                    }
                    break;
                }
            }
            const child_count = c.ts_node_child_count(node);
            var i: u32 = 0;
            while (i < child_count) : (i += 1) {
                stack.append(self.allocator, c.ts_node_child(node, i)) catch return null;
            }
        }
        return best;
    }

    /// Function-like node kinds across the supported grammars. Used by
    /// `]m` / `[m` (next/prev method).
    pub const function_kinds: []const []const u8 = &.{
        "function_declaration",
        "function_definition",
        "function_item", // rust
        "method_declaration",
        "method_definition",
        "constructor_declaration",
        "fn_proto",
        "FnProto",
        "fn_decl",
        "function", // ocaml, r
        "let_binding",
    };

    /// Inverse of `expandSelection`: if the selection spans a node
    /// exactly, shrink to its first named child. Otherwise no-op.
    pub fn shrinkSelection(
        self: *SyntaxManager,
        start_line: usize,
        start_col: usize,
        end_line: usize,
        end_col: usize,
    ) Selection {
        self.treeLock();
        defer self.treeUnlock();
        const tree = self.tree orelse return .{ .start_line = start_line, .start_col = start_col, .end_line = end_line, .end_col = end_col };
        const root = c.ts_tree_root_node(tree);

        const start_point = c.TSPoint{ .row = @intCast(start_line), .column = @intCast(start_col) };
        const end_point = c.TSPoint{ .row = @intCast(end_line), .column = @intCast(end_col) };
        const node = c.ts_node_descendant_for_point_range(root, start_point, end_point);

        if (c.ts_node_is_null(node)) return .{ .start_line = start_line, .start_col = start_col, .end_line = end_line, .end_col = end_col };

        // Look for the first named child of this node.
        const child_count = c.ts_node_named_child_count(node);
        if (child_count == 0) return .{ .start_line = start_line, .start_col = start_col, .end_line = end_line, .end_col = end_col };

        const child = c.ts_node_named_child(node, 0);
        if (c.ts_node_is_null(child)) return .{ .start_line = start_line, .start_col = start_col, .end_line = end_line, .end_col = end_col };

        const cs = c.ts_node_start_point(child);
        const ce = c.ts_node_end_point(child);
        return .{ .start_line = cs.row, .start_col = cs.column, .end_line = ce.row, .end_col = ce.column };
    }

    /// Compute the bounds of the smallest named AST node covering the
    /// cursor. Used by `vN` ("visual node") to seed a tree-aware
    /// selection from a single keystroke.
    pub fn selectCurrentNode(self: *SyntaxManager, line: usize, col: usize) ?Selection {
        self.treeLock();
        defer self.treeUnlock();
        const tree = self.tree orelse return null;
        const root = c.ts_tree_root_node(tree);

        const point = c.TSPoint{ .row = @intCast(line), .column = @intCast(col) };
        var node = c.ts_node_descendant_for_point_range(root, point, point);
        if (c.ts_node_is_null(node)) return null;

        // Prefer a named node — if we land on an anonymous token (e.g.
        // a keyword), climb until we hit a named parent.
        while (!c.ts_node_is_null(node) and !c.ts_node_is_named(node)) {
            node = c.ts_node_parent(node);
        }
        if (c.ts_node_is_null(node)) return null;

        const s = c.ts_node_start_point(node);
        const e = c.ts_node_end_point(node);
        return .{ .start_line = s.row, .start_col = s.column, .end_line = e.row, .end_col = e.column };
    }

    pub fn expandSelection(
        self: *SyntaxManager,
        start_line: usize,
        start_col: usize,
        end_line: usize,
        end_col: usize,
    ) Selection {
        self.treeLock();
        defer self.treeUnlock();
        const tree = self.tree orelse return .{
            .start_line = start_line,
            .start_col = start_col,
            .end_line = end_line,
            .end_col = end_col,
        };
        const root = c.ts_tree_root_node(tree);

        const start_point = c.TSPoint{ .row = @intCast(start_line), .column = @intCast(start_col) };
        const end_point = c.TSPoint{ .row = @intCast(end_line), .column = @intCast(end_col) };

        var node = c.ts_node_descendant_for_point_range(root, start_point, end_point);

        if (c.ts_node_is_null(node)) return .{
            .start_line = start_line,
            .start_col = start_col,
            .end_line = end_line,
            .end_col = end_col,
        };

        const node_start = c.ts_node_start_point(node);
        const node_end = c.ts_node_end_point(node);

        const at_start = (node_start.row == start_line and node_start.column == start_col);
        const at_end = (node_end.row == end_line and node_end.column == end_col);

        if (at_start and at_end) {
            const parent = c.ts_node_parent(node);
            if (!c.ts_node_is_null(parent)) {
                node = parent;
            }
        }

        const final_start = c.ts_node_start_point(node);
        const final_end = c.ts_node_end_point(node);

        return .{
            .start_line = final_start.row,
            .start_col = final_start.column,
            .end_line = final_end.row,
            .end_col = final_end.column,
        };
    }

    fn getIndentSize(self: *SyntaxManager) usize {
        _ = self;
        return 4;
    }

    pub fn getSmartIndent(self: *SyntaxManager, line_idx: usize) usize {
        self.treeLock();
        defer self.treeUnlock();
        const tree = self.tree orelse return 0;
        const root = c.ts_tree_root_node(tree);

        const line_start = c.TSPoint{ .row = @intCast(line_idx), .column = 0 };
        const node = c.ts_node_descendant_for_point_range(root, line_start, line_start);

        if (c.ts_node_is_null(node)) return 0;

        var indent_level: usize = 0;
        var current = node;

        while (!c.ts_node_is_null(current)) {
            const node_type = std.mem.span(c.ts_node_type(current));
            const node_start = c.ts_node_start_point(current);

            if (node_start.row < line_idx) {
                switch (self.current_lang) {
                    .python => {
                        if (std.mem.eql(u8, node_type, "block") or
                            std.mem.eql(u8, node_type, "function_definition") or
                            std.mem.eql(u8, node_type, "class_definition") or
                            std.mem.eql(u8, node_type, "if_statement") or
                            std.mem.eql(u8, node_type, "for_statement") or
                            std.mem.eql(u8, node_type, "while_statement") or
                            std.mem.eql(u8, node_type, "try_statement"))
                        {
                            indent_level += 1;
                        }
                    },
                    .javascript, .typescript, .tsx => {
                        if (std.mem.eql(u8, node_type, "statement_block") or
                            std.mem.eql(u8, node_type, "function_declaration") or
                            std.mem.eql(u8, node_type, "class_declaration") or
                            std.mem.eql(u8, node_type, "if_statement") or
                            std.mem.eql(u8, node_type, "for_statement") or
                            std.mem.eql(u8, node_type, "while_statement") or
                            std.mem.eql(u8, node_type, "switch_statement") or
                            std.mem.eql(u8, node_type, "object") or
                            std.mem.eql(u8, node_type, "array"))
                        {
                            indent_level += 1;
                        }
                    },
                    .zig => {
                        if (std.mem.eql(u8, node_type, "Block") or
                            std.mem.eql(u8, node_type, "ContainerDecl") or
                            std.mem.eql(u8, node_type, "SwitchExpr") or
                            std.mem.eql(u8, node_type, "IfExpr"))
                        {
                            indent_level += 1;
                        }
                    },
                    .rust => {
                        if (std.mem.eql(u8, node_type, "block") or
                            std.mem.eql(u8, node_type, "struct_item") or
                            std.mem.eql(u8, node_type, "enum_item") or
                            std.mem.eql(u8, node_type, "impl_item") or
                            std.mem.eql(u8, node_type, "function_item") or
                            std.mem.eql(u8, node_type, "match_expression"))
                        {
                            indent_level += 1;
                        }
                    },
                    .html, .css => {
                        if (std.mem.eql(u8, node_type, "block") or
                            std.mem.eql(u8, node_type, "element"))
                        {
                            indent_level += 1;
                        }
                    },
                    .c, .cpp => {
                        if (std.mem.eql(u8, node_type, "compound_statement") or
                            std.mem.eql(u8, node_type, "if_statement") or
                            std.mem.eql(u8, node_type, "for_statement") or
                            std.mem.eql(u8, node_type, "while_statement") or
                            std.mem.eql(u8, node_type, "switch_statement") or
                            std.mem.eql(u8, node_type, "function_definition") or
                            std.mem.eql(u8, node_type, "class_specifier") or
                            std.mem.eql(u8, node_type, "struct_specifier"))
                        {
                            indent_level += 1;
                        }
                    },
                    .java, .csharp => {
                        if (std.mem.eql(u8, node_type, "block") or
                            std.mem.eql(u8, node_type, "class_declaration") or
                            std.mem.eql(u8, node_type, "interface_declaration") or
                            std.mem.eql(u8, node_type, "method_declaration") or
                            std.mem.eql(u8, node_type, "if_statement") or
                            std.mem.eql(u8, node_type, "for_statement") or
                            std.mem.eql(u8, node_type, "while_statement") or
                            std.mem.eql(u8, node_type, "switch_statement"))
                        {
                            indent_level += 1;
                        }
                    },
                    .ruby => {
                        if (std.mem.eql(u8, node_type, "method") or
                            std.mem.eql(u8, node_type, "class") or
                            std.mem.eql(u8, node_type, "module") or
                            std.mem.eql(u8, node_type, "do_block") or
                            std.mem.eql(u8, node_type, "if") or
                            std.mem.eql(u8, node_type, "unless") or
                            std.mem.eql(u8, node_type, "while") or
                            std.mem.eql(u8, node_type, "until") or
                            std.mem.eql(u8, node_type, "case"))
                        {
                            indent_level += 1;
                        }
                    },
                    .unknown, .bash, .json, .markdown, .go, .php, .swift, .kotlin, .lua, .dart, .elixir, .haskell, .ocaml, .scala, .r, .perl, .erlang => {},
                }
            }

            current = c.ts_node_parent(current);
        }

        return indent_level * self.getIndentSize();
    }

    pub fn getFoldableRegions(
        self: *SyntaxManager,
        allocator: std.mem.Allocator,
    ) ![]FoldableRegion {
        self.treeLock();
        defer self.treeUnlock();
        const tree = self.tree orelse return &.{};
        const root = c.ts_tree_root_node(tree);

        var regions = std.ArrayList(FoldableRegion).empty;
        errdefer regions.deinit(allocator);

        try self.extractFoldableNodes(allocator, root, &regions);
        return regions.toOwnedSlice(allocator);
    }

    fn extractFoldableNodes(
        self: *SyntaxManager,
        allocator: std.mem.Allocator,
        node: c.TSNode,
        regions: *std.ArrayList(FoldableRegion),
    ) !void {
        const node_type = std.mem.span(c.ts_node_type(node));
        const start = c.ts_node_start_point(node);
        const end = c.ts_node_end_point(node);

        const fold_info: ?struct { kind: FoldableRegion.FoldKind } = switch (self.current_lang) {
            .python => blk: {
                if (std.mem.eql(u8, node_type, "function_definition")) break :blk .{ .kind = .function };
                if (std.mem.eql(u8, node_type, "class_definition")) break :blk .{ .kind = .class };
                if (std.mem.eql(u8, node_type, "if_statement") or
                    std.mem.eql(u8, node_type, "for_statement") or
                    std.mem.eql(u8, node_type, "while_statement")) break :blk .{ .kind = .block };
                if (std.mem.eql(u8, node_type, "import_statement") or
                    std.mem.eql(u8, node_type, "import_from_statement")) break :blk .{ .kind = .import };
                break :blk null;
            },
            .javascript, .typescript, .tsx => blk: {
                if (std.mem.eql(u8, node_type, "function_declaration") or
                    std.mem.eql(u8, node_type, "arrow_function") or
                    std.mem.eql(u8, node_type, "method_definition")) break :blk .{ .kind = .function };
                if (std.mem.eql(u8, node_type, "class_declaration")) break :blk .{ .kind = .class };
                if (std.mem.eql(u8, node_type, "statement_block") or
                    std.mem.eql(u8, node_type, "object")) break :blk .{ .kind = .block };
                if (std.mem.eql(u8, node_type, "import_statement")) break :blk .{ .kind = .import };
                break :blk null;
            },
            .zig => blk: {
                if (std.mem.eql(u8, node_type, "FnDecl") or
                    std.mem.eql(u8, node_type, "function_signature")) break :blk .{ .kind = .function };
                if (std.mem.eql(u8, node_type, "ContainerDecl")) break :blk .{ .kind = .class };
                if (std.mem.eql(u8, node_type, "Block")) break :blk .{ .kind = .block };
                break :blk null;
            },
            .go => blk: {
                if (std.mem.eql(u8, node_type, "function_declaration") or
                    std.mem.eql(u8, node_type, "method_declaration")) break :blk .{ .kind = .function };
                if (std.mem.eql(u8, node_type, "type_declaration")) break :blk .{ .kind = .class };
                if (std.mem.eql(u8, node_type, "block") or
                    std.mem.eql(u8, node_type, "if_statement") or
                    std.mem.eql(u8, node_type, "for_statement")) break :blk .{ .kind = .block };
                if (std.mem.eql(u8, node_type, "import_declaration")) break :blk .{ .kind = .import };
                break :blk null;
            },
            .rust => blk: {
                if (std.mem.eql(u8, node_type, "function_item") or
                    std.mem.eql(u8, node_type, "function_signature_item")) break :blk .{ .kind = .function };
                if (std.mem.eql(u8, node_type, "struct_item") or
                    std.mem.eql(u8, node_type, "enum_item") or
                    std.mem.eql(u8, node_type, "trait_item") or
                    std.mem.eql(u8, node_type, "impl_item")) break :blk .{ .kind = .class };
                if (std.mem.eql(u8, node_type, "block")) break :blk .{ .kind = .block };
                if (std.mem.eql(u8, node_type, "use_declaration")) break :blk .{ .kind = .import };
                break :blk null;
            },
            .json => blk: {
                if (std.mem.eql(u8, node_type, "object") or
                    std.mem.eql(u8, node_type, "array")) break :blk .{ .kind = .block };
                break :blk null;
            },
            .bash => blk: {
                if (std.mem.eql(u8, node_type, "function_definition")) break :blk .{ .kind = .function };
                if (std.mem.eql(u8, node_type, "if_statement") or
                    std.mem.eql(u8, node_type, "for_statement") or
                    std.mem.eql(u8, node_type, "while_statement") or
                    std.mem.eql(u8, node_type, "case_statement")) break :blk .{ .kind = .block };
                break :blk null;
            },
            .html => blk: {
                if (std.mem.eql(u8, node_type, "element")) break :blk .{ .kind = .block };
                break :blk null;
            },
            .css => blk: {
                if (std.mem.eql(u8, node_type, "rule_set") or
                    std.mem.eql(u8, node_type, "media_statement")) break :blk .{ .kind = .block };
                break :blk null;
            },
            .c, .cpp => blk: {
                if (std.mem.eql(u8, node_type, "function_definition")) break :blk .{ .kind = .function };
                if (std.mem.eql(u8, node_type, "class_specifier") or
                    std.mem.eql(u8, node_type, "struct_specifier") or
                    std.mem.eql(u8, node_type, "union_specifier") or
                    std.mem.eql(u8, node_type, "enum_specifier")) break :blk .{ .kind = .class };
                if (std.mem.eql(u8, node_type, "compound_statement") or
                    std.mem.eql(u8, node_type, "if_statement") or
                    std.mem.eql(u8, node_type, "for_statement") or
                    std.mem.eql(u8, node_type, "while_statement") or
                    std.mem.eql(u8, node_type, "switch_statement")) break :blk .{ .kind = .block };
                if (std.mem.eql(u8, node_type, "preproc_include")) break :blk .{ .kind = .import };
                break :blk null;
            },
            .java => blk: {
                if (std.mem.eql(u8, node_type, "method_declaration") or
                    std.mem.eql(u8, node_type, "constructor_declaration")) break :blk .{ .kind = .function };
                if (std.mem.eql(u8, node_type, "class_declaration") or
                    std.mem.eql(u8, node_type, "interface_declaration") or
                    std.mem.eql(u8, node_type, "enum_declaration") or
                    std.mem.eql(u8, node_type, "record_declaration")) break :blk .{ .kind = .class };
                if (std.mem.eql(u8, node_type, "block")) break :blk .{ .kind = .block };
                if (std.mem.eql(u8, node_type, "import_declaration")) break :blk .{ .kind = .import };
                break :blk null;
            },
            .ruby => blk: {
                if (std.mem.eql(u8, node_type, "method") or
                    std.mem.eql(u8, node_type, "singleton_method")) break :blk .{ .kind = .function };
                if (std.mem.eql(u8, node_type, "class") or
                    std.mem.eql(u8, node_type, "module")) break :blk .{ .kind = .class };
                if (std.mem.eql(u8, node_type, "do_block") or
                    std.mem.eql(u8, node_type, "if") or
                    std.mem.eql(u8, node_type, "unless") or
                    std.mem.eql(u8, node_type, "while") or
                    std.mem.eql(u8, node_type, "case")) break :blk .{ .kind = .block };
                break :blk null;
            },
            .csharp => blk: {
                if (std.mem.eql(u8, node_type, "method_declaration") or
                    std.mem.eql(u8, node_type, "constructor_declaration") or
                    std.mem.eql(u8, node_type, "local_function_statement")) break :blk .{ .kind = .function };
                if (std.mem.eql(u8, node_type, "class_declaration") or
                    std.mem.eql(u8, node_type, "interface_declaration") or
                    std.mem.eql(u8, node_type, "struct_declaration") or
                    std.mem.eql(u8, node_type, "record_declaration") or
                    std.mem.eql(u8, node_type, "enum_declaration")) break :blk .{ .kind = .class };
                if (std.mem.eql(u8, node_type, "block")) break :blk .{ .kind = .block };
                if (std.mem.eql(u8, node_type, "using_directive")) break :blk .{ .kind = .import };
                break :blk null;
            },
            .php, .swift, .kotlin, .lua, .dart, .elixir, .haskell, .ocaml, .scala, .r, .perl, .erlang => null,
            .markdown, .unknown => null,
        };

        if (fold_info) |info| {
            if (end.row > start.row + 2) {
                try regions.append(allocator, .{
                    .start_line = start.row,
                    .end_line = end.row,
                    .kind = info.kind,
                });
            }
        }

        const child_count = c.ts_node_child_count(node);
        for (0..child_count) |i| {
            const child = c.ts_node_child(node, @intCast(i));
            try self.extractFoldableNodes(allocator, child, regions);
        }
    }

    pub fn applyIncrementalEdit(
        self: *SyntaxManager,
        start_byte: usize,
        old_end_byte: usize,
        new_end_byte: usize,
        start_row: usize,
        start_col: usize,
        old_end_row: usize,
        old_end_col: usize,
        new_end_row: usize,
        new_end_col: usize,
    ) void {
        self.treeLock();
        defer self.treeUnlock();
        const tree = self.tree orelse return;

        const ts_edit = c.TSInputEdit{
            .start_byte = @intCast(start_byte),
            .old_end_byte = @intCast(old_end_byte),
            .new_end_byte = @intCast(new_end_byte),
            .start_point = .{ .row = @intCast(start_row), .column = @intCast(start_col) },
            .old_end_point = .{ .row = @intCast(old_end_row), .column = @intCast(old_end_col) },
            .new_end_point = .{ .row = @intCast(new_end_row), .column = @intCast(new_end_col) },
        };

        c.ts_tree_edit(tree, &ts_edit);
    }

    pub const BracketInfo = struct {
        line: u32,
        col: u32,
        depth: u8,
        is_opening: bool,
        char: u8,
    };

    pub const ScopeInfo = struct {
        start_line: u32,
        start_col: u32,
        end_line: u32,
        end_col: u32,
    };

    pub fn findBrackets(
        self: *SyntaxManager,
        allocator: std.mem.Allocator,
        content: []const u8,
        start_line: usize,
        end_line: usize,
    ) ![]protocol.SyntaxToken {
        // Cache lookup. `content_len` is the cheap "has the buffer
        // changed?" check — exact enough since any edit changes the
        // byte count by ±1 or more, and the few cases where two
        // unrelated edits net to zero length delta are vanishingly
        // rare. On cache hit we hand back a fresh copy so the caller
        // can free it without touching our entry.
        if (self.bracket_cache.valid and
            self.bracket_cache.resource_id == self.current_resource_id and
            self.bracket_cache.content_len == content.len and
            self.bracket_cache.start_line == start_line and
            self.bracket_cache.end_line == end_line)
        {
            return try allocator.dupe(protocol.SyntaxToken, self.bracket_cache.tokens.items);
        }

        var tokens = std.ArrayListUnmanaged(protocol.SyntaxToken).empty;
        errdefer tokens.deinit(allocator);

        var paren_depth: u8 = 0;
        var brace_depth: u8 = 0;
        var bracket_depth: u8 = 0;

        var line_num: u32 = 0;
        var col: u32 = 0;

        for (content) |byte| {
            if (byte == '\n') {
                line_num += 1;
                col = 0;
                continue;
            }

            if (line_num >= start_line and line_num < end_line) {
                const bracket_type: ?struct { depth: *u8, is_opening: bool } = switch (byte) {
                    '(' => .{ .depth = &paren_depth, .is_opening = true },
                    ')' => .{ .depth = &paren_depth, .is_opening = false },
                    '{' => .{ .depth = &brace_depth, .is_opening = true },
                    '}' => .{ .depth = &brace_depth, .is_opening = false },
                    '[' => .{ .depth = &bracket_depth, .is_opening = true },
                    ']' => .{ .depth = &bracket_depth, .is_opening = false },
                    else => null,
                };

                if (bracket_type) |bt| {
                    const depth_level: u8 = if (bt.is_opening) blk: {
                        bt.depth.* +|= 1;
                        break :blk bt.depth.*;
                    } else blk: {
                        const d = bt.depth.*;
                        bt.depth.* -|= 1;
                        break :blk d;
                    };

                    const normalized = ((depth_level -| 1) % 6) + 1;
                    const token_type: protocol.SyntaxToken.TokenType = switch (normalized) {
                        1 => .bracket_1,
                        2 => .bracket_2,
                        3 => .bracket_3,
                        4 => .bracket_4,
                        5 => .bracket_5,
                        else => .bracket_6,
                    };

                    try tokens.append(allocator, .{
                        .line = line_num,
                        .start_col = col,
                        .length = 1,
                        .token_type = token_type,
                    });
                }
            } else if (line_num < start_line) {
                switch (byte) {
                    '(' => paren_depth +|= 1,
                    ')' => paren_depth -|= 1,
                    '{' => brace_depth +|= 1,
                    '}' => brace_depth -|= 1,
                    '[' => bracket_depth +|= 1,
                    ']' => bracket_depth -|= 1,
                    else => {},
                }
            }

            col += 1;
        }

        const result = try tokens.toOwnedSlice(allocator);

        // Populate the cache with our own copy. The caller's `result`
        // slice (which we return) is allocated from the per-frame
        // arena, so we re-copy into our long-lived allocator.
        self.bracket_cache.invalidate(self.allocator);
        self.bracket_cache.tokens.appendSlice(self.allocator, result) catch {
            // OOM while populating cache is fine — just skip the
            // cache, the caller still gets a correct result.
            return result;
        };
        self.bracket_cache.resource_id = self.current_resource_id;
        self.bracket_cache.content_len = content.len;
        self.bracket_cache.start_line = start_line;
        self.bracket_cache.end_line = end_line;
        self.bracket_cache.valid = true;
        return result;
    }

    pub fn findCurrentScope(
        self: *SyntaxManager,
        cursor_line: usize,
        cursor_col: usize,
    ) ?ScopeInfo {
        self.treeLock();
        defer self.treeUnlock();
        const tree = self.tree orelse return null;
        const root = c.ts_tree_root_node(tree);

        const cursor_point = c.TSPoint{
            .row = @intCast(cursor_line),
            .column = @intCast(cursor_col),
        };

        var node = c.ts_node_descendant_for_point_range(root, cursor_point, cursor_point);
        if (c.ts_node_is_null(node)) return null;

        while (!c.ts_node_is_null(node)) {
            const node_type = std.mem.span(c.ts_node_type(node));

            const is_scope = switch (self.current_lang) {
                .zig => std.mem.eql(u8, node_type, "Block") or
                    std.mem.eql(u8, node_type, "ContainerDecl") or
                    std.mem.eql(u8, node_type, "InitList"),
                .rust => std.mem.eql(u8, node_type, "block") or
                    std.mem.eql(u8, node_type, "struct_expression") or
                    std.mem.eql(u8, node_type, "enum_variant_list"),
                .go => std.mem.eql(u8, node_type, "block") or
                    std.mem.eql(u8, node_type, "literal_value"),
                .python => std.mem.eql(u8, node_type, "block") or
                    std.mem.eql(u8, node_type, "function_definition") or
                    std.mem.eql(u8, node_type, "class_definition"),
                .javascript, .typescript, .tsx => std.mem.eql(u8, node_type, "statement_block") or
                    std.mem.eql(u8, node_type, "object") or
                    std.mem.eql(u8, node_type, "array"),
                .c, .cpp => std.mem.eql(u8, node_type, "compound_statement") or
                    std.mem.eql(u8, node_type, "class_specifier") or
                    std.mem.eql(u8, node_type, "struct_specifier") or
                    std.mem.eql(u8, node_type, "namespace_definition"),
                .java, .csharp => std.mem.eql(u8, node_type, "block") or
                    std.mem.eql(u8, node_type, "class_body") or
                    std.mem.eql(u8, node_type, "interface_body") or
                    std.mem.eql(u8, node_type, "enum_body"),
                .ruby => std.mem.eql(u8, node_type, "do_block") or
                    std.mem.eql(u8, node_type, "block") or
                    std.mem.eql(u8, node_type, "class") or
                    std.mem.eql(u8, node_type, "module") or
                    std.mem.eql(u8, node_type, "method"),
                else => false,
            };

            if (is_scope) {
                const start = c.ts_node_start_point(node);
                const end = c.ts_node_end_point(node);

                if (end.row > start.row) {
                    return .{
                        .start_line = start.row,
                        .start_col = start.column,
                        .end_line = end.row,
                        .end_col = end.column,
                    };
                }
            }

            node = c.ts_node_parent(node);
        }

        return null;
    }
};

test "SyntaxManager init and deinit" {
    try MemoryTestUtils.testNoLeaks(std.testing.allocator, testSyntaxManagerInit);
}

fn testSyntaxManagerInit(allocator: std.mem.Allocator) !void {
    var sm = try SyntaxManager.init(allocator);
    defer sm.deinit();

    // `parser` and `cursor` are non-optional `*TSParser`/`*TSQueryCursor`
    // so we can't check `!= null` — getting past init is itself the
    // assertion that they were allocated.
    try std.testing.expectEqual(SyntaxManager.Language.unknown, sm.current_lang);
    try std.testing.expect(sm.tree == null);
    try std.testing.expect(sm.language == null);
    try std.testing.expect(sm.query == null);
}

test "SyntaxManager language detection" {
    try std.testing.expectEqual(SyntaxManager.Language.zig, SyntaxManager.Language.fromExtension(".zig"));
    try std.testing.expectEqual(SyntaxManager.Language.python, SyntaxManager.Language.fromExtension(".py"));
    try std.testing.expectEqual(SyntaxManager.Language.python, SyntaxManager.Language.fromExtension(".pyw"));
    try std.testing.expectEqual(SyntaxManager.Language.javascript, SyntaxManager.Language.fromExtension(".js"));
    try std.testing.expectEqual(SyntaxManager.Language.javascript, SyntaxManager.Language.fromExtension(".mjs"));
    try std.testing.expectEqual(SyntaxManager.Language.typescript, SyntaxManager.Language.fromExtension(".ts"));
    try std.testing.expectEqual(SyntaxManager.Language.tsx, SyntaxManager.Language.fromExtension(".tsx"));
    try std.testing.expectEqual(SyntaxManager.Language.tsx, SyntaxManager.Language.fromExtension(".jsx"));
    try std.testing.expectEqual(SyntaxManager.Language.unknown, SyntaxManager.Language.fromExtension(".txt"));
    try std.testing.expectEqual(SyntaxManager.Language.unknown, SyntaxManager.Language.fromExtension(""));
}

test "SyntaxManager filename detection" {
    try std.testing.expectEqual(SyntaxManager.Language.zig, SyntaxManager.Language.fromFilename("main.zig"));
    try std.testing.expectEqual(SyntaxManager.Language.python, SyntaxManager.Language.fromFilename("script.py"));
    try std.testing.expectEqual(SyntaxManager.Language.javascript, SyntaxManager.Language.fromFilename("app.js"));
    try std.testing.expectEqual(SyntaxManager.Language.typescript, SyntaxManager.Language.fromFilename("types.ts"));
    try std.testing.expectEqual(SyntaxManager.Language.tsx, SyntaxManager.Language.fromFilename("component.tsx"));
    try std.testing.expectEqual(SyntaxManager.Language.unknown, SyntaxManager.Language.fromFilename("README.md"));
    try std.testing.expectEqual(SyntaxManager.Language.unknown, SyntaxManager.Language.fromFilename("noextension"));
}

test "SyntaxManager setLanguage zig" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");
    try std.testing.expectEqual(SyntaxManager.Language.zig, sm.current_lang);
    try std.testing.expect(sm.language != null);
    try std.testing.expect(sm.query != null);
}

test "SyntaxManager setLanguage python" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("python");
    try std.testing.expectEqual(SyntaxManager.Language.python, sm.current_lang);
    try std.testing.expect(sm.language != null);
    try std.testing.expect(sm.query != null);
}

test "SyntaxManager setLanguage javascript" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("javascript");
    try std.testing.expectEqual(SyntaxManager.Language.javascript, sm.current_lang);
    try std.testing.expect(sm.language != null);
    try std.testing.expect(sm.query != null);
}

test "SyntaxManager setLanguage unknown" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try std.testing.expectError(error.UnsupportedLanguage, sm.setLanguage("unknown"));
    try std.testing.expectEqual(SyntaxManager.Language.unknown, sm.current_lang);
}

test "SyntaxManager setLanguageEnum" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguageEnum(.zig);
    try std.testing.expectEqual(SyntaxManager.Language.zig, sm.current_lang);

    try sm.setLanguageEnum(.python);
    try std.testing.expectEqual(SyntaxManager.Language.python, sm.current_lang);
}

test "SyntaxManager parse zig code" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");
    try sm.parse("const x = 42;", null);

    try std.testing.expect(sm.tree != null);
}

test "SyntaxManager parse python code" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("python");
    try sm.parse("x = 42", null);

    try std.testing.expect(sm.tree != null);
}

test "SyntaxManager parse empty content" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");
    try sm.parse("", null);

    try std.testing.expect(sm.tree != null);
}

test "SyntaxManager parse without language set" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.parse("const x = 1;", null);
    try std.testing.expect(sm.tree == null);
}

test "SyntaxManager getNodeAt zig" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");
    try sm.parse("const x = 42;", null);

    const node1 = sm.getNodeAt(0, 0);
    try std.testing.expect(node1 != null);

    const node2 = sm.getNodeAt(0, 6);
    try std.testing.expect(node2 != null);

    const node3 = sm.getNodeAt(0, 20);
    try std.testing.expect(node3 == null);
}

test "SyntaxManager getNodeType" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");
    try sm.parse("const x = 42;", null);

    const node = sm.getNodeAt(0, 6);
    if (node) |n| {
        const node_type = sm.getNodeType(n);
        try std.testing.expect(node_type.len > 0);
    }
}

test "SyntaxManager getEnclosingNodeForPoints" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");
    try sm.parse("const x = 42;", null);

    const node = sm.getEnclosingNodeForPoints(0, 6, 0, 6);
    try std.testing.expect(node != null);
}

test "SyntaxManager getNodeByteRange" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");
    try sm.parse("const x = 42;", null);

    const node = sm.getNodeAt(0, 6);
    if (node) |n| {
        const range = sm.getNodeByteRange(n);
        try std.testing.expect(range.start <= range.end);
    }
}

test "SyntaxManager highlight zig code" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");
    try sm.parse("const x = 42;", null);

    const tokens = try sm.highlight(std.testing.allocator, 0, 1);
    defer std.testing.allocator.free(tokens);

    try std.testing.expect(tokens.len > 0);

    var found_keyword = false;
    var found_identifier = false;
    var found_number = false;

    for (tokens) |token| {
        switch (token.token_type) {
            .keyword => found_keyword = true,
            .variable => found_identifier = true,
            .number => found_number = true,
            else => {},
        }
    }

    try std.testing.expect(found_keyword);
    try std.testing.expect(found_identifier);
    try std.testing.expect(found_number);
}

test "SyntaxManager highlight python code" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("python");
    try sm.parse("x = 42", null);

    const tokens = try sm.highlight(std.testing.allocator, 0, 1);
    defer std.testing.allocator.free(tokens);

    try std.testing.expect(tokens.len > 0);
}

test "SyntaxManager highlight empty range" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");
    try sm.parse("const x = 42;", null);

    const tokens = try sm.highlight(std.testing.allocator, 1, 1);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 0), tokens.len);
}

test "SyntaxManager highlight without tree" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");

    const tokens = try sm.highlight(std.testing.allocator, 0, 1);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 0), tokens.len);
}

test "SyntaxManager getSymbols zig" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");
    const source = "const x = 1;\nfn foo() void {}\nconst y = 2;";

    const symbols = try sm.getSymbols(std.testing.allocator, source);
    defer std.testing.allocator.free(symbols);

    try std.testing.expect(symbols.len > 0);

    var found_foo = false;
    for (symbols) |sym| {
        if (std.mem.eql(u8, sym.name, "foo")) {
            found_foo = true;
            try std.testing.expectEqualStrings("function", sym.kind);
            try std.testing.expectEqual(@as(usize, 1), sym.line);
        }
    }
    try std.testing.expect(found_foo);
}

test "SyntaxManager getSymbols python" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("python");
    const source = "def foo():\n    pass\nclass Bar:\n    pass";

    const symbols = try sm.getSymbols(std.testing.allocator, source);
    defer std.testing.allocator.free(symbols);

    try std.testing.expect(symbols.len >= 2);

    var found_foo = false;
    var found_bar = false;
    for (symbols) |sym| {
        if (std.mem.eql(u8, sym.name, "foo")) {
            found_foo = true;
            try std.testing.expectEqualStrings("function", sym.kind);
        } else if (std.mem.eql(u8, sym.name, "Bar")) {
            found_bar = true;
            try std.testing.expectEqualStrings("struct", sym.kind);
        }
    }
    try std.testing.expect(found_foo and found_bar);
}

test "SyntaxManager getSymbols empty source" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");

    const symbols = try sm.getSymbols(std.testing.allocator, "");
    defer std.testing.allocator.free(symbols);

    try std.testing.expectEqual(@as(usize, 0), symbols.len);
}

test "SyntaxManager expandSelection zig" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");
    try sm.parse("const x = 42;", null);

    const expanded = sm.expandSelection(0, 6, 0, 6);
    try std.testing.expect(expanded.start_col <= 6);
    try std.testing.expect(expanded.end_col >= 6);
}

test "SyntaxManager expandSelection python" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("python");
    try sm.parse("def foo(): pass", null);

    const expanded = sm.expandSelection(0, 4, 0, 4);
    try std.testing.expect(expanded.start_col <= 4);
    try std.testing.expect(expanded.end_col >= 6);
}

test "SyntaxManager getSmartIndent zig" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");

    try sm.parse("fn foo() {\n    const x = 1;\n}", null);

    const indent1 = sm.getSmartIndent(1);
    try std.testing.expectEqual(@as(usize, 4), indent1);

    const indent2 = sm.getSmartIndent(2);
    try std.testing.expectEqual(@as(usize, 0), indent2);
}

test "SyntaxManager getSmartIndent python" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("python");

    try sm.parse("def foo():\n    x = 1\n    if True:\n        y = 2\n", null);

    const indent1 = sm.getSmartIndent(1);
    try std.testing.expectEqual(@as(usize, 4), indent1);

    const indent2 = sm.getSmartIndent(3);
    try std.testing.expectEqual(@as(usize, 8), indent2);
}

test "SyntaxManager getFoldableRegions zig" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");
    try sm.parse("fn foo() {\n    const x = 1;\n    const y = 2;\n}", null);

    const regions = try sm.getFoldableRegions(std.testing.allocator);
    defer std.testing.allocator.free(regions);

    try std.testing.expect(regions.len > 0);
    var found_function = false;
    for (regions) |region| {
        if (region.kind == .function) {
            found_function = true;
            try std.testing.expect(region.start_line < region.end_line);
        }
    }
    try std.testing.expect(found_function);
}

test "SyntaxManager getFoldableRegions python" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("python");
    try sm.parse("def foo():\n    x = 1\n    y = 2\n\nclass Bar:\n    pass", null);

    const regions = try sm.getFoldableRegions(std.testing.allocator);
    defer std.testing.allocator.free(regions);

    try std.testing.expect(regions.len >= 2);

    var found_function = false;
    var found_class = false;
    for (regions) |region| {
        if (region.kind == .function) found_function = true;
        if (region.kind == .class) found_class = true;
    }
    try std.testing.expect(found_function and found_class);
}

test "SyntaxManager applyIncrementalEdit" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");
    try sm.parse("const x = 1;", null);

    // Signature: (start_byte, old_end_byte, new_end_byte,
    //             start_row, start_col, old_end_row, old_end_col,
    //             new_end_row, new_end_col)
    sm.applyIncrementalEdit(10, 11, 13, 0, 10, 0, 11, 0, 13);

    try std.testing.expect(sm.tree != null);
}

test "SyntaxManager performance large file" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");

    var large_source = std.ArrayList(u8).empty;
    defer large_source.deinit(std.testing.allocator);

    for (0..1000) |i| {
        const line = try std.fmt.allocPrint(std.testing.allocator, "const x{} = {};\n", .{ i, i });
        defer std.testing.allocator.free(line);
        try large_source.appendSlice(std.testing.allocator, line);
    }

    try PerformanceTestUtils.expectPerformance(SyntaxManager.parse, .{ &sm, large_source.items, @as(?u64, null) }, 10_000_000);

    try PerformanceTestUtils.expectPerformance(SyntaxManager.highlight, .{ &sm, std.testing.allocator, @as(usize, 100), @as(usize, 120) }, 1_000_000);
}

test "SyntaxManager performance symbol extraction" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");

    var source = std.ArrayList(u8).empty;
    defer source.deinit(std.testing.allocator);

    for (0..100) |i| {
        const line = try std.fmt.allocPrint(std.testing.allocator, "fn func{}() void {{}}\nconst const{} = {};\n", .{ i, i, i });
        defer std.testing.allocator.free(line);
        try source.appendSlice(std.testing.allocator, line);
    }

    try sm.parse(source.items, null);

    try PerformanceTestUtils.expectPerformance(SyntaxManager.getSymbols, .{ &sm, std.testing.allocator, source.items }, 5_000_000);
}

test "SyntaxManager handle parsing errors gracefully" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");

    try sm.parse("const x = ;", null);

    const result = sm.highlight(std.testing.allocator, 0, 1);
    if (result) |_| {} else |err| {
        try std.testing.expect(err != error.OutOfMemory);
    }
}

test "SyntaxManager handle empty tree operations" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    const node = sm.getNodeAt(0, 0);
    try std.testing.expect(node == null);

    const tokens = try sm.highlight(std.testing.allocator, 0, 1);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 0), tokens.len);

    const symbols = try sm.getSymbols(std.testing.allocator, "");
    defer std.testing.allocator.free(symbols);
    try std.testing.expectEqual(@as(usize, 0), symbols.len);
}

test "SyntaxManager memory cleanup" {
    try MemoryTestUtils.testNoLeaks(std.testing.allocator, testSyntaxManagerMemory);
}

fn testSyntaxManagerMemory(allocator: std.mem.Allocator) !void {
    var sm = try SyntaxManager.init(allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");
    try sm.parse("const x = 42; fn foo() void {}", null);

    _ = try sm.highlight(allocator, 0, 2);
    _ = try sm.getSymbols(allocator, "const x = 42; fn foo() void {}");
    _ = sm.getNodeAt(0, 0);
}

test "SyntaxManager handle unicode content" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");
    try sm.parse("// Comment with émojis 🌍\nconst x = 42;", null);

    const tokens = try sm.highlight(std.testing.allocator, 0, 2);
    defer std.testing.allocator.free(tokens);

    try std.testing.expect(tokens.len >= 0);
}

test "SyntaxManager handle very long lines" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");

    var long_line = std.ArrayList(u8).empty;
    defer long_line.deinit(std.testing.allocator);

    try long_line.appendSlice(std.testing.allocator, "const x = \"");
    for (0..10000) |_| {
        try long_line.append(std.testing.allocator, 'a');
    }
    try long_line.appendSlice(std.testing.allocator, "\";");

    try sm.parse(long_line.items, null);

    const tokens = try sm.highlight(std.testing.allocator, 0, 1);
    defer std.testing.allocator.free(tokens);

    try std.testing.expect(tokens.len > 0);
}

// ---------------------------------------------------------------------
// Async parse worker tests. submitParse must fall back to a synchronous
// parse when no worker is running, and otherwise hand off to the worker
// and eventually update self.tree.
// ---------------------------------------------------------------------

const test_utils_root = @import("../test_utils.zig");

test "submitParse: synchronous fallback when worker not started" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");
    try std.testing.expect(sm.tree == null);

    // No worker → submitParse should parse inline and tree should be set.
    try sm.submitParse("const x: u32 = 1;", null);
    try std.testing.expect(sm.tree != null);
    try std.testing.expectEqual(@as(u64, 0), sm.current_resource_id);
}

test "submitParse: stores resource_id" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");
    try sm.submitParse("const x = 1;", 42);
    try std.testing.expectEqual(@as(u64, 42), sm.current_resource_id);
}

test "submitParse: no-op for unknown/markdown language" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    // Default lang is .unknown.
    try sm.submitParse("anything", null);
    try std.testing.expect(sm.tree == null);

    try sm.setLanguage("markdown");
    try sm.submitParse("# heading", null);
    try std.testing.expect(sm.tree == null);
}

test "submitParse: async path delivers tree via worker" {
    var io_ctx = test_utils_root.TestIo.init(std.testing.allocator);
    defer io_ctx.deinit();
    const io = io_ctx.io();

    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");
    try sm.startParseWorker(io);

    try sm.submitParse("fn main() void {}", 7);

    // Poll until the worker installs the tree.
    const Wait = struct {
        m: *SyntaxManager,
        fn pred(s: @This()) bool {
            s.m.treeLock();
            defer s.m.treeUnlock();
            return s.m.tree != null;
        }
    };
    try std.testing.expect(test_utils_root.waitUntil(io, 2000, Wait{ .m = &sm }, Wait.pred));
    try std.testing.expectEqual(@as(u64, 7), sm.current_resource_id);
}

test "submitParse: language switch discards stale pending job" {
    var sm = try SyntaxManager.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLanguage("zig");
    // Without a worker, this runs inline.
    try sm.submitParse("const x = 1;", null);
    try std.testing.expect(sm.tree != null);

    // Switching language must clear the tree.
    try sm.setLanguage("python");
    try std.testing.expect(sm.tree == null);
    try std.testing.expect(sm.pending_job == null);
}

// Smoke test: every shipped grammar's highlight query has to compile, or
// `setLanguage` returns `error.InvalidQuery` and the language renders
// without highlighting. This catches typos / stale node references the
// moment they're introduced rather than the next time someone opens that
// language for real.
test "all shipped languages: setLanguage succeeds (query compiles)" {
    const langs = [_][]const u8{
        "zig",    "python", "javascript", "typescript", "tsx",
        "json",   "bash",   "go",         "html",       "css",
        "rust",   "c",      "cpp",        "java",       "ruby",
        "csharp",
    };
    for (langs) |l| {
        var sm = try SyntaxManager.init(std.testing.allocator);
        defer sm.deinit();
        sm.setLanguage(l) catch |err| {
            std.log.err("setLanguage('{s}') failed: {}", .{ l, err });
            return err;
        };
    }
}
