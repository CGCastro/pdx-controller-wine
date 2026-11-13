#!/bin/bash
# build-runtime — build the complete Wine that pdx-controller-wine ships.
# Source build: wine-staging 11.18 + the patch series from patches/.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$HOME/.local/share/pdx-controller-wine/runtime"
BUILD_DIR="$PROJECT_DIR/build"
CACHE_DIR="${PDX_BUILD_CACHE:-$HOME/.cache/pdx-runtime-build}"

WINE_VERSION="11.18"
WINE_URL="https://dl.winehq.org/wine/source/11.x/wine-${WINE_VERSION}.tar.xz"
WINE_SHA256="c6282f6d4daecf11f3ab9f9a2b6c598f67be7e28c363ba2cae8a3c44b611e7a4"
STAGING_URL="https://github.com/wine-staging/wine-staging/archive/refs/tags/v${WINE_VERSION}.tar.gz"
STAGING_SHA256="be9ab2471ce3ef729484c9d7e2752790a9145e1bb0c0e680f01268d15e5488c5"

JOBS="${JOBS:-$(nproc)}"

log()  { printf '\033[1;36m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

for cmd in curl sha256sum tar patch python3 make gcc pkg-config; do
  command -v "$cmd" >/dev/null || die "missing tool: $cmd"
done
command -v x86_64-w64-mingw32-gcc >/dev/null || warn "x86_64-w64-mingw32-gcc not found — PE build will fail"
command -v i686-w64-mingw32-gcc   >/dev/null || warn "i686-w64-mingw32-gcc not found — 32-bit PE build will fail"
for pc in x11 alsa freetype2 fontconfig gl libusb-1.0 libudev; do
  pkg-config --exists "$pc" 2>/dev/null || warn "pkg-config $pc not found — configure may drop a needed feature"
done

free_gb=$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')
if [ "$free_gb" -lt 10 ]; then
  warn "only ${free_gb}G free on /; source build needs ~10G"
  read -r -p "Continue anyway? [y/N] " reply
  [[ "$reply" =~ ^[yY] ]] || exit 1
fi

mkdir -p "$CACHE_DIR" "$BUILD_DIR"

fetch() {
  local url="$1" sum="$2" out="$CACHE_DIR/$3"
  if [[ ! -f "$out" ]] || ! echo "$sum  $out" | sha256sum -c --status; then
    log "fetching $3"
    curl -fL --retry 3 -o "$out.part" "$url" || die "download failed: $url"
    mv -f "$out.part" "$out"
  fi
  echo "$sum  $out" | sha256sum -c --status || die "sha256 mismatch: $out"
}
fetch "$WINE_URL"    "$WINE_SHA256"    "wine-${WINE_VERSION}.tar.xz"
fetch "$STAGING_URL" "$STAGING_SHA256" "wine-staging-${WINE_VERSION}.tar.gz"

SRC="$BUILD_DIR/wine-${WINE_VERSION}-pdx"
log "extracting wine source to $SRC"
rm -rf "$SRC"; mkdir -p "$SRC"
tar -C "$SRC" --strip-components=1 -xf "$CACHE_DIR/wine-${WINE_VERSION}.tar.xz"

STAGING="$BUILD_DIR/wine-staging-${WINE_VERSION}"
log "extracting wine-staging"
rm -rf "$STAGING"; mkdir -p "$STAGING"
tar -C "$STAGING" --strip-components=1 -xzf "$CACHE_DIR/wine-staging-${WINE_VERSION}.tar.gz"

log "applying wine-staging patchset (--all)..."
python3 "$STAGING/staging/patchinstall.py" --all -d "$SRC" >"$CACHE_DIR/staging.log" 2>&1 \
  || { tail -20 "$CACHE_DIR/staging.log"; die "staging patchset failed"; }
log "  ok ($(grep -c 'gitapply.sh' "$CACHE_DIR/staging.log" || echo '?') patches)"

cd "$SRC"
log "applying patch series from $PROJECT_DIR/patches/..."
for p in "$PROJECT_DIR"/patches/0*.patch; do
  name="$(basename "$p")"
  if [ "$name" = "0011-hidclass-implement-indexed-string.patch" ] && \
     grep -q 'RBW-INDEXED' dlls/hidclass.sys/device.c 2>/dev/null; then
    log "  skip  $name (staging already implements it)"
    continue
  fi
  if ! patch -p1 -f --no-backup-if-mismatch < "$p" >"$CACHE_DIR/patch-$name.log" 2>&1; then
    cat "$CACHE_DIR/patch-$name.log"
    die "patch failed: $name"
  fi
  if grep -q 'with fuzz' "$CACHE_DIR/patch-$name.log"; then
    warn "  fuzz  $name — check $CACHE_DIR/patch-$name.log"
  fi
  log "  ok    $name"
done

log "splicing rbw-usbhcd.c into wineusb.sys..."
python3 "$PROJECT_DIR/patches/splice-usbhcd.py" "$PROJECT_DIR/patches/rbw-usbhcd.c" "$SRC"

log "configure (--enable-archs=i386,x86_64) — a few minutes"
export CFLAGS="${CFLAGS:--O2 -pipe}" CROSSCFLAGS="${CROSSCFLAGS:--O2 -pipe}"
./configure \
  --prefix="$RUNTIME_DIR" \
  --enable-archs=i386,x86_64 \
  --disable-tests \
  --with-x --with-alsa --with-opengl --with-dbus --with-gnutls \
  --with-freetype --with-fontconfig --with-usb --with-udev --without-ffmpeg \
  >"$CACHE_DIR/configure.log" 2>&1 \
  || { tail -20 "$CACHE_DIR/configure.log"; die "configure failed"; }
log "  ok"

if grep -E "^configure: " "$CACHE_DIR/configure.log" | grep -Ei "libusb|libudev|gnutls|freetype|fontconfig|OpenGL|alsa|dbus"; then
  warn "configure dropped a feature above — install the dev package and rerun"
fi

log "build (-j$JOBS; ~30-60 min on first run)..."
make -j"$JOBS" >"$CACHE_DIR/build.log" 2>&1 \
  || { grep -iE "error" "$CACHE_DIR/build.log" | tail -20; die "build failed"; }
log "  ok"

log "installing to $RUNTIME_DIR..."
rm -rf "$RUNTIME_DIR"
make install >"$CACHE_DIR/install.log" 2>&1 \
  || { tail -20 "$CACHE_DIR/install.log"; die "install failed"; }
log "  ok"

log "verifying patch markers..."
fail=0
check_marker() { if grep -aq "$2" "$1" 2>/dev/null; then log "  ok    $3"; else warn "  MISSING $3"; fail=1; fi; }
check_marker "$RUNTIME_DIR/lib/wine/i386-windows/hidclass.sys"   "INDEXED_STRING" "hidclass i386"
check_marker "$RUNTIME_DIR/lib/wine/x86_64-windows/hidclass.sys" "INDEXED_STRING" "hidclass x86_64"
[ "$fail" = "0" ] || warn "some markers missing — the app may still run, but report this"

log ""
log "runtime ready: $RUNTIME_DIR"
log "next: pdx-controller-wine --check && pdx-controller-wine --run"
