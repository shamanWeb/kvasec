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
! grep -F 'iptables -I FORWARD -i br0 -p udp --dport 443 -j REJECT' "$WATCHER" >/dev/null

# `ipset test` receives one IP, not a CIDR.  CIDR input never confirmed the
# set membership and caused needless writes on every watcher cycle.
grep -F 'ipset test KVAS_LIST 149.154.160.1 >/dev/null 2>&1' "$WATCHER" >/dev/null
! grep -F 'ipset test KVAS_LIST 149.154.160.0/20' "$WATCHER" >/dev/null

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

# purge_unmarked_conns: only LAN→KVAS_LIST pairs with mark=0, router's own
# addresses skipped.  Run it against stubbed conntrack/ipset/ip.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/conntrack" <<'STUB'
#!/bin/sh
case "$1" in
  -L) cat <<'OUT'
tcp      6 431999 ESTABLISHED src=192.168.1.74 dst=52.1.1.1 sport=1 dport=443 src=52.1.1.1 dst=10.2.20.21 sport=443 dport=1 [ASSURED] mark=0 use=1
tcp      6 431999 ESTABLISHED src=192.168.1.74 dst=52.1.1.1 sport=2 dport=443 src=52.1.1.1 dst=10.2.20.21 sport=443 dport=2 [ASSURED] mark=0 use=1
tcp      6 431999 ESTABLISHED src=192.168.1.59 dst=93.158.177.1 sport=3 dport=443 src=93.158.177.1 dst=10.2.20.21 sport=443 dport=3 [ASSURED] mark=0 use=1
tcp      6 10 TIME_WAIT src=10.2.20.21 dst=52.1.1.1 sport=4 dport=80 src=52.1.1.1 dst=10.2.20.21 sport=80 dport=4 [ASSURED] mark=0 use=1
OUT
  ;;
  -D) echo "$*" >>"$CT_LOG" ;;
esac
STUB
printf '#!/bin/sh\n[ "$3" = 52.1.1.1 ]\n' >"$TMP/ipset"
printf '#!/bin/sh\necho "2: eth3    inet 10.2.20.21/24 brd 10.2.20.255 scope global eth3"\n' >"$TMP/ip"
chmod +x "$TMP/conntrack" "$TMP/ipset" "$TMP/ip"
sed -n '/^purge_unmarked_conns()/,/^}/p' "$WATCHER" >"$TMP/fn.sh"
CT_LOG="$TMP/ct.log" LOG="$TMP/w.log" PATH="$TMP:$PATH" sh -c '. "$1"; purge_unmarked_conns' _ "$TMP/fn.sh"
[ "$(cat "$TMP/ct.log")" = "-D -m 0 -s 192.168.1.74 -d 52.1.1.1" ]
grep -F 'немаркированных соединений к KVAS_LIST: 1' "$TMP/w.log" >/dev/null
