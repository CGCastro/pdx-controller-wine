#!/bin/bash
# build-runtime — compile only hidclass.sys with the IOCTL_HID_GET_INDEXED_STRING
# patch and install it into a separate runtime. Does not rebuild all of Wine.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
RUNTIME_DIR="$HOME/.local/share/pdx-controller-wine/runtime"
WINE_VERSION="11.18"
WINE_TARBALL="wine-${WINE_VERSION}.tar.xz"
WINE_URL="https://dl.winehq.org/wine/source/11.x/${WINE_TARBALL}"
BASE_RUNTIME="${BASE_RUNTIME:-/usr/lib/rekordbox-wine/wine}"
NO_CONFIRM="${NO_CONFIRM:-0}"

log()  { printf '\033[1;36m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. Disk space estimate ---
TARBALL_MB=45
SOURCE_MB=500
RUNTIME_MB=1700
EXTRA_MB=100
needed=$((TARBALL_MB + SOURCE_MB + RUNTIME_MB + EXTRA_MB))
[ -f "$BUILD_DIR/$WINE_TARBALL" ] && needed=$((needed - TARBALL_MB))
[ -d "$BUILD_DIR/wine-${WINE_VERSION}" ] && needed=$((needed - SOURCE_MB))
[ -x "$RUNTIME_DIR/bin/wine" ] && needed=$((needed - RUNTIME_MB))

free=$(df -BM / | awk 'NR==2 {gsub("M","",$4); print $4}')

log "Disk usage estimate:"
if [ -f "$BUILD_DIR/$WINE_TARBALL" ]; then
    log "  Wine tarball:      present"
else
    log "  Wine tarball:      ${TARBALL_MB} MB"
fi
if [ -d "$BUILD_DIR/wine-${WINE_VERSION}" ]; then
    log "  Extracted source:  present"
else
    log "  Extracted source:  ${SOURCE_MB} MB"
fi
if [ -x "$RUNTIME_DIR/bin/wine" ]; then
    log "  Runtime copy:      present"
else
    log "  Runtime copy:      ${RUNTIME_MB} MB"
fi
log "  Build artifacts:   ${EXTRA_MB} MB"
log "  Need / have:       ${needed} / ${free} MB"
if [ "$free" -lt "$needed" ]; then
    die "Not enough disk space on / (need ${needed} MB, have ${free} MB)."
fi

# --- 2. Dependencies + install prompt ---
declare -A PKG_FOR=(
    [wget]=wget [tar]=tar [patch]=patch [make]=make [gcc]=gcc
    [x86_64-w64-mingw32-gcc]=gcc-mingw-w64-x86-64 [strings]=binutils
)
missing_cmds=()
missing_pkgs=()
for cmd in "${!PKG_FOR[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        missing_cmds+=("$cmd")
        missing_pkgs+=("${PKG_FOR[$cmd]}")
    fi
done

if [ ${#missing_cmds[@]} -gt 0 ]; then
    warn "Missing commands: ${missing_cmds[*]}"
    warn "Required packages: ${missing_pkgs[*]}"

    uris=$(apt --print-uris install --no-install-recommends -y "${missing_pkgs[@]}" 2>&1 || true)
    download_bytes=$(printf '%s\n' "$uris" | awk '/\.deb/ {sum+=$3} END {print sum+0}')
    pkg_names=$(printf '%s\n' "$uris" | awk '/\.deb/ {print $2}' | sed 's/_[^_]*_[^_]*\.deb$//' | tr '\n' ' ')

    if [ "${download_bytes:-0}" -gt 0 ]; then
        dl_mb=$(LC_ALL=C awk -v b="$download_bytes" 'BEGIN {printf "%.1f", b/1024/1024}')
        warn "Download: ${dl_mb} MB"
    fi
    if [ -n "$pkg_names" ]; then
        install_kb=$(apt-cache show $pkg_names 2>/dev/null | awk '/^Installed-Size:/ {sum+=$2} END {print sum+0}')
        if [ "${install_kb:-0}" -gt 0 ]; then
            inst_mb=$(LC_ALL=C awk -v k="$install_kb" 'BEGIN {printf "%.1f", k/1024}')
            warn "Install size: ${inst_mb} MB"
        fi
    fi

    if [ "$NO_CONFIRM" = "1" ] || [ ! -t 0 ]; then
        log "Non-interactive: installing automatically (NO_CONFIRM=1 or no tty)."
    else
        read -r -p "Install them now? [y/N] " reply
        case "$reply" in
            [yY]|[yY][eE][sS]) ;;
            *) die "Aborted. Install with: sudo apt install --no-install-recommends ${missing_pkgs[*]}" ;;
        esac
    fi
    sudo apt install -y --no-install-recommends "${missing_pkgs[@]}" || die "apt install failed"
fi

# --- 3. Base runtime ---
[ -x "$BASE_RUNTIME/bin/wine" ] || die "no wine found at $BASE_RUNTIME/bin/wine (set BASE_RUNTIME=/path/to/wine)"
log "Dependencies satisfied."

# --- 4. Download, extract, patch, configure, build ---
mkdir -p "$BUILD_DIR"
if [ ! -f "$BUILD_DIR/$WINE_TARBALL" ]; then
    log "Downloading $WINE_TARBALL (~45 MB)..."
    wget -q --show-progress -O "$BUILD_DIR/$WINE_TARBALL" "$WINE_URL"
else
    log "Tarball already present: $BUILD_DIR/$WINE_TARBALL"
fi

if [ ! -d "$BUILD_DIR/wine-${WINE_VERSION}" ]; then
    log "Extracting..."
    tar -xf "$BUILD_DIR/$WINE_TARBALL" -C "$BUILD_DIR"
else
    log "Source already extracted."
fi

cd "$BUILD_DIR/wine-${WINE_VERSION}"
if grep -q "RBW-INDEXED" dlls/hidclass.sys/device.c; then
    log "Patch already applied."
else
    log "Applying patch..."
    patch -p1 < "$PROJECT_DIR/patches/0001-hidclass-implement-indexed-string.patch"
fi

if [ ! -f Makefile ]; then
    log "Running ./configure (~3-5 min)..."
    ./configure --enable-archs=x86_64 --disable-tests --disable-win16 2>&1 | tail -3
else
    log "Makefile already present."
fi

log "Building dlls/hidclass.sys/all..."
make -j"$(nproc)" dlls/hidclass.sys/all 2>&1 | tail -5

# --- 5. Install ---
log "Installing to $RUNTIME_DIR..."
mkdir -p "$RUNTIME_DIR"
if [ ! -x "$RUNTIME_DIR/bin/wine" ]; then
    log "Copying base runtime..."
    cp -r "$BASE_RUNTIME"/* "$RUNTIME_DIR/"
fi
cp "$BUILD_DIR/wine-${WINE_VERSION}/dlls/hidclass.sys/x86_64-windows/hidclass.sys" "$RUNTIME_DIR/lib/wine/x86_64-windows/hidclass.sys"

log "Verifying: patch present in the binary?"
strings "$RUNTIME_DIR/lib/wine/x86_64-windows/hidclass.sys" > /tmp/pdx-verify.txt
if grep -q "IOCTL_HID_GET_INDEXED_STRING" /tmp/pdx-verify.txt; then
    rm -f /tmp/pdx-verify.txt
    log "OK — IOCTL_HID_GET_INDEXED_STRING found in $RUNTIME_DIR/lib/wine/x86_64-windows/hidclass.sys"
else
    rm -f /tmp/pdx-verify.txt
    die "ERROR — IOCTL_HID_GET_INDEXED_STRING not found in the final binary"
fi

log "Runtime ready: $RUNTIME_DIR"
log "To launch: $PROJECT_DIR/bin/pdx-controller-wine"
