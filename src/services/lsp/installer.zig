const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.LSPInstaller);

/// System-wide binary lookup, usable outside the `Installer` (for
/// example by `external.runExternalServer` to resolve interpreters
/// like `node` and `java` before spawning an LSP child). Searches
/// `$PATH` first, then the same well-known toolchain bin directories
/// the Installer probes. Returns null when nothing matches.
///
/// Caller owns the returned slice.
pub fn findOnSystem(
    allocator: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    environ_block: std.process.Environ.Block,
) ?[]u8 {
    var inst: Installer = .{
        .allocator = allocator,
        .io = io,
        .environ_block = environ_block,
    };
    return inst.findBinary(name, &[_][]const u8{});
}

fn childExitCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .exited => |code| @intCast(code),
        .signal => |sig| -@as(i32, @intCast(@intFromEnum(sig))),
        else => -999,
    };
}

pub const Installer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_block: std.process.Environ.Block,
    /// Optional user-facing progress sink. The CLI sets this to stderr
    /// so `stem lsp install` prints download / extract milestones live
    /// — without it, the same messages only land in `~/.stem/logs/*`
    /// and the command looks frozen for the 10+ seconds curl is busy.
    progress: ?*std.Io.Writer = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ_block: std.process.Environ.Block) Installer {
        return .{
            .allocator = allocator,
            .io = io,
            .environ_block = environ_block,
        };
    }

    /// Emit a milestone message: always to the structured log; to the
    /// user-facing progress writer too if one is attached. Errors on
    /// the progress write are swallowed — a broken pipe to the CLI
    /// shouldn't abort the install.
    fn note(self: *Installer, comptime fmt: []const u8, args: anytype) void {
        log.info(fmt, args);
        if (self.progress) |w| {
            w.print("    " ++ fmt ++ "\n", args) catch {};
            w.flush() catch {};
        }
    }

    pub fn ensurePyright(self: *Installer, auto_install: bool) ![]const u8 {
        log.info("ensurePyright called (auto_install={})", .{auto_install});
        const install_dir = try self.getInstallDir("pyright");
        defer self.allocator.free(install_dir);

        const entry_point = try std.fs.path.join(self.allocator, &.{ install_dir, "package", "langserver.index.js" });
        errdefer self.allocator.free(entry_point);

        const file = std.Io.Dir.openFileAbsolute(self.io, entry_point, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (!auto_install) {
                    log.info("Pyright not installed (run `stem lsp install python` to install)", .{});
                    return error.NotInstalled;
                }
                log.info("Pyright not found at {s}, installing...", .{entry_point});
                try self.installNpmPackage("pyright", install_dir);

                std.Io.Dir.accessAbsolute(self.io, entry_point, .{}) catch |e| {
                    log.info("Verification failed for {s}: {}", .{ entry_point, e });
                    std.log.err("Pyright installation failed. File not found: {s}. Error: {}", .{ entry_point, e });
                    return error.InstallFailed;
                };

                log.info("Installation verified at {s}", .{entry_point});
                return entry_point;
            },
            else => return err,
        };
        file.close(self.io);
        log.info("Pyright already installed at {s}", .{entry_point});
        return entry_point;
    }

    fn homeDir(self: *Installer) ![]u8 {
        const platform = @import("../../kernel/platform.zig");
        if (try platform.getEnv(self.allocator, self.environ_block, "HOME")) |h| return h;
        if (try platform.getEnv(self.allocator, self.environ_block, "USERPROFILE")) |up| return up;
        return error.HomeNotFound;
    }

    fn getInstallDir(self: *Installer, name: []const u8) ![]const u8 {
        const home = try self.homeDir();
        defer self.allocator.free(home);
        return try std.fs.path.join(self.allocator, &.{ home, ".stem", "lsp", name });
    }

    fn tempDir(self: *Installer) ![]u8 {
        if (builtin.os.tag == .windows) {
            const platform = @import("../../kernel/platform.zig");
            if (try platform.getEnv(self.allocator, self.environ_block, "TEMP")) |t| return t;
            if (try platform.getEnv(self.allocator, self.environ_block, "TMP")) |t| return t;
            return self.allocator.dupe(u8, "C:\\Windows\\Temp");
        }
        return self.allocator.dupe(u8, "/tmp");
    }

    /// Fetch JSON metadata for an npm package and return the dist.tarball URL.
    /// Caller frees the returned slice.
    fn fetchNpmTarballUrl(self: *Installer, package: []const u8) ![]u8 {
        const metadata_url = try std.fmt.allocPrint(self.allocator, "https://registry.npmjs.org/{s}/latest", .{package});
        defer self.allocator.free(metadata_url);
        self.note("fetching npm metadata for {s}", .{package});

        const json_out = try self.runCommand(&.{ "curl", "-fsSL", metadata_url });
        defer self.allocator.free(json_out);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json_out, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const dist = parsed.value.object.get("dist") orelse return error.InvalidMetadata;
        if (dist != .object) return error.InvalidMetadata;
        const tarball_val = dist.object.get("tarball") orelse return error.InvalidMetadata;
        if (tarball_val != .string) return error.InvalidMetadata;

        // Defensive: only allow https:// URLs from the npm registry to be
        // safe even if shell were ever reintroduced.
        if (!std.mem.startsWith(u8, tarball_val.string, "https://")) return error.InvalidMetadata;
        return self.allocator.dupe(u8, tarball_val.string);
    }

    /// Install an npm-distributed package (Pyright, typescript-language-server)
    /// by downloading the tarball and extracting it. Uses argv-based curl/tar
    /// — no `sh -c` shell layer, so URLs / paths are not shell-injectable.
    fn installNpmPackage(self: *Installer, package: []const u8, install_dir: []const u8) !void {
        const tarball_url = try self.fetchNpmTarballUrl(package);
        defer self.allocator.free(tarball_url);

        try std.Io.Dir.cwd().createDirPath(self.io, install_dir);

        const tmp = try self.tempDir();
        defer self.allocator.free(tmp);
        const archive_name = try std.fmt.allocPrint(self.allocator, "stem-{s}.tgz", .{package});
        defer self.allocator.free(archive_name);
        const archive_path = try std.fs.path.join(self.allocator, &.{ tmp, archive_name });
        defer self.allocator.free(archive_path);

        self.note("downloading tarball", .{});
        try self.runArgvVerbose(&.{ "curl", "-fsSL", "-o", archive_path, tarball_url });
        defer std.Io.Dir.cwd().deleteFile(self.io, archive_path) catch {};

        self.note("extracting to {s}", .{install_dir});
        try self.runArgvVerbose(&.{ "tar", "-xzf", archive_path, "-C", install_dir });
    }

    /// Run an argv with no shell, no allocations of intermediate command lines.
    /// Logs stderr on non-zero exit. Errors map to InstallFailed.
    fn runArgvVerbose(self: *Installer, argv: []const []const u8) !void {
        const res = std.process.run(self.allocator, self.io, .{ .argv = argv }) catch |err| {
            log.err("Failed to run {s}: {}", .{ argv[0], err });
            return error.InstallFailed;
        };
        defer {
            self.allocator.free(res.stdout);
            self.allocator.free(res.stderr);
        }
        const exit_code = childExitCode(res.term);
        if (exit_code != 0) {
            log.err("{s} failed (exit={d}): {s}", .{ argv[0], exit_code, res.stderr });
            return error.InstallFailed;
        }
    }

    fn runCommand(self: *Installer, argv: []const []const u8) ![]u8 {
        const res = try std.process.run(self.allocator, self.io, .{
            .argv = argv,
        });
        if (childExitCode(res.term) != 0) {
            self.allocator.free(res.stdout);
            self.allocator.free(res.stderr);
            return error.CommandFailed;
        }
        self.allocator.free(res.stderr);
        return res.stdout;
    }

    pub fn ensureTypeScriptLS(self: *Installer, auto_install: bool) ![]const u8 {
        log.info("ensureTypeScriptLS called (auto_install={})", .{auto_install});
        const install_dir = try self.getInstallDir("typescript-language-server");
        defer self.allocator.free(install_dir);

        const entry_point = try std.fs.path.join(self.allocator, &.{ install_dir, "package", "lib", "cli.mjs" });
        errdefer self.allocator.free(entry_point);

        const file = std.Io.Dir.openFileAbsolute(self.io, entry_point, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (!auto_install) {
                    log.info("TypeScript LS not installed (run `stem lsp install typescript` to install)", .{});
                    return error.NotInstalled;
                }
                log.info("TypeScript LS not found at {s}, installing...", .{entry_point});
                try self.installNpmPackage("typescript-language-server", install_dir);

                std.Io.Dir.accessAbsolute(self.io, entry_point, .{}) catch |e| {
                    log.info("Verification failed for {s}: {}", .{ entry_point, e });
                    return error.InstallFailed;
                };

                log.info("Installation verified at {s}", .{entry_point});
                return entry_point;
            },
            else => return err,
        };
        file.close(self.io);
        log.info("TypeScript LS already installed at {s}", .{entry_point});
        return entry_point;
    }

    pub fn ensureGopls(self: *Installer, auto_install: bool) ![]const u8 {
        log.info("ensureGopls called (auto_install={})", .{auto_install});
        const install_dir = try self.getInstallDir("gopls");
        defer self.allocator.free(install_dir);

        const binary_name = if (builtin.os.tag == .windows) "gopls.exe" else "gopls";

        const entry_point = try std.fs.path.join(self.allocator, &.{ install_dir, "bin", binary_name });
        errdefer self.allocator.free(entry_point);

        const file = std.Io.Dir.openFileAbsolute(self.io, entry_point, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (!auto_install) {
                    log.info("gopls not installed (run `stem lsp install go` to install)", .{});
                    return error.NotInstalled;
                }
                log.info("gopls not found at {s}, installing...", .{entry_point});
                try self.installGopls(install_dir);

                std.Io.Dir.accessAbsolute(self.io, entry_point, .{}) catch |e| {
                    log.info("Verification failed for {s}: {}", .{ entry_point, e });
                    std.log.err("gopls installation failed. File not found: {s}. Error: {}", .{ entry_point, e });
                    return error.InstallFailed;
                };

                log.info("Installation verified at {s}", .{entry_point});
                return entry_point;
            },
            else => return err,
        };
        file.close(self.io);
        log.info("gopls already installed at {s}", .{entry_point});
        return entry_point;
    }

    fn installGopls(self: *Installer, install_dir: []const u8) !void {
        const bin_dir = try std.fs.path.join(self.allocator, &.{ install_dir, "bin" });
        defer self.allocator.free(bin_dir);
        try std.Io.Dir.cwd().createDirPath(self.io, bin_dir);

        self.note("running 'go install golang.org/x/tools/gopls@latest' (this can take a minute)", .{});

        // Pass GOBIN via the child's environment block rather than via shell
        // string interpolation.
        const argv = [_][]const u8{ "go", "install", "golang.org/x/tools/gopls@latest" };

        var env_map: std.process.Environ.Map = .init(self.allocator);
        defer env_map.deinit();
        // Inherit keys that matter for `go install`.
        const inherit_keys = [_][]const u8{ "PATH", "HOME", "USERPROFILE", "GOPATH", "GOMODCACHE", "GOCACHE", "GOPROXY", "GOFLAGS" };
        const platform = @import("../../kernel/platform.zig");
        for (inherit_keys) |k| {
            const v = platform.getEnv(self.allocator, self.environ_block, k) catch null;
            if (v) |val| {
                defer self.allocator.free(val);
                try env_map.put(k, val);
            }
        }
        try env_map.put("GOBIN", bin_dir);

        const res = std.process.run(self.allocator, self.io, .{
            .argv = &argv,
            .environ_map = &env_map,
        }) catch |err| {
            log.err("Failed to run 'go install': {} (is Go on PATH?)", .{err});
            return error.InstallFailed;
        };
        defer {
            self.allocator.free(res.stdout);
            self.allocator.free(res.stderr);
        }
        const exit_code = childExitCode(res.term);
        if (exit_code != 0) {
            log.err("'go install' failed (exit={d}): {s}", .{ exit_code, res.stderr });
            log.info("Note: gopls requires Go to be installed on your system.", .{});
            return error.InstallFailed;
        }

        log.info("gopls installation success", .{});
    }

    pub fn ensureRustAnalyzer(self: *Installer, auto_install: bool) ![]const u8 {
        log.info("ensureRustAnalyzer called (auto_install={})", .{auto_install});
        const install_dir = try self.getInstallDir("rust-analyzer");
        defer self.allocator.free(install_dir);

        const binary_name = if (builtin.os.tag == .windows) "rust-analyzer.exe" else "rust-analyzer";
        const entry_point = try std.fs.path.join(self.allocator, &.{ install_dir, binary_name });
        errdefer self.allocator.free(entry_point);

        const file = std.Io.Dir.openFileAbsolute(self.io, entry_point, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (!auto_install) {
                    log.info("rust-analyzer not installed (run `stem lsp install rust` to install)", .{});
                    return error.NotInstalled;
                }
                log.info("rust-analyzer not found at {s}, installing...", .{entry_point});
                try self.installRustAnalyzer(install_dir, binary_name);

                std.Io.Dir.accessAbsolute(self.io, entry_point, .{}) catch |e| {
                    log.info("Verification failed for {s}: {}", .{ entry_point, e });
                    return error.InstallFailed;
                };

                log.info("Installation verified at {s}", .{entry_point});
                return entry_point;
            },
            else => return err,
        };
        file.close(self.io);
        log.info("rust-analyzer already installed at {s}", .{entry_point});
        return entry_point;
    }

    fn installRustAnalyzer(self: *Installer, install_dir: []const u8, binary_name: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(self.io, install_dir);

        const arch = builtin.cpu.arch;
        const os = builtin.os.tag;

        const target_tuple = switch (os) {
            .macos => switch (arch) {
                .aarch64 => "aarch64-apple-darwin",
                .x86_64 => "x86_64-apple-darwin",
                else => return error.UnsupportedArch,
            },
            .linux => switch (arch) {
                .aarch64 => "aarch64-unknown-linux-gnu",
                .x86_64 => "x86_64-unknown-linux-gnu",
                else => return error.UnsupportedArch,
            },
            .windows => switch (arch) {
                .aarch64 => "aarch64-pc-windows-msvc",
                .x86_64 => "x86_64-pc-windows-msvc",
                else => return error.UnsupportedArch,
            },
            else => return error.UnsupportedOS,
        };

        const ext = if (os == .windows) ".zip" else ".gz";
        const download_url = try std.fmt.allocPrint(
            self.allocator,
            "https://github.com/rust-lang/rust-analyzer/releases/latest/download/rust-analyzer-{s}{s}",
            .{ target_tuple, ext },
        );
        defer self.allocator.free(download_url);

        self.note("downloading rust-analyzer ({s})", .{target_tuple});

        const tmp = try self.tempDir();
        defer self.allocator.free(tmp);
        const archive_name = try std.fmt.allocPrint(self.allocator, "stem-rust-analyzer{s}", .{ext});
        defer self.allocator.free(archive_name);
        const archive_path = try std.fs.path.join(self.allocator, &.{ tmp, archive_name });
        defer self.allocator.free(archive_path);

        try self.runArgvVerbose(&.{ "curl", "-fsSL", "-o", archive_path, download_url });
        defer std.Io.Dir.cwd().deleteFile(self.io, archive_path) catch {};
        self.note("extracting", .{});

        const final_path = try std.fs.path.join(self.allocator, &.{ install_dir, binary_name });
        defer self.allocator.free(final_path);

        if (os == .windows) {
            // Windows: extract zip into install_dir. Modern Windows ships tar
            // which can read zip; fall back to using tar with -xf.
            try self.runArgvVerbose(&.{ "tar", "-xf", archive_path, "-C", install_dir });
        } else {
            // Linux/macOS: gunzip the .gz to the final binary location.
            // `gunzip -c` writes to stdout — we can't easily redirect via argv,
            // so use `gzip -dc` and capture stdout, then write to file.
            const res = std.process.run(self.allocator, self.io, .{
                .argv = &.{ "gzip", "-dc", archive_path },
                .stdout_limit = .limited(64 * 1024 * 1024),
            }) catch |err| {
                log.err("Failed to gunzip rust-analyzer archive: {}", .{err});
                return error.InstallFailed;
            };
            defer {
                self.allocator.free(res.stdout);
                self.allocator.free(res.stderr);
            }
            const exit_code = childExitCode(res.term);
            if (exit_code != 0) {
                log.err("gunzip failed (exit={d}): {s}", .{ exit_code, res.stderr });
                return error.InstallFailed;
            }

            const out_file = try std.Io.Dir.createFileAbsolute(self.io, final_path, .{});
            defer out_file.close(self.io);
            try out_file.writeStreamingAll(self.io, res.stdout);
            // Mark the binary executable.
            out_file.setPermissions(self.io, std.Io.File.Permissions.executable_file) catch |e| {
                log.warn("Failed to chmod rust-analyzer +x: {}", .{e});
            };
        }

        log.info("rust-analyzer installed successfully", .{});
    }

    // ---------- clangd ----------
    //
    // clangd ships with LLVM and is almost always already installed on a dev
    // machine via Xcode CLI tools (macOS) or apt/yum (Linux). Rather than
    // downloading a ~80 MB clangd tarball we just look on PATH. If the user
    // doesn't have it, we tell them how to install it via their package
    // manager — that's the canonical path and gets them updates too.

    pub fn ensureClangd(self: *Installer, auto_install: bool) ![]const u8 {
        _ = auto_install; // we never auto-install clangd; PATH only
        const name = if (builtin.os.tag == .windows) "clangd.exe" else "clangd";
        if (self.findOnPath(name)) |p| {
            log.info("clangd found on PATH at {s}", .{p});
            return p;
        }
        log.info("clangd not on PATH. Install via your package manager:", .{});
        switch (builtin.os.tag) {
            .macos => log.info("  brew install llvm  (then add /usr/local/opt/llvm/bin to PATH)", .{}),
            .linux => log.info("  apt install clangd     or     dnf install clang-tools-extra", .{}),
            else => log.info("  Install LLVM/clang from https://releases.llvm.org/", .{}),
        }
        return error.NotInstalled;
    }

    /// Resolve a binary name on the user's PATH. Returns an owned
    /// absolute path string on hit, null on miss. Kept as a thin
    /// wrapper over `findBinary` so the simple case stays readable.
    fn findOnPath(self: *Installer, name: []const u8) ?[]u8 {
        return self.findBinary(name, &[_][]const u8{});
    }

    /// Search for `name` in PATH, then in well-known toolchain bin
    /// directories that GUI-launched stem (or a fresh shell before
    /// rc-files load) tends to miss. `extra_dirs` are tool-specific
    /// fallbacks the caller already knows about. Caller owns the
    /// returned slice.
    ///
    /// Order matters: PATH first (so user-overridden binaries win),
    /// then `extra_dirs` (tool-specific knowledge), then a bundled
    /// list of common locations (brew/cargo/ghcup/opam/coursier/
    /// sdkman/asdf/etc.). The first hit wins.
    fn findBinary(self: *Installer, name: []const u8, extra_dirs: []const []const u8) ?[]u8 {
        const platform = @import("../../kernel/platform.zig");
        const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';

        // Cross-platform env access — env.getPosix would crash the build on Windows.
        if (platform.getEnv(self.allocator, self.environ_block, "PATH") catch null) |path| {
            defer self.allocator.free(path);
            var it = std.mem.tokenizeScalar(u8, path, sep);
            while (it.next()) |dir| {
                if (self.tryJoinFile(dir, name)) |p| return p;
            }
        }

        for (extra_dirs) |dir| {
            if (self.expandAndTry(dir, name)) |p| return p;
        }

        // expandAndTry itself does HOME expansion; we don't need a
        // local `home` here. The previous code captured it for
        // documentation but never used it.
        const common = commonBinDirs();
        for (common) |dir| {
            if (self.expandAndTry(dir, name)) |p| return p;
        }

        // Some toolchains expose binaries via glob-y dirs (`~/.opam/<switch>/bin`,
        // `~/.sdkman/candidates/<tool>/current/bin`). Probe them too.
        if (self.findInOpamSwitches(name)) |p| return p;
        if (self.findInSdkmanCandidates(name)) |p| return p;
        return null;
    }

    /// Catalogue of well-known per-toolchain bin directories. Each
    /// entry may contain a leading `~/` which `expandAndTry` resolves
    /// against `$HOME` (or `%USERPROFILE%` on Windows).
    fn commonBinDirs() []const []const u8 {
        const posix = &[_][]const u8{
            // System / package-manager defaults.
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            // Per-user defaults written to by lots of installers.
            "~/.local/bin",
            "~/.local/share/coursier/bin",
            "~/Library/Application Support/Coursier/bin",
            // Language toolchain shims / bins.
            "~/.cargo/bin",
            "~/.ghcup/bin",
            "~/.cabal/bin",
            "~/.opam/default/bin",
            "~/.pub-cache/bin",
            "~/.gem/ruby/3.4.0/bin",
            "~/.gem/ruby/3.3.0/bin",
            "~/.gem/ruby/3.2.0/bin",
            "~/.gem/ruby/3.1.0/bin",
            "~/.asdf/shims",
            "~/.volta/bin",
            "~/.pyenv/shims",
            "~/.rbenv/shims",
            "~/.nodenv/shims",
            // Common scoop / clang prefix on macOS.
            "/opt/homebrew/opt/llvm/bin",
            "/usr/local/opt/llvm/bin",
        };
        const windows = &[_][]const u8{
            "~/scoop/shims",
            "~/AppData/Local/Programs/Python/Python312/Scripts",
            "~/AppData/Roaming/npm",
            "C:/Program Files/LLVM/bin",
            "C:/Program Files (x86)/LLVM/bin",
        };
        return if (builtin.os.tag == .windows) windows else posix;
    }

    fn tryJoinFile(self: *Installer, dir: []const u8, name: []const u8) ?[]u8 {
        // POSIX: just join + access. Windows: probe `name`, `name.exe`,
        // `name.cmd`, `name.bat` in that order — the bare name only
        // exists for tools that ship cygwin/msys2 launchers, while the
        // common case is `pylsp.exe`, `prettier.cmd` (npm-installed),
        // etc. Callers that already hard-code `.exe` (gopls, clangd,
        // rust-analyzer) still work because step 1 finds them.
        const candidate = std.fs.path.join(self.allocator, &.{ dir, name }) catch return null;
        if (std.Io.Dir.accessAbsolute(self.io, candidate, .{})) |_| {
            return candidate;
        } else |_| {}
        defer self.allocator.free(candidate);

        if (builtin.os.tag != .windows) return null;

        const win_exts = [_][]const u8{ ".exe", ".cmd", ".bat" };
        for (win_exts) |ext| {
            const full = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ candidate, ext }) catch continue;
            if (std.Io.Dir.accessAbsolute(self.io, full, .{})) |_| {
                return full;
            } else |_| {
                self.allocator.free(full);
            }
        }
        return null;
    }

    /// Resolve a `~/`-prefixed directory against `$HOME` (or
    /// `%USERPROFILE%`), then probe for `<dir>/<name>`.
    fn expandAndTry(self: *Installer, dir: []const u8, name: []const u8) ?[]u8 {
        const platform = @import("../../kernel/platform.zig");
        if (std.mem.startsWith(u8, dir, "~/")) {
            const home_opt: ?[]u8 = (platform.getEnv(self.allocator, self.environ_block, "HOME") catch null) orelse
                (platform.getEnv(self.allocator, self.environ_block, "USERPROFILE") catch null);
            const home = home_opt orelse return null;
            defer self.allocator.free(home);
            const expanded = std.fs.path.join(self.allocator, &.{ home, dir[2..] }) catch return null;
            defer self.allocator.free(expanded);
            return self.tryJoinFile(expanded, name);
        }
        return self.tryJoinFile(dir, name);
    }

    /// Walk `~/.opam/*/bin` for `name`. Opam uses one bin dir per
    /// switch (`~/.opam/default/bin`, `~/.opam/5.1.0/bin`, …) and
    /// users rarely have `default` set without overriding it, so a
    /// shallow scan is the only reliable way short of running
    /// `opam env`.
    fn findInOpamSwitches(self: *Installer, name: []const u8) ?[]u8 {
        const platform = @import("../../kernel/platform.zig");
        const home = (platform.getEnv(self.allocator, self.environ_block, "HOME") catch null) orelse
            (platform.getEnv(self.allocator, self.environ_block, "USERPROFILE") catch null) orelse return null;
        defer self.allocator.free(home);
        const opam_root = std.fs.path.join(self.allocator, &.{ home, ".opam" }) catch return null;
        defer self.allocator.free(opam_root);

        var dir = std.Io.Dir.openDirAbsolute(self.io, opam_root, .{ .iterate = true }) catch return null;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            // Skip non-switch dirs (opam keeps state in `repo/`, `log/`, etc).
            if (std.mem.eql(u8, entry.name, "repo") or
                std.mem.eql(u8, entry.name, "log") or
                std.mem.eql(u8, entry.name, "download-cache") or
                std.mem.eql(u8, entry.name, "plugins") or
                (entry.name.len > 0 and entry.name[0] == '.')) continue;
            const bin_dir = std.fs.path.join(self.allocator, &.{ opam_root, entry.name, "bin" }) catch continue;
            defer self.allocator.free(bin_dir);
            if (self.tryJoinFile(bin_dir, name)) |p| return p;
        }
        return null;
    }

    /// Walk `~/.sdkman/candidates/*/current/bin/` for `name`. SDKMAN
    /// is a common installer for JVM-ecosystem tools (Kotlin, Scala,
    /// gradle, etc.) and creates `current/` symlinks per candidate.
    fn findInSdkmanCandidates(self: *Installer, name: []const u8) ?[]u8 {
        const platform = @import("../../kernel/platform.zig");
        const home = (platform.getEnv(self.allocator, self.environ_block, "HOME") catch null) orelse
            (platform.getEnv(self.allocator, self.environ_block, "USERPROFILE") catch null) orelse return null;
        defer self.allocator.free(home);
        const root = std.fs.path.join(self.allocator, &.{ home, ".sdkman", "candidates" }) catch return null;
        defer self.allocator.free(root);

        var dir = std.Io.Dir.openDirAbsolute(self.io, root, .{ .iterate = true }) catch return null;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const bin_dir = std.fs.path.join(self.allocator, &.{ root, entry.name, "current", "bin" }) catch continue;
            defer self.allocator.free(bin_dir);
            if (self.tryJoinFile(bin_dir, name)) |p| return p;
        }
        return null;
    }

    // ---------- ruby-lsp ----------
    //
    // ruby-lsp is a Ruby gem. We rely on `gem install` because that's how
    // the Ruby ecosystem distributes binaries — there's no pre-built tarball.
    // The user-installed binary lives under `~/.gem/ruby/*/bin/ruby-lsp` or
    // wherever their gem env points. Search the standard candidates.

    pub fn ensureRubyLsp(self: *Installer, auto_install: bool) ![]const u8 {
        log.info("ensureRubyLsp called (auto_install={})", .{auto_install});

        // First, the easy case: PATH.
        if (self.findOnPath("ruby-lsp")) |p| {
            log.info("ruby-lsp found on PATH at {s}", .{p});
            return p;
        }

        if (!auto_install) {
            log.info("ruby-lsp not installed (run `stem lsp install ruby` to install via gem)", .{});
            return error.NotInstalled;
        }

        // Install via `gem install --user-install ruby-lsp`. User-install
        // avoids needing sudo and writes to ~/.gem.
        self.note("running 'gem install --user-install ruby-lsp'", .{});
        const res = std.process.run(self.allocator, self.io, .{
            .argv = &.{ "gem", "install", "--user-install", "--no-document", "ruby-lsp" },
        }) catch |err| {
            log.err("Failed to run 'gem install': {} (is Ruby installed?)", .{err});
            return error.InstallFailed;
        };
        defer {
            self.allocator.free(res.stdout);
            self.allocator.free(res.stderr);
        }
        const exit_code = childExitCode(res.term);
        if (exit_code != 0) {
            log.err("gem install ruby-lsp failed (exit={d}): {s}", .{ exit_code, res.stderr });
            return error.InstallFailed;
        }

        // After install, ruby-lsp's binary location depends on the gem env.
        // Re-check PATH (the gem user-install dir is usually already there)
        // and fall back to a few well-known locations.
        if (self.findOnPath("ruby-lsp")) |p| return p;

        const home = try self.homeDir();
        defer self.allocator.free(home);
        const candidates = [_][]const u8{
            ".gem/ruby/3.3.0/bin/ruby-lsp",
            ".gem/ruby/3.2.0/bin/ruby-lsp",
            ".gem/ruby/3.1.0/bin/ruby-lsp",
            ".local/share/gem/ruby/3.3.0/bin/ruby-lsp",
        };
        for (candidates) |rel| {
            const full = try std.fs.path.join(self.allocator, &.{ home, rel });
            std.Io.Dir.accessAbsolute(self.io, full, .{}) catch {
                self.allocator.free(full);
                continue;
            };
            return full;
        }

        log.err("ruby-lsp installed but binary not found on PATH. Add gem bin dir to PATH.", .{});
        return error.InstallFailed;
    }

    // ---------- OmniSharp (.NET LSP) ----------
    //
    // OmniSharp ships as a self-contained tarball per platform/arch on
    // GitHub releases. We pick the matching one, extract under
    // ~/.stem/lsp/omnisharp, and return the path to the `OmniSharp` binary.

    pub fn ensureOmniSharp(self: *Installer, auto_install: bool) ![]const u8 {
        log.info("ensureOmniSharp called (auto_install={})", .{auto_install});
        const install_dir = try self.getInstallDir("omnisharp");
        defer self.allocator.free(install_dir);

        const binary_name = if (builtin.os.tag == .windows) "OmniSharp.exe" else "OmniSharp";
        const entry_point = try std.fs.path.join(self.allocator, &.{ install_dir, binary_name });
        errdefer self.allocator.free(entry_point);

        const f = std.Io.Dir.openFileAbsolute(self.io, entry_point, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (!auto_install) {
                    log.info("OmniSharp not installed (run `stem lsp install csharp` to install)", .{});
                    return error.NotInstalled;
                }
                log.info("OmniSharp not found at {s}, installing...", .{entry_point});
                try self.installOmniSharp(install_dir);
                std.Io.Dir.accessAbsolute(self.io, entry_point, .{}) catch |e| {
                    log.err("OmniSharp install verification failed: {}", .{e});
                    return error.InstallFailed;
                };
                return entry_point;
            },
            else => return err,
        };
        f.close(self.io);
        log.info("OmniSharp already installed at {s}", .{entry_point});
        return entry_point;
    }

    fn installOmniSharp(self: *Installer, install_dir: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(self.io, install_dir);

        const arch = builtin.cpu.arch;
        const os = builtin.os.tag;
        const asset = switch (os) {
            .macos => switch (arch) {
                .aarch64 => "omnisharp-osx-arm64-net6.0.tar.gz",
                .x86_64 => "omnisharp-osx-x64-net6.0.tar.gz",
                else => return error.UnsupportedArch,
            },
            .linux => switch (arch) {
                .aarch64 => "omnisharp-linux-arm64-net6.0.tar.gz",
                .x86_64 => "omnisharp-linux-x64-net6.0.tar.gz",
                else => return error.UnsupportedArch,
            },
            .windows => switch (arch) {
                .x86_64 => "omnisharp-win-x64-net6.0.zip",
                else => return error.UnsupportedArch,
            },
            else => return error.UnsupportedOS,
        };
        const download_url = try std.fmt.allocPrint(
            self.allocator,
            "https://github.com/OmniSharp/omnisharp-roslyn/releases/latest/download/{s}",
            .{asset},
        );
        defer self.allocator.free(download_url);

        const tmp = try self.tempDir();
        defer self.allocator.free(tmp);
        const archive_path = try std.fs.path.join(self.allocator, &.{ tmp, asset });
        defer self.allocator.free(archive_path);

        self.note("downloading OmniSharp ({s})", .{asset});
        try self.runArgvVerbose(&.{ "curl", "-fsSL", "-o", archive_path, download_url });
        defer std.Io.Dir.cwd().deleteFile(self.io, archive_path) catch {};
        self.note("extracting", .{});

        try self.runArgvVerbose(&.{ "tar", "-xzf", archive_path, "-C", install_dir });
    }

    // ---------- jdtls (Eclipse JDT Language Server) ----------
    //
    // jdtls is the canonical Java LSP. It ships as a tarball with a launcher
    // jar that's run by `java -jar`. Setup is more involved than the others
    // because jdtls needs a JVM to run — we don't bundle that, just verify
    // `java` is on PATH at start time.

    pub fn ensureJdtls(self: *Installer, auto_install: bool) ![]const u8 {
        log.info("ensureJdtls called (auto_install={})", .{auto_install});
        const install_dir = try self.getInstallDir("jdtls");
        defer self.allocator.free(install_dir);

        const launcher = try findJdtlsLauncher(self.allocator, self.io, install_dir);
        if (launcher) |path| {
            log.info("jdtls launcher found at {s}", .{path});
            return path;
        }

        if (!auto_install) {
            log.info("jdtls not installed (run `stem lsp install java` to install)", .{});
            return error.NotInstalled;
        }

        self.note("downloading jdtls (~100 MB)", .{});
        try self.installJdtls(install_dir);

        const found = try findJdtlsLauncher(self.allocator, self.io, install_dir);
        if (found) |p| return p;
        log.err("jdtls install completed but launcher jar not found", .{});
        return error.InstallFailed;
    }

    fn findJdtlsLauncher(allocator: std.mem.Allocator, io: std.Io, install_dir: []const u8) !?[]u8 {
        // jdtls's launcher jar lives at `plugins/org.eclipse.equinox.launcher_*.jar`.
        // Find it by iterating the plugins dir.
        const plugins_dir = try std.fs.path.join(allocator, &.{ install_dir, "plugins" });
        defer allocator.free(plugins_dir);

        var dir = std.Io.Dir.openDirAbsolute(io, plugins_dir, .{ .iterate = true }) catch return null;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.startsWith(u8, entry.name, "org.eclipse.equinox.launcher_") and
                std.mem.endsWith(u8, entry.name, ".jar"))
            {
                return try std.fs.path.join(allocator, &.{ plugins_dir, entry.name });
            }
        }
        return null;
    }

    fn installJdtls(self: *Installer, install_dir: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(self.io, install_dir);

        // The Eclipse "stable latest" milestone tarball is the recommended
        // distribution. URL pattern is documented at
        // https://download.eclipse.org/jdtls/snapshots/.
        const download_url = "https://download.eclipse.org/jdtls/snapshots/jdt-language-server-latest.tar.gz";

        const tmp = try self.tempDir();
        defer self.allocator.free(tmp);
        const archive_path = try std.fs.path.join(self.allocator, &.{ tmp, "jdtls.tar.gz" });
        defer self.allocator.free(archive_path);

        try self.runArgvVerbose(&.{ "curl", "-fsSL", "-o", archive_path, download_url });
        defer std.Io.Dir.cwd().deleteFile(self.io, archive_path) catch {};

        self.note("extracting", .{});
        try self.runArgvVerbose(&.{ "tar", "-xzf", archive_path, "-C", install_dir });
    }

    // ---------- bash-language-server ----------
    //
    // Distributed as an npm package; we mirror the Pyright pattern.

    pub fn ensureBashLanguageServer(self: *Installer, auto_install: bool) ![]const u8 {
        log.info("ensureBashLanguageServer called (auto_install={})", .{auto_install});
        const install_dir = try self.getInstallDir("bash-language-server");
        defer self.allocator.free(install_dir);

        const entry_point = try std.fs.path.join(self.allocator, &.{ install_dir, "package", "out", "cli.js" });
        errdefer self.allocator.free(entry_point);

        const file = std.Io.Dir.openFileAbsolute(self.io, entry_point, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (!auto_install) {
                    log.info("bash-language-server not installed (run `stem lsp install bash`)", .{});
                    return error.NotInstalled;
                }
                self.note("installing bash-language-server via npm tarball", .{});
                try self.installNpmPackage("bash-language-server", install_dir);
                std.Io.Dir.accessAbsolute(self.io, entry_point, .{}) catch |e| {
                    log.err("bash-language-server install verification failed: {}", .{e});
                    return error.InstallFailed;
                };
                return entry_point;
            },
            else => return err,
        };
        file.close(self.io);
        log.info("bash-language-server already installed at {s}", .{entry_point});
        return entry_point;
    }

    // ---------- lua-language-server ----------
    //
    // lua-language-server (sumneko) ships as a platform-specific tarball on
    // GitHub releases — single self-contained binary per platform, no system
    // Lua needed at runtime. We download into ~/.stem/lsp/lua-language-server
    // and return the path to the launcher binary.

    pub fn ensureLuaLanguageServer(self: *Installer, auto_install: bool) ![]const u8 {
        log.info("ensureLuaLanguageServer called (auto_install={})", .{auto_install});
        const install_dir = try self.getInstallDir("lua-language-server");
        defer self.allocator.free(install_dir);

        const binary_name = if (builtin.os.tag == .windows) "lua-language-server.exe" else "lua-language-server";
        const entry_point = try std.fs.path.join(self.allocator, &.{ install_dir, "bin", binary_name });
        errdefer self.allocator.free(entry_point);

        const file = std.Io.Dir.openFileAbsolute(self.io, entry_point, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                // PATH fallback before downloading — users with `brew install
                // lua-language-server` already have it and we'd rather use
                // theirs (gets security updates via brew).
                if (self.findOnPath(binary_name)) |p| {
                    self.allocator.free(entry_point);
                    log.info("lua-language-server found on PATH at {s}", .{p});
                    return p;
                }
                if (!auto_install) {
                    log.info("lua-language-server not installed (run `stem lsp install lua`)", .{});
                    return error.NotInstalled;
                }
                self.note("downloading lua-language-server from GitHub releases", .{});
                try self.installLuaLanguageServer(install_dir);
                std.Io.Dir.accessAbsolute(self.io, entry_point, .{}) catch |e| {
                    log.err("lua-language-server install verification failed: {}", .{e});
                    return error.InstallFailed;
                };
                return entry_point;
            },
            else => return err,
        };
        file.close(self.io);
        log.info("lua-language-server already installed at {s}", .{entry_point});
        return entry_point;
    }

    fn installLuaLanguageServer(self: *Installer, install_dir: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(self.io, install_dir);

        // sumneko publishes a per-platform tarball. Version is pinned to a
        // recent stable — bumping it is a one-line change.
        const version = "3.13.6";
        const arch = builtin.cpu.arch;
        const os = builtin.os.tag;
        const asset_suffix = switch (os) {
            .macos => switch (arch) {
                .aarch64 => "darwin-arm64.tar.gz",
                .x86_64 => "darwin-x64.tar.gz",
                else => return error.UnsupportedArch,
            },
            .linux => switch (arch) {
                .aarch64 => "linux-arm64.tar.gz",
                .x86_64 => "linux-x64.tar.gz",
                else => return error.UnsupportedArch,
            },
            .windows => switch (arch) {
                .x86_64 => "win32-x64.zip",
                else => return error.UnsupportedArch,
            },
            else => return error.UnsupportedOS,
        };
        const download_url = try std.fmt.allocPrint(
            self.allocator,
            "https://github.com/LuaLS/lua-language-server/releases/download/{s}/lua-language-server-{s}-{s}",
            .{ version, version, asset_suffix },
        );
        defer self.allocator.free(download_url);

        const tmp = try self.tempDir();
        defer self.allocator.free(tmp);
        const archive_name = try std.fmt.allocPrint(self.allocator, "lua-ls.{s}", .{asset_suffix});
        defer self.allocator.free(archive_name);
        const archive_path = try std.fs.path.join(self.allocator, &.{ tmp, archive_name });
        defer self.allocator.free(archive_path);

        self.note("downloading lua-language-server {s} ({s})", .{ version, asset_suffix });
        try self.runArgvVerbose(&.{ "curl", "-fsSL", "-o", archive_path, download_url });
        defer std.Io.Dir.cwd().deleteFile(self.io, archive_path) catch {};

        self.note("extracting", .{});
        if (std.mem.endsWith(u8, asset_suffix, ".zip")) {
            try self.runArgvVerbose(&.{ "unzip", "-q", archive_path, "-d", install_dir });
        } else {
            try self.runArgvVerbose(&.{ "tar", "-xzf", archive_path, "-C", install_dir });
        }
    }

    // ---------- sourcekit-lsp (Swift) ----------
    //
    // sourcekit-lsp ships with the Swift toolchain (Xcode on macOS, swiftly
    // / swift.org tarballs on Linux). No reasonable way to vendor it
    // independently of Swift itself — just look on PATH and tell the user
    // where to get the toolchain.

    pub fn ensureSourcekitLsp(self: *Installer, auto_install: bool) ![]const u8 {
        _ = auto_install;
        const name = if (builtin.os.tag == .windows) "sourcekit-lsp.exe" else "sourcekit-lsp";
        if (self.findOnPath(name)) |p| {
            log.info("sourcekit-lsp found on PATH at {s}", .{p});
            return p;
        }
        log.info("sourcekit-lsp not on PATH. Install the Swift toolchain:", .{});
        switch (builtin.os.tag) {
            .macos => log.info("  Install Xcode from the App Store, or just the Command Line Tools: xcode-select --install", .{}),
            .linux => log.info("  Install Swift from https://www.swift.org/install/linux/ (the tarball includes sourcekit-lsp)", .{}),
            else => log.info("  Install Swift from https://www.swift.org/install/", .{}),
        }
        return error.NotInstalled;
    }

    // ---------- R languageserver ----------
    //
    // The canonical R LSP is the `languageserver` CRAN package, invoked as
    // `R --slave -e "languageserver::run()"`. It needs R installed plus that
    // one package. We can't install R itself, but we can offer to install
    // the package if R is present.

    pub fn ensureRLanguageServer(self: *Installer, auto_install: bool) ![]const u8 {
        const r_bin = if (builtin.os.tag == .windows) "R.exe" else "R";
        const r_path = self.findOnPath(r_bin) orelse {
            log.info("R not on PATH. Install R first:", .{});
            switch (builtin.os.tag) {
                .macos => log.info("  brew install r       (or https://cran.r-project.org/bin/macosx/)", .{}),
                .linux => log.info("  apt install r-base   (or your distro's package manager)", .{}),
                else => log.info("  https://cran.r-project.org/", .{}),
            }
            return error.NotInstalled;
        };

        // Detect whether `languageserver` is installed in any of the user's
        // R library paths. `Rscript -e 'cat(requireNamespace(...))'` writes
        // TRUE/FALSE to stdout.
        const probe = std.process.run(self.allocator, self.io, .{
            .argv = &.{ r_path, "--slave", "-e", "cat(requireNamespace('languageserver', quietly=TRUE))" },
        }) catch |err| {
            log.err("Failed to probe R for languageserver: {}", .{err});
            self.allocator.free(r_path);
            return error.NotInstalled;
        };
        defer {
            self.allocator.free(probe.stdout);
            self.allocator.free(probe.stderr);
        }

        const has_pkg = std.mem.indexOf(u8, probe.stdout, "TRUE") != null;
        if (has_pkg) return r_path;

        if (!auto_install) {
            log.info("R 'languageserver' package not installed. Run `stem lsp install r` or in R:", .{});
            log.info("  install.packages('languageserver')", .{});
            self.allocator.free(r_path);
            return error.NotInstalled;
        }

        self.note("installing R 'languageserver' package (this can take a few minutes)", .{});
        const install_res = std.process.run(self.allocator, self.io, .{
            .argv = &.{ r_path, "--slave", "-e", "install.packages('languageserver', repos='https://cloud.r-project.org')" },
        }) catch |err| {
            log.err("Failed to run R install: {}", .{err});
            self.allocator.free(r_path);
            return error.InstallFailed;
        };
        defer {
            self.allocator.free(install_res.stdout);
            self.allocator.free(install_res.stderr);
        }
        const exit_code = childExitCode(install_res.term);
        if (exit_code != 0) {
            log.err("R languageserver install failed (exit={d}): {s}", .{ exit_code, install_res.stderr });
            self.allocator.free(r_path);
            return error.InstallFailed;
        }
        return r_path;
    }

    // ---------- vscode-langservers-extracted (CSS / HTML / JSON) ----------
    //
    // One npm package ships three lightweight servers: CSS, HTML, and
    // JSON. We install once into ~/.stem/lsp/vscode-langservers-extracted
    // and return the right binary path per language. The binaries are
    // node scripts; spawn via `node <path> --stdio`.

    fn vsLangServerInstall(self: *Installer, auto_install: bool) ![]const u8 {
        const install_dir = try self.getInstallDir("vscode-langservers-extracted");
        errdefer self.allocator.free(install_dir);

        const marker = try std.fs.path.join(self.allocator, &.{ install_dir, "package", "package.json" });
        defer self.allocator.free(marker);

        const file = std.Io.Dir.openFileAbsolute(self.io, marker, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (!auto_install) return error.NotInstalled;
                self.note("installing vscode-langservers-extracted via npm tarball", .{});
                try self.installNpmPackage("vscode-langservers-extracted", install_dir);
                std.Io.Dir.accessAbsolute(self.io, marker, .{}) catch |e| {
                    log.err("vscode-langservers-extracted install verification failed: {}", .{e});
                    self.allocator.free(install_dir);
                    return error.InstallFailed;
                };
                return install_dir;
            },
            else => return err,
        };
        file.close(self.io);
        return install_dir;
    }

    fn vsLangServerBin(self: *Installer, auto_install: bool, binary_rel: []const u8) ![]const u8 {
        const install_dir = try self.vsLangServerInstall(auto_install);
        defer self.allocator.free(install_dir);
        return std.fs.path.join(self.allocator, &.{ install_dir, "package", binary_rel });
    }

    pub fn ensureCssLanguageServer(self: *Installer, auto_install: bool) ![]const u8 {
        return self.vsLangServerBin(auto_install, "bin/vscode-css-language-server");
    }

    pub fn ensureHtmlLanguageServer(self: *Installer, auto_install: bool) ![]const u8 {
        return self.vsLangServerBin(auto_install, "bin/vscode-html-language-server");
    }

    pub fn ensureJsonLanguageServer(self: *Installer, auto_install: bool) ![]const u8 {
        return self.vsLangServerBin(auto_install, "bin/vscode-json-language-server");
    }

    // ---------- intelephense (PHP) ----------

    pub fn ensureIntelephense(self: *Installer, auto_install: bool) ![]const u8 {
        const install_dir = try self.getInstallDir("intelephense");
        defer self.allocator.free(install_dir);

        const entry_point = try std.fs.path.join(self.allocator, &.{ install_dir, "package", "lib", "intelephense.js" });
        errdefer self.allocator.free(entry_point);

        const file = std.Io.Dir.openFileAbsolute(self.io, entry_point, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (!auto_install) return error.NotInstalled;
                self.note("installing intelephense via npm tarball", .{});
                try self.installNpmPackage("intelephense", install_dir);
                std.Io.Dir.accessAbsolute(self.io, entry_point, .{}) catch |e| {
                    log.err("intelephense install verification failed: {}", .{e});
                    return error.InstallFailed;
                };
                return entry_point;
            },
            else => return err,
        };
        file.close(self.io);
        return entry_point;
    }

    // ---------- perlnavigator (Perl) ----------

    pub fn ensurePerlNavigator(self: *Installer, auto_install: bool) ![]const u8 {
        const install_dir = try self.getInstallDir("perlnavigator");
        defer self.allocator.free(install_dir);

        // `perlnavigator-server` package ships its bin script as a
        // shell wrapper around `node`. We invoke the JS directly to
        // skip an extra exec.
        const entry_point = try std.fs.path.join(self.allocator, &.{ install_dir, "package", "out", "server.js" });
        errdefer self.allocator.free(entry_point);

        const file = std.Io.Dir.openFileAbsolute(self.io, entry_point, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (!auto_install) return error.NotInstalled;
                self.note("installing perlnavigator-server via npm tarball", .{});
                try self.installNpmPackage("perlnavigator-server", install_dir);
                std.Io.Dir.accessAbsolute(self.io, entry_point, .{}) catch |e| {
                    log.err("perlnavigator install verification failed: {}", .{e});
                    return error.InstallFailed;
                };
                return entry_point;
            },
            else => return err,
        };
        file.close(self.io);
        return entry_point;
    }

    // ---------- PATH-only servers ----------
    //
    // The following all rely on external toolchains: Dart (dart SDK),
    // Elixir (mix / asdf), Erlang (rebar3), Haskell (ghcup), Kotlin
    // (sdkman / brew), OCaml (opam), Scala (coursier). We don't try
    // to install those toolchains ourselves — just look for the LSP
    // binary on PATH and give the user a one-line hint if it's
    // missing.

    fn ensureOnPath(
        self: *Installer,
        binary: []const u8,
        install_hint: []const u8,
    ) ![]const u8 {
        if (self.findOnPath(binary)) |p| return p;
        log.info("{s} not on PATH. {s}", .{ binary, install_hint });
        return error.NotInstalled;
    }

    pub fn ensureDartLanguageServer(self: *Installer, auto_install: bool) ![]const u8 {
        _ = auto_install;
        return self.ensureOnPath(
            if (builtin.os.tag == .windows) "dart.exe" else "dart",
            "Install the Dart SDK from https://dart.dev/get-dart or `brew install dart`.",
        );
    }

    pub fn ensureElixirLs(self: *Installer, auto_install: bool) ![]const u8 {
        _ = auto_install;
        return self.ensureOnPath(
            "elixir-ls",
            "Install elixir-ls from https://github.com/elixir-lsp/elixir-ls/releases or `brew install elixir-ls`.",
        );
    }

    pub fn ensureErlangLs(self: *Installer, auto_install: bool) ![]const u8 {
        _ = auto_install;
        return self.ensureOnPath(
            "erlang_ls",
            "Install erlang_ls from https://github.com/erlang-ls/erlang_ls (requires Erlang/OTP + rebar3).",
        );
    }

    pub fn ensureHaskellLanguageServer(self: *Installer, auto_install: bool) ![]const u8 {
        _ = auto_install;
        // The launcher script picks the right server binary for the
        // GHC the project uses; the bare `haskell-language-server`
        // binary is a pinned version. Prefer the launcher.
        if (self.findOnPath("haskell-language-server-wrapper")) |p| return p;
        return self.ensureOnPath(
            "haskell-language-server",
            "Install via `ghcup install hls` (https://www.haskell.org/ghcup/).",
        );
    }

    pub fn ensureKotlinLanguageServer(self: *Installer, auto_install: bool) ![]const u8 {
        _ = auto_install;
        return self.ensureOnPath(
            "kotlin-language-server",
            "Install kotlin-language-server from https://github.com/fwcd/kotlin-language-server/releases or `brew install kotlin-language-server`.",
        );
    }

    pub fn ensureOcamlLsp(self: *Installer, auto_install: bool) ![]const u8 {
        _ = auto_install;
        return self.ensureOnPath(
            "ocamllsp",
            "Install via `opam install ocaml-lsp-server` (https://opam.ocaml.org/).",
        );
    }

    pub fn ensureMetals(self: *Installer, auto_install: bool) ![]const u8 {
        _ = auto_install;
        return self.ensureOnPath(
            "metals",
            "Install via `coursier install metals` (https://scalameta.org/metals/).",
        );
    }
};
