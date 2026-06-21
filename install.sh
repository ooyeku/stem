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

# WSL-on-Windows-filesystem guard.
#
# When the repo is checked out under /mnt/c (or any /mnt/<drive>)
# and we're inside WSL, Zig's per-build cache lives at .zig-cache/
# next to build.zig — i.e. on the Windows NTFS volume reached via
# the 9P/DrvFs translation layer. DrvFs does not honor POSIX
# rename(2) the way ext4 does (cross-mount renames return EACCES,
# and Defender real-time scanning grabs freshly-written .o/.lib
# files long enough to block the rename), which is why the build
# fails with:
#
#   failed to rename compilation results into local cache: AccessDenied
#
# Redirect ZIG_LOCAL_CACHE_DIR onto the WSL ext4 home dir so the
# cache lives on a real Linux filesystem. The downloaded-deps
# cache (ZIG_GLOBAL_CACHE_DIR, default ~/.cache/zig) is already on
# ext4, so we leave it alone.
case "$(pwd -P)" in
    /mnt/*)
        if [ -z "${ZIG_LOCAL_CACHE_DIR:-}" ] && \
           grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null; then
            export ZIG_LOCAL_CACHE_DIR="$HOME/.cache/stem-build"
            mkdir -p "$ZIG_LOCAL_CACHE_DIR"
            echo "Note: WSL on a Windows-mounted path detected."
            echo "      Redirecting Zig build cache to $ZIG_LOCAL_CACHE_DIR"
            echo "      (DrvFs rename(2) is unreliable; cache must live on ext4.)"
        fi
        ;;
esac

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
$SUDO cp zig-out/bin/stem-lsp-host "$BIN_DIR/stem-lsp-host"
$SUDO cp zig-out/bin/stem-lsp-zig "$BIN_DIR/stem-lsp-zig"
$SUDO chmod +x "$BIN_DIR/stem" "$BIN_DIR/stem-lsp-host" "$BIN_DIR/stem-lsp-zig"

# On macOS the kernel sometimes SIGKILLs a freshly-`cp`'d binary
# whose embedded adhoc signature got invalidated by the copy. Re-
# signing in place repairs the signature against the new on-disk
# location. Harmless no-op on other platforms (codesign absent).
if command -v codesign >/dev/null 2>&1; then
    for bin in stem stem-lsp-host stem-lsp-zig; do
        $SUDO codesign --force -s - "$BIN_DIR/$bin" >/dev/null 2>&1 || true
    done
fi

# ===== Bundled plugin install =====
# Bundled plugins now ship as directories (plugin.json + entry
# artifact). Each one goes to <PLUGIN_DIR>/<name>/ alongside its
# manifest. Legacy flat .dylib copies are no longer produced or
# installed; the seed-on-first-launch pathway in stem still handles
# third-party .dylib plugins dropped directly into ~/.stem/plugins/.

install_plugin_dir() {
    # $1 = source directory under bundled/plugins/
    # $2 = artifact filename under zig-out/bin/ (or zig-out/lib/)
    # $3 = "$DEST" for system, "$USER" for per-user
    local src_dir="$1"
    local artifact="$2"
    local target_root="$3"

    local name
    name="$(basename "$src_dir")"
    local dest_dir="$target_root/$name"

    if [ ! -d "$src_dir" ]; then
        echo "  (skip $name: source dir missing)" >&2
        return
    fi

    if [ "$target_root" = "$PLUGIN_DIR" ]; then
        $SUDO rm -rf "$dest_dir"
        $SUDO mkdir -p "$dest_dir"
        $SUDO cp "$src_dir/plugin.json" "$dest_dir/"
        if [ -f "zig-out/bin/$artifact" ]; then
            $SUDO cp "zig-out/bin/$artifact" "$dest_dir/"
        elif [ -f "zig-out/lib/$artifact" ]; then
            $SUDO cp "zig-out/lib/$artifact" "$dest_dir/"
        fi
    else
        rm -rf "$dest_dir"
        mkdir -p "$dest_dir"
        cp "$src_dir/plugin.json" "$dest_dir/"
        if [ -f "zig-out/bin/$artifact" ]; then
            cp "zig-out/bin/$artifact" "$dest_dir/"
        elif [ -f "zig-out/lib/$artifact" ]; then
            cp "zig-out/lib/$artifact" "$dest_dir/"
        fi
    fi
}

USER_PLUGIN_DIR="$HOME/.stem/plugins"
mkdir -p "$USER_PLUGIN_DIR"

# Wasm bundled plugins: echo, git, plugin-manager, sdk demo.
WASM_PLUGINS="echo git-wasm plugin-manager-wasm sdk-demo"

echo "Installing bundled wasm plugins to $PLUGIN_DIR/"
for name in $WASM_PLUGINS; do
    install_plugin_dir "bundled/plugins/$name" "$name.wasm" "$PLUGIN_DIR"
    echo "  $PLUGIN_DIR/$name/"
done

echo ""
echo "Refreshing per-user plugin dir: $USER_PLUGIN_DIR"
for name in $WASM_PLUGINS; do
    install_plugin_dir "bundled/plugins/$name" "$name.wasm" "$USER_PLUGIN_DIR"
done

# Sweep dylib plugins from older releases out of the per-user dir.
# stem no longer has a dylib loader at all; any leftover .dylib would
# just be dead bytes on disk, but removing them keeps `~/.stem/plugins`
# clean and avoids confusion in `stem plugin list`.
if [ -d "$USER_PLUGIN_DIR" ]; then
    for stale in "$USER_PLUGIN_DIR"/*.dylib "$USER_PLUGIN_DIR"/*.so "$USER_PLUGIN_DIR"/*.dll; do
        [ -f "$stale" ] || continue
        rm -f "$stale"
        echo "  removed legacy $stale"
    done
fi

echo ""
echo "Installed:"
echo "  $BIN_DIR/stem"
echo "  $PLUGIN_DIR/{$(echo "$WASM_PLUGINS" | tr ' ' ',')}/"
echo "  $USER_PLUGIN_DIR/  (refreshed)"

if ! printf '%s' "$PATH" | tr ':' '\n' | grep -Fxq "$BIN_DIR"; then
    echo ""
    echo "Note: $BIN_DIR is not in your PATH. Add to your shell profile:"
    echo "  export PATH=\"\$PATH:$BIN_DIR\""
fi

echo ""
echo "Optional: install language servers (Python / TS / Go / Rust) with:"
echo "  stem lsp install all"
