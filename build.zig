const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ===== Tree-sitter & grammar dependencies =====
    // All fetched by Zig's package manager — see build.zig.zon.
    const ts_dep = b.dependency("tree_sitter", .{});
    const ts_zig_dep = b.dependency("tree_sitter_zig", .{});
    const ts_python_dep = b.dependency("tree_sitter_python", .{});
    const ts_js_dep = b.dependency("tree_sitter_javascript", .{});
    const ts_typescript_dep = b.dependency("tree_sitter_typescript", .{});
    const ts_json_dep = b.dependency("tree_sitter_json", .{});
    const ts_bash_dep = b.dependency("tree_sitter_bash", .{});
    const ts_go_dep = b.dependency("tree_sitter_go", .{});
    const ts_html_dep = b.dependency("tree_sitter_html", .{});
    const ts_css_dep = b.dependency("tree_sitter_css", .{});
    const ts_rust_dep = b.dependency("tree_sitter_rust", .{});
    const ts_c_dep = b.dependency("tree_sitter_c", .{});
    const ts_cpp_dep = b.dependency("tree_sitter_cpp", .{});
    const ts_java_dep = b.dependency("tree_sitter_java", .{});
    const ts_ruby_dep = b.dependency("tree_sitter_ruby", .{});
    const ts_csharp_dep = b.dependency("tree_sitter_c_sharp", .{});
    // Tier 2 languages
    const ts_php_dep = b.dependency("tree_sitter_php", .{});
    const ts_swift_dep = b.dependency("tree_sitter_swift", .{});
    const ts_kotlin_dep = b.dependency("tree_sitter_kotlin", .{});
    const ts_lua_dep = b.dependency("tree_sitter_lua", .{});
    const ts_dart_dep = b.dependency("tree_sitter_dart", .{});
    const ts_elixir_dep = b.dependency("tree_sitter_elixir", .{});
    const ts_haskell_dep = b.dependency("tree_sitter_haskell", .{});
    const ts_ocaml_dep = b.dependency("tree_sitter_ocaml", .{});
    const ts_scala_dep = b.dependency("tree_sitter_scala", .{});
    const ts_r_dep = b.dependency("tree_sitter_r", .{});
    const ts_perl_dep = b.dependency("tree_sitter_perl", .{});
    const ts_erlang_dep = b.dependency("tree_sitter_erlang", .{});

    // The tree-sitter repo uses `lib/src/tree_sitter/{parser,array,alloc}.h`
    // symlinks that point to `lib/src/*.h`. Zig's package extractor drops
    // symlinks, so we stage the headers at `tree_sitter/*` by copying the real
    // files. Several scanners (TypeScript, PHP, OCaml, etc.) include these
    // under the `tree_sitter/` prefix.
    const ts_shim = b.addWriteFiles();
    _ = ts_shim.addCopyFile(ts_dep.path("lib/src/parser.h"), "tree_sitter/parser.h");
    _ = ts_shim.addCopyFile(ts_dep.path("lib/src/array.h"), "tree_sitter/array.h");
    _ = ts_shim.addCopyFile(ts_dep.path("lib/src/alloc.h"), "tree_sitter/alloc.h");
    const ts_shim_dir = ts_shim.getDirectory();

    const mod = b.addModule("stem", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tree-sitter C flags - POSIX macros only needed on Linux.
    // `-Dassert(...)=` neutralizes the bare `assert()` calls in several
    // upstream scanners (php's common/scanner.h, etc.) that never
    // include <assert.h>. Under C11+ those would be a hard error in
    // ReleaseFast; we don't want grammar runtime assertions anyway.
    const tree_sitter_cflags = if (target.result.os.tag == .linux)
        &[_][]const u8{ "-std=c11", "-fno-sanitize=all", "-D_POSIX_C_SOURCE=200112L", "-D_DEFAULT_SOURCE", "-Dassert(x)=((void)0)" }
    else
        &[_][]const u8{ "-std=c11", "-fno-sanitize=all", "-Dassert(x)=((void)0)" };

    // Tree-sitter core
    mod.addCSourceFile(.{
        .file = ts_dep.path("lib/src/lib.c"),
        .flags = tree_sitter_cflags,
    });
    mod.addIncludePath(ts_dep.path("lib/include"));
    mod.addIncludePath(ts_dep.path("lib/src"));
    mod.addIncludePath(ts_shim_dir);

    // Zig grammar
    mod.addCSourceFile(.{
        .file = ts_zig_dep.path("src/parser.c"),
        .flags = tree_sitter_cflags,
    });
    // Python grammar
    mod.addCSourceFile(.{
        .file = ts_python_dep.path("src/parser.c"),
        .flags = tree_sitter_cflags,
    });
    mod.addCSourceFile(.{
        .file = ts_python_dep.path("src/scanner.c"),
        .flags = tree_sitter_cflags,
    });
    // JavaScript grammar
    mod.addCSourceFile(.{
        .file = ts_js_dep.path("src/parser.c"),
        .flags = tree_sitter_cflags,
    });
    mod.addCSourceFile(.{
        .file = ts_js_dep.path("src/scanner.c"),
        .flags = tree_sitter_cflags,
    });
    // TypeScript grammars (typescript and tsx are separate parsers).
    // The TS scanners include common/scanner.h which references
    // <tree_sitter/parser.h>; that path is provided by ts_dep's lib/include.
    mod.addCSourceFile(.{
        .file = ts_typescript_dep.path("typescript/src/parser.c"),
        .flags = tree_sitter_cflags,
    });
    mod.addCSourceFile(.{
        .file = ts_typescript_dep.path("typescript/src/scanner.c"),
        .flags = tree_sitter_cflags,
    });
    mod.addCSourceFile(.{
        .file = ts_typescript_dep.path("tsx/src/parser.c"),
        .flags = tree_sitter_cflags,
    });
    mod.addCSourceFile(.{
        .file = ts_typescript_dep.path("tsx/src/scanner.c"),
        .flags = tree_sitter_cflags,
    });
    // JSON grammar (no scanner)
    mod.addCSourceFile(.{
        .file = ts_json_dep.path("src/parser.c"),
        .flags = tree_sitter_cflags,
    });
    // Bash grammar
    mod.addCSourceFile(.{
        .file = ts_bash_dep.path("src/parser.c"),
        .flags = tree_sitter_cflags,
    });
    mod.addCSourceFile(.{
        .file = ts_bash_dep.path("src/scanner.c"),
        .flags = tree_sitter_cflags,
    });
    // Go grammar
    mod.addCSourceFile(.{
        .file = ts_go_dep.path("src/parser.c"),
        .flags = tree_sitter_cflags,
    });
    // HTML grammar
    mod.addCSourceFile(.{
        .file = ts_html_dep.path("src/parser.c"),
        .flags = tree_sitter_cflags,
    });
    mod.addCSourceFile(.{
        .file = ts_html_dep.path("src/scanner.c"),
        .flags = tree_sitter_cflags,
    });
    // CSS grammar
    mod.addCSourceFile(.{
        .file = ts_css_dep.path("src/parser.c"),
        .flags = tree_sitter_cflags,
    });
    mod.addCSourceFile(.{
        .file = ts_css_dep.path("src/scanner.c"),
        .flags = tree_sitter_cflags,
    });
    // C grammar (no scanner)
    mod.addCSourceFile(.{
        .file = ts_c_dep.path("src/parser.c"),
        .flags = tree_sitter_cflags,
    });
    // C++ grammar
    mod.addCSourceFile(.{
        .file = ts_cpp_dep.path("src/parser.c"),
        .flags = tree_sitter_cflags,
    });
    mod.addCSourceFile(.{
        .file = ts_cpp_dep.path("src/scanner.c"),
        .flags = tree_sitter_cflags,
    });
    // Java grammar (no scanner)
    mod.addCSourceFile(.{
        .file = ts_java_dep.path("src/parser.c"),
        .flags = tree_sitter_cflags,
    });
    // Ruby grammar
    mod.addCSourceFile(.{
        .file = ts_ruby_dep.path("src/parser.c"),
        .flags = tree_sitter_cflags,
    });
    mod.addCSourceFile(.{
        .file = ts_ruby_dep.path("src/scanner.c"),
        .flags = tree_sitter_cflags,
    });
    // C# grammar
    mod.addCSourceFile(.{
        .file = ts_csharp_dep.path("src/parser.c"),
        .flags = tree_sitter_cflags,
    });
    mod.addCSourceFile(.{
        .file = ts_csharp_dep.path("src/scanner.c"),
        .flags = tree_sitter_cflags,
    });

    // Rust grammar
    mod.addCSourceFile(.{
        .file = ts_rust_dep.path("src/parser.c"),
        .flags = tree_sitter_cflags,
    });
    mod.addCSourceFile(.{
        .file = ts_rust_dep.path("src/scanner.c"),
        .flags = tree_sitter_cflags,
    });

    // ===== Tier 2 grammars =====
    // PHP (with-HTML variant; we use the `php/` parser which mixes HTML+PHP)
    mod.addCSourceFile(.{ .file = ts_php_dep.path("php/src/parser.c"), .flags = tree_sitter_cflags });
    mod.addCSourceFile(.{ .file = ts_php_dep.path("php/src/scanner.c"), .flags = tree_sitter_cflags });
    // Swift
    mod.addCSourceFile(.{ .file = ts_swift_dep.path("src/parser.c"), .flags = tree_sitter_cflags });
    mod.addCSourceFile(.{ .file = ts_swift_dep.path("src/scanner.c"), .flags = tree_sitter_cflags });
    // Kotlin
    mod.addCSourceFile(.{ .file = ts_kotlin_dep.path("src/parser.c"), .flags = tree_sitter_cflags });
    mod.addCSourceFile(.{ .file = ts_kotlin_dep.path("src/scanner.c"), .flags = tree_sitter_cflags });
    // Lua
    mod.addCSourceFile(.{ .file = ts_lua_dep.path("src/parser.c"), .flags = tree_sitter_cflags });
    mod.addCSourceFile(.{ .file = ts_lua_dep.path("src/scanner.c"), .flags = tree_sitter_cflags });
    // Dart
    mod.addCSourceFile(.{ .file = ts_dart_dep.path("src/parser.c"), .flags = tree_sitter_cflags });
    mod.addCSourceFile(.{ .file = ts_dart_dep.path("src/scanner.c"), .flags = tree_sitter_cflags });
    // Elixir
    mod.addCSourceFile(.{ .file = ts_elixir_dep.path("src/parser.c"), .flags = tree_sitter_cflags });
    mod.addCSourceFile(.{ .file = ts_elixir_dep.path("src/scanner.c"), .flags = tree_sitter_cflags });
    // Haskell
    mod.addCSourceFile(.{ .file = ts_haskell_dep.path("src/parser.c"), .flags = tree_sitter_cflags });
    mod.addCSourceFile(.{ .file = ts_haskell_dep.path("src/scanner.c"), .flags = tree_sitter_cflags });
    // OCaml (multi-grammar package; we use the main `ocaml` variant)
    mod.addCSourceFile(.{ .file = ts_ocaml_dep.path("grammars/ocaml/src/parser.c"), .flags = tree_sitter_cflags });
    mod.addCSourceFile(.{ .file = ts_ocaml_dep.path("grammars/ocaml/src/scanner.c"), .flags = tree_sitter_cflags });
    // Scala
    mod.addCSourceFile(.{ .file = ts_scala_dep.path("src/parser.c"), .flags = tree_sitter_cflags });
    mod.addCSourceFile(.{ .file = ts_scala_dep.path("src/scanner.c"), .flags = tree_sitter_cflags });
    // R
    mod.addCSourceFile(.{ .file = ts_r_dep.path("src/parser.c"), .flags = tree_sitter_cflags });
    mod.addCSourceFile(.{ .file = ts_r_dep.path("src/scanner.c"), .flags = tree_sitter_cflags });
    // Perl
    mod.addCSourceFile(.{ .file = ts_perl_dep.path("src/parser.c"), .flags = tree_sitter_cflags });
    mod.addCSourceFile(.{ .file = ts_perl_dep.path("src/scanner.c"), .flags = tree_sitter_cflags });
    // Erlang
    mod.addCSourceFile(.{ .file = ts_erlang_dep.path("src/parser.c"), .flags = tree_sitter_cflags });
    mod.addCSourceFile(.{ .file = ts_erlang_dep.path("src/scanner.c"), .flags = tree_sitter_cflags });

    const options = b.addOptions();
    // Version is defined in build.zig.zon, embed it at comptime
    const zon = @import("build.zig.zon");
    const version_string = zon.version;
    options.addOption([]const u8, "version", version_string);

    // Embed the short git commit hash at build time so `stem --version` /
    // bug reports include actionable build identification. Falls back to
    // "unknown" when not in a git checkout (e.g. tarball builds).
    const git_hash: []const u8 = blk: {
        var exit_code: u8 = undefined;
        const out = b.runAllowFail(
            &.{ "git", "rev-parse", "--short", "HEAD" },
            &exit_code,
            .ignore,
        ) catch break :blk "unknown";
        break :blk std.mem.trim(u8, out, " \t\r\n");
    };
    options.addOption([]const u8, "git_hash", git_hash);

    mod.addOptions("config", options);

    const exe = b.addExecutable(.{
        .name = "stem",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "stem", .module = mod },
            },
        }),
    });
    exe.root_module.addOptions("config", options);
    exe.root_module.link_libc = true;
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("vaxis", vaxis_dep.module("vaxis"));
    const vigil_dep = b.dependency("vigil", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("vigil", vigil_dep.module("vigil"));
    const zls_dep = b.dependency("zls", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zls", zls_dep.module("zls"));

    const lsp_dep = b.dependency("lsp", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("lsp", lsp_dep.module("lsp"));

    const uucode_dep = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .fields = @as([]const []const u8, &.{
            "east_asian_width",
            "grapheme_break",
            "general_category",
            "is_emoji_presentation",
        }),
    });
    exe.root_module.addImport("uucode", uucode_dep.module("uucode"));

    // Add dependencies to the main module as well (needed for tests)
    mod.addImport("vaxis", vaxis_dep.module("vaxis"));
    mod.addImport("vigil", vigil_dep.module("vigil"));
    mod.addImport("zls", zls_dep.module("zls"));
    mod.addImport("lsp", lsp_dep.module("lsp"));
    mod.addImport("uucode", uucode_dep.module("uucode"));
    // Include paths for the exe so it can see tree-sitter headers.
    exe.root_module.addIncludePath(ts_dep.path("lib/include"));
    exe.root_module.addIncludePath(ts_dep.path("lib/src"));
    b.installArtifact(exe);

    // ===== Bundled WebAssembly plugins =====
    // All bundled plugins target the wasm runtime. The host still
    // supports exec (out-of-process JSON-RPC) plugins, but nothing
    // bundled uses that path. Built for `wasm32-freestanding`; host
    // imports (env.stem_*) are left unresolved at build time and bound
    // by the host's pure-Zig interpreter at instantiate time.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const WasmPlugin = struct { name: []const u8, source: []const u8 };
    const wasm_plugins = [_]WasmPlugin{
        .{ .name = "echo", .source = "bundled/plugins/echo/src/main.zig" },
        .{ .name = "git-wasm", .source = "bundled/plugins/git-wasm/src/main.zig" },
        .{ .name = "plugin-manager-wasm", .source = "bundled/plugins/plugin-manager-wasm/src/main.zig" },
    };
    inline for (wasm_plugins) |wp| {
        const exe_wasm = b.addExecutable(.{
            .name = wp.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(wp.source),
                .target = wasm_target,
                .optimize = .ReleaseSmall,
            }),
        });
        exe_wasm.entry = .disabled;
        exe_wasm.rdynamic = true;
        b.installArtifact(exe_wasm);
    }

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    mod.link_libc = true;
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Diagnostic: `zig build query-check` reports which grammar's highlight
    // query (if any) fails to compile against the linked tree-sitter
    // language. Useful when adding a new language or after a grammar bump.
    const query_check = b.addExecutable(.{
        .name = "query-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/query_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "stem", .module = mod },
            },
        }),
    });
    query_check.root_module.link_libc = true;
    query_check.root_module.addIncludePath(ts_dep.path("lib/include"));
    query_check.root_module.addIncludePath(ts_dep.path("lib/src"));
    const run_query_check = b.addRunArtifact(query_check);
    const query_check_step = b.step("query-check", "Verify every shipped tree-sitter query compiles");
    query_check_step.dependOn(&run_query_check.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // ===== Fuzz Testing =====
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_mod.addImport("stem", mod);
    fuzz_mod.addImport("vaxis", vaxis_dep.module("vaxis"));
    fuzz_mod.addImport("vigil", vigil_dep.module("vigil"));

    fuzz_mod.link_libc = true;
    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_mod,
    });

    fuzz_mod.addIncludePath(ts_dep.path("lib/include"));
    fuzz_mod.addIncludePath(ts_dep.path("lib/src"));

    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);

    const fuzz_step = b.step("fuzz", "Run fuzz tests (use: zig build --fuzz fuzz)");
    fuzz_step.dependOn(&run_fuzz_tests.step);
}
