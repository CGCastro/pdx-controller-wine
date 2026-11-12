#!/bin/bash
# fetch-pdx — download PDX Controller v1.2 and extract the executable.
#
# Note: v1.2 is under "Firmware → previous versions" on the Lab.gruppen site.
# The "main" version is v1.0, but v1.2 fixes USB connection bugs with the
# PDX3000.
#
# Usage: fetch-pdx.sh [destination-dir]
#        NO_BROWSER=1 fetch-pdx.sh   (don't open a browser on failure)

set -euo pipefail

DEST="${1:-$HOME/.local/share/pdx-controller-wine/cache}"
URL="https://cdn-media.empowertribe.com/8e80fcd368e84d29a992ec7508091a44/PDX%20Controller%20v1.2.zip"
ZIP="/tmp/PDX-Controller-v1.2.zip"
FALLBACK_URL="https://www.labgruppen.com/en/products/0106-AAN?tab=downloads"

log() { printf '\033[1;36m[fetch]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

for cmd in wget unzip; do
    command -v "$cmd" >/dev/null || die "missing $cmd (sudo apt install unzip)"
done

# 1. Download
log "Downloading $URL ..."
if ! wget -q --show-progress -O "$ZIP" "$URL"; then
    echo ""
    printf '\033[1;33m[warning]\033[0m Automatic download failed.\n'
    printf '\033[1;33m[warning]\033[0m Open the official Lab.gruppen page:\n'
    printf '          %s\n' "$FALLBACK_URL"
    printf '\033[1;33m[warning]\033[0m v1.2 is under "Firmware → previous versions" (main is v1.0).\n'
    printf '\033[1;33m[warning]\033[0m After downloading, extract the ZIP and run:\n'
    printf '          %s --install "<path-to-PDX Controller.exe>"\n' \
        "$(dirname "$0")/pdx-controller-wine"
    echo ""
    if [ "${NO_BROWSER:-0}" = "1" ]; then
        log "(NO_BROWSER=1 — browser not opened for testing)"
    elif command -v xdg-open >/dev/null; then
        xdg-open "$FALLBACK_URL" >/dev/null 2>&1 &
        log "Opening page in browser..."
    fi
    exit 1
fi

# 2. Extract
mkdir -p "$DEST"
log "Extracting to $DEST ..."
unzip -o -q "$ZIP" -d "$DEST"
rm -f "$ZIP"

# 3. Flatten: if the ZIP created a nested "PDX Controller v1.2" subdir, move its contents up
if [ -d "$DEST/PDX Controller v1.2" ] && [ ! -f "$DEST/PDX Controller.exe" ]; then
    log "Flattening nested extraction..."
    mv "$DEST/PDX Controller v1.2"/* "$DEST/" 2>/dev/null || true
    rmdir "$DEST/PDX Controller v1.2" 2>/dev/null || true
fi

# 4. Locate the .exe
EXE=$(find "$DEST" -maxdepth 2 -iname 'PDX Controller.exe' -print -quit)
if [ -z "$EXE" ]; then
    die "PDX Controller.exe not found after extraction. Contents:"
    find "$DEST" -maxdepth 2 -type f | head -20
fi

log "OK — installer at: $EXE"
log "Cached in $DEST (removable after 'pdx-controller-wine --install')"
