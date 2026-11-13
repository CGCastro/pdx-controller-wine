# pdx-controller-wine

Runs the **PDX Controller v1.2** on Linux under Wine, so a **Lab.gruppen
PDX3000** amplifier can be configured without a Windows machine.

A source build of **wine-staging 11.18** with eleven patches compiled in, a
launcher that builds and verifies it, and a one-command installer.

> **PDX Controller is not included** — it is proprietary. `fetch-pdx.sh`
> downloads it from the Music Tribe CDN; if that fails it opens the official
> Lab.gruppen download page.

## Two problems, in order

### 1. The HID ioctl

On stock Wine the PDX Controller opens, detects the HID device, and never
connects to the amplifier. `WINEDEBUG=+hid` shows:

    fixme:hid:pdo_ioctl Unsupported ioctl 0xb01e2 (device=b access=0 func=78 method=2)

`0xb01e2` is `IOCTL_HID_GET_INDEXED_STRING` (`HID_OUT_CTL_CODE(120)`). Wine's
`hidclass.sys` has no case for it, so it returns `STATUS_NOT_SUPPORTED`. The
software retries the same index forever.

This project's `0011-hidclass-implement-indexed-string.patch` implements it
with the Windows index convention:

| Index | Windows returns | Source |
|---|---|---|
| 0 | 0x0409 (en-US language ID) | Windows convention |
| 1 | "LAB.GRUPPEN" | USB String Descriptor (iManufacturer) |
| 2 | "PDX3000" | USB String Descriptor (iProduct) |
| 3 | "bPWFCuDVqLCL9S2A" | USB String Descriptor (iSerialNumber) |
| 4 | "AP" | USB String Descriptor (vendor-specific) |
| 5+ | STATUS_OBJECT_NAME_NOT_FOUND | not present |

See `docs/TECHNICAL.md` for the index convention and why "AP" is hardcoded.

### 2. The `0x5630cd` crash

With the HID ioctl implemented, the PDX Controller reaches the amplifier, sends
`/info`, gets a real response (`Castro Audio...V1.0`), and then crashes:

    Unhandled exception: page fault on read access to 0x00000000
    EIP:005630cd  EAX:000000ea  EDI:0000001d  ECX:00000000
    0x005630cd: movl (%ecx), %eax

Deterministic, independent of HID. The instruction sequence around it is SSE
single-precision floating point (`movss`/`mulss`/`divss`/`cvtdq2ps`), with
`EAX=234` and `EDI=29` — sizes that match audio buffer structures. The crash
is triggered by a COM virtual call returning a NULL out-parameter that the
application does not validate.

