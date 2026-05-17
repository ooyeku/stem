#!/bin/sh
# Remove the stem binary and bundled plugins.
#
# Usage:
#   ./uninstall.sh           Remove binary + bundled plugins
#   ./uninstall.sh --purge   Also remove ~/.stem (config, user plugins, logs,
#                            installed language servers)

set -e

PURGE=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        -h|--help)
            sed -n '2,7p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

removed_any=0

remove_under() {
    prefix="$1"
    bin="$prefix/bin/stem"
    plugins="$prefix/lib/stem"
    sudo=""
    if [ -e "$prefix" ] && [ ! -w "$prefix" ]; then
        sudo="sudo"
    fi
    if [ -f "$bin" ]; then
        $sudo rm -f "$bin"
        echo "Removed $bin"
        removed_any=1
    fi
    if [ -d "$plugins" ]; then
        $sudo rm -rf "$plugins"
        echo "Removed $plugins"
        removed_any=1
    fi
}

remove_under "/usr/local"
remove_under "$HOME/.local"

if [ "$removed_any" -eq 0 ]; then
    echo "stem was not found in /usr/local or \$HOME/.local."
fi

if [ "$PURGE" -eq 1 ]; then
    if [ -d "$HOME/.stem" ]; then
        printf 'Delete %s? This cannot be undone. [y/N] ' "$HOME/.stem"
        read -r reply
        case "$reply" in
            y|Y|yes|YES)
                rm -rf "$HOME/.stem"
                echo "Removed $HOME/.stem"
                ;;
            *)
                echo "Skipped $HOME/.stem"
                ;;
        esac
    fi
fi

echo "Done."
