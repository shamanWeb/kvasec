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
