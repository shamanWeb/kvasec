#!/bin/sh
# Traffic-monitor regressions: one slow PTR must never block a WebUI poll.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/opt/bin/monitor/www/cgi-bin/data.sh"
UI="$ROOT/opt/bin/monitor/www/index.html"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

mkdir -p "$WORK/tokens" "$WORK/bin"
sed \
  -e "s|^TOKEN_DIR=.*|TOKEN_DIR=$WORK/tokens|" \
  -e "s|^DNS_LOG=.*|DNS_LOG=$WORK/dns.log|" \
  -e "s|^PTR_CACHE=.*|PTR_CACHE=$WORK/ptr-cache|" \
  -e "s|^PTR_PENDING_DIR=.*|PTR_PENDING_DIR=$WORK/ptr-pending|" \
  "$SOURCE" > "$WORK/data.sh"

printf '%s\n' '#!/bin/sh' 'echo "tcp 6 120 ESTABLISHED src=192.168.1.20 dst=203.0.113.10 sport=50000 dport=443"' > "$WORK/bin/conntrack"
# Deliberately slow resolver: the response must return before it completes.
printf '%s\n' '#!/bin/sh' 'sleep 4' > "$WORK/bin/dig"
chmod +x "$WORK/bin/conntrack" "$WORK/bin/dig"

token=0123456789abcdef0123456789abcdef
date +%s > "$WORK/tokens/$token"
started=$(date +%s)
output=$(PATH="$WORK/bin:$PATH" QUERY_STRING="action=data&ips=192.168.1.20&token=$token" sh "$WORK/data.sh")
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 2 ]
printf '%s' "$output" | grep -F '"dst":"203.0.113.10"' >/dev/null

# The last DNS mapping wins for an IP, which is important for CDN reuse.
printf '%s\n' 'dnsmasq: reply old.example is 203.0.113.10' 'dnsmasq: reply new.example is 203.0.113.10' > "$WORK/dns.log"
output=$(PATH="$WORK/bin:$PATH" QUERY_STRING="action=data&ips=192.168.1.20&token=$token" sh "$WORK/data.sh")
printf '%s' "$output" | grep -F '"dname":"new.example"' >/dev/null

# The browser avoids overlapping slow CGI requests and logs a flow only once
# while it remains in the current snapshot.
grep -F 'if (pollInFlight) return;' "$UI" >/dev/null
grep -F 'var seenConnectionAt = new Map();' "$UI" >/dev/null
grep -F 'if (!firstSeen) return;' "$UI" >/dev/null
