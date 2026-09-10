#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WATCH="$ROOT/opt/bin/monitor/block_watch.sh"
MANAGE="$ROOT/opt/bin/monitor/www/cgi-bin/manage.sh"

sh -n "$WATCH"
grep -F 'UNREPLIED' "$WATCH" >/dev/null
grep -F '$1=="tcp" || $3=="tcp"' "$WATCH" >/dev/null
grep -F 'function non_public' "$WATCH" >/dev/null
grep -F 'trap cleanup EXIT HUP INT TERM' "$WATCH" >/dev/null
grep -F 'log-queries=extra' "$WATCH" >/dev/null
grep -F 'log-facility=%s' "$WATCH" >/dev/null
grep -F 'disable_dns_capture' "$WATCH" >/dev/null
grep -F 'rm -f "$DNS_LOG"' "$WATCH" >/dev/null
grep -F 'tail -300 "$DNS_LOG"' "$WATCH" >/dev/null
grep -F 'BLOCK_WATCH_LOCK_DIR' "$MANAGE" >/dev/null
grep -F 'block_watch_start)' "$MANAGE" >/dev/null
grep -F 'block_watch_stop)' "$MANAGE" >/dev/null
grep -F 'block_watch_status)' "$MANAGE" >/dev/null
grep -F 'bypass_check_stop)' "$MANAGE" >/dev/null
grep -F 'stop_bypass_check()' "$MANAGE" >/dev/null
grep -F 'clear_stale_bypass_check()' "$MANAGE" >/dev/null
grep -F 'BYPASS_PID_FILE="$BYPASS_CHECK_PID"' "$MANAGE" >/dev/null
grep -F 'clear_stale_block_watch()' "$MANAGE" >/dev/null
grep -F 'stop_block_watch()' "$MANAGE" >/dev/null
grep -F 'BLOCK_WATCH_LOCK_DIR="$BLOCK_WATCH_LOCK_DIR"' "$MANAGE" >/dev/null

# conntrack -L has TCP in $1, unlike /proc/net/nf_conntrack where it is $3.
# Exercise a real watcher iteration so that a format regression cannot silently
# leave the WebUI empty again.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
mkdir -p "$WORK/bin"
printf '%s\n' '#!/bin/sh' 'printf "1: br0: <UP>\\n    inet 192.168.1.1/24\\n"' > "$WORK/bin/ip"
printf '%s\n' '#!/bin/sh' 'printf "dnsmasq[1]: reply blocked.example is 203.0.113.7\\n"' > "$WORK/bin/logread"
printf '%s\n' '#!/bin/sh' 'case "$*" in *"-x 203.0.113.8"*) echo owner.example. ;; *) : ;; esac' > "$WORK/bin/dig"
printf '%s\n' '#!/bin/sh' 'printf "tcp 6 120 SYN_SENT src=192.168.1.50 dst=203.0.113.7 sport=50000 dport=443 [UNREPLIED]\\ntcp 6 120 SYN_SENT src=192.168.1.51 dst=203.0.113.8 sport=50001 dport=443 [UNREPLIED]\\n"' > "$WORK/bin/conntrack"
chmod +x "$WORK/bin/ip" "$WORK/bin/logread" "$WORK/bin/dig" "$WORK/bin/conntrack"
PATH="$WORK/bin:$PATH" BLOCK_WATCH_EVENTS="$WORK/events" BLOCK_WATCH_PID="$WORK/pid" BLOCK_WATCH_LOCK_DIR="$WORK/lock" BLOCK_WATCH_DNS_CONF="$WORK/dns.dnsmasq" BLOCK_WATCH_DNS_LOG="$WORK/dns.log" BLOCK_WATCH_DNS_RESTART_BIN=/bin/true BLOCK_WATCH_INTERVAL=1 sh "$WATCH" >/dev/null 2>&1 &
watch_pid=$!
for wait_event in 1 2 3 4; do
  grep -F '|fail|192.168.1.50|203.0.113.7:443' "$WORK/events" >/dev/null 2>&1 && break
  sleep 1
done
grep -F '|map|203.0.113.7|blocked.example' "$WORK/events" >/dev/null
grep -F '|fail|192.168.1.50|203.0.113.7:443' "$WORK/events" >/dev/null
grep -F '|ptr|203.0.113.8|owner.example' "$WORK/events" >/dev/null
kill "$watch_pid" 2>/dev/null || true
wait "$watch_pid" 2>/dev/null || true
test ! -e "$WORK/pid"
test ! -e "$WORK/lock"
test ! -e "$WORK/dns.dnsmasq"
