#!/bin/sh
# Install stem from a prebuilt GitHub release tarball.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ooyeku/stem/main/scripts/install.sh | sh
#
# Optional environment variables:
#   STEM_VERSION   Specific version to install (e.g. v0.6.0). Defaults to latest.
#   STEM_PREFIX    Install prefix. Defaults to /usr/local if writable
#                  (or sudo is available), else $HOME/.local.

set -eu

REPO="ooyeku/stem"
VERSION="${STEM_VERSION:-}"
PREFIX="${STEM_PREFIX:-}"

err()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

require() {
    command -v "$1" >/dev/null 2>&1 || err "missing required command: $1"
}

require curl
require tar
require uname

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
    Darwin) os_label="macos" ;;
    Linux)  os_label="linux" ;;
    *)      err "unsupported OS: $OS" ;;
esac

case "$ARCH" in
    arm64|aarch64) arch_label="aarch64" ;;
    x86_64|amd64)  arch_label="x86_64"  ;;
    *)             err "unsupported architecture: $ARCH" ;;
esac

target="${arch_label}-${os_label}"

if [ -z "$VERSION" ]; then
    info "Resolving latest stem release..."
    # Try the "latest" endpoint first — fastest, but it skips prereleases.
    VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
        | grep -E '"tag_name":' | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
    # Fall back to the full release list (which includes prereleases) if the
    # "latest" endpoint 404'd — common on repos that have only ever cut
    # prerelease tags.
    if [ -z "$VERSION" ]; then
        VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases" 2>/dev/null \
            | grep -E '"tag_name":' | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
    fi
    [ -n "$VERSION" ] || err "could not resolve latest version. Set STEM_VERSION=vX.Y.Z to install a specific tag."
fi
info "Installing stem $VERSION for $target"

archive="stem-${VERSION}-${target}.tar.gz"
url="https://github.com/${REPO}/releases/download/${VERSION}/${archive}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
info "Downloading $url"
if ! curl -fsSL "$url" -o "$tmp/$archive"; then
    err "download failed: $url

The release '$VERSION' may not have a prebuilt binary for $target.
Visit https://github.com/${REPO}/releases to see what's available, or
set STEM_VERSION=vX.Y.Z to choose a different tag."
fi

# Optional checksum verification — only if shasum/sha256sum is available and the
# .sha256 file is present in the release.
if curl -fsSL "$url.sha256" -o "$tmp/$archive.sha256" 2>/dev/null; then
    if command -v shasum >/dev/null 2>&1; then
        (cd "$tmp" && shasum -a 256 -c "$archive.sha256") || err "checksum verification failed"
        info "Verified SHA-256 checksum."
    elif command -v sha256sum >/dev/null 2>&1; then
        (cd "$tmp" && sha256sum -c "$archive.sha256") || err "checksum verification failed"
        info "Verified SHA-256 checksum."
    else
        info "warning: neither shasum nor sha256sum found; skipping checksum verification."
    fi
else
    info "warning: $url.sha256 not available; skipping checksum verification."
fi

(cd "$tmp" && tar -xzf "$archive")
staged="$(find "$tmp" -maxdepth 1 -type d -name 'stem-*' | head -n1)"
[ -n "$staged" ] || err "could not find extracted directory"

# Pick a prefix if one wasn't passed via STEM_PREFIX.
if [ -z "$PREFIX" ]; then
    if [ -w "/usr/local" ] || { [ ! -e "/usr/local" ] && [ -w "/usr" ]; }; then
        PREFIX="/usr/local"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        PREFIX="/usr/local"
    else
        PREFIX="$HOME/.local"
        info "Note: no write access to /usr/local; installing under $PREFIX"
    fi
fi

BIN_DIR="$PREFIX/bin"
PLUGIN_DIR="$PREFIX/lib/stem/plugins"

SUDO=""
if [ -e "$PREFIX" ] && [ ! -w "$PREFIX" ]; then
    SUDO="sudo"
fi

$SUDO mkdir -p "$BIN_DIR" "$PLUGIN_DIR"
$SUDO cp "$staged/bin/stem" "$BIN_DIR/stem"
$SUDO chmod +x "$BIN_DIR/stem"
if [ -d "$staged/lib/stem/plugins" ]; then
    for f in "$staged"/lib/stem/plugins/*; do
        [ -f "$f" ] || continue
        $SUDO cp "$f" "$PLUGIN_DIR/"
    done
fi

info ""
info "Installed stem $VERSION:"
info "  $BIN_DIR/stem"
info "  $PLUGIN_DIR/*"

if ! printf '%s' "$PATH" | tr ':' '\n' | grep -Fxq "$BIN_DIR"; then
    info ""
    info "Note: $BIN_DIR is not in your PATH. Add to your shell profile:"
    info "  export PATH=\"\$PATH:$BIN_DIR\""
fi

info ""
info "Run 'stem --help' to get started."
info "Optional: install language servers with 'stem lsp install all'."
