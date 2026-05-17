//! Filetype gating for bulk file opens.
//!
//! When the user opens a directory (Shift+Enter in the file picker, or
//! `stem somedir/` from the CLI), we walk the tree and add buffers for every
//! "openable" file. Binaries — images, archives, compiled objects — would
//! corrupt the terminal if we tried to render them, and offer nothing useful
//! anyway, so they're skipped here.
//!
//! The policy is: only accept files whose extension or basename is on a
//! small allowlist of "text source, config, or docs." Anything else is
//! filtered out at scan time. Users can still open an arbitrary file via
//! `:e <path>` if they really want.

const std = @import("std");

/// Returns true if `path` looks like a text file worth opening in the
/// editor. Decision is made purely from the filename — no I/O.
pub fn isOpenable(path: []const u8) bool {
    const basename = std.fs.path.basename(path);
    if (basename.len == 0) return false;

    // First match by full basename for files with no useful extension
    // (Dockerfile, Makefile, README, etc.).
    for (allowed_basenames) |name| {
        if (std.ascii.eqlIgnoreCase(basename, name)) return true;
    }

    const ext = std.fs.path.extension(basename);
    if (ext.len == 0) return false; // no extension and not on the basename allowlist

    for (allowed_extensions) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

const allowed_extensions = [_][]const u8{
    // stem itself
    ".stem",

    // languages
    ".zig",
    ".zon",
    ".py",
    ".pyi",
    ".pyx",
    ".ts",
    ".tsx",
    ".js",
    ".jsx",
    ".mjs",
    ".cjs",
    ".rs",
    ".go",
    ".c",
    ".h",
    ".cpp",
    ".hpp",
    ".cc",
    ".cxx",
    ".hxx",
    ".m",
    ".mm",
    ".java",
    ".kt",
    ".kts",
    ".scala",
    ".groovy",
    ".gradle",
    ".rb",
    ".swift",
    ".php",
    ".cs",
    ".fs",
    ".fsi",
    ".vb",
    ".dart",
    ".lua",
    ".ex",
    ".exs",
    ".erl",
    ".hrl",
    ".eex",
    ".leex",
    ".heex",
    ".clj",
    ".cljs",
    ".cljc",
    ".edn",
    ".ml",
    ".mli",
    ".re",
    ".rei",
    ".hs",
    ".lhs",
    ".nim",
    ".nims",
    ".d",
    ".v",
    ".vh",
    ".sv",
    ".svh",
    ".vhd",
    ".sh",
    ".bash",
    ".zsh",
    ".fish",
    ".ps1",
    ".bat",
    ".cmd",
    ".vim",
    ".sql",
    ".r",
    ".rmd",
    ".jl",
    ".pl",
    ".pm",
    ".tcl",
    ".asm",
    ".s",
    ".coffee",
    ".elm",
    ".cr",
    ".zsh",
    ".bashrc",
    ".raku",
    ".rakumod",

    // shaders / GPU
    ".glsl",
    ".vert",
    ".frag",
    ".geom",
    ".tesc",
    ".tese",
    ".comp",
    ".hlsl",
    ".wgsl",
    ".metal",

    // IDL / bindings / build
    ".proto",
    ".thrift",
    ".capnp",
    ".graphql",
    ".gql",
    ".bzl",
    ".bazel",
    ".star",
    ".cmake",
    ".mk",
    ".ninja",

    // markup / docs
    ".md",
    ".markdown",
    ".mdx",
    ".rst",
    ".org",
    ".tex",
    ".latex",
    ".bib",
    ".adoc",
    ".asciidoc",
    ".txt",
    ".text",
    ".log",

    // config / data
    ".json",
    ".jsonc",
    ".json5",
    ".yaml",
    ".yml",
    ".toml",
    ".xml",
    ".html",
    ".htm",
    ".xhtml",
    ".svg",
    ".css",
    ".scss",
    ".sass",
    ".less",
    ".styl",
    ".ini",
    ".cfg",
    ".conf",
    ".properties",
    ".env",
    ".csv",
    ".tsv",
    ".dockerfile",
    ".plist",
    ".lock", // Cargo.lock, package-lock.json (jsonish; viewable)

    // diff / patch
    ".diff",
    ".patch",

    // git / editor
    ".gitignore",
    ".gitattributes",
    ".gitmodules",
    ".gitconfig",
    ".editorconfig",
    ".dockerignore",
};

const allowed_basenames = [_][]const u8{
    "Dockerfile",
    "Makefile",
    "GNUmakefile",
    "CMakeLists.txt",
    "README",
    "LICENSE",
    "COPYING",
    "AUTHORS",
    "CHANGELOG",
    "CHANGES",
    "HISTORY",
    "CONTRIBUTING",
    "NOTICE",
    "TODO",
    "Rakefile",
    "Gemfile",
    "Procfile",
    "Berksfile",
    "Vagrantfile",
    "Jenkinsfile",
    "Cargo.lock",
    "Cargo.toml",
    "go.sum",
    "package.json",
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "tsconfig.json",
    "jsconfig.json",
    "pyproject.toml",
    "requirements.txt",
    ".gitignore",
    ".gitattributes",
    ".editorconfig",
    ".dockerignore",
    ".envrc",
    ".prettierrc",
    ".eslintrc",
};

test "isOpenable: common code files" {
    try std.testing.expect(isOpenable("/foo/bar.zig"));
    try std.testing.expect(isOpenable("src/main.py"));
    try std.testing.expect(isOpenable("README.md"));
    try std.testing.expect(isOpenable("README")); // basename allowlist
    try std.testing.expect(isOpenable("Dockerfile"));
    try std.testing.expect(isOpenable("./.gitignore"));
    try std.testing.expect(isOpenable("config.toml"));
}

test "isOpenable: binaries and unknown rejected" {
    try std.testing.expect(!isOpenable("photo.png"));
    try std.testing.expect(!isOpenable("archive.zip"));
    try std.testing.expect(!isOpenable("a.out"));
    try std.testing.expect(!isOpenable("libfoo.so"));
    try std.testing.expect(!isOpenable("libfoo.dylib"));
    try std.testing.expect(!isOpenable("bin/stem")); // no extension, unknown basename
    try std.testing.expect(!isOpenable("module.pyc"));
    try std.testing.expect(!isOpenable("class.class"));
}

test "isOpenable: case insensitive" {
    try std.testing.expect(isOpenable("foo.ZIG"));
    try std.testing.expect(isOpenable("DOCKERFILE"));
    try std.testing.expect(isOpenable("Readme"));
}

test "isOpenable: empty path" {
    try std.testing.expect(!isOpenable(""));
}

test "isOpenable: path with multiple dots uses final extension" {
    try std.testing.expect(isOpenable("foo.bar.zig"));
    try std.testing.expect(isOpenable("/a/b.c/d/file.py"));
    try std.testing.expect(!isOpenable("archive.tar.gz")); // .gz not allowed
}

test "isOpenable: extension-less filenames" {
    // README has no extension; basename allowlist catches it.
    try std.testing.expect(isOpenable("README"));
    try std.testing.expect(isOpenable("/some/path/README"));
    // "foo" has no extension and not in basename list.
    try std.testing.expect(!isOpenable("foo"));
    try std.testing.expect(!isOpenable("/usr/bin/stem"));
}

test "isOpenable: hidden dotfiles" {
    // Allowed dotfiles (treated as extensions by std.fs.path.extension).
    try std.testing.expect(isOpenable(".gitignore"));
    try std.testing.expect(isOpenable("/repo/.gitignore"));
    try std.testing.expect(isOpenable(".editorconfig"));
    // Random dotfile shouldn't slip through.
    try std.testing.expect(!isOpenable(".DS_Store"));
    try std.testing.expect(!isOpenable(".env.local"));
}

test "isOpenable: known binary extensions rejected" {
    const binaries = [_][]const u8{
        "image.png",  "image.jpg",   "image.jpeg",
        "doc.pdf",    "doc.docx",    "video.mp4",
        "audio.mp3",  "archive.zip", "archive.tar",
        "archive.gz", "lib.so",      "lib.dylib",
        "lib.dll",    "obj.o",       "obj.a",
        "py.pyc",     "java.class",
    };
    for (binaries) |b| {
        try std.testing.expect(!isOpenable(b));
    }
}

test "isOpenable: path separators don't confuse" {
    try std.testing.expect(isOpenable("a/b/c/d/main.zig"));
    try std.testing.expect(isOpenable("/abs/path/to/Makefile"));
    try std.testing.expect(!isOpenable("/abs/path/binary.exe"));
}
