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

# 7.8 add_host_to_adguard: не дублирует запись в kvas.list, точная проверка, без дублей ipset=
{
    echo "KVAS_LIST_FILE='$WORK/kl'; ADGUARD_IPSET_FILE='$WORK/ag'; DNSMASQ_IPSET_HOSTS='$WORK/dm'; IPSET_TABLE_NAME=KVAS_LIST"
    sed -n '/^_list_entry_awk=/,/^list_remove_entry() {/p' "$ROOT/opt/bin/libs/main"
    sed -n '/^list_remove_entry() {/,/^}/p' "$ROOT/opt/bin/libs/main" | sed 1d
    sed -n '/^add_host_to_adguard(){/,/^}/p' "$ROOT/opt/bin/libs/vpn"
} > "$WORK/ag.sh"
printf '%s\n' 'x.com' > "$WORK/kl"; printf '%s\n' 'netflix.com/KVAS_LIST' > "$WORK/ag"; : > "$WORK/dm"
RUNB="sh"; command -v busybox >/dev/null 2>&1 && RUNB="busybox sh"
$RUNB -c ". '$WORK/ag.sh'; add_host_to_adguard flix.com flix.com; add_host_to_adguard flix.com flix.com; add_host_to_adguard w.org '*w.org'"
printf '%s\n' 'x.com' | cmp - "$WORK/kl" || { echo 'FAIL 7.8: kvas.list изменён'; exit 1; }
printf '%s\n' 'netflix.com/KVAS_LIST' 'flix.com/KVAS_LIST' 'w.org/KVAS_LIST' | cmp - "$WORK/ag" || { echo 'FAIL 7.8: kvas.ipset'; cat "$WORK/ag"; exit 1; }
printf '%s\n' 'ipset=/flix.com/KVAS_LIST' 'ipset=/:.*w.org:/KVAS_LIST' | cmp - "$WORK/dm" || { echo 'FAIL 7.8: dnsmasq ipset'; exit 1; }

# 7.9 Ожидание первичной настройки AdGuard: выход при смерти процесса/таймауте + возврат DNS
grep -F 'if ! kill -0 "${ag_pid}" 2>/dev/null || [ "${ag_wait}" -ge 1800 ]; then' "$ROOT/opt/bin/libs/vpn" >/dev/null
grep -F '/opt/etc/init.d/S56dnsmasq start' "$ROOT/opt/bin/libs/vpn" >/dev/null

# 3.5 kvas upgrade/rollback возвращают код upgrade-скрипта, а не всегда 0
grep -F 'sh /opt/apps/kvas/bin/main/upgrade "${2}" "${3}"; exit $?' "$ROOT/opt/bin/kvas" >/dev/null
grep -F 'sh /opt/apps/kvas/bin/main/upgrade rollback "${2}"; exit $?' "$ROOT/opt/bin/kvas" >/dev/null

# 3.4 Обновление AdGuardHome: без curl -k, sha256 по checksums.txt (формат релиза: "hash  ./file")
! grep -hE 'curl -k|curl -[a-zA-Z]*k[a-zA-Z]* ' "$ROOT/opt/bin/libs/update" "$ROOT/opt/bin/libs/main" | grep -qv '^[[:space:]]*#' \
    || { echo 'FAIL 3.4: curl -k'; exit 1; }
printf '%s\n' 'aaa  ./AdGuardHome_linux_mips.tar.gz' 'f5c3  ./AdGuardHome_linux_arm64.tar.gz' > "$WORK/cs.txt"
awkprog=$(grep -o "\$2 == f || [^']*" "$ROOT/opt/bin/libs/update")
[ "$(awk -v f=AdGuardHome_linux_arm64.tar.gz "$awkprog" "$WORK/cs.txt")" = f5c3 ] || { echo 'FAIL 3.4: checksums parse'; exit 1; }
# sha256 обязателен для kvasec_*.ipk (upgrade и install.sh)
grep -F 'kvasec_*) print_error "Не удалось получить SHA-256' "$ROOT/opt/bin/main/upgrade" >/dev/null
grep -F "fail 'cannot download SHA-256 file" "$ROOT/install.sh" >/dev/null
