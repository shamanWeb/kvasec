#!/bin/sh
# Регрессия: имя закваски из WebUI не должно попадать в код awk / regex / CLI.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/opt/bin/monitor/www/cgi-bin/manage.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# На роутере CGI исполняет busybox (ash + busybox awk) — инъекция воспроизводилась именно там.
SH="sh"
command -v busybox >/dev/null 2>&1 && SH="busybox sh"

cp "$SOURCE" "$WORK/manage.sh"
sed -i \
    -e "s|^TOKEN_DIR=.*|TOKEN_DIR=$WORK/tokens|" \
    -e "s|^KVAS_BIN=.*|KVAS_BIN=$WORK/kvas|" \
    -e "s|^KVAS_LIST=.*|KVAS_LIST=$WORK/kvas.list|" \
    -e "s|^TAGS_FILE=.*|TAGS_FILE=$WORK/tags.list|" \
    "$WORK/manage.sh"

# Фейковый kvas: записывает аргументы, чтобы проверить, что именно дошло до CLI.
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >> "$TEST_KVAS_ARGS"' > "$WORK/kvas"
chmod +x "$WORK/kvas"
export TEST_KVAS_ARGS="$WORK/kvas-args"

printf '%s\n' '[google]' 'google.com' 'gstatic.com' '[my-tag_2]' 'example.org' > "$WORK/tags.list"
: > "$WORK/kvas.list"
mkdir -p "$WORK/tokens"
token=0123456789abcdef0123456789abcdef
date +%s > "$WORK/tokens/$token"

run_api() {
    QUERY_STRING="$1&token=$token" REQUEST_METHOD=GET $SH "$WORK/manage.sh"
}

# Штатные имена работают, домены секции — ровно свои.
out=$(run_api 'action=tags_status&tag=google')
printf '%s' "$out" | grep -F '"google.com"' >/dev/null
printf '%s' "$out" | grep -F '"gstatic.com"' >/dev/null
! printf '%s' "$out" | grep -F 'example.org' >/dev/null
run_api 'action=tags_status&tag=my-tag_2' | grep -F '"example.org"' >/dev/null

# Префикс/подстрока имени — не та же закваска.
run_api 'action=tags_status&tag=goog' | grep -F 'tag not found' >/dev/null

# awk-инъекция (system()) через имя — отклоняется, команда не выполняется.
pwned="$WORK/pwned"
run_api "action=tags_status&tag=%5C%7B0%5C%7D%5C(%2F%7C%7Csystem(%22touch%20$pwned%22)%7C%7C%2F%5C)%5C%7B0%5C%7D" \
    | grep -F 'invalid tag' >/dev/null
run_api "action=tags_status&tag=\\{0\\}\\(/||system(\"touch\\\${IFS}$pwned\")||/\\)\\{0\\}" \
    | grep -F 'invalid tag' >/dev/null
test ! -e "$pwned"

# Имя-опция и спецсимволы не доходят до kvas.
run_api 'action=tags_add&tag=-h' | grep -F 'invalid tag' >/dev/null
run_api 'action=tags_delete&tag=goo.le' | grep -F 'invalid tag' >/dev/null
run_api 'action=tags_create&name=-x&domains=a.com' | grep -F 'invalid name' >/dev/null
run_api 'action=tags_create&name=a%20b&domains=a.com' | grep -F 'invalid name' >/dev/null
test ! -e "$TEST_KVAS_ARGS"

# Валидные запросы доходят до kvas с url-декодированным именем.
run_api 'action=tags_add&tag=google' | grep -F '"ok":true' >/dev/null
run_api 'action=tags_create&name=new%2Dtag&domains=a.com%0Ab.com' | grep -F '"ok":true' >/dev/null
grep -Fx 'tags add-protect google' "$TEST_KVAS_ARGS" >/dev/null
grep -Fx 'tags create new-tag a.com b.com' "$TEST_KVAS_ARGS" >/dev/null
