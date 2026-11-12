#!/bin/bash
# install.sh — install the launcher and runtime.
#
# Modes:
#   ./install.sh            per-user (~/.local/bin + runtime stays in ~/.local/share)
#   ./install.sh --system   system-wide (/usr/local/bin + /opt/pdx-controller-wine)
#   ./install.sh --run      run after install
#   NO_CONFIRM=1 ./install.sh   non-interactive

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="user"
ACTION="install"
RUN_AFTER=0
NO_CONFIRM="${NO_CONFIRM:-0}"
UNINSTALL_LIB=""

usage() {
    cat <<'USAGE'
Usage: install.sh [--system] [--run] [--help]

Options:
  --system    System-wide install (/usr/local/bin + /opt/pdx-controller-wine)
  --run       Launch PDX Controller after install
  --uninstall Remove launcher, fetch, runtime, prefix, and cache
  --help      Show this help

Default: per-user install (~/.local/bin + ~/.local/share/pdx-controller-wine)
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --system) MODE="system"; shift ;;
        --run)    RUN_AFTER=1; shift ;;
        --uninstall) ACTION="uninstall"; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

log()  { printf '\033[1;36m[install]\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[1;33mwarn\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# Sanity checks
[ -x "$PROJECT_DIR/bin/pdx-controller-wine" ] || die "launcher not found in $PROJECT_DIR/bin/"
[ -x "$PROJECT_DIR/bin/fetch-pdx.sh" ] || die "fetch-pdx.sh not found in $PROJECT_DIR/bin/"

PER_USER_RUNTIME="$HOME/.local/share/pdx-controller-wine/runtime"
if [ ! -x "$PER_USER_RUNTIME/bin/wine" ]; then
    die "runtime not found at $PER_USER_RUNTIME/bin/wine
       Run first: $PROJECT_DIR/bin/build-runtime.sh"
fi

if [ "$ACTION" = "uninstall" ]; then
    # Auto-detect mode if not explicit
    if [ -x "/usr/local/bin/pdx-controller-wine" ] && [ "$MODE" != "user" ]; then
        MODE="system"
    fi
    case "$MODE" in
        user)
            LAUNCHER="$HOME/.local/bin/pdx-controller-wine"
            LIB_DIR="$HOME/.local/lib/pdx-controller-wine"
            ;;
        system)
            LAUNCHER="/usr/local/bin/pdx-controller-wine"
            LIB_DIR="/usr/local/lib/pdx-controller-wine"
            ;;
    esac
    RUNTIME_DIR="${PDX_RUNTIME:-$HOME/.local/share/pdx-controller-wine/runtime}"
    PREFIX_DIR="${PDX_PREFIX:-$HOME/.local/share/pdx-controller-wine/prefix}"
    CACHE_DIR="$HOME/.local/share/pdx-controller-wine/cache"

    log "Uninstall (${MODE})"
    [ -e "$LAUNCHER" ] && { sudo rm -f "$LAUNCHER" 2>/dev/null || rm -f "$LAUNCHER"; ok "removed launcher: $LAUNCHER"; } || warn "launcher not present: $LAUNCHER"
    [ -d "$LIB_DIR" ] && { sudo rm -rf "$LIB_DIR" 2>/dev/null || rm -rf "$LIB_DIR"; ok "removed: $LIB_DIR"; } || warn "not present: $LIB_DIR"

    if [ -d "$RUNTIME_DIR" ]; then
        size=$(du -sh "$RUNTIME_DIR" 2>/dev/null | cut -f1)
        if [ "$NO_CONFIRM" = "1" ] || [ ! -t 0 ]; then
            reply="y"
        else
            read -r -p "Remove runtime ($size at $RUNTIME_DIR)? [y/N] " reply
        fi
        case "$reply" in
            [yY]|[yY][eE][sS]) rm -rf "$RUNTIME_DIR"; ok "removed runtime";;
            *) warn "kept runtime";;
        esac
    fi

    if [ -d "$PREFIX_DIR" ]; then
        size=$(du -sh "$PREFIX_DIR" 2>/dev/null | cut -f1)
        if [ "$NO_CONFIRM" = "1" ] || [ ! -t 0 ]; then
            reply="y"
        else
            read -r -p "Remove prefix ($size at $PREFIX_DIR)? [y/N] " reply
        fi
        case "$reply" in
            [yY]|[yY][eE][sS]) rm -rf "$PREFIX_DIR"; ok "removed prefix";;
            *) warn "kept prefix";;
        esac
    fi

    if [ -d "$CACHE_DIR" ]; then
        rm -rf "$CACHE_DIR"; ok "removed cache"
    fi

    echo ""
    log "Uninstall complete."
    log "Build artifacts (build/) and apt packages were not removed."
    log "To also remove them: rm -rf $PROJECT_DIR/build"
    exit 0
