#!/bin/bash
# detect-jobs.sh — imprime o valor ideal de -j para o make.
#
# Precedência:
#   1. JOBS já definido no ambiente         → respeitado
#   2. icecc presente + scheduler acessível → soma dos slots anunciados
#   3. icecc presente + scheduler offline   → 2 × CPUs locais (mín. 8)
#   4. icecc ausente                        → CPUs locais
set -euo pipefail

if [ -n "${JOBS:-}" ]; then
    printf '%s\n' "$JOBS"
    exit 0
fi

_ncpus() { nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1; }

command -v icecc >/dev/null 2>&1 || { _ncpus; exit 0; }

_sched="${ICECC_SCHEDULER_HOST:-}"
if [ -z "$_sched" ]; then
    for conf in /etc/icecc/icecc.conf /usr/local/etc/icecc/icecc.conf; do
        [ -r "$conf" ] || continue
        _sched="$(sed -n 's/^ICECC_SCHEDULER_HOST="\{0,1\}\([^"]*\)"\{0,1\}/\1/p' "$conf" | head -1)"
        [ -n "$_sched" ] && break
    done
fi
if [ -z "$_sched" ]; then
    _sched="$(ps aux 2>/dev/null | awk '/[i]ceccd/ && /-s / {for(i=1;i<=NF;i++) if($i=="-s"){print $(i+1); exit}}')"
fi
[ -z "$_sched" ] && _sched="localhost"

_slots=0
if command -v nc >/dev/null 2>&1; then
    _resp="$(printf 'listcs\n' | timeout 2 nc "$_sched" 8766 2>/dev/null || true)"
    if [ -n "$_resp" ]; then
        _slots="$(printf '%s\n' "$_resp" \
            | grep -oE 'jobs=[0-9]+/[0-9]+' \
            | cut -d/ -f2 \
            | awk '{s+=$1} END {print s+0}')"
    fi
fi

if [ "$_slots" -gt 0 ]; then
    _j="$_slots"
else
    _j=$(( $(_ncpus) * 2 ))
fi
[ "$_j" -lt 8 ] && _j=8
printf '%s\n' "$_j"
