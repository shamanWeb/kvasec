#!/bin/sh
# Регрессия: удаление/поиск записей kvas.list — точное, не подстрока/регэксп.
# Раньше `kvas del x.com` удалял и netflix.com, `del t.co` — microsoft.com,
# а `add google.com` считал дублем google.com.ua.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

sed -n '/^_list_entry_awk=/,/^list_remove_entry() {/p' "$ROOT/opt/bin/libs/main" > "$WORK/h.sh"
sed -n '/^list_remove_entry() {/,/^}/p' "$ROOT/opt/bin/libs/main" | sed 1d >> "$WORK/h.sh"

for impl in sh "busybox sh"; do
    [ "$impl" = sh ] || command -v busybox >/dev/null 2>&1 || continue
    printf '%s\n' '*.netflix.com' 'x.com' 'box.com' '*.youtube.com' 'microsoft.com' 't.co' \
        '1.2.3.0/24' '# x.com' 'music.youtube.com' 'google.com.ua' > "$WORK/list"
    printf '%s\n' 'x.com/KVAS_LIST' '*.youtube.com/KVAS_LIST' 'box.com/KVAS_LIST' > "$WORK/ag"
    $impl -c '
        set -e
        . "$1/h.sh"; IPSET_TABLE_NAME=KVAS_LIST; L="$1/list"; A="$1/ag"
        list_has_entry "$L" x.com
        list_has_entry "$L" youtube.com          # есть как *.youtube.com
        list_has_entry "$L" "*.youtube.com"
        list_has_entry "$L" 1.2.3.0/24
        if list_has_entry "$L" google.com; then exit 1; fi          # google.com.ua — другой домен
        if list_has_entry "$L" tube.com; then exit 1; fi
        list_remove_entry "$L" x.com
        list_remove_entry "$L" t.co
        list_remove_entry "$L" "*.youtube.com"
        if list_remove_entry "$L" nothere.com; then exit 1; fi
        list_remove_entry "$A" youtube.com
    ' _ "$WORK" || { echo "FAIL: list helpers under $impl"; exit 1; }
    printf '%s\n' '*.netflix.com' 'box.com' 'microsoft.com' '1.2.3.0/24' '# x.com' \
        'music.youtube.com' 'google.com.ua' | cmp - "$WORK/list" || { echo "FAIL: list content under $impl"; exit 1; }
    printf '%s\n' 'x.com/KVAS_LIST' 'box.com/KVAS_LIST' | cmp - "$WORK/ag" || { echo "FAIL: ag content under $impl"; exit 1; }
    for f in "$WORK"/*.tmp.*; do [ ! -e "$f" ] || { echo "FAIL: tmp file left: $f"; exit 1; }; done
done

# host_del из WebUI: только домен / IP / CIDR / диапазон, до kvas не доходит мусор.
SOURCE="$ROOT/opt/bin/monitor/www/cgi-bin/manage.sh"
cp "$SOURCE" "$WORK/manage.sh"
sed -i -e "s|^TOKEN_DIR=.*|TOKEN_DIR=$WORK/tokens|" -e "s|^KVAS_BIN=.*|KVAS_BIN=$WORK/kvas|" "$WORK/manage.sh"
printf '%s\n' '#!/bin/sh' '[ "$1" = del ] && printf "%s\n" "$*" >> "$TEST_KVAS_ARGS"; exit 0' > "$WORK/kvas"
chmod +x "$WORK/kvas"
export TEST_KVAS_ARGS="$WORK/kvas-args"
mkdir -p "$WORK/tokens"; token=0123456789abcdef0123456789abcdef; date +%s > "$WORK/tokens/$token"
api() { QUERY_STRING="$1&token=$token" REQUEST_METHOD=GET sh "$WORK/manage.sh"; }
api 'action=host_del&domain=.' | grep -F 'invalid domain' >/dev/null
api 'action=host_del&domain=a%3Bb' | grep -F 'invalid domain' >/dev/null
api 'action=host_del&domain=%24(id)' | grep -F 'invalid domain' >/dev/null
api 'action=host_del&domain=-x' | grep -F 'invalid domain' >/dev/null
test ! -e "$TEST_KVAS_ARGS"
api 'action=host_del&domain=%2A.YouTube.com' | grep -F '"ok":true' >/dev/null
api 'action=host_del&domain=1.2.3.0%2F24' | grep -F '"ok":true' >/dev/null
api 'action=host_del&domain=1.2.3.4-1.2.3.9' | grep -F '"ok":true' >/dev/null
# реальные записи, которые строгий valid_domain отвергал
api 'action=host_del&domain=%2A.ru' | grep -F '"ok":true' >/dev/null
api 'action=host_del&domain=_dmarc.example.com' | grep -F '"ok":true' >/dev/null
api 'action=host_del&domain=a%20b' | grep -F 'invalid domain' >/dev/null
printf '%s\n' 'del YouTube.com' 'del 1.2.3.0/24' 'del 1.2.3.4-1.2.3.9' 'del ru' 'del _dmarc.example.com' | cmp - "$TEST_KVAS_ARGS"
