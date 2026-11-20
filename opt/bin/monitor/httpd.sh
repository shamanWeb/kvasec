#!/bin/sh
# HTTP server on socat for KVAS monitoring
# Static files + CGI
PORT=${1:-8085}
WWW_DIR=/opt/apps/kvas/bin/monitor/www
PID_FILE=/var/run/kvas-monitor-web.pid
LOG_FILE=${MONITOR_WEB_LOG:-/tmp/kvas-monitor-web.log}
# Web UI is administration access, not a public HTTP service.  Override only
# deliberately (for example MONITOR_BIND=192.168.4.1) when the LAN changes.
MONITOR_BIND=${MONITOR_BIND:-192.168.1.1}
# socat 1.8 uses address:netmask syntax for range (not CIDR notation).
MONITOR_ALLOW_RANGE=${MONITOR_ALLOW_RANGE:-192.168.1.0:255.255.255.0}

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    [ -z "$ts" ] && ts="unknown-time"
    echo "[$ts] [httpd] $*" >> "$LOG_FILE"
}

if [ "$1" = "stop" ]; then
    log "stop requested"
    [ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE")" 2>/dev/null
    rm -f "$PID_FILE"
    exit 0
fi

if ! command -v socat >/dev/null 2>&1; then
    log "socat not found"
    echo "ERROR: socat not found"
    exit 1
fi

if [ ! -d "$WWW_DIR" ]; then
    log "www dir not found: $WWW_DIR"
    echo "ERROR: www dir not found: $WWW_DIR"
    exit 1
fi

# CGI handler — written to file, no heredoc issues
cat > /tmp/kvas-httpd-handler.sh << 'HANDLER_EOF'
#!/bin/sh
W="/opt/apps/kvas/bin/monitor/www"
LOG_FILE=${MONITOR_WEB_LOG:-/tmp/kvas-monitor-web.log}
log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    [ -z "$ts" ] && ts="unknown-time"
    echo "[$ts] [handler] $*" >> "$LOG_FILE"
}
R=""
L=""
T=""
AP=""
AC=""
AN=""
CL=""
# Заголовки: не дольше HDR_TIMEOUT с на строку и не больше 50 строк — иначе
# медленный/бесконечный клиент (slowloris) держал бы процесс на роутере вечно.
# Таймаут только на чтение заголовков: время работы самого CGI не ограничено.
HDR_TIMEOUT=10
RT=""
# busybox ash (роутер) умеет read -t; dash (тесты/CI) — нет
(echo | read -r -t 1 _) 2>/dev/null && RT="-t $HDR_TIMEOUT"
CR=$(printf '\r')
N=0
# shellcheck disable=SC2086  # $RT намеренно без кавычек: пусто или "-t N"
while IFS='' read -r $RT L; do
    L=${L%"$CR"}
    [ -z "$L" ] && break
    N=$((N + 1))
    if [ "$N" -gt 50 ]; then
        log "request rejected: too many header lines"
        printf "HTTP/1.0 431 Request Header Fields Too Large\r\nContent-Type: text/plain\r\n\r\nToo many headers"
        exit 0
    fi
    [ -z "$R" ] && R="$L"
    case "$L" in
        [Xx]-[Kk][Vv][Aa][Ss]-[Tt]oken:*) T=$(echo "${L#*:}" | sed 's/^[[:space:]]*//');;
        [Xx]-[Kk][Vv][Aa][Ss]-[Pp]ass:*) AP=$(echo "${L#*:}" | sed 's/^[[:space:]]*//');;
        [Xx]-[Kk][Vv][Aa][Ss]-[Cc]urrent:*) AC=$(echo "${L#*:}" | sed 's/^[[:space:]]*//');;
        [Xx]-[Kk][Vv][Aa][Ss]-[Nn]ew-[Pp]ass:*) AN=$(echo "${L#*:}" | sed 's/^[[:space:]]*//');;
        [Cc]ontent-[Ll]ength:*) CL=$(echo "${L#*:}" | tr -d ' \t');;
    esac
