#!/bin/bash
# Garante o g++ mingw de cada alvo (o icecc precisa dele para montar o ambiente)
# e pede ao icecc um ambiente de cada compilador, um de cada vez, antes do make.
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
echo 'int main(void){return 0;}' > "$t/t.c"
for arch in x86_64 i686; do
  gcc=/usr/bin/$arch-w64-mingw32-gcc; gxx=/usr/bin/$arch-w64-mingw32-g++
  pkg="g++-mingw-w64-${arch/_/-}"
  [ -x "$gcc" ] || continue
  if [ ! -x "$gxx" ]; then
    echo "[icecc] falta $gxx -> a instalar $pkg"
    sudo -n apt-get install -y "$pkg" \
      || echo "[icecc] AVISO: $pkg nao instalado; $arch compila local (sudo apt-get install $pkg)"
  fi
done
for cc in /usr/bin/gcc /usr/bin/x86_64-w64-mingw32-gcc /usr/bin/i686-w64-mingw32-gcc; do
  [ -x "$cc" ] || continue
  : > "$t/ic.log"
  ICECC_DEBUG=debug ICECC_LOGFILE="$t/ic.log" timeout 300 icecc "$cc" -c "$t/t.c" -o "$t/t.o" >/dev/null 2>&1
  if grep -q "can't determine native" "$t/ic.log"; then
    echo "[icecc] $cc: SEM ambiente (compila local)"
  else
    echo "[icecc] $cc: ambiente OK"
  fi
done