fi

case "$MODE" in
    user)
        log "Per-user install (no sudo needed)"
        BIN_DIR="$HOME/.local/bin"
        LIB_DIR="$HOME/.local/lib/pdx-controller-wine"
        mkdir -p "$BIN_DIR" "$LIB_DIR"
        install -m 755 "$PROJECT_DIR/bin/pdx-controller-wine" "$BIN_DIR/pdx-controller-wine"
        install -m 755 "$PROJECT_DIR/bin/fetch-pdx.sh" "$LIB_DIR/fetch-pdx.sh"
        UNINSTALL_LIB="$LIB_DIR"
        ok "launcher: $BIN_DIR/pdx-controller-wine"
        ok "fetch:    $LIB_DIR/fetch-pdx.sh"
        ok "runtime:  $PER_USER_RUNTIME (unchanged)"
        # PATH hint
        case ":$PATH:" in
            *":$BIN_DIR:"*) ok "$BIN_DIR is already in PATH" ;;
            *) warn "$BIN_DIR is not in PATH — add it with:"
               printf '         export PATH="%s:$PATH"\n' "$BIN_DIR" ;;
        esac
        ;;
    system)
        log "System install (sudo will be requested)"
        sudo mkdir -p /opt/pdx-controller-wine /usr/local/lib/pdx-controller-wine /usr/local/bin
        # Runtime: copy (do not move — per-user one is still useful for dev)
        if [ ! -x /opt/pdx-controller-wine/runtime/bin/wine ]; then
            log "Copying runtime to /opt/pdx-controller-wine/runtime (~1.7 GB)..."
            sudo cp -r "$PER_USER_RUNTIME" /opt/pdx-controller-wine/runtime
        else
            ok "runtime already at /opt/pdx-controller-wine/runtime"
        fi
        sudo install -m 755 "$PROJECT_DIR/bin/pdx-controller-wine" /usr/local/bin/pdx-controller-wine
        sudo install -m 755 "$PROJECT_DIR/bin/fetch-pdx.sh" /usr/local/lib/pdx-controller-wine/fetch-pdx.sh
        UNINSTALL_LIB="/usr/local/lib/pdx-controller-wine"
        ok "launcher: /usr/local/bin/pdx-controller-wine"
        ok "fetch:    /usr/local/lib/pdx-controller-wine/fetch-pdx.sh"
        ok "runtime:  /opt/pdx-controller-wine/runtime"
        ;;
esac

echo ""
log "Verifying installation..."
if [ "$MODE" = "system" ]; then
    LAUNCHER="/usr/local/bin/pdx-controller-wine"
else
    LAUNCHER="$HOME/.local/bin/pdx-controller-wine"
fi
"$LAUNCHER" --check || warn "--check reported issues; run 'pdx-controller-wine --check' for details"

if [ "$RUN_AFTER" = "1" ]; then
    echo ""
    log "Launching PDX Controller..."
    "$LAUNCHER" || warn "launcher returned non-zero"
fi

echo ""
log "Done. Run: pdx-controller-wine"
log "Uninstall: rm -f ${LAUNCHER} && rm -rf ${UNINSTALL_LIB}"
