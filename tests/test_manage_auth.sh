#!/bin/sh
# Регрессия для WebUI-аутентификации без доступа к роутеру.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/opt/bin/monitor/www/cgi-bin/manage.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

cp "$SOURCE" "$WORK/manage.sh"
sed -i \
    -e "s|^PASS_FILE=.*|PASS_FILE=$WORK/pass|" \
    -e "s|^TOKEN_DIR=.*|TOKEN_DIR=$WORK/tokens|" \
    -e "s|^FAIL_COUNT=.*|FAIL_COUNT=$WORK/fail-count|" \
    -e "s|^FAIL_TIME=.*|FAIL_TIME=$WORK/fail-time|" \
    -e "s|^AUTH_LOCK_DIR=.*|AUTH_LOCK_DIR=$WORK/auth.lock|" \
    -e "s|^KVAS_BIN=.*|KVAS_BIN=$WORK/kvas|" \
    "$WORK/manage.sh"

printf '%s\n' '#!/bin/sh' '[ "$1" = upgrade ] && : > "$TEST_UPGRADE_MARK"' > "$WORK/kvas"
chmod +x "$WORK/kvas"
export TEST_UPGRADE_MARK="$WORK/upgrade-called"

run_api() {
    QUERY_STRING="$1" REQUEST_METHOD="$2" sh "$WORK/manage.sh"
}

# Первичная установка — только POST и минимум 8 символов.
run_api 'action=set_pass&pass=abc' POST | grep -F 'min 8 symbols' >/dev/null
run_api 'action=set_pass&pass=first%2Dpassword%2D123' GET | grep -F 'POST required' >/dev/null
run_api 'action=set_pass&pass=first%2Dpassword%2D123' POST | grep -F '"ok":true' >/dev/null
grep -Eq '^sha256:[0-9a-f]{64}$' "$WORK/pass"

# Уже установленный пароль нельзя перезаписать анонимным запросом.
run_api 'action=set_pass&pass=attacker-password-123' POST | grep -F 'password already set' >/dev/null

# Лимит действительно срабатывает после пяти ошибочных попыток.
i=1
while [ "$i" -le 5 ]; do
    run_api 'action=auth&pass=wrong-password-123' POST | grep -F 'wrong password' >/dev/null
    i=$((i + 1))
done
run_api 'action=auth&pass=wrong-password-123' POST | grep -F 'too many attempts' >/dev/null

# Блокировка — по адресу клиента: другой хост LAN не может запереть владельца.
QUERY_STRING='action=auth&pass=wrong-password-123' REQUEST_METHOD=POST SOCAT_PEERADDR=192.168.1.77 \
    sh "$WORK/manage.sh" | grep -F 'wrong password' >/dev/null

# Токен — только 32 hex: путь к чужому файлу со свежим epoch (fail-time) не даёт входа,
# а "просроченный" путь не приводит к rm -f произвольного файла.
mkdir -p "$WORK/tokens"
run_api 'action=hosts&token=..%2Ffail-time' GET | grep -F 'auth required' >/dev/null
QUERY_STRING='action=hosts' REQUEST_METHOD=GET HTTP_X_KVAS_TOKEN='../fail-time' sh "$WORK/manage.sh" \
    | grep -F 'auth required' >/dev/null
echo 1 > "$WORK/victim"
run_api 'action=hosts&token=..%2Fvictim' GET | grep -F 'auth required' >/dev/null
test -f "$WORK/victim"
rm -f "$WORK"/fail-count* "$WORK"/fail-time*

# Параллельный перебор с одного адреса не обходит лимит: попытки сериализованы
# mkdir-локом. Проверка имеет смысл только там, где mkdir атомарен (на роутере — да;
# на некоторых свежих ядрах — нет, тогда пропускаем, чтобы тест не мигал).
mkdir_atomic() {
    r=0 hits=0
    while [ "$r" -lt 50 ]; do
        for _ in 1 2 3 4; do (mkdir "$WORK/probe" 2>/dev/null && echo ok) & done
        wait
        rmdir "$WORK/probe"
        r=$((r + 1))
    done > "$WORK/probe.out"
    hits=$(wc -l < "$WORK/probe.out")
    rm -f "$WORK/probe.out"
    [ "$hits" -eq 50 ]
}
# Как на роутере — busybox mkdir (uutils coreutils mkdir не атомарен: 2 процесса
# могут оба «создать» каталог). Обёртка в PATH для manage.sh и пробы.
if command -v busybox >/dev/null 2>&1; then
    mkdir -p "$WORK/bb"
    printf '%s\n' '#!/bin/sh' 'exec busybox mkdir "$@"' > "$WORK/bb/mkdir"
    chmod +x "$WORK/bb/mkdir"
    PATH="$WORK/bb:$PATH"; export PATH
fi
if mkdir_atomic; then
    i=1
    while [ "$i" -le 10 ]; do
        run_api 'action=auth&pass=wrong-password-123' POST > "$WORK/par.$i" &
        i=$((i + 1))
    done
    wait
    wrong=$(cat "$WORK"/par.* | grep -c 'wrong password' || true)
    [ "$wrong" -le 5 ] || { echo "FAIL: параллельно принято $wrong неверных попыток (> 5)"; exit 1; }
    cat "$WORK"/par.* | grep -F 'too many attempts' >/dev/null
    test ! -d "$WORK/auth.lock"
else
    echo "skip: mkdir в этом окружении не атомарен — параллельная проверка лока пропущена"
fi
rm -f "$WORK"/fail-count* "$WORK"/fail-time* "$WORK"/par.*

# Успешный вход по старому MD5 мигрирует файл на SHA-256.
printf '%s' 'legacy-password-123' | md5sum | awk '{print $1}' > "$WORK/pass"
legacy_auth=$(run_api 'action=auth&pass=legacy-password-123' POST)
printf '%s' "$legacy_auth" | grep -Eq '"token":"[0-9a-f]+"'
grep -Eq '^sha256:[0-9a-f]{64}$' "$WORK/pass"

# Новые клиенты передают пароль в заголовке, не оставляя его в URL.
header_auth=$(QUERY_STRING='action=auth' REQUEST_METHOD=POST HTTP_X_KVAS_PASS=legacy-password-123 sh "$WORK/manage.sh")
printf '%s' "$header_auth" | grep -Eq '"token":"[0-9a-f]+"'

# Смена требует действующий token, POST и текущий пароль.
run_api 'action=change_pass&current=legacy-password-123&new_pass=updated-password-123' POST | grep -F 'auth required' >/dev/null
token=$(printf '%s' "$legacy_auth" | sed -n 's/.*"token":"\([0-9a-f]*\)".*/\1/p')
run_api "action=change_pass&token=$token&current=legacy-password-123&new_pass=updated-password-123" POST | grep -F '"ok":true' >/dev/null
run_api 'action=auth&pass=updated-password-123' POST | grep -Eq '"token":"[0-9a-f]+"'

# The full-package updater is an authenticated POST and starts in background,
# so the WebUI can reply before package postinst restarts its listener.
run_api "action=upgrade&token=$token" GET | grep -F 'POST required' >/dev/null
run_api "action=upgrade&token=$token" POST | grep -F '"ok":true' >/dev/null
i=0
while [ ! -f "$TEST_UPGRADE_MARK" ] && [ "$i" -lt 30 ]; do
    sleep 0.1
    i=$((i + 1))
done
test -f "$TEST_UPGRADE_MARK"
