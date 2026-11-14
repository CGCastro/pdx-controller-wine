#!/bin/bash
# install.sh — install the launcher and runtime.
#
# Modes:
#   ./install.sh            per-user (~/.local/bin + runtime stays in ~/.local/share)
#   ./install.sh --system   system-wide (/usr/local/bin + /opt/pdx-controller-wine)
#   ./install.sh --run      run after install
#   NO_CONFIRM=1 ./install.sh   non-interactive
#
# Can also be run directly from the network:
#   curl -fsSL https://raw.githubusercontent.com/CGCastro/pdx-controller-wine/master/bin/install.sh | bash
# In that case it installs git if missing, clones the repository to
# $PDX_SRC_DIR (default ~/GITs/pdx-controller-wine), and re-execs from there.

set -euo pipefail

# --- bootstrap: allow `curl ... | bash` ---
# When run from a clone, BASH_SOURCE points at bin/install.sh and its
# parent directory contains bin/build-runtime.sh. When piped from curl,
# BASH_SOURCE is /dev/stdin (or empty) and the check fails — in that case
# clone the repository and re-exec from the clone.
_self="${BASH_SOURCE[0]:-}"
if [ -n "$_self" ] && [ -f "$_self" ]; then
    _proj="$(cd "$(dirname "$_self")/.." 2>/dev/null && pwd || true)"
else
    _proj=""
fi
if [ -z "$_proj" ] || [ ! -f "$_proj/bin/build-runtime.sh" ]; then
    _bootstrap="${PDX_SRC_DIR:-$HOME/GITs/pdx-controller-wine}"
    printf '[install] running outside a clone — bootstrapping to %s\n' "$_bootstrap"
    if ! command -v git >/dev/null 2>&1; then
        printf '[install] git missing — installing\n'
        _sudo=""
        if [ "$(id -u)" != "0" ]; then
            if command -v sudo >/dev/null 2>&1; then
                _sudo="sudo"
            else
                printf '[install] not root and sudo not available — install git manually and rerun\n' >&2
                exit 1
            fi
        fi
        if   command -v apt-get >/dev/null 2>&1; then $_sudo apt-get update -qq && $_sudo apt-get install -y git
        elif command -v dnf     >/dev/null 2>&1; then $_sudo dnf install -y git
        elif command -v pacman  >/dev/null 2>&1; then $_sudo pacman -S --noconfirm git
        else
            printf '[install] no supported package manager — install git manually and rerun\n' >&2
            exit 1
        fi
    fi
    if [ ! -d "$_bootstrap/.git" ]; then
        git clone https://github.com/CGCastro/pdx-controller-wine.git "$_bootstrap" \
            || { printf '[install] clone failed\n' >&2; exit 1; }
    else
        ( cd "$_bootstrap" && git pull --ff-only ) || true
    fi
    if [ ! -f "$_bootstrap/bin/build-runtime.sh" ]; then
        printf '[install] clone is missing bin/build-runtime.sh — aborting\n' >&2
        exit 1
    fi
    exec bash "$_bootstrap/bin/install.sh" "$@"
fi

PROJECT_DIR="$_proj"
MODE="user"
ACTION="install"
RUN_AFTER=0
FULL_INSTALL=0
NO_CONFIRM="${NO_CONFIRM:-0}"
UNINSTALL_LIB=""

usage() {
    cat <<'USAGE'
Usage: install.sh [--system] [--run] [--help]

Options:
  --system    System-wide install (/usr/local/bin + /opt/pdx-controller-wine)
  --run       Launch PDX Controller after install
  --full      Install dependencies, build Wine (~30-60 min), install the
              PDX Controller, then optionally launch. Implies --run.
  --cleanup   Remove build tree, download caches, tracked apt packages.
              Keeps runtime, prefix and launcher so the app still runs.
  --uninstall Remove launcher, fetch, runtime, prefix, and cache
  --yes, -y   Auto-confirm cleanup (non-interactive)
  --help      Show this help

Default: per-user install (~/.local/bin + ~/.local/share/pdx-controller-wine)
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --system) MODE="system"; shift ;;
        --run)    RUN_AFTER=1; shift ;;
        --full)   FULL_INSTALL=1; RUN_AFTER=1; shift ;;
        --cleanup) ACTION="cleanup"; shift ;;
        --yes|-y) NO_CONFIRM=1; shift ;;
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
if [ "$ACTION" = "cleanup" ] || [ "$ACTION" = "uninstall" ]; then
    : # cleanup and uninstall do not need the runtime to exist
elif [ "$FULL_INSTALL" = "1" ] && [ "$ACTION" = "install" ]; then
    : # run_full builds the runtime before installing the launcher
