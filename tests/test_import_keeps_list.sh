#!/bin/sh
# Регрессия: импорт (WebUI «Импорт», закваски add-protect) дописывает новые
# записи и НЕ переписывает весь kvas.list (раньше снимал "*." со всех записей,
# удалял комментарии и сортировал).
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
if command -v busybox >/dev/null 2>&1; then RUN="busybox sh"; else RUN="bash"; fi

fn() { sed -n "/^$2() *{/,/^}/p" "$ROOT/opt/bin/libs/$1"; }
{
    echo "KVAS_LIST_FILE='$WORK/kvas.list'; KVAS_LIST_FILE_BACKUP='$WORK/kvas.list.bak'; IPSET_TABLE_NAME=KVAS_LIST"
    echo 'ready() { :; }; when_ok() { :; }; when_bad() { :; }; error() { echo "ERR $*" >&2; }; warning() { :; }; print_line() { :; }'
    echo 'cmd_ads_status() { echo ОТКЛЮЧЕН; }; cmd_kvas_init() { :; }'
    sed -n '/^_list_entry_awk=/,/^list_remove_entry() {/p' "$ROOT/opt/bin/libs/main"
    sed -n '/^list_remove_entry() {/,/^}/p' "$ROOT/opt/bin/libs/main" | sed 1d
    grep '^IP_FILTER=' "$ROOT/opt/bin/libs/main"
    for f in clear_file clear_content clear_file_content get_regexp_ip_or_range; do fn main "$f"; done
    fn vpn rec_in_var
    fn vpn cmd_import_hosts
} > "$WORK/lib.sh"

printf '%s\n' '*.youtube.com' 'google.com' '' '# --- Telegram DC ---' '149.154.160.0/20' > "$WORK/kvas.list"
printf '%s' '*.zz-last.com' >> "$WORK/kvas.list"          # без \n в конце
printf '%s\n' 'new-one.com' 'youtube.com' 'google.com' '*.new-wild.org' > "$WORK/import.txt"

$RUN -c ". '$WORK/lib.sh'; cmd_import_hosts '$WORK/import.txt'" >/dev/null 2>&1

printf '%s\n' '*.youtube.com' 'google.com' '' '# --- Telegram DC ---' '149.154.160.0/20' '*.zz-last.com' \
    'new-one.com' 'new-wild.org' | cmp - "$WORK/kvas.list" || { echo 'FAIL: kvas.list переписан'; cat "$WORK/kvas.list"; exit 1; }
