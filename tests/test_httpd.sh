#!/bin/sh
# Проверяет, что handler не отдаёт произвольные пути и не включает CORS wildcard.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
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
