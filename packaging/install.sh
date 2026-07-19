#!/bin/sh
# Install a prebuilt stem release. This script ships inside the release
# tarball next to the binaries — run it from the extracted directory:
#
#   ./install.sh             Install to /usr/local (or ~/.local, see below)
#   ./install.sh --prefix P  Install under <P>/bin and <P>/lib/stem/plugins
#
# Mirrors the from-source install.sh in the repo, minus the build step:
# same prefix selection (/usr/local if writable or passwordless sudo,
# else $HOME/.local), same plugin layout, same per-user plugin refresh.
# On macOS it also clears the Gatekeeper quarantine attribute and
# refreshes the ad-hoc code signature, so binaries downloaded with a
# browser run without the "Apple could not verify" dialog.

set -e

PREFIX=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            PREFIX="$2"
            shift 2
            ;;
        --prefix=*)
            PREFIX="${1#--prefix=}"
            shift
            ;;
        -h|--help)
            sed -n '2,13p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
    esac
done

# Run from the extracted release directory regardless of invocation path.
cd "$(dirname "$0")"

if [ ! -f "./stem" ]; then
    echo "Error: ./stem not found next to this script." >&2
    echo "Run install.sh from inside the extracted release directory." >&2
    exit 1
fi

# Pick a prefix if one wasn't passed.
if [ -z "$PREFIX" ]; then
    if [ -w "/usr/local" ] || { [ ! -e "/usr/local" ] && [ -w "/usr" ]; }; then
        PREFIX="/usr/local"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        PREFIX="/usr/local"
    else
        PREFIX="$HOME/.local"
        echo "Note: no write access to /usr/local; installing under $PREFIX"
    fi
fi

BIN_DIR="$PREFIX/bin"
PLUGIN_DIR="$PREFIX/lib/stem/plugins"

SUDO=""
if [ -e "$PREFIX" ] && [ ! -w "$PREFIX" ]; then
    SUDO="sudo"
fi

# Binaries present in the tarball. Older tarballs shipped only `stem`;
# the LSP host binaries are optional so this script works for both.
BINARIES="stem"
for extra in stem-lsp-host stem-lsp-zig; do
    [ -f "./$extra" ] && BINARIES="$BINARIES $extra"
done

echo "Installing stem binaries to $BIN_DIR"
$SUDO mkdir -p "$BIN_DIR" "$PLUGIN_DIR"
for bin in $BINARIES; do
    $SUDO cp "./$bin" "$BIN_DIR/$bin"
    $SUDO chmod +x "$BIN_DIR/$bin"
done

# macOS: a browser download tags the archive (and everything extracted
# from it) with com.apple.quarantine, which makes Gatekeeper refuse to
# run the binary. Clear it, then refresh the ad-hoc signature in place —
# the copy above can invalidate the embedded signature's file-location
# binding. Both are harmless no-ops elsewhere (tools absent).
if command -v xattr >/dev/null 2>&1; then
    for bin in $BINARIES; do
        $SUDO xattr -d com.apple.quarantine "$BIN_DIR/$bin" 2>/dev/null || true
    done
fi
if command -v codesign >/dev/null 2>&1; then
    for bin in $BINARIES; do
        $SUDO codesign --force -s - "$BIN_DIR/$bin" >/dev/null 2>&1 || true
    done
fi

# ===== Bundled plugin install =====
# The tarball ships plugins pre-assembled as plugins/<name>/{plugin.json,
# <name>.wasm} — the exact layout the plugin loader expects — so install
# is a straight directory copy, system-wide and per-user.

USER_PLUGIN_DIR="$HOME/.stem/plugins"
mkdir -p "$USER_PLUGIN_DIR"

INSTALLED_PLUGINS=""
if [ -d "./plugins" ]; then
    echo "Installing bundled wasm plugins to $PLUGIN_DIR/"
    for src_dir in ./plugins/*/; do
        [ -d "$src_dir" ] || continue
        name="$(basename "$src_dir")"
        INSTALLED_PLUGINS="$INSTALLED_PLUGINS $name"

        $SUDO rm -rf "$PLUGIN_DIR/$name"
        $SUDO mkdir -p "$PLUGIN_DIR/$name"
        $SUDO cp "$src_dir"* "$PLUGIN_DIR/$name/"
        echo "  $PLUGIN_DIR/$name/"

        rm -rf "$USER_PLUGIN_DIR/$name"
        mkdir -p "$USER_PLUGIN_DIR/$name"
        cp "$src_dir"* "$USER_PLUGIN_DIR/$name/"
    done
    echo ""
    echo "Refreshed per-user plugin dir: $USER_PLUGIN_DIR"
fi

# Sweep native plugins from older releases out of the per-user dir —
# stem no longer has a native plugin loader; leftovers just confuse
# `stem plugin list`.
for stale in "$USER_PLUGIN_DIR"/*.dylib "$USER_PLUGIN_DIR"/*.so "$USER_PLUGIN_DIR"/*.dll; do
    [ -f "$stale" ] || continue
    rm -f "$stale"
    echo "  removed legacy $stale"
done

echo ""
echo "Installed:"
for bin in $BINARIES; do
    echo "  $BIN_DIR/$bin"
done
if [ -n "$INSTALLED_PLUGINS" ]; then
    echo "  $PLUGIN_DIR/{$(echo "$INSTALLED_PLUGINS" | sed 's/^ //;s/ /,/g')}/"
fi

# PATH check: if the bin dir is already on PATH, stem works right away.
# Otherwise name the exact profile file for the user's shell so the fix
# is one copy-paste.
if printf '%s' "$PATH" | tr ':' '\n' | grep -Fxq "$BIN_DIR"; then
    echo ""
    echo "$BIN_DIR is on your PATH — run: stem"
else
    case "${SHELL:-}" in
        */zsh)  profile="$HOME/.zshrc" ;;
        */bash) profile="$HOME/.bashrc" ;;
        */fish) profile="" ;;
        *)      profile="$HOME/.profile" ;;
    esac
    echo ""
    echo "Note: $BIN_DIR is not in your PATH."
    if [ -n "${SHELL:-}" ] && [ -z "$profile" ]; then
        echo "Add it for fish with:"
        echo "  fish_add_path $BIN_DIR"
    else
        echo "Add it by appending this line to ${profile:-your shell profile}:"
        echo "  export PATH=\"\$PATH:$BIN_DIR\""
        echo "then restart your shell (or run it inline for this session)."
    fi
fi

echo ""
echo "Optional: install language servers (Python / TS / Go / Rust) with:"
echo "  stem lsp install all"
