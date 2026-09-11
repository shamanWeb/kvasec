#!/bin/sh
# Parent-control domains must cover subdomains and reject malformed entries.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GENERATOR="$ROOT/opt/bin/main/parental_dns"
CGI="$ROOT/opt/bin/monitor/www/cgi-bin/manage.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

cat > "$WORK/block.list" <<'EOF'
Example.COM
*.video.example.com
bad value
example..com
EOF

KVAS_BLOCK_LIST="$WORK/block.list" KVAS_PARENTAL_DNS_FILE="$WORK/parental.dnsmasq" sh "$GENERATOR"

expected='address=/.example.com/0.0.0.0
address=/.video.example.com/0.0.0.0'
[ "$(cat "$WORK/parental.dnsmasq")" = "$expected" ]

sh -n "$GENERATOR"
sh -n "$CGI"
grep -F 'adguard_active && json_error' "$CGI" >/dev/null
grep -F 'valid_domain "$domain" || json_error' "$CGI" >/dev/null
grep -F 'address=/.%s/0.0.0.0' "$GENERATOR" >/dev/null

# Web UI management starts the existing local setup non-interactively and
# reports a real service state instead of claiming that AdGuard is available.
grep -F 'adguard_status_json' "$CGI" >/dev/null
grep -F '"$KVAS_BIN" adguard on web' "$CGI" >/dev/null
grep -F 'adguard_active && json_error "AdGuard Home всё ещё запущен"' "$CGI" >/dev/null
grep -F 'adguard_web_backup || json_error' "$CGI" >/dev/null
grep -F 'adguard_web_restore > "$ADGUARD_WEB_LOG"' "$CGI" >/dev/null
grep -F 'web|local) _answer=n' "$ROOT/opt/bin/libs/vpn" >/dev/null
