# Atribuição dos patches

Os patches `0001-*` a `0010-*`, `rbw-usbhcd.c`, `reviewed-fuzz.txt` e
`splice-usbhcd.py` neste directório vêm do projecto
[rekordbox-wine](https://github.com/MrNorm/rekordbox-wine), sob
LGPL-2.1-or-later (igual ao Wine).

Foram copiados porque implementam correcções a componentes do Wine
(`dxgi`, `mmdevapi`, `winealsa`, `winex11`, `mountmgr`, `setupapi`,
`wineusb`) que o PDX Controller também precisa para funcionar. Ver
`docs/TECHNICAL.md` para quais são realmente usados.

O patch `0011-*` é deste projecto (implementação do
`IOCTL_HID_GET_INDEXED_STRING` no `hidclass.sys`).
