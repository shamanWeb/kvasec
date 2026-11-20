#!/bin/sh
# Regression checks for the AmneziaWG routing watcher.  It must repair only
# KVASEC state and never disrupt unrelated browser traffic.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WATCHER="$ROOT/opt/etc/init.d/S99kvas-awg-route"

sh -n "$WATCHER"

# Legacy releases inserted a router-wide QUIC reject every five seconds.  This
# breaks HTTP/3 for all clients and can surface as ERR_NETWORK_CHANGED.
grep -F 'legacy QUIC block udp/443 removed' "$WATCHER" >/dev/null
grep -F 'iptables -D FORWARD -i br0 -p udp --dport 443 -j REJECT' "$WATCHER" >/dev/null
grep -F 'iptables -I FORWARD -i br0 -p udp --dport 443 -j REJECT' "$WATCHER" >/dev/null && exit 1

# `ipset test` receives one IP, not a CIDR.  CIDR input never confirmed the
# set membership and caused needless writes on every watcher cycle.
grep -F 'ipset test KVAS_LIST 149.154.160.1 >/dev/null 2>&1' "$WATCHER" >/dev/null
grep -F 'ipset test KVAS_LIST 149.154.160.0/20' "$WATCHER" >/dev/null && exit 1

# Ten seconds keeps the recovery delay short while halving constant polling.
grep -Fx '    sleep 10' "$WATCHER" >/dev/null

# Fail-closed: when the tunnel interface disappears, marked traffic must hit an
# unreachable route in table 1001 instead of falling through to main → WAN.
grep -F 'unreachable default metric 4000' "$WATCHER" >/dev/null

# Connections opened while KVAS_MARK was missing keep mark=0 forever (restore-mark
# then '! NEW → RETURN'); the watcher must reset them after restoring the chain.
grep -A2 'KVAS_MARK восстановлен' "$WATCHER" | grep -F 'purge_unmarked_conns' >/dev/null

# Two parallel restarts used to spawn two watchers that raced ndm's
# check-then-add and duplicated PREROUTING jumps.
grep -F 'mkdir "$LOCK"' "$WATCHER" >/dev/null
grep -F 'kill_others' "$WATCHER" >/dev/null
grep -F 'dedupe_rules mangle PREROUTING' "$WATCHER" >/dev/null

# purge_unmarked_conns: логика — в main/purge_unmarked (свой тест
# test_purge_unmarked.sh); сторож вызывает скрипт и пишет число в лог.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
printf '#!/bin/sh\necho 3\n' >"$TMP/purge"; chmod +x "$TMP/purge"
sed -n '/^purge_unmarked_conns()/,/^}/p' "$WATCHER" >"$TMP/fn.sh"
PURGE="$TMP/purge" LOG="$TMP/w.log" sh -c '. "$1"; purge_unmarked_conns' _ "$TMP/fn.sh"
grep -F 'немаркированных соединений к KVAS_LIST: 3' "$TMP/w.log" >/dev/null

# Аудит 2.5: интерфейс default — поле после "dev"; ip rule — именно с priority 99;
# KVAS_MARK целая по --save-mark; KVAS_DNS тоже проверяется и чинится хуком.
printf '%s\n' 'default dev opkgtun10 scope link' >"$TMP/rt"
awkdev=$(grep -o "awk '/^default/ { for[^']*'" "$WATCHER" | sed "s/^awk '//; s/'$//")
[ "$(awk "$awkdev" "$TMP/rt")" = opkgtun10 ]
grep -F 'grep -c "^${RPRIO}:.*fwmark ${MARK}.*lookup ${RTABLE}"' "$WATCHER" >/dev/null
grep -F -- 'grep -c -- "--save-mark"' "$WATCHER" >/dev/null
grep -F 'KVAS_DNS восстановлен' "$WATCHER" >/dev/null

# busybox `kill -0 ""` succeeds, so an unguarded pidfile check made start()
# exit immediately and the watcher never ran after install.
grep -E 'kill -0 "\$\(cat' "$WATCHER" >/dev/null && exit 1
exit 0
