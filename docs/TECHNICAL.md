# Technical notes

This document covers the two problems the project solves, in the order they
were found. The first is a Wine HID ioctl; the second is a Wine build
configuration that crashes the application after HID works.

## Part 1 — the HID ioctl

### The IOCTL

`HID_OUT_CTL_CODE(120)` expands to `0xb01e2`. It is issued by user-space code
that calls `HidD_GetIndexedString()` from `hid.dll`. On Linux the call chain
looks like:

    hid.dll: HidD_GetIndexedString(file, index, buffer, length)
      -> DeviceIoControl(IOCTL_HID_GET_INDEXED_STRING)
        -> hidclass.sys: pdo_ioctl(...)
          -> winebus.sys: internal_ioctl(...)
            -> unixlib: read from /dev/hidraw*

On stock Wine the `hidclass.sys` step has no case for this ioctl and returns
`STATUS_NOT_SUPPORTED`, with the FIXME we see in the log.

### The index convention

Windows and Wine disagree about what a "string index" is:

| | Wine `IOCTL_HID_GET_STRING` | Windows `IOCTL_HID_GET_INDEXED_STRING` |
|---|---|---|
| 0 | manufacturer | language ID (0x0409 = en-US) |
| 1 | product | manufacturer |
| 2 | serial | product |
| 3 | - | serial |
| 4+ | - | vendor-specific |

The `HID_STRING_ID_*` constants in `include/ddk/hidclass.h` are **descriptor**
indices, used by `winebus.sys` with `IOCTL_HID_GET_STRING`. They do **not**
apply to `IOCTL_HID_GET_INDEXED_STRING`, whose indices are defined by the HID
class driver spec.

`patches/0011-hidclass-implement-indexed-string.patch` adds a switch that maps
each incoming index to the right source.

### Why hardcode "AP"

The PDX3000's USB descriptor exposes five strings:

    pyusb read of /dev/bus/usb/XXX/YYY
    index 0: LANGIDs [0x0409]           (en-US)
    index 1: "LAB.GRUPPEN"              iManufacturer
    index 2: "PDX3000"                  iProduct
    index 3: "bPWFCuDVqLCL9S2A"         iSerialNumber
    index 4: "AP"                       vendor-specific (not referenced by any interface)
    index 5+: error                     not present

Index 4 is not referenced by any interface descriptor; it is a vendor-specific
string that the amplifier firmware stores and the Windows driver returns as-is.
There is no standard way for `hidclass.sys` to know it should return "AP"
without either (a) hardcoding it, or (b) reading the USB descriptor directly.

Option (b) requires work in `winebus.sys/unixlib.c` to issue the USB control
transfer GET_DESCRIPTOR (type STRING) with the requested index, then feed it
back up through the HID stack. That is what the Wine upstream discussion
(MR1494) calls "retrieved from the lower USB level". It is the right fix for
upstream; it is not what this project does, because it doubles the scope and
needs hardware to test.

### Buffer size

The Windows software calls `HidD_GetIndexedString(file, 4, buffer, 6)` — a
6-byte buffer, which holds 3 wide characters. "AP" plus the null terminator is
exactly 3 wide characters (A, P, \0), so it fits. "PDX3000" is 8 wide
characters and does not fit; the software reports STATUS_BUFFER_TOO_SMALL and
gives up. This is why the hardcoded string must be exactly "AP" — any longer
and the call fails.

### If the firmware changes

If Lab.gruppen ships a PDX3000 firmware update that changes the string at
index 4, the patch needs to be updated. To check, run:

    sudo python3 -c "
    import usb.core
    dev = usb.core.find(idVendor=0x1220, idProduct=0x4701)
    raw = dev.ctrl_transfer(0x80, 0x06, (0x03 << 8) | 4, 0x0409, 255)
    print(bytes(raw[2:raw[0]]).decode('utf-16-le'))
    "

If the output is not "AP", edit `vendor_str[]` in
`patches/0011-hidclass-implement-indexed-string.patch` and rebuild.

## Part 2 — the `0x5630cd` crash

With the HID ioctl implemented, the application reaches the amplifier, sends
`/info`, receives a real response (`Castro Audio...V1.0`), and then crashes:

    Unhandled exception: page fault on read access to 0x00000000
    EIP:005630cd  EAX:000000ea  EDI:0000001d  ECX:00000000
    0x005630cd: movl (%ecx), %eax

### What the crash is

The instruction is a null dereference. The stack shows the same offset
(`0x5630cd`), the same registers (`EAX=0xEA`, `EDI=0x1D`), and the same
`ECX=0` across every configuration tested. It is deterministic, not
intermittent.

The disassembly around `0x562d70` (the function containing the crash) shows
SSE single-precision operations (`movss`, `mulss`, `divss`, `cvtdq2ps`,
`cvtsi2ss`) on values loaded from a structure. `EAX=234` and `EDI=29` are sizes
that match audio buffer structures — sample count and channel count, most
plausibly. The upstream caller (`0x564810`) computes `mulss`/`divss` on the same
sort of values.

The value that crashes is loaded from `[arg1+0xc]`, passed to `0x562d70` by
`0x5628a0` as `arg5`. `0x562710` checks `[arg1]` and `[arg1+8]` for non-NULL
but does **not** check `[arg1+0xc]`. The application then dereferences it.

