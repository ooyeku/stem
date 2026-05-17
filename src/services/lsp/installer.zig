const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.LSPInstaller);

pub const Installer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_block: std.process.Environ.Block,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ_block: std.process.Environ.Block) Installer {
        return .{
            .allocator = allocator,
            .io = io,
            .environ_block = environ_block,
        };
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
        const env: std.process.Environ = .{ .block = self.environ_block };
        if (env.getPosix("HOME")) |h| return self.allocator.dupe(u8, h);
        if (builtin.os.tag == .windows) {
            if (env.getPosix("USERPROFILE")) |up| return self.allocator.dupe(u8, up);
        }
        return error.HomeNotFound;
    }

    fn getInstallDir(self: *Installer, name: []const u8) ![]const u8 {
        const home = try self.homeDir();
        defer self.allocator.free(home);
        return try std.fs.path.join(self.allocator, &.{ home, ".stem", "lsp", name });
    }

    fn tempDir(self: *Installer) ![]u8 {
        if (builtin.os.tag == .windows) {
            const env: std.process.Environ = .{ .block = self.environ_block };
            if (env.getPosix("TEMP")) |t| return self.allocator.dupe(u8, t);
            if (env.getPosix("TMP")) |t| return self.allocator.dupe(u8, t);
            return self.allocator.dupe(u8, "C:\\Windows\\Temp");
        }
        return self.allocator.dupe(u8, "/tmp");
    }

    /// Fetch JSON metadata for an npm package and return the dist.tarball URL.
    /// Caller frees the returned slice.
    fn fetchNpmTarballUrl(self: *Installer, package: []const u8) ![]u8 {
        const metadata_url = try std.fmt.allocPrint(self.allocator, "https://registry.npmjs.org/{s}/latest", .{package});
        defer self.allocator.free(metadata_url);
        log.info("Fetching metadata from {s}", .{metadata_url});

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
        log.info("Found tarball: {s}", .{tarball_url});

        try std.Io.Dir.cwd().createDirPath(self.io, install_dir);

        const tmp = try self.tempDir();
        defer self.allocator.free(tmp);
        const archive_name = try std.fmt.allocPrint(self.allocator, "stem-{s}.tgz", .{package});
        defer self.allocator.free(archive_name);
        const archive_path = try std.fs.path.join(self.allocator, &.{ tmp, archive_name });
        defer self.allocator.free(archive_path);

        try self.runArgvVerbose(&.{ "curl", "-fsSL", "-o", archive_path, tarball_url });
        defer std.Io.Dir.cwd().deleteFile(self.io, archive_path) catch {};

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
        if (res.term.exited != 0) {
            log.err("{s} failed (exit={d}): {s}", .{ argv[0], res.term.exited, res.stderr });
            return error.InstallFailed;
        }
    }

    fn runCommand(self: *Installer, argv: []const []const u8) ![]u8 {
        const res = try std.process.run(self.allocator, self.io, .{
            .argv = argv,
        });
        if (res.term.exited != 0) {
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

        log.info("Installing gopls via 'go install' with GOBIN={s}", .{bin_dir});

        // Pass GOBIN via the child's environment block rather than via shell
        // string interpolation.
        const argv = [_][]const u8{ "go", "install", "golang.org/x/tools/gopls@latest" };

        var env_map: std.process.Environ.Map = .init(self.allocator);
        defer env_map.deinit();
        // Inherit keys that matter for `go install`.
        const inherit_keys = [_][]const u8{ "PATH", "HOME", "USERPROFILE", "GOPATH", "GOMODCACHE", "GOCACHE", "GOPROXY", "GOFLAGS" };
        const parent: std.process.Environ = .{ .block = self.environ_block };
        for (inherit_keys) |k| {
            if (parent.getPosix(k)) |v| try env_map.put(k, v);
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
        if (res.term.exited != 0) {
            log.err("'go install' failed (exit={d}): {s}", .{ res.term.exited, res.stderr });
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

        log.info("Downloading rust-analyzer from {s}", .{download_url});

        const tmp = try self.tempDir();
        defer self.allocator.free(tmp);
        const archive_name = try std.fmt.allocPrint(self.allocator, "stem-rust-analyzer{s}", .{ext});
        defer self.allocator.free(archive_name);
        const archive_path = try std.fs.path.join(self.allocator, &.{ tmp, archive_name });
        defer self.allocator.free(archive_path);

        try self.runArgvVerbose(&.{ "curl", "-fsSL", "-o", archive_path, download_url });
        defer std.Io.Dir.cwd().deleteFile(self.io, archive_path) catch {};

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
            if (res.term.exited != 0) {
                log.err("gunzip failed (exit={d}): {s}", .{ res.term.exited, res.stderr });
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

    /// Resolve a binary name on the user's PATH. Returns an owned absolute
    /// path string on hit, null on miss. Used by language servers that ship
    /// with system toolchains (clangd, jdtls launcher script).
    fn findOnPath(self: *Installer, name: []const u8) ?[]u8 {
        const env: std.process.Environ = .{ .block = self.environ_block };
        const path = env.getPosix("PATH") orelse return null;
        var it = std.mem.tokenizeScalar(u8, path, if (builtin.os.tag == .windows) ';' else ':');
        while (it.next()) |dir| {
            const candidate = std.fs.path.join(self.allocator, &.{ dir, name }) catch continue;
            // Check that it's executable. `access` with .mode = .read_only
            // would be enough to confirm existence; we trust PATH placement
            // to mean executable.
            std.Io.Dir.accessAbsolute(self.io, candidate, .{}) catch {
                self.allocator.free(candidate);
                continue;
            };
            return candidate;
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
        log.info("Installing ruby-lsp via 'gem install --user-install ruby-lsp'", .{});
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
        if (res.term.exited != 0) {
            log.err("gem install ruby-lsp failed (exit={d}): {s}", .{ res.term.exited, res.stderr });
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

        try self.runArgvVerbose(&.{ "curl", "-fsSL", "-o", archive_path, download_url });
        defer std.Io.Dir.cwd().deleteFile(self.io, archive_path) catch {};

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

        log.info("Installing jdtls...", .{});
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

        try self.runArgvVerbose(&.{ "tar", "-xzf", archive_path, "-C", install_dir });
    }
};
