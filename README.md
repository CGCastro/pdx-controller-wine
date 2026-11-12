# pdx-controller-wine

Runs the **PDX Controller v1.2** on Linux under Wine, so a **Lab.gruppen
PDX3000** amplifier can be configured without a Windows machine.

One patch to Wine's `hidclass.sys`, a launcher that builds and verifies it, and
a one-command installer.

> **PDX Controller is not included** — it is proprietary. `fetch-pdx.sh`
> downloads it from the Music Tribe CDN; if that fails it opens the official
> Lab.gruppen download page.

## The problem

On stock Wine the PDX Controller opens, detects a HID device, and then never
connects to the amplifier. `WINEDEBUG=+hid` shows:

    fixme:hid:pdo_ioctl Unsupported ioctl 0xb01e2 (device=b access=0 func=78 method=2)

`0xb01e2` is `IOCTL_HID_GET_INDEXED_STRING` (`HID_OUT_CTL_CODE(120)`). Wine's
`hidclass.sys` has no case for it, so it returns `STATUS_NOT_SUPPORTED`. The
software retries the same index forever and never reaches the SET commands
that would configure the amplifier.

## The fix

A single patch to `dlls/hidclass.sys/device.c` that implements
`IOCTL_HID_GET_INDEXED_STRING` with the Windows index convention:

| Index | Windows returns | Source |
|---|---|---|
| 0 | 0x0409 (en-US language ID) | Windows convention |
| 1 | "LAB.GRUPPEN" | USB String Descriptor (iManufacturer) |
| 2 | "PDX3000" | USB String Descriptor (iProduct) |
| 3 | "bPWFCuDVqLCL9S2A" | USB String Descriptor (iSerialNumber) |
| 4 | "AP" | USB String Descriptor (vendor-specific) |
| 5+ | STATUS_OBJECT_NAME_NOT_FOUND | not present |

Wine's `winebus.sys` implements `IOCTL_HID_GET_STRING` with the **descriptor**
indices (0=manufacturer, 1=product, 2=serial). The Windows `HID` IOCTL uses
**different** indices. The patch shifts by one and adds the vendor string.
See `docs/TECHNICAL.md` for details.

## Requirements

| | |
|---|---|
| Distribution | Debian trixie (tested). Should work on Ubuntu 24.04+. |
| Architecture | x86_64 |
| Base runtime | The Wine from rekordbox-wine, or any Wine with the same layout. Set BASE_RUNTIME=/path/to/wine to override. |
| Build deps | wget, tar, patch, make, gcc, x86_64-w64-mingw32-gcc, unzip |
| Disk | ~1.5 GB for the build + runtime |
| Root | Only for apt install of the build dependencies |

## Install

    git clone <repo-url> ~/GITs/pdx-controller-wine
    cd ~/GITs/pdx-controller-wine

    bin/build-runtime.sh              # download wine-11.18, apply patch, compile
    bin/pdx-controller-wine --install # download PDX Controller, install to prefix
    bin/pdx-controller-wine           # launch

`bin/pdx-controller-wine --check` reports the state of the runtime and prefix
without changing anything.

## HiDPI displays

The launcher sets `LogPixels=192` (2x) by default, which suits Retina or
4K screens. To use a different scale, pass `PDX_DPI` on the command line:

    PDX_DPI=144 pdx-controller-wine        # 1.5x (typical 1080p laptop)
    PDX_DPI=96  pdx-controller-wine        # 1x (external monitor)
    PDX_DPI=192 pdx-controller-wine        # 2x (Retina, the default)

The value is applied on every run when `PDX_DPI` is set, so you can switch
without deleting the prefix. `--check` reports the current DPI.

## What works

- PDX Controller launches on stock Wine 11.18 + the patch
- PDX3000 detected as a HID device
- Amplifier appears in the software
- Channel levels, EQ, presets and mute reach the hardware

## Not tested

- v1.0 of the software (only v1.2 is verified)
- **PDX2000** — announced by Lab.gruppen but **never released to market**.
  No units exist to test, so compatibility is unknown. If a PDX2000 ever
  surfaces (prototype, trade show unit), its firmware may expose a different
  vendor string at index 4 and the patch would need updating.
- Other Lab.gruppen / Music Tribe amplifiers that may share the same HID
  protocol

## What is a workaround, not a fix

The "AP" at index 4 is **hardcoded** in the patch. It is a USB String
Descriptor read from the PDX3000 firmware (pyusb confirms it: index 4 returns
"AP" on the current firmware). If Lab.gruppen ships a firmware update that
changes this string, or if another Music Tribe device uses a different vendor
string, the patch needs to be updated.

The upstream-correct fix would read the USB String Descriptor directly from
the device via libusb inside winebus.sys's unixlib. That work is not done
here; the hardcode is a deliberate trade-off to make one real device work
today. See the Wine bug MR1494 discussion.

## Structure

    bin/
      build-runtime.sh         compile hidclass.sys + install to runtime
      fetch-pdx.sh             download and extract PDX Controller v1.2
      pdx-controller-wine      launcher (--check, --install, --run)
    patches/
      0001-hidclass-implement-indexed-string.patch
    docs/
      TECHNICAL.md             why the patch is needed and what it does

## Multiple installations

The launcher respects two environment variables for isolating installations:

| Variable | Default | Purpose |
|---|---|---|
| `PDX_PREFIX` | `~/.local/share/pdx-controller-wine/prefix` | Wine prefix |
| `PDX_RUNTIME` | `~/.local/share/pdx-controller-wine/runtime` | Patched Wine runtime |

For a throwaway prefix (testing, CI):

    PDX_PREFIX=/tmp/pdx-test pdx-controller-wine --install
    PDX_PREFIX=/tmp/pdx-test pdx-controller-wine

## Removal

    rm -rf ~/.local/share/pdx-controller-wine

The patch only affects this runtime. The system Wine, rekordbox-wine's
runtime, and any other Wine prefix are untouched.

## Licence

- **Wine patch** (`patches/`): LGPL-2.1-or-later, matching Wine.
- **Scripts and documentation** (`bin/`, `docs/`, `README.md`): MIT.

Full texts in [`LICENSES/`](LICENSES/):
[LGPL-2.1-or-later](LICENSES/LGPL-2.1-or-later.txt) · [MIT](LICENSES/MIT.txt)
