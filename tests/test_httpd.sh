#!/bin/sh
# Проверяет, что handler не отдаёт произвольные пути и не включает CORS wildcard.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
HTTPD="$ROOT/opt/bin/monitor/httpd.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

sh -n "$HTTPD"

mkdir -p "$WORK/www/cgi-bin"
printf '<html>KVAS test</html>\n' > "$WORK/www/index.html"
printf '<svg/>\n' > "$WORK/www/favicon.svg"
printf '#!/bin/sh\nprintf "{\\"ok\\":true}\\n"\n' > "$WORK/www/cgi-bin/manage.sh"
chmod +x "$WORK/www/cgi-bin/manage.sh"

# Извлекаем тот же handler, который httpd.sh передаёт socat, и подменяем только
# web-root на временный fixture.
HANDLER=$(sed -n '/^cat > \/tmp\/kvas-httpd-handler.sh << /,/^HANDLER_EOF$/p' "$HTTPD" | sed '1d;$d' | sed "s|^W=.*|W=\"$WORK/www\"|")

request() {
    printf '%b' "$1" | sh -c "$HANDLER"
}

request 'GET /../../../../etc/passwd HTTP/1.0\r\nHost: test\r\n\r\n' | head -1 | tr -d '\r' | grep -Fx 'HTTP/1.0 404 Not Found' >/dev/null
request 'DELETE / HTTP/1.0\r\nHost: test\r\n\r\n' | head -1 | tr -d '\r' | grep -Fx 'HTTP/1.0 405 Method Not Allowed' >/dev/null
request 'GET / HTTP/1.0\r\nHost: test\r\n\r\n' | grep -F '<html>KVAS test</html>' >/dev/null
request 'GET /cgi-bin/manage.sh?action=ping HTTP/1.0\r\nHost: test\r\n\r\n' | grep -F '{"ok":true}' >/dev/null

if grep -Fq 'Access-Control-Allow-Origin: *' "$HTTPD"; then
    echo 'HTTP handler must not enable wildcard CORS' >&2
    exit 1
fi

grep -Fq 'path=${S:-/}' "$HTTPD"

# Лимит строк заголовков: 60 строк → 431, а не бесконечный разбор.
many=$(i=0; while [ "$i" -lt 60 ]; do printf 'X-H%s: v\\r\\n' "$i"; i=$((i + 1)); done)
request "GET / HTTP/1.0\\r\\n${many}\\r\\n" | head -1 | tr -d '\r' | grep -Fx 'HTTP/1.0 431 Request Header Fields Too Large' >/dev/null

# Таймаут заголовков (где shell умеет read -t): клиент, который молчит, отваливается.
if command -v busybox >/dev/null 2>&1; then
    mkfifo "$WORK/slow"
    busybox sh -c "$(printf '%s' "$HANDLER" | sed 's/^HDR_TIMEOUT=.*/HDR_TIMEOUT=1/')" < "$WORK/slow" > /dev/null 2>&1 &
    hpid=$!
    # писатель держит FIFO открытым и молчит после первой строки
    (printf 'GET / HTTP/1.0\r\n'; sleep 20) > "$WORK/slow" &
    wpid=$!
    i=0
    while kill -0 "$hpid" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
    alive=0; kill -0 "$hpid" 2>/dev/null && alive=1
    kill "$hpid" "$wpid" 2>/dev/null || true
    [ "$alive" -eq 0 ] || { echo 'header read timeout not applied' >&2; exit 1; }
fi

# POST-тело по Content-Length при НЕзакрытом соединении (как у браузера):
# CGI получает CONTENT_LENGTH и читает ровно столько, обработчик не висит.
printf '#!/bin/sh\nprintf "{\\"len\\":\\"%%s\\",\\"body\\":\\"%%s\\"}" "$CONTENT_LENGTH" "$(head -c "$CONTENT_LENGTH")"\n' > "$WORK/www/cgi-bin/manage.sh"
mkfifo "$WORK/post"
sh -c "$HANDLER" < "$WORK/post" > "$WORK/post.out" 2>/dev/null &
hpid=$!
(printf 'POST /cgi-bin/manage.sh?action=x HTTP/1.1\r\nContent-Length: 11\r\n\r\na.com\nb.com'; sleep 20) > "$WORK/post" &
wpid=$!
i=0
while kill -0 "$hpid" 2>/dev/null && [ "$i" -lt 25 ]; do sleep 0.2; i=$((i + 1)); done
alive=0; kill -0 "$hpid" 2>/dev/null && alive=1
kill "$hpid" "$wpid" 2>/dev/null || true
[ "$alive" -eq 0 ] || { echo 'POST handler hangs waiting for EOF' >&2; exit 1; }
grep -F '"len":"11","body":"a.com' "$WORK/post.out" >/dev/null || { echo 'CGI did not get the body'; cat "$WORK/post.out"; exit 1; }
request 'POST / HTTP/1.0\r\nContent-Length: 1x\r\n\r\n' | head -1 | tr -d '\r' | grep -Fx 'HTTP/1.0 400 Bad Request' >/dev/null
request 'POST / HTTP/1.0\r\nContent-Length: 99999999\r\n\r\n' | head -1 | tr -d '\r' | grep -Fx 'HTTP/1.0 413 Payload Too Large' >/dev/null
