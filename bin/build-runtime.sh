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

log() { printf '\033[1;36m[build]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

for cmd in wget tar patch make gcc x86_64-w64-mingw32-gcc strings; do
    command -v "$cmd" >/dev/null || die "missing $cmd (sudo apt install ...)"
done

[ -x "$BASE_RUNTIME/bin/wine" ] || die "no wine found at $BASE_RUNTIME/bin/wine (set BASE_RUNTIME=/path/to/wine)"

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

log "Installing to $RUNTIME_DIR..."
mkdir -p "$RUNTIME_DIR"
if [ ! -x "$RUNTIME_DIR/bin/wine" ]; then
    log "Copying base runtime..."
    cp -r "$BASE_RUNTIME"/* "$RUNTIME_DIR/"
fi
cp "$BUILD_DIR/wine-${WINE_VERSION}/dlls/hidclass.sys/x86_64-windows/hidclass.sys" \
   "$RUNTIME_DIR/lib/wine/x86_64-windows/hidclass.sys"

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
