#!/bin/sh
# Regression checks for the AmneziaWG routing watcher.  It must repair only
# KVASEC state and never disrupt unrelated browser traffic.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WATCHER="$ROOT/opt/etc/init.d/S99kvas-awg-route"

sh -n "$WATCHER"

# Legacy releases inserted a router-wide QUIC reject every five seconds.  This
# breaks HTTP/3 for all clients and can surface as ERR_NETWORK_CHANGED.
grep -F 'legacy QUIC block udp/443 removed' "$WATCHER" >/dev/null
grep -F 'iptables -D FORWARD -i br0 -p udp --dport 443 -j REJECT' "$WATCHER" >/dev/null
! grep -F 'iptables -I FORWARD -i br0 -p udp --dport 443 -j REJECT' "$WATCHER" >/dev/null

# `ipset test` receives one IP, not a CIDR.  CIDR input never confirmed the
# set membership and caused needless writes on every five-second cycle.
grep -F 'ipset test KVAS_LIST 149.154.160.1 >/dev/null 2>&1' "$WATCHER" >/dev/null
! grep -F 'ipset test KVAS_LIST 149.154.160.0/20' "$WATCHER" >/dev/null
