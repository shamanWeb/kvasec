#!/bin/sh
# Регрессии мелких ошибок CLI (этап 7 аудита 2026-11).
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# 7.1 IP_PORT_FILTER: 0 в последнем октете допустим (раньше [1-9] отвергал .10/.100)
eval "$(grep '^IP_PORT_FILTER=' "$ROOT/opt/bin/libs/main")"
for ok in 10.0.0.10:53 192.168.1.100#5353 1.2.3.4:53; do
    echo "$ok" | grep -qxE "$IP_PORT_FILTER" || { echo "FAIL 7.1: $ok отвергнут"; exit 1; }
done
for bad in 1.2.3:53 1.2.3.4 x1.2.3.4:53; do
    ! echo "$bad" | grep -qxE "$IP_PORT_FILTER" || { echo "FAIL 7.1: $bad принят"; exit 1; }
done
grep -F 'grep -qxE "${IP_PORT_FILTER}"' "$ROOT/opt/bin/libs/vpn" >/dev/null
