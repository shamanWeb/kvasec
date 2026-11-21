#!/bin/sh
# Регрессия: декодирование и валидация входных параметров manage.sh.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/opt/bin/monitor/www/cgi-bin/manage.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# url_decode — одинаково в dash и busybox (раньше printf %b: в dash не знал \x).
sed -n '/^url_decode() {/,/^}/p' "$SOURCE" > "$WORK/ud.sh"
for impl in sh "busybox sh"; do
    [ "$impl" = sh ] || command -v busybox >/dev/null 2>&1 || continue
    check() {
        got=$($impl -c ". '$WORK/ud.sh'; url_decode \"\$1\"" _ "$1" | od -An -c | tr -s ' \n' ' ')
        want=$(printf "$2" | od -An -c | tr -s ' \n' ' ')
        [ "$got" = "$want" ] || { echo "FAIL url_decode [$impl] '$1': got '$got' want '$want'"; exit 1; }
    }
    check 'a%2Db+c' 'a-b c'
    check 'abc%00def' 'abcdef'
    check '%01%1Fz' 'z'
    check 'x%0Ay' 'x\ny'
    check 'a\cb' 'a\\cb'
    check '50%' '50%%'
    check '%zz' '%%zz'
    check '%D0%A2' '\320\242'
done

# restore — только каталоги kvas backup (он перезаписывает конфиги и пароль панели).
cp "$SOURCE" "$WORK/manage.sh"
sed -i \
    -e "s|^TOKEN_DIR=.*|TOKEN_DIR=$WORK/tokens|" \
    -e "s|^KVAS_BIN=.*|KVAS_BIN=$WORK/kvas|" \
    "$WORK/manage.sh"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >> "$TEST_KVAS_ARGS"' > "$WORK/kvas"
chmod +x "$WORK/kvas"
export TEST_KVAS_ARGS="$WORK/kvas-args"
mkdir -p "$WORK/tokens"
token=0123456789abcdef0123456789abcdef
date +%s > "$WORK/tokens/$token"
api() { QUERY_STRING="$1&token=$token" REQUEST_METHOD=GET sh "$WORK/manage.sh"; }

api 'action=restore&path=%2Ftmp%2Fevil' | grep -F 'invalid backup path' >/dev/null
api 'action=restore&path=%2Fopt%2Fkvas_backup_20261120-101010%0A%2Ftmp' | grep -F 'invalid backup path' >/dev/null
api 'action=restore&path=%2Fopt%2Fkvas_backup_..%2F..%2Ftmp' | grep -F 'invalid backup path' >/dev/null
test ! -e "$TEST_KVAS_ARGS"
api 'action=restore&path=%2Fopt%2Fkvas_backup_20261120-101010' | grep -F '"ok":true' >/dev/null
api 'action=restore' | grep -F '"ok":true' >/dev/null
grep -Fx 'restore /opt/kvas_backup_20261120-101010' "$TEST_KVAS_ARGS" >/dev/null

# host_import: тело — ровно CONTENT_LENGTH байт, stdin не закрыт (раньше `cat` ждал EOF вечно).
sed -i "s|/tmp/kvas_import_|$WORK/kvas_import_|g" "$WORK/manage.sh"
mkfifo "$WORK/body"
QUERY_STRING="action=host_import&token=$token" REQUEST_METHOD=POST CONTENT_LENGTH=11 \
    sh "$WORK/manage.sh" < "$WORK/body" > "$WORK/import.out" &
mpid=$!
(printf 'a.com\nb.com'; sleep 20) > "$WORK/body" &
wpid=$!
i=0
while kill -0 "$mpid" 2>/dev/null && [ "$i" -lt 25 ]; do sleep 0.2; i=$((i + 1)); done
alive=0; kill -0 "$mpid" 2>/dev/null && alive=1
kill "$mpid" "$wpid" 2>/dev/null || true
[ "$alive" -eq 0 ] || { echo 'FAIL: host_import висит в ожидании EOF'; exit 1; }
grep -F '"total":2' "$WORK/import.out" >/dev/null || { echo "FAIL: host_import: $(cat "$WORK/import.out")"; exit 1; }

# host_add: домен уже в списке (kvas add → 1) — не ошибка; x.com → *.x.com работает.
sed -i "s|^KVAS_LIST=.*|KVAS_LIST=$WORK/kvas.list|" "$WORK/manage.sh"
printf '%s\n' 'x.example' > "$WORK/kvas.list"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$WORK/kvas"
api 'action=host_add&domain=*.x.example' | grep -F '"ok":true' >/dev/null || { echo 'FAIL host_add: уже в списке → ошибка'; exit 1; }
grep -qx '\*\.x\.example' "$WORK/kvas.list" || { echo 'FAIL host_add: не стал wildcard'; cat "$WORK/kvas.list"; exit 1; }
# нет в списке и kvas add упал — ошибка
api 'action=host_add&domain=y.example' | grep -F 'add failed' >/dev/null || { echo 'FAIL host_add: настоящая ошибка проглочена'; exit 1; }
