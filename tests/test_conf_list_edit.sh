#!/bin/sh
# Регрессия 6.5: правка списков в kvas.conf из WebUI — точная, атомарная, под локом.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# как на роутере: busybox mkdir (uutils coreutils mkdir не атомарен)
if command -v busybox >/dev/null 2>&1; then
    mkdir -p "$WORK/bb"
    printf '%s\n' '#!/bin/sh' 'exec busybox mkdir "$@"' > "$WORK/bb/mkdir"; chmod +x "$WORK/bb/mkdir"
    PATH="$WORK/bb:$PATH"; export PATH
fi

{
    echo "KVAS_CONF_FILE='$WORK/kvas.conf'; CONF_LOCK_DIR='$WORK/conf.lock'"
    sed -n '/^conf_lock() {/,/^}/p; /^conf_unlock()/p; /^conf_list_edit() {/,/^}/p' \
        "$ROOT/opt/bin/monitor/www/cgi-bin/manage.sh"
} > "$WORK/lib.sh"
ce() { sh -c ". '$WORK/lib.sh'; conf_list_edit \"\$@\"" _ "$@"; }

printf '%s\n' 'INFACE_ENT=opkgtun10' 'route_full_ip=10.0.0.1+10.0.0.10' 'X=1' > "$WORK/kvas.conf"
ce route_full_ip + add 10.0.0.2
if ce route_full_ip + add 10.0.0.2; then echo 'FAIL: повторное add «изменило» файл'; exit 1; fi
ce route_full_ip + del 10.0.0.1                     # не задевает 10.0.0.10 (раньше grep -v "^ip$" — регэксп)
grep -qx 'route_full_ip=10.0.0.10+10.0.0.2' "$WORK/kvas.conf" || { echo 'FAIL: del/add'; cat "$WORK/kvas.conf"; exit 1; }
ce route_full_ip + del 10.0.0.10; ce route_full_ip + del 10.0.0.2
if grep -q '^route_full_ip=' "$WORK/kvas.conf"; then echo 'FAIL: пустой ключ остался'; exit 1; fi
if ce route_full_ip + del 9.9.9.9; then echo 'FAIL: del несуществующего «изменил» файл'; exit 1; fi
ce INFACE_GUEST_ENT , add br1
ce INFACE_GUEST_ENT , add br2
grep -qx 'INFACE_GUEST_ENT=br1,br2' "$WORK/kvas.conf" || { echo 'FAIL: guest'; exit 1; }
grep -qx 'INFACE_ENT=opkgtun10' "$WORK/kvas.conf" && grep -qx 'X=1' "$WORK/kvas.conf" || { echo 'FAIL: прочие ключи'; exit 1; }

# параллельные add разных IP — ни один не теряется
i=1
while [ "$i" -le 12 ]; do ce route_excluded_ip + add "192.168.1.$i" & i=$((i + 1)); done
wait
n=$(grep '^route_excluded_ip=' "$WORK/kvas.conf" | cut -d= -f2 | tr '+' '\n' | grep -c .)
[ "$n" -eq 12 ] || { echo "FAIL: из 12 параллельных add сохранилось $n"; exit 1; }
[ ! -d "$WORK/conf.lock" ] || { echo 'FAIL: лок не снят'; exit 1; }
