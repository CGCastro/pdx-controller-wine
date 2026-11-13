# STATE — pdx-controller-wine

Última actualização: 2026-11-13.

## Hipótese actual

O crash `page fault on read access to 0x00000000` em `pdx controller+0x5630cd`
é causado pela build do Wine, não pela app nem pelo HID. Concretamente:
o `.deb` do WineHQ (wine-devel ou wine-staging) difere do source build do
wine-staging 11.18 em algo que a app usa (provavelmente mmdevapi / winealsa,
dado o disassembly ser SSE float — áudio).

Solução: compilar wine-staging 11.18 de source, com os patches do
rekordbox-wine aplicados, `--enable-archs=i386,x86_64`.

## Provado

- PDX Controller v1.2 é PE32 i386 (`file` confirma).
- `/dev/hidraw0` acessível ao utilizador (ACL + grupo `audio`).
- Wine detecta o device: `HID_NAME=LAB.GRUPPEN PDX3000`, `vid 1220 pid 4701`.
- Patch `IOCTL_HID_GET_INDEXED_STRING` funciona (índice 4, `output_len=6`).
- `/info` enviado e respondido com dados reais (`Castro Audio...V1.0`).
- Com o wine do rekordbox-wine (wine-staging 11.18 source build + 10 patches
  + splice wineusb), a app **arranca, liga ao PDX3000, e funciona**.
- wine-devel 11.18 `.deb` (WineHQ) + patch hidclass → crash no mesmo `0x5630cd`.
- wine-devel 11.18 `.deb` + as 5 PE patchadas do rekordbox → crash.
- wine-devel 11.18 `.deb` + o `lib/wine` inteiro do rekordbox → funciona.
- wine-devel 11.18 `.deb` + só o `x86_64-unix/` do rekordbox → sem crash, janela branca.
- wine-devel 11.18 `.deb` + `x86_64-unix` + PE gráficas do rekordbox → janela branca.
- `renderer=gl` não resolve o crash.

## Desmentido

- Prefixo win32 vs win64 não é a causa.
- Permissões do `/dev/hidraw*` não são a causa.
- Patch ao `hidclass.sys` (i386 ou ambos) não é suficiente — o crash persiste.
- Mesma versão base (11.18) entre WineHQ e rekordbox-wine não implica
  comportamento idêntico; a build (source vs .deb) faz diferença.

## Próxima acção (uma)

Correr `bin/build-runtime.sh` e verificar que (a) os 11 patches aplicam,
(b) o build termina, (c) a app arranca e liga ao PDX3000 sem crash.

## Bloqueado em

Build de ~30–60 min. Nada mais.

## Ficheiros do projecto

- `bin/build-runtime.sh` — reescrito 2026-11-13, source build do wine-staging
  11.18 + 11 patches. Versão anterior (`.deb` do WineHQ) em `.bak`.
- `patches/` — 11 patches + `rbw-usbhcd.c` + `splice-usbhcd.py`, copiados do
  rekordbox-wine (LGPL, ver `patches/ATTRIBUTION.md`).
- `patches/0011-hidclass-implement-indexed-string.patch` — nosso, renomeado
  para evitar colisão com o `0001-dxgi` do rekordbox-wine.

## Não é para reabrir sem evidência nova

- "Talvez o prefixo esteja sujo." — Não. Foram recriados do zero, win32 e win64,
  e o comportamento foi idêntico.
- "Talvez o problema seja o patch ao hidclass." — Não. O teste com o
  hidclass do rekordbox (que tem a implementação) também crasha.
