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

# 7.3 Меню отката: ≥10 релизов (шаблон [1-N] в case ломался), Enter, мусор, .sha256 не в списке
{
    echo 'print_line() { :; }; print_error() { :; }; get_n_spaces() { :; }; release_url=x'
    echo 'gh_api() { cat "$GH_JSON"; }'
    sed -n '/^select_release_from_list(){/,/^}/p' "$ROOT/opt/bin/main/upgrade"
} > "$WORK/upg.sh"
python3 -c '
import json
print(json.dumps([{"assets":[{"name":"kvasec_1.%d.0.ipk"%i,"browser_download_url":"u/v/w/x/y/z/a/kvasec_1.%d.0.ipk"%i},
                             {"name":"kvasec_1.%d.0.ipk.sha256"%i,"browser_download_url":"u/v/w/x/y/z/a/kvasec_1.%d.0.ipk.sha256"%i}]}
                  for i in range(12, 0, -1)]))' > "$WORK/gh.json"
pick() { printf "$1" | GH_JSON="$WORK/gh.json" sh -c ". '$WORK/upg.sh'; select_release_from_list R >/dev/null; echo \"\$R\""; }
[ "$(pick '11\n')" = "u/v/w/x/y/z/a/kvasec_1.2.0.ipk" ] || { echo "FAIL 7.3: пункт 11 — $(pick '11\n')"; exit 1; }
[ "$(pick '\n')" = "u/v/w/x/y/z/a/kvasec_1.12.0.ipk" ] || { echo "FAIL 7.3: Enter"; exit 1; }
[ "$(pick 'x\n13\n0\n2\n')" = "u/v/w/x/y/z/a/kvasec_1.11.0.ipk" ] || { echo "FAIL 7.3: мусор/вне диапазона"; exit 1; }
grep -F "''|*[!0-9]*) num_inface=0 ;;" "$ROOT/opt/bin/libs/vpn" >/dev/null
