#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WATCH="$ROOT/opt/bin/monitor/block_watch.sh"
MANAGE="$ROOT/opt/bin/monitor/www/cgi-bin/manage.sh"

sh -n "$WATCH"
grep -F 'UNREPLIED' "$WATCH" >/dev/null
grep -F '$3=="tcp"' "$WATCH" >/dev/null
grep -F 'function non_public' "$WATCH" >/dev/null
grep -F 'trap cleanup EXIT HUP INT TERM' "$WATCH" >/dev/null
grep -F 'BLOCK_WATCH_LOCK_DIR' "$MANAGE" >/dev/null
grep -F 'block_watch_start)' "$MANAGE" >/dev/null
grep -F 'block_watch_stop)' "$MANAGE" >/dev/null
grep -F 'block_watch_status)' "$MANAGE" >/dev/null