done
M=$(echo "$R" | awk '{print $1}')
P=$(echo "$R" | awk '{print $2}')
S=$(echo "$P" | sed 's/[?#].*//')
# Do not log query strings: they historically contained WebUI session tokens
# and older clients may still send credentials there.
log "request method=${M:-unknown} path=${S:-/}"

# Тело POST: CGI читает ровно Content-Length байт (head -c) — браузер не
# закрывает соединение после тела, и `cat` ждал бы EOF вечно (импорт висел).
case "$CL" in
    '') CL=0 ;;
    *[!0-9]*)
        printf "HTTP/1.0 400 Bad Request\r\nContent-Type: text/plain\r\n\r\nBad Content-Length"
        exit 0
        ;;
esac
if [ "$CL" -gt 2097152 ]; then
    printf "HTTP/1.0 413 Payload Too Large\r\nContent-Type: text/plain\r\n\r\nToo large"
    exit 0
fi

case "$M" in
    GET|POST) ;;
    *)
        printf "HTTP/1.0 405 Method Not Allowed\r\nContent-Type: text/plain\r\nX-Content-Type-Options: nosniff\r\n\r\nMethod not allowed"
        exit 0
        ;;
esac

# Do not append an untrusted request path to W.  This explicit allow-list is
# both simpler and safer than trying to normalise ../ or encoded path variants.
case "$S" in
    /cgi-bin/manage.sh|/cgi-bin/data.sh)
        Q="${P#*\?}"
        [ "$Q" = "$P" ] && Q=""
        case "$S" in
            /cgi-bin/manage.sh) X="$W/cgi-bin/manage.sh" ;;
            /cgi-bin/data.sh)   X="$W/cgi-bin/data.sh" ;;
        esac
        if [ -x "$X" ]; then
            export QUERY_STRING="$Q"
            export REQUEST_METHOD="$M"
            export HTTP_X_KVAS_TOKEN="$T"
            export HTTP_X_KVAS_PASS="$AP"
            export HTTP_X_KVAS_CURRENT="$AC"
            export HTTP_X_KVAS_NEW_PASS="$AN"
            export CONTENT_LENGTH="$CL"
            printf "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nX-Content-Type-Options: nosniff\r\nCache-Control: no-store\r\n\r\n"
            "$X"
            log "cgi ok path=$S"
        else
            log "cgi missing path=$S"
            printf "{\"error\":\"script not found\"}"
        fi
        ;;
    /|/index.html)
        printf "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\nX-Content-Type-Options: nosniff\r\nCache-Control: no-cache\r\n\r\n"
        cat "$W/index.html"
        log "static ok path=/index.html"
        ;;
    /favicon.svg)
        printf "HTTP/1.0 200 OK\r\nContent-Type: image/svg+xml\r\nX-Content-Type-Options: nosniff\r\nCache-Control: no-cache\r\n\r\n"
        cat "$W/favicon.svg"
        log "static ok path=/favicon.svg"
        ;;
    *)
        log "request rejected path=${S:-<empty>}"
        printf "HTTP/1.0 404 Not Found\r\nContent-Type: text/plain\r\nX-Content-Type-Options: nosniff\r\n\r\nNot found"
        ;;
esac
HANDLER_EOF
chmod +x /tmp/kvas-httpd-handler.sh

log "starting socat listener on ${MONITOR_BIND}:${PORT}, allowed=${MONITOR_ALLOW_RANGE}"
MONITOR_WEB_LOG="$LOG_FILE" socat TCP-LISTEN:"$PORT",bind="$MONITOR_BIND",range="$MONITOR_ALLOW_RANGE",reuseaddr,fork,max-children=16 EXEC:"sh /tmp/kvas-httpd-handler.sh" >> "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"
sleep 1
if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    log "socat listener started with pid $(cat "$PID_FILE")"
    echo "OK socat $PORT"
else
    log "socat listener failed to start"
    echo "ERROR: socat failed to start on port $PORT"
    rm -f "$PID_FILE"
    exit 1
fi
