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
printf '%s\n' 'dnsmasq[1]: query[AAAA] ipv6-query.example from 192.168.1.20' >> "$WORK/dns.log"

printf '%s\n' '#!/bin/sh' 'echo 203.0.113.10' > "$WORK/bin/dig"
printf '%s\n' '#!/bin/sh' 'echo "10: opkgtun10: <UP>"' > "$WORK/bin/ip"
printf '%s\n' '#!/bin/sh' 'case "$*" in' '  *vpn-failed.example*) echo 000 ;;' '  *direct-blocked.example*) case "$*" in *--interface*) echo 200 ;; *) echo 000 ;; esac ;;' '  *timeout.example*) echo 000; exit 28 ;;' '  *tls-failed.example*) echo 000; exit 35 ;;' '  *forbidden.example*) echo 403 ;;' '  *vpn-ok.example*) echo 204 ;;' '  *) echo 200 ;;' 'esac' > "$WORK/bin/curl"
chmod +x "$WORK/bin/dig" "$WORK/bin/ip" "$WORK/bin/curl"

PATH="$WORK/bin:$PATH" KVAS_CONF="$WORK/kvas.conf" KVAS_LIST="$WORK/kvas.list" DNS_LOG="$WORK/dns.log" BYPASS_RESULT_FILE="$WORK/result.json" BYPASS_PROGRESS_FILE="$WORK/progress" BYPASS_LOCK_FILE="$WORK/lock" BYPASS_PID_FILE="$WORK/pid" BYPASS_MAX_DOMAINS=10 sh "$CHECKER"

grep -F '"domain":"vpn-ok.example","in_vpn":true,"status":"ok"' "$WORK/result.json" >/dev/null
grep -F '"domain":"vpn-failed.example","in_vpn":true,"status":"awg_failed"' "$WORK/result.json" >/dev/null
grep -F '"domain":"direct-blocked.example","in_vpn":false,"status":"direct_failed_awg_ok"' "$WORK/result.json" >/dev/null
test ! -e "$WORK/lock"
test ! -e "$WORK/pid"
grep -Fx '4|4' "$WORK/progress" >/dev/null

# Большой VPN-список не должен вытеснять новые DNS-кандидаты из лимита.
printf '%s\n' one.example two.example three.example four.example five.example six.example > "$WORK/crowded.list"
PATH="$WORK/bin:$PATH" KVAS_CONF="$WORK/kvas.conf" KVAS_LIST="$WORK/crowded.list" DNS_LOG="$WORK/dns.log" BYPASS_RESULT_FILE="$WORK/crowded.json" BYPASS_LOCK_FILE="$WORK/crowded.lock" BYPASS_MAX_DOMAINS=4 sh "$CHECKER"
grep -F '"domain":"direct-blocked.example"' "$WORK/crowded.json" >/dev/null

# Explicit modes: all checks every VPN domain, dns is limited to observed DNS.
PATH="$WORK/bin:$PATH" KVAS_CONF="$WORK/kvas.conf" KVAS_LIST="$WORK/crowded.list" DNS_LOG="$WORK/dns.log" BYPASS_RESULT_FILE="$WORK/all.json" BYPASS_LOCK_FILE="$WORK/all.lock" BYPASS_MODE=all sh "$CHECKER"
grep -F '"domain":"six.example"' "$WORK/all.json" >/dev/null
PATH="$WORK/bin:$PATH" KVAS_CONF="$WORK/kvas.conf" KVAS_LIST="$WORK/crowded.list" DNS_LOG="$WORK/dns.log" BYPASS_RESULT_FILE="$WORK/dns.json" BYPASS_LOCK_FILE="$WORK/dns.lock" BYPASS_MODE=dns sh "$CHECKER"
grep -F '"domain":"direct-blocked.example"' "$WORK/dns.json" >/dev/null
grep -F '"domain":"ipv6-query.example"' "$WORK/dns.json" >/dev/null

# HTTP-level denials are reported separately from failed network connections.
printf '%s\n' forbidden.example > "$WORK/forbidden.list"
PATH="$WORK/bin:$PATH" KVAS_CONF="$WORK/kvas.conf" KVAS_LIST="$WORK/forbidden.list" DNS_LOG="$WORK/dns.log" BYPASS_RESULT_FILE="$WORK/forbidden.json" BYPASS_LOCK_FILE="$WORK/forbidden.lock" BYPASS_MODE=all sh "$CHECKER"
grep -F '"domain":"forbidden.example","in_vpn":true,"status":"http_denied"' "$WORK/forbidden.json" >/dev/null
grep -F '"http_code":"403"' "$WORK/forbidden.json" >/dev/null

# A failed request exposes its network stage; it must not be indistinguishable
# from an HTTP denial or a generic possible block.
printf '%s\n' 'dnsmasq[1]: query[A] timeout.example from 192.168.1.20' 'dnsmasq[1]: query[A] tls-failed.example from 192.168.1.20' > "$WORK/diagnostic.log"
PATH="$WORK/bin:$PATH" KVAS_CONF="$WORK/kvas.conf" KVAS_LIST="$WORK/empty.list" DNS_LOG="$WORK/diagnostic.log" BYPASS_RESULT_FILE="$WORK/diagnostic.json" BYPASS_LOCK_FILE="$WORK/diagnostic.lock" BYPASS_MODE=dns sh "$CHECKER"
grep -F 'таймаут TCP/TLS (curl 28)' "$WORK/diagnostic.json" >/dev/null
grep -F 'TLS-handshake не прошёл (curl 35)' "$WORK/diagnostic.json" >/dev/null

# A watcher event can request one exact domain without reading or modifying the
# VPN list.  This is the path used by the "Проверить доступ" button.
PATH="$WORK/bin:$PATH" KVAS_CONF="$WORK/kvas.conf" KVAS_LIST="$WORK/empty.list" BYPASS_RESULT_FILE="$WORK/one.json" BYPASS_LOCK_FILE="$WORK/one.lock" BYPASS_MODE=domain BYPASS_DOMAIN=direct-blocked.example sh "$CHECKER"
grep -F '"domain":"direct-blocked.example","in_vpn":false,"status":"direct_failed_awg_ok"' "$WORK/one.json" >/dev/null
