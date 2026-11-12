# Technical notes

## The IOCTL

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

## The index convention

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

The patch adds a switch that maps each incoming index to the right source.

## Why hardcode "AP"

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

## Buffer size

The Windows software calls `HidD_GetIndexedString(file, 4, buffer, 6)` - a
6-byte buffer, which holds 3 wide characters. "AP" plus the null terminator is
exactly 3 wide characters (A, P, \0), so it fits. "PDX3000" is 8 wide
characters and does not fit; the software reports STATUS_BUFFER_TOO_SMALL and
gives up. This is why the hardcoded string must be exactly "AP" - any longer
and the call fails.

## Why one patch to hidclass.sys is enough

The `winebus.sys` layer already has everything else the PDX Controller needs:

- HID enumeration (SetupDiEnumDeviceInterfaces)
- Output reports (IOCTL_HID_SET_OUTPUT_REPORT)
- Feature reports (IOCTL_HID_GET_FEATURE / IOCTL_HID_SET_FEATURE)
- Input reports (level meters - visible in WINEDEBUG=+hid)

Only the indexed-string ioctl is missing. Once it returns the right data, the
software proceeds to the SET commands and the amplifier responds.

## If the firmware changes

If Lab.gruppen ships a PDX3000 firmware update that changes the string at
index 4, the patch needs to be updated. To check, run:

    sudo python3 -c "
    import usb.core
    dev = usb.core.find(idVendor=0x1220, idProduct=0x4701)
    raw = dev.ctrl_transfer(0x80, 0x06, (0x03 << 8) | 4, 0x0409, 255)
    print(bytes(raw[2:raw[0]]).decode('utf-16-le'))
    "

If the output is not "AP", edit vendor_str[] in
`patches/0001-hidclass-implement-indexed-string.patch` and rebuild.

## PDX2000

The PDX2000 was announced by Lab.gruppen alongside the PDX3000 but **never
released to market**. No units are in circulation, so no tests exist and none
can be performed. It is listed here so future readers know it is out of scope,
not forgotten.

If a pre-production PDX2000 ever surfaces, the diagnostic is the same: run
`fetch-pdx.sh` on the software that shipped with it, then use the pyusb
command above to read its string descriptors. If index 4 is not "AP", update
vendor_str[] in the patch and rebuild. The rest of the pipeline should be
identical, since both models share the Lab.gruppen HID protocol family.