elif [ ! -x "$PER_USER_RUNTIME/bin/wine" ]; then
    die "runtime not found at $PER_USER_RUNTIME/bin/wine
       Run first: $PROJECT_DIR/bin/build-runtime.sh
       Or run this script with --full to build it and install."
fi

# --- dependency detection / installation / full install ---

# Ask a question on the controlling terminal. When piped from curl, stdin
# is the pipe, not the tty. Read from /dev/tty instead.
ask() {
    local prompt="$1" default="$2" reply=""
    if [ -t 0 ] && [ -t 1 ]; then
        read -r -p "$prompt" reply
    elif [ -r /dev/tty ] && [ -w /dev/tty ]; then
        printf '%s' "$prompt" >/dev/tty
        read -r reply </dev/tty || reply=""
    fi
    echo "${reply:-$default}"
}

detect_missing_deps() {
    MISSING_CMDS=()
    MISSING_PC=()
    for cmd in git curl sha256sum tar patch make gcc pkg-config unzip winetricks; do
        command -v "$cmd" >/dev/null 2>&1 || MISSING_CMDS+=("$cmd")
    done
    for cc in x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc; do
        command -v "$cc" >/dev/null 2>&1 || MISSING_CMDS+=("$cc")
    done
    for pc in x11 alsa freetype2 fontconfig gl libusb-1.0 libudev dbus-1 gnutls; do
        pkg-config --exists "$pc" 2>/dev/null || MISSING_PC+=("$pc")
    done
}

pkg_install_cmd() {
    if   command -v apt-get >/dev/null 2>&1; then
        echo "apt-get update -qq && apt-get install -y git curl wget tar patch make gcc pkg-config unzip gcc-mingw-w64-x86-64 gcc-mingw-w64-i686 winetricks libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxinerama-dev libxcomposite-dev libasound2-dev libfreetype-dev libfontconfig-dev libgl-dev libegl-dev libusb-1.0-0-dev libudev-dev libdbus-1-dev libgnutls28-dev"
    elif command -v dnf     >/dev/null 2>&1; then
        echo "dnf install -y git curl wget tar patch make gcc pkg-config unzip mingw64-gcc mingw32-gcc winetricks libX11-devel libXext-devel libXrandr-devel libXcursor-devel libXi-devel libXinerama-devel libXcomposite-devel alsa-lib-devel freetype-devel fontconfig-devel mesa-libGL-devel mesa-libEGL-devel libusb1-devel systemd-devel dbus-devel gnutls-devel"
    elif command -v pacman  >/dev/null 2>&1; then
        echo "pacman -S --noconfirm --needed git curl wget tar patch make gcc pkg-config unzip mingw-w64-gcc winetricks libx11 libxext libxrandr libxcursor libxi libxinerama libxcomposite alsa-lib freetype2 fontconfig mesa libusb systemd dbus gnutls"
    fi
}

