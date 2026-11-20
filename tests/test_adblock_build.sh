#!/bin/sh
# Регрессия main/adblock: список собирается с нуля, исключения (≥2 записей) работают,
# при недоступности всех источников рабочий список не трогается, dnsmasq применяет.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
if command -v busybox >/dev/null 2>&1; then RUN="busybox sh"; else RUN="bash"; fi

O="$WORK/opt"
mkdir -p "$O/etc/adblock" "$O/tmp" "$O/bin" "$WORK/bin" "$WORK/src"
{
    echo "ADBLOCK_HOSTS_FILE='$O/etc/adblock/ads.kvas.list'; KVAS_LIST_FILE='$O/etc/kvas.list'"
    echo "ADBLOCK_PARENTAL_DNS_FILE='$O/parental.dnsmasq'"
    echo 'ready() { :; }; when_ok() { :; }; when_bad() { :; }; when_alert() { :; }; error() { echo "ERR $*" >&2; }'
    echo 'print_line() { :; }; progress_bar() { :; }; dig_frm() { echo "$1"; }; pidof() { echo 1; }'
    echo "restart_dns_service() { echo \"reload \$1\" >> '$WORK/reloads'; }"
    sed -n '/^ads_filter_exceptions() {/,/^}/p; /^parental_dns_sum() {/,/^}/p' "$ROOT/opt/bin/libs/adblock"
} > "$WORK/libs.sh"
sed -e "s|^\. /opt/apps/kvas/bin/libs/vpn|. '$WORK/libs.sh'|" -e "s|/opt/|$O/|g" "$ROOT/opt/bin/main/adblock" > "$WORK/adblock.sh"

# curl-заглушка: копирует file-источник в -o; источник "bad" — сбой
cat > "$WORK/bin/curl" <<'EOS'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; -*) ;; *) url="$1" ;; esac; shift; done
[ -f "$url" ] || exit 22
cp "$url" "$out"
EOS
printf '%s\n' '#!/bin/sh' 'exit 0' > "$WORK/bin/logger"
chmod +x "$WORK/bin/curl" "$WORK/bin/logger"
export PATH="$WORK/bin:$PATH"

printf '%s\n' '0.0.0.0 ads.example' '0.0.0.0 collector.githubapp.com' '0.0.0.0 api.github.com' \
    '0.0.0.0 xgithub.com' '0.0.0.0 tracker.vpnsite.com' > "$WORK/src/hosts1"
printf '%s\n' "$WORK/src/hosts1" > "$O/etc/adblock/sources.list"
printf '%s\n' 'github.com' 'githubapp.com' > "$O/etc/adblock/exception.list"
printf '%s\n' '*.vpnsite.com' > "$O/etc/kvas.list"
printf '%s\n' '0.0.0.0 stale-from-old-run.example' > "$O/etc/adblock/ads.kvas.list"

$RUN "$WORK/adblock.sh" yes >/dev/null 2>&1
L="$O/etc/adblock/ads.kvas.list"
grep -qx '0.0.0.0 ads.example' "$L"                       || { echo 'FAIL: нет рекламного домена'; exit 1; }
grep -qx '0.0.0.0 xgithub.com' "$L"                        || { echo 'FAIL: xgithub.com не должен исключаться'; exit 1; }
if grep -q 'stale-from-old-run' "$L"; then echo 'FAIL 5.3: старая запись осталась'; exit 1; fi
if grep -qE 'collector.githubapp.com|api.github.com' "$L"; then echo 'FAIL 5.2: исключения не сработали'; exit 1; fi
if grep -q 'tracker.vpnsite.com' "$L"; then echo 'FAIL: домен из kvas.list не исключён'; exit 1; fi
grep -q '^reload' "$WORK/reloads"                          || { echo 'FAIL: dnsmasq не применил список'; exit 1; }
if [ -d "$O/tmp/adblock" ]; then echo 'FAIL: временные файлы не убраны'; exit 1; fi

# все источники недоступны → рабочий список не меняется, код 1
cp "$L" "$WORK/before"
printf '%s\n' "$WORK/src/missing" > "$O/etc/adblock/sources.list"
if $RUN "$WORK/adblock.sh" yes >/dev/null 2>&1; then echo 'FAIL: сбой загрузки вернул 0'; exit 1; fi
cmp "$WORK/before" "$L" || { echo 'FAIL: список испорчен при недоступных источниках'; exit 1; }
