#!/bin/sh
# Проверяет классификацию bypass checker без сети и роутера.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CHECKER="$ROOT/opt/bin/monitor/bypass_check.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

mkdir -p "$WORK/bin"
printf '%s\n' 'vpn-ok.example' 'vpn-failed.example' > "$WORK/kvas.list"
printf '%s\n' 'INFACE_ENT=opkgtun10' > "$WORK/kvas.conf"
printf '%s\n' 'dnsmasq[1]: query[A] direct-blocked.example from 192.168.1.20' > "$WORK/dns.log"

printf '%s\n' '#!/bin/sh' 'echo 203.0.113.10' > "$WORK/bin/dig"
printf '%s\n' '#!/bin/sh' 'echo "10: opkgtun10: <UP>"' > "$WORK/bin/ip"
printf '%s\n' '#!/bin/sh' 'case "$*" in' '  *vpn-failed.example*) echo 000 ;;' '  *direct-blocked.example*) case "$*" in *--interface*) echo 200 ;; *) echo 000 ;; esac ;;' '  *vpn-ok.example*) echo 204 ;;' '  *) echo 200 ;;' 'esac' > "$WORK/bin/curl"
chmod +x "$WORK/bin/dig" "$WORK/bin/ip" "$WORK/bin/curl"

PATH="$WORK/bin:$PATH" KVAS_CONF="$WORK/kvas.conf" KVAS_LIST="$WORK/kvas.list" DNS_LOG="$WORK/dns.log" BYPASS_RESULT_FILE="$WORK/result.json" BYPASS_LOCK_FILE="$WORK/lock" BYPASS_MAX_DOMAINS=10 sh "$CHECKER"

grep -F '"domain":"vpn-ok.example","in_vpn":true,"status":"ok"' "$WORK/result.json" >/dev/null
grep -F '"domain":"vpn-failed.example","in_vpn":true,"status":"awg_failed"' "$WORK/result.json" >/dev/null
grep -F '"domain":"direct-blocked.example","in_vpn":false,"status":"direct_failed_awg_ok"' "$WORK/result.json" >/dev/null
test ! -e "$WORK/lock"

# Большой VPN-список не должен вытеснять новые DNS-кандидаты из лимита.
printf '%s\n' one.example two.example three.example four.example five.example six.example > "$WORK/crowded.list"
PATH="$WORK/bin:$PATH" KVAS_CONF="$WORK/kvas.conf" KVAS_LIST="$WORK/crowded.list" DNS_LOG="$WORK/dns.log" BYPASS_RESULT_FILE="$WORK/crowded.json" BYPASS_LOCK_FILE="$WORK/crowded.lock" BYPASS_MAX_DOMAINS=4 sh "$CHECKER"
grep -F '"domain":"direct-blocked.example"' "$WORK/crowded.json" >/dev/null
