#!/bin/sh
# Регрессия для WebUI-аутентификации без доступа к роутеру.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/opt/bin/monitor/www/cgi-bin/manage.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

cp "$SOURCE" "$WORK/manage.sh"
sed -i \
    -e "s|^PASS_FILE=.*|PASS_FILE=$WORK/pass|" \
    -e "s|^TOKEN_DIR=.*|TOKEN_DIR=$WORK/tokens|" \
    -e "s|^FAIL_COUNT=.*|FAIL_COUNT=$WORK/fail-count|" \
    -e "s|^FAIL_TIME=.*|FAIL_TIME=$WORK/fail-time|" \
    "$WORK/manage.sh"

run_api() {
    QUERY_STRING="$1" REQUEST_METHOD="$2" sh "$WORK/manage.sh"
}

# Первичная установка — только POST и минимум 4 символа.
run_api 'action=set_pass&pass=abc' POST | grep -F 'min 4 symbols' >/dev/null
run_api 'action=set_pass&pass=first%2Dpassword%2D123' GET | grep -F 'POST required' >/dev/null
run_api 'action=set_pass&pass=first%2Dpassword%2D123' POST | grep -F '"ok":true' >/dev/null
grep -Eq '^sha256:[0-9a-f]{64}$' "$WORK/pass"

# Уже установленный пароль нельзя перезаписать анонимным запросом.
run_api 'action=set_pass&pass=attacker-password-123' POST | grep -F 'password already set' >/dev/null

# Лимит действительно срабатывает после пяти ошибочных попыток.
i=1
while [ "$i" -le 5 ]; do
    run_api 'action=auth&pass=wrong-password-123' GET | grep -F 'wrong password' >/dev/null
    i=$((i + 1))
done
run_api 'action=auth&pass=wrong-password-123' GET | grep -F 'too many attempts' >/dev/null
rm -f "$WORK/fail-count" "$WORK/fail-time"

# Успешный вход по старому MD5 мигрирует файл на SHA-256.
printf '%s' 'legacy-password-123' | md5sum | awk '{print $1}' > "$WORK/pass"
legacy_auth=$(run_api 'action=auth&pass=legacy-password-123' GET)
printf '%s' "$legacy_auth" | grep -Eq '"token":"[0-9a-f]+"'
grep -Eq '^sha256:[0-9a-f]{64}$' "$WORK/pass"

# Смена требует действующий token, POST и текущий пароль.
run_api 'action=change_pass&current=legacy-password-123&new_pass=updated-password-123' POST | grep -F 'auth required' >/dev/null
token=$(printf '%s' "$legacy_auth" | sed -n 's/.*"token":"\([0-9a-f]*\)".*/\1/p')
run_api "action=change_pass&token=$token&current=legacy-password-123&new_pass=updated-password-123" POST | grep -F '"ok":true' >/dev/null
run_api 'action=auth&pass=updated-password-123' GET | grep -Eq '"token":"[0-9a-f]+"'