This project does not patch the application. The fix is in the **Wine build**:
the PDX Controller works on the source-built wine-staging 11.18 that the
[rekordbox-wine](https://github.com/MrNorm/rekordbox-wine) project ships, and
crashes on the equivalent WineHQ `.deb`. `bin/build-runtime.sh` builds the
same source configuration.

## What changed from the `.deb` approach

Earlier versions of this project downloaded wine-staging 11.18 from WineHQ as
`.deb` packages and patched `hidclass.sys` only. That is not enough:

| Configuration | Crash `0x5630cd`? |
|---|---|
| WineHQ wine-staging 11.18 `.deb` + patch `hidclass` | yes |
| WineHQ wine-devel 11.18 `.deb` + patch `hidclass` | yes |
| WineHQ `.deb` + `lib/wine` from rekordbox-wine | **no** |
| Source-built wine-staging 11.18 + patches | **no** |

The difference is in `lib/wine/`, not in `bin/`: substituting the whole
`lib/wine` tree of a working rekordbox-wine runtime into a wine-devel `bin/`
produces a runtime that works. The `.deb` packaging is not equivalent to a
source build for this application.

The investigation log is in `docs/investigation/`.

## Wine patches and attribution

The eleven patches in `patches/`:

| Patch | Origin |
|---|---|
| `0001-dxgi-implement-WaitForVBlank.patch` | [rekordbox-wine](https://github.com/MrNorm/rekordbox-wine), LGPL-2.1-or-later |
| `0002-mmdevapi-exclusive-event-streams.patch` | rekordbox-wine, LGPL-2.1-or-later |
| `0003-winealsa-exclusive-audio.patch` | rekordbox-wine, LGPL-2.1-or-later |
| `0004-winealsa-midi.patch` | rekordbox-wine, LGPL-2.1-or-later |
| `0005-winex11-popup-not-managed.patch` | rekordbox-wine, LGPL-2.1-or-later |
| `0006-mountmgr-removable-unknown-media.patch` | rekordbox-wine, LGPL-2.1-or-later |
| `0007-mountmgr-storage-descriptor-truth.patch` | rekordbox-wine, LGPL-2.1-or-later |
| `0008-setupapi-physical-device-object-name.patch` | rekordbox-wine, LGPL-2.1-or-later |
| `0009-mountmgr-volume-devnodes.patch` | rekordbox-wine, LGPL-2.1-or-later |
| `0010-wineusb-hcd-unixlib.patch` | rekordbox-wine, LGPL-2.1-or-later |
| `0011-hidclass-implement-indexed-string.patch` | this project, LGPL-2.1-or-later |
| `rbw-usbhcd.c` (spliced into `wineusb.sys` by `splice-usbhcd.py`) | rekordbox-wine, LGPL-2.1-or-later |

`patches/ATTRIBUTION.md` records the provenance. All files are LGPL-2.1-or-later,
matching Wine.

Which of these the PDX Controller actually needs is not yet proven. All eleven
are in the build because that is the configuration measured to work. The plan
is to bisect down to the minimum once the baseline is accepted, and record the
result here.

The `rbw-usbhcd.c` splice is separate from the numbered patches because it
adds code (a `\\.\HCDn` device object that rekordbox's USB validation needs)
rather than modifying existing code. It is appended to `wineusb.c` after the
patch series.

## Requirements

| | |
|---|---|
| Distribution | Debian trixie (tested). Should work on Ubuntu 24.04+. |
| Architecture | x86_64 (the runtime is WoW64: PE 32-bit on unix 64-bit) |
| Wine | None. `build-runtime.sh` builds wine-staging 11.18 from source. The system Wine is not used or touched. |
| Base runtime | **Not needed.** The `BASE_RUNTIME` variable from earlier versions is gone. |
| Build deps | wget, curl, tar, patch, make, gcc, pkg-config, **gcc-mingw-w64-x86-64**, gcc-mingw-w64-i686, unzip |
| Configure deps | libx11-dev, libxext-dev, libxrandr-dev, libxcursor-dev, libxi-dev, libxinerama-dev, libxcomposite-dev, libasound2-dev, libfreetype-dev, libfontconfig-dev, libgl-dev, libegl-dev, libusb-1.0-0-dev, libudev-dev, libdbus-1-dev, libgnutls28-dev |
| Disk | ~10 GB during the build (source tree ~4 GB, object files, runtime). See below. |
| Time | 30–60 min for the Wine build on a modern CPU. |
| Root | Only for `apt install` of the build dependencies. |

The build is a full Wine compile, not a single `.so`. The first run downloads
~50 MB of tarballs, extracts ~1.5 GB of source, applies 272 wine-staging
patches and the project's 11 patches, and compiles.

## Install

    git clone https://github.com/CGCastro/pdx-controller-wine.git ~/GITs/pdx-controller-wine
    cd ~/GITs/pdx-controller-wine

    bin/build-runtime.sh               # ~30-60 min, source build of wine-staging 11.18
    bin/pdx-controller-wine --install  # download PDX Controller, install to prefix
    bin/pdx-controller-wine            # launch

`bin/pdx-controller-wine --check` reports the state of the runtime and prefix
without changing anything.

### If the build fails

The script writes full logs to `~/.cache/pdx-runtime-build/`:

| File | Contents |
|---|---|
| `staging.log` | wine-staging patchset application |
| `patch-*.log` | each project patch |
| `configure.log` | `./configure` output |
| `build.log` | `make` output |
| `install.log` | `make install` output |

The script prints a `tail` of the relevant log when a step fails. Most failures
are missing development packages — the script names the feature that
`configure` dropped.

`--without-ffmpeg` is passed to `configure` because the WineHQ tarball does not
include all the ffmpeg submodules that `winegstreamer` needs. The PDX Controller
is an audio application and does not use `winegstreamer`.

## HiDPI displays

The launcher sets `LogPixels=192` (2x) by default. To use a different scale,
pass `PDX_DPI` on the command line:

    PDX_DPI=144 pdx-controller-wine        # 1.5x
    PDX_DPI=96  pdx-controller-wine        # 1x (external monitor)
    PDX_DPI=192 pdx-controller-wine        # 2x (Retina, the default)

The value is applied on every run. `--check` reports the current DPI.

## What works

- PDX Controller launches, renders with text, and accepts input.
- PDX3000 detected as a HID device.
- Amplifier appears in the software and connects.
- `/info` command sent and answered with real device data.
- Channel levels, EQ, presets and mute reach the hardware.

## Not tested

- v1.0 of the software (only v1.2 is verified).
- **PDX2000** — announced by Lab.gruppen but **never released to market**.
  No units exist to test. If a pre-production unit ever surfaces, its firmware
  may expose a different vendor string at index 4 and the patch would need
  updating.
- Other Lab.gruppen / Music Tribe amplifiers that may share the same HID
  protocol.
- A build with fewer than the eleven patches. The minimum set is not yet known.

## What is a workaround, not a fix

### "AP" at index 4

The vendor string is **hardcoded** in `patches/0011-hidclass-...`. It is a USB
String Descriptor read from the PDX3000 firmware (pyusb confirms it: index 4
returns "AP"). If Lab.gruppen ships a firmware update that changes this string,
or if another Music Tribe device uses a different vendor string, the patch
needs to be updated.

The upstream-correct fix reads the USB String Descriptor directly from the
device via libusb inside `winebus.sys`'s unixlib. That work is not done here.
See `docs/TECHNICAL.md` and the Wine MR1494 discussion.

### Source build instead of `.deb`

The WineHQ `.deb` for wine-staging 11.18 (and wine-devel 11.18) crashes the PDX
Controller at `0x5630cd`. The equivalent source build does not. The root cause
is not yet identified — the disassembly suggests an audio buffer, and the
suspect patches are `0002-mmdevapi` and `0003-winealsa`. This is recorded as an
open question in `docs/investigation/STATE.md`.

The upstream-correct fix is to identify the divergence and either report it to
WineHQ or write a minimal patch. Until then, the project builds from source.

## Structure

    bin/
      build-runtime.sh         source build of wine-staging 11.18 + patches
      fetch-pdx.sh             download and extract PDX Controller v1.2
      pdx-controller-wine      launcher (--check, --install, --run)
    patches/
      0001-0010-*.patch        from rekordbox-wine, LGPL
      0011-hidclass-*.patch    this project's HID ioctl fix
      rbw-usbhcd.c             from rekordbox-wine, spliced into wineusb.sys
      splice-usbhcd.py         splice helper
      reviewed-fuzz.txt        allowed fuzz per patch
      ATTRIBUTION.md           provenance
    docs/
      TECHNICAL.md             why each patch is needed
      investigation/           STATE.md, JOURNAL.md
    LICENSES/                  LGPL-2.1-or-later, MIT

## Multiple installations

The launcher respects environment variables for isolating installations:

| Variable | Default | Purpose |
|---|---|---|
| `PDX_PREFIX` | `~/.local/share/pdx-controller-wine/prefix` | Wine prefix |
| `PDX_RUNTIME` | `~/.local/share/pdx-controller-wine/runtime` | Wine runtime |
| `PDX_BUILD_CACHE` | `~/.cache/pdx-runtime-build` | Download and build cache |

For a throwaway prefix (testing, CI):

    PDX_PREFIX=/tmp/pdx-test pdx-controller-wine --install
    PDX_PREFIX=/tmp/pdx-test pdx-controller-wine

## Removal

    rm -rf ~/.local/share/pdx-controller-wine ~/.cache/pdx-runtime-build

The runtime is private to this project. The system Wine and any other Wine
prefix are untouched.

## Licence

- **Wine patches** (`patches/`): LGPL-2.1-or-later, matching Wine.
- **Scripts and documentation** (`bin/`, `docs/`, `README.md`): MIT.

Full texts in [`LICENSES/`](LICENSES/):
[LGPL-2.1-or-later](LICENSES/LGPL-2.1-or-later.txt) · [MIT](LICENSES/MIT.txt)
