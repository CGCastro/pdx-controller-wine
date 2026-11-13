# JOURNAL — pdx-controller-wine

Append-only. Cada entrada é uma sessão.

---

## 2026-11-13 — sessão longa; diagnóstico fechado; build de source

**Ponto de partida.** A app crashava em `0x5630cd` com o runtime do projecto
(`wine-staging 11.18` extraído de `.deb` do WineHQ, patch ao `hidclass.sys`).

**O que foi feito.**

1. Confirmado que o prefixo não era o problema (recriado win32 e win64, mesmo
   comportamento).
2. Confirmado que as permissões do `/dev/hidraw0` estavam correctas.
3. Descoberto que o `build-runtime.sh` original só compilava/instalava a
   `hidclass.sys` **x86_64** (`--enable-archs=x86_64`); a app é i386 e a
   `i386-windows/hidclass.sys` do `.deb` ficava sem patch. Recompilada.
4. Mesmo com o patch i386, crash. Mesmo com patch i386+x86_64, crash.
5. Testado o wine do rekordbox-wine (outro projecto, mesma versão 11.18):
   **a app funciona e liga ao PDX3000**. Isto isolou o problema à build do Wine.
6. Bisectado: `lib/wine` do rekordbox no `bin/` do wine-devel → funciona.
   Só `x86_64-unix/` do rekordbox → sem crash mas janela branca.
   Substituições parciais de PE não resolvem a janela branca (builds mistas
   de PE e ELF não são modulares).
7. Lido o source do rekordbox-wine (`~/GITs/rekordbox-wine-src`): usa
   wine-staging 11.18 **source build** com 10 patches + splice `wineusb`,
   `--enable-archs=i386,x86_64`.
8. Copiados os 10 patches + `rbw-usbhcd.c` + `splice-usbhcd.py` para
   `patches/` (renomeado o nosso `0001-hidclass` para `0011-` para evitar
   colisão). `patches/ATTRIBUTION.md` criado.
9. `bin/build-runtime.sh` reescrito: descarrega source, aplica staging + 11
   patches + splice, `./configure --enable-archs=i386,x86_64`, `make install`.
   O `0011-hidclass` tem skip condicional (se o staging já implementa, salta).

**O que está pendente.** Correr o build e testar. A expectativa é que a app
arranque, ligue ao PDX3000, e não crasha.

**O que ainda falta depois disso.** Fontes (corefonts), DPI 192, e reduzir o
conjunto de patches ao mínimo necessário (provavelmente #1 dxgi para a janela,
#2/#3 para o áudio, #10 wineusb para o device — mas isto é hipótese até o
build funcionar).