### Why this project does not patch the application

Patching the application is out of scope: it is proprietary, and the crash is a
symptom of a Wine difference, not an application bug that we can fix upstream.
The correct response is to make Wine behave as it does on Windows.

### What was tried and rejected

| Configuration | `0x5630cd`? |
|---|---|
| WineHQ wine-staging 11.18 `.deb` + `0011-hidclass` | yes |
| WineHQ wine-devel 11.18 `.deb` + `0011-hidclass` | yes |
| WineHQ `.deb` + the five patched PE from rekordbox-wine | yes |
| WineHQ `.deb` + the whole `lib/wine` from rekordbox-wine | **no** |
| WineHQ `.deb` + only `x86_64-unix/` from rekordbox-wine | no crash, blank window |
| Source-built wine-staging 11.18 + all 11 patches | **no** |

Two conclusions:

1. The crash is in `lib/wine/`, not in `bin/wine`. Mixing a working `lib/wine`
   into a `bin/` from a different build is enough to make the application work,
   which means the divergence is in what `lib/wine/` provides.
2. The `.deb` packaging of wine-staging 11.18 is not equivalent to a source
   build. Partial substitutions of PE (the `*-windows/` directory) do not fix
   it; partial substitutions of ELF (`x86_64-unix/`) remove the crash but leave
   the window blank, because mixing PE and ELF from different builds is not
   supported by Wine.

The working configuration — and the one `bin/build-runtime.sh` reproduces — is
a source build with all the patches. Reducing the patch set to the minimum the
PDX Controller needs is an open task.

### The suspect patches

The crash is inside an SSE float pipeline that looks like audio buffer
arithmetic. The two most likely candidates are:

- `0002-mmdevapi-exclusive-event-streams.patch` — Wine's `mmdevapi` refuses
  event-driven exclusive streams outright on stock; the patch makes them work.
- `0003-winealsa-exclusive-audio.patch` — Wine's `winealsa` signals the
  exclusive-mode event with no period free, leading to buffer refusals.

If either is the reason the crash disappears, this is a Wine defect to report
upstream, not a property of the PDX Controller. The investigation is recorded in
`docs/investigation/`.

## The patch series

The eleven patches in `patches/` came from two sources.

**Ten from [rekordbox-wine](https://github.com/MrNorm/rekordbox-wine)**, LGPL-2.1-or-later:

| Patch | Component |
|---|---|
| `0001-dxgi-implement-WaitForVBlank.patch` | `dxgi` |
| `0002-mmdevapi-exclusive-event-streams.patch` | `mmdevapi` |
| `0003-winealsa-exclusive-audio.patch` | `winealsa` |
| `0004-winealsa-midi.patch` | `winealsa` |
| `0005-winex11-popup-not-managed.patch` | `winex11` |
| `0006-mountmgr-removable-unknown-media.patch` | `mountmgr` |
| `0007-mountmgr-storage-descriptor-truth.patch` | `mountmgr` |
| `0008-setupapi-physical-device-object-name.patch` | `setupapi` |
| `0009-mountmgr-volume-devnodes.patch` | `mountmgr` |
| `0010-wineusb-hcd-unixlib.patch` | `wineusb` |

**One from this project**, LGPL-2.1-or-later:

| Patch | Component |
|---|---|
| `0011-hidclass-implement-indexed-string.patch` | `hidclass` |

**Plus** `rbw-usbhcd.c`, a code block spliced into `wineusb.sys` by
`splice-usbhcd.py` after the numbered patches. It adds a `\\.\HCDn` device
object. `patches/ATTRIBUTION.md` records provenance.

### Why the patch from rekordbox-wine came over as-is

The rekordbox-wine project ships its own wine-staging 11.18 source build with
these patches. The PDX Controller works on that build and crashes on the
equivalent WineHQ `.deb`. Rather than try to identify a subset of patches that
might work — which would require a source build per subset, 30–60 minutes each
— the initial configuration takes the whole series. Reducing it is planned but
not done.

### Build configuration

`bin/build-runtime.sh` mirrors `build-wine-runtime.sh` from rekordbox-wine with
three differences:

1. No Wine Mono or Wine Gecko — the PDX Controller has no .NET or HTML
   dependency.
2. `--without-ffmpeg` — the WineHQ tarball does not include all the ffmpeg
   submodules, and the PDX Controller does not use `winegstreamer`.
3. `0011-hidclass` is skipped automatically if the wine-staging patchset
   already implements it. It does on 11.18; the skip is there for future
   wine-staging versions where it might not.

## PDX2000

The PDX2000 was announced by Lab.gruppen alongside the PDX3000 but **never
released to market**. No units are in circulation, so no tests exist and none
can be performed. It is listed here so future readers know it is out of scope,
not forgotten.

If a pre-production PDX2000 ever surfaces, the diagnostic is the same: run
`fetch-pdx.sh` on the software that shipped with it, then use the pyusb
command above to read its string descriptors. If index 4 is not "AP", update
`vendor_str[]` in the patch and rebuild. The rest of the pipeline should be
identical, since both models share the Lab.gruppen HID protocol family.
