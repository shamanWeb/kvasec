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