install_deps_auto() {
    detect_missing_deps
    if [ ${#MISSING_CMDS[@]} -eq 0 ] && [ ${#MISSING_PC[@]} -eq 0 ]; then
        log "Build dependencies: all present"
        return 0
    fi
    log "Build dependencies missing:"
    [ ${#MISSING_CMDS[@]} -gt 0 ] && log "  commands:    ${MISSING_CMDS[*]}"
    [ ${#MISSING_PC[@]} -gt 0 ]   && log "  pkg-config:  ${MISSING_PC[*]}"

    local sudo_prefix=""
    [ "$(id -u)" != "0" ] && sudo_prefix="sudo"

    # Snapshot packages before install, to track exactly what we add.
    local before_file="" after_file=""
    if command -v dpkg-query >/dev/null 2>&1; then
        before_file="$(mktemp)"
        dpkg-query -W -f='${Package}\n' 2>/dev/null | sort > "$before_file"
    fi

    # Install in groups, so a conflict in one group (e.g. libasound2-dev
    # against a newer libasound2t64) does not block the others. On Debian
    # trixie, asking apt for everything at once fails the whole transaction.
    local groups_ok=() groups_fail=()
    install_group() {
        local name="$1"; shift
        [ $# -eq 0 ] && return 0
        if $sudo_prefix apt-get install -y "$@" >/dev/null 2>&1 \
           || $sudo_prefix dnf install -y "$@" >/dev/null 2>&1 \
           || $sudo_prefix pacman -S --noconfirm --needed "$@" >/dev/null 2>&1; then
            groups_ok+=("$name")
            log "  ok    $name"
        else
            groups_fail+=("$name")
            warn "  fail  $name: $*"
        fi
    }

    log "Installing in groups (a failed group does not block the others):"
    install_group base   git curl wget tar patch make gcc pkg-config unzip winetricks autoconf automake libtool flex bison
    install_group x11    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxinerama-dev libxcomposite-dev
    install_group fonts  libfreetype-dev libfontconfig-dev
    install_group gl     libgl-dev libegl-dev
    install_group usb    libusb-1.0-0-dev libudev-dev
    install_group dbus   libdbus-1-dev
    install_group gnutls libgnutls28-dev
    install_group alsa   libasound2-dev
    install_group mingw64 gcc-mingw-w64-x86-64
    install_group mingw32 gcc-mingw-w64-i686

    if [ -n "$before_file" ] && [ -f "$before_file" ] && command -v dpkg-query >/dev/null 2>&1; then
        after_file="$(mktemp)"
        dpkg-query -W -f='${Package}\n' 2>/dev/null | sort > "$after_file"
        local new_pkgs
        new_pkgs="$(comm -13 "$before_file" "$after_file")"
        rm -f "$before_file" "$after_file"
        if [ -n "$new_pkgs" ]; then
            mkdir -p "$HOME/.cache/pdx-runtime-build"
            echo "$new_pkgs" > "$HOME/.cache/pdx-runtime-build/.pkgs-installed"
            log "Tracked $(echo "$new_pkgs" | wc -l) newly installed packages (for cleanup)"
        fi
    elif [ -n "$before_file" ]; then
        rm -f "$before_file"
    fi

    detect_missing_deps
    if [ ${#MISSING_PC[@]} -eq 0 ]; then
        log "Build dependencies: installed"
        return 0
    fi

    # Some pkg-config libraries are still missing. If the only gaps are ALSA
    # (or ALSA plus mingw, which is not fatal until the PE build), continue:
    # the PDX Controller talks to the amplifier over HID, and the Wine build
    # can run without ALSA. build-runtime.sh reads PDX_NO_ALSA and passes
    # --without-alsa to configure.
    local fatal=0
    for pc in "${MISSING_PC[@]}"; do
        [ "$pc" = "alsa" ] && continue
        fatal=1
    done
    if [ "$fatal" = "0" ]; then
        warn "ALSA dev files missing; continuing with --without-alsa (HID still works)"
        export PDX_NO_ALSA=1
        return 0
    fi

    warn "still missing after install: ${MISSING_CMDS[*]:-} ${MISSING_PC[*]:-}"
    return 1
}

check_deps() {
    detect_missing_deps
    if [ ${#MISSING_CMDS[@]} -eq 0 ] && [ ${#MISSING_PC[@]} -eq 0 ]; then
        return 0
    fi
    warn "missing build dependencies - build-runtime.sh will fail without them"
    [ ${#MISSING_CMDS[@]} -gt 0 ] && warn "  commands:    ${MISSING_CMDS[*]}"
    [ ${#MISSING_PC[@]} -gt 0 ]   && warn "  pkg-config:  ${MISSING_PC[*]}"
    local cmd
    cmd="$(pkg_install_cmd)"
    [ -n "$cmd" ] && warn "install with: sudo $cmd"
}

cleanup_after_full() {
    local build_failed="${1:-0}"
    log ""
    log "=== Cleanup ==="
    if [ "$build_failed" = "1" ]; then
        log "The build failed. Removing what was installed for it."
    else
        log "The app is installed. Everything else from the build is optional."
    fi
    log ""

    local build_dir="$PROJECT_DIR/build"
    local cache_dir="$HOME/.cache/pdx-runtime-build"
    local wt_cache="$HOME/.cache/winetricks"
    local inst_cache1="$HOME/.local/share/pdx-controller-wine/cache"
    local inst_cache2="$HOME/.cache/pdx-controller-wine"
    local pkgs_file="$cache_dir/.pkgs-installed"

    local build_size="" cache_size="" wt_size="" inst_size=""
    [ -d "$build_dir" ]    && build_size="$(du -sh "$build_dir" 2>/dev/null | cut -f1)"
    [ -d "$cache_dir" ]    && cache_size="$(du -sh "$cache_dir" 2>/dev/null | cut -f1)"
    [ -d "$wt_cache" ]     && wt_size="$(du -sh "$wt_cache" 2>/dev/null | cut -f1)"
    [ -d "$inst_cache1" ]  && inst_size="$(du -sh "$inst_cache1" 2>/dev/null | cut -f1)"
    [ -d "$inst_cache2" ]  && inst_size="$(du -sh "$inst_cache2" 2>/dev/null | cut -f1)"

    log "What can be removed:"
    [ -n "$build_size" ] && log "  build tree:           $build_size  $build_dir"
    [ -n "$cache_size" ] && log "  download cache:       $cache_size  $cache_dir"
    [ -n "$inst_size" ]  && log "  PDX installer cache:  $inst_size"
    [ -n "$wt_size" ]    && log "  winetricks cache:     $wt_size  $wt_cache"
    local n_pkgs=0 mb_pkgs=""
    if [ -f "$pkgs_file" ]; then
        n_pkgs=$(wc -l < "$pkgs_file")
        mb_pkgs=$(dpkg-query -Wf '${Installed-Size}\n' $(cat "$pkgs_file") 2>/dev/null | awk '{s+=$1} END {printf "%.0f", s/1024}')
        log "  apt packages:         $n_pkgs packages (~${mb_pkgs:-?} MB)"
    fi

    local reply
    reply="$(ask "Remove all of the above? [Y/n] " "y")"
    case "$reply" in
        [nN]|[nN][oO]) log "Cleanup skipped. Remove manually if needed."; return 0 ;;
    esac

    # Preserve the packages list before deleting the cache dir that holds it
    if [ -f "$pkgs_file" ]; then
        cp "$pkgs_file" /tmp/.pdx-pkgs-installed.tmp
    fi

    if [ -d "$build_dir" ]; then
        log "Removing $build_dir ($build_size)..."
        rm -rf "$build_dir"
    fi
    if [ -d "$cache_dir" ]; then
        log "Removing $cache_dir ($cache_size)..."
        rm -rf "$cache_dir"
    fi
    [ -d "$inst_cache1" ] && { log "Removing $inst_cache1..."; rm -rf "$inst_cache1"; }
    [ -d "$inst_cache2" ] && { log "Removing $inst_cache2..."; rm -rf "$inst_cache2"; }
    if [ -d "$wt_cache" ]; then
        log "Removing $wt_cache ($wt_size)..."
        rm -rf "$wt_cache"
    fi

    local pkgs_tmp="/tmp/.pdx-pkgs-installed.tmp"
    if [ -f "$pkgs_tmp" ]; then
        local pkgs
        pkgs="$(cat "$pkgs_tmp")"
        if [ -n "$pkgs" ]; then
            local sudo_prefix=""
            [ "$(id -u)" != "0" ] && sudo_prefix="sudo"
            log "Removing $n_pkgs packages installed for the build (~${mb_pkgs:-?} MB)..."
            if command -v apt-get >/dev/null 2>&1; then
                # shellcheck disable=SC2086
                $sudo_prefix apt-get purge -y $pkgs >/dev/null 2>&1 || true
                $sudo_prefix apt-get autoremove -y >/dev/null 2>&1 || true
            elif command -v dnf >/dev/null 2>&1; then
                # shellcheck disable=SC2086
                $sudo_prefix dnf remove -y $pkgs >/dev/null 2>&1 || true
            fi
            log "Packages removed."
        fi
        rm -f "$pkgs_tmp"
    fi

    log ""
    log "Cleanup complete."
    if [ "$build_failed" = "1" ]; then
        log "The build did not produce a runtime. Re-run --full to try again."
    else
        log "Kept: runtime (~745 MB), prefix (~1 GB), launcher, PDX Controller."
        log "The app is ready: run \"pdx-controller-wine\" to launch."
    fi
}

run_full() {
    log "Full install: dependencies -> build (~30-60 min) -> PDX Controller"
    install_deps_auto || die "dependencies not satisfied"
    log ""
    log "Running the Wine source build (30-60 minutes)..."
    if ! "$PROJECT_DIR/bin/build-runtime.sh"; then
        warn "build-runtime.sh failed - see ~/.cache/pdx-runtime-build/ for logs"
        echo ""
        local reply
        reply="$(ask "Remove everything that was installed for the build? [Y/n] " "y")"
        case "$reply" in
            [yY]|[yY][eE][sS]|"") cleanup_after_full 1 ;;
            *) log "Kept. Inspect ~/.cache/pdx-runtime-build/ to diagnose." ;;
        esac
        die "build-runtime.sh failed"
    fi
    log ""
    log "Installing PDX Controller into the prefix..."
    if ! "$PROJECT_DIR/bin/pdx-controller-wine" --install; then
        die "PDX Controller install failed"
    fi
    log ""
    log "Full install complete."
    cleanup_after_full

    if [ "$RUN_AFTER" = "1" ]; then
        local reply
        reply="$(ask "Launch PDX Controller now? [Y/n] " "y")"
        case "$reply" in
            [yY]|[yY][eE][sS]|"") "$PROJECT_DIR/bin/pdx-controller-wine" & ;;
            *) log "Launch later with: $PROJECT_DIR/bin/pdx-controller-wine" ;;
        esac
    fi
}

# --- end of full-install helpers ---

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

if [ "$ACTION" = "cleanup" ]; then
    cleanup_after_full
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
if [ "$FULL_INSTALL" = "1" ] && [ "$ACTION" = "install" ]; then
    run_full
    exit $?
fi
check_deps

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
