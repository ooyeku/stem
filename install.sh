#!/bin/sh
# Build stem from source and install it system-wide.
#
# Usage:
#   ./install.sh             Build (ReleaseFast) and install
#   ./install.sh --prefix P  Install under <P>/bin and <P>/lib/stem/plugins
#
# Defaults: prefix is /usr/local if writable (or sudo is available passwordless),
# else $HOME/.local.

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
            sed -n '2,10p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
    esac
done

if ! command -v zig >/dev/null 2>&1; then
    echo "Error: zig is required to build from source." >&2
    echo "Install Zig 0.16+ from https://ziglang.org/download/ and retry." >&2
    echo "(For a prebuilt binary, see the README's Quick Start.)" >&2
    exit 1
fi

echo "Building stem (ReleaseFast)..."
zig build -Doptimize=ReleaseFast

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

echo "Installing stem binary to $BIN_DIR"
echo "Installing bundled plugins to $PLUGIN_DIR"

$SUDO mkdir -p "$BIN_DIR" "$PLUGIN_DIR"
$SUDO cp zig-out/bin/stem "$BIN_DIR/stem"
$SUDO chmod +x "$BIN_DIR/stem"

for lib in zig-out/lib/libgit.* zig-out/lib/libmarkdown_viewer.* zig-out/lib/libplugin_manager.*; do
    [ -f "$lib" ] || continue
    $SUDO cp "$lib" "$PLUGIN_DIR/"
done

echo ""
echo "Installed:"
echo "  $BIN_DIR/stem"
echo "  $PLUGIN_DIR/*"

if ! printf '%s' "$PATH" | tr ':' '\n' | grep -Fxq "$BIN_DIR"; then
    echo ""
    echo "Note: $BIN_DIR is not in your PATH. Add to your shell profile:"
    echo "  export PATH=\"\$PATH:$BIN_DIR\""
fi

echo ""
echo "Optional: install language servers (Python / TS / Go / Rust) with:"
echo "  stem lsp install all"
