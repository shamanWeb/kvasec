#!/bin/sh
# One-shot accessibility check for the WebUI.  It is deliberately capped: the
# router must not continuously scan sites or turn one click into hundreds of
# outbound requests.

set -u

KVAS_LIST=${KVAS_LIST:-/opt/etc/kvas.list}
DNS_LOG=${DNS_LOG:-/tmp/kvas-dns.log}
RESULT_FILE=${BYPASS_RESULT_FILE:-/tmp/kvas-bypass-check.json}
PROGRESS_FILE=${BYPASS_PROGRESS_FILE:-/tmp/kvas-bypass-check.progress}
LOCK_FILE=${BYPASS_LOCK_FILE:-/tmp/kvas-bypass-check.lock}
LOCK_DIR=${BYPASS_LOCK_DIR:-${LOCK_FILE}.d}
PID_FILE=${BYPASS_PID_FILE:-/tmp/kvas-bypass-check.pid}
MAX_DOMAINS=${BYPASS_MAX_DOMAINS:-40}
MODE=${BYPASS_MODE:-mixed}
BYPASS_DOMAIN=${BYPASS_DOMAIN:-}
KVAS_CONF=${KVAS_CONF:-/opt/etc/kvas.conf}
# Резолвим через kvas dnsmasq, как LAN-клиенты: системный resolv.conf роутера
# смотрит на DNS провайдера, а тот для заблокированных доменов отдаёт заглушку.
DNS_SERVER=${BYPASS_DNS_SERVER:-127.0.0.1}
DNS_PORT=${BYPASS_DNS_PORT:-9753}
TMP_FILE="${RESULT_FILE}.$$"

# shellcheck source=adguard_querylog.sh
. "$(dirname "$0")/adguard_querylog.sh"

umask 077
printf '%s\n' "$$" > "$LOCK_FILE"
printf '%s\n' "$$" > "$PID_FILE"

# PID-файл и лок общие для всех прогонов. Пока прогон «наш» (в PID-файле наш $$),
# он пишет прогресс/результат и снимает лок; прогон, у которого «Остановить» или
# новый старт забрали PID-файл, ничего общего уже не трогает. Раньше старый прогон
# при выходе удалял PID и лок НОВОГО — UI видел «не идёт» и пустой список.
is_owner() { [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ]; }
cleanup() {
    rm -f "$TMP_FILE" "${TMP_FILE}.domains" "${TMP_FILE}.vpn" "${TMP_FILE}.dns"
    if is_owner; then
        rm -f "$LOCK_FILE" "$PID_FILE"
        rmdir "$LOCK_DIR" 2>/dev/null
    fi
}
trap cleanup EXIT
# Без exit ловушка на TERM лишь чистила файлы, и цикл шёл дальше: «Остановить
# проверку» оставляла живой прогон (несколько параллельных после старт/стоп).
trap 'exit 143' HUP INT TERM

json_str() {
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$1" | jq -Rs .
    else
        printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    fi
}

valid_domain() {
    case "$1" in ''|.*|*.|*..*) return 1;; esac
    printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9.-]*[A-Za-z0-9]$'
}

# Запись kvas.list, под которую попадает домен (как в dnsmasq: ipset=/x/ ловит x и
# все его поддомены; ведущие «*»/«*.» снимаются). Печатает запись как в списке —
# её и удаляет «Убрать из VPN». Раньше сравнивалось только точное имя: поддомены
# *.facebook.com считались «не в VPN», проверялись напрямую и предлагались к добавлению.
vpn_entry() {
    [ -f "$KVAS_LIST" ] || return 0
    awk -v d="$1" '
        BEGIN { d = tolower(d) }
        { e = $0; sub(/#.*/, "", e); gsub(/[ \t\r]/, "", e); if (e == "") next
          h = tolower(e); sub(/^\*\.?/, "", h); if (h == "") next
          if (d == h || (length(d) > length(h) && substr(d, length(d) - length(h)) == "." h)) { print e; exit } }
    ' "$KVAS_LIST" 2>/dev/null
}

resolve_ipv4() {
    local domain="$1" out
    if command -v dig >/dev/null 2>&1; then
        # 3 с × 2 попытки: при 2 с × 1 под нагрузкой dnscrypt часть имён ложно «не резолвилась».
        out=$(dig +time=3 +tries=2 +short A "$domain" @"$DNS_SERVER" -p "$DNS_PORT" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
    else
        out=$(nslookup "$domain" 127.0.0.1 2>/dev/null | awk '/^Address: / {print $2} /^Address [0-9]+: / {print $3}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)
    fi
    printf '%s' "$out"
}

http_probe() {
    # Output is HTTP-code|curl-exit-code.  The latter lets the UI distinguish a
    # timeout, TCP refusal and TLS failure instead of calling every failure a
    # possible block.  A 4xx response still proves the resource was reached.
    # $3 — адрес из kvas dnsmasq (--resolve): без него curl спросил бы DNS провайдера.
    local domain="$1" iface="${2:-}" ip="${3:-}" code rc
    set -- -sS -L -r 0-0 --connect-timeout 4 --max-time 8 -o /dev/null -w '%{http_code}'
    [ -n "$ip" ] && set -- "$@" --resolve "${domain}:443:${ip}"
    [ -n "$iface" ] && set -- "$@" --interface "$iface"
    code=$(curl "$@" "https://${domain}/" 2>/dev/null)
    rc=$?
    case "$code" in [1-5][0-9][0-9]) :;; *) code=000;; esac
    printf '%s|%s' "$code" "$rc"
}

# curl 60/51: TCP и TLS прошли, но сертификат не для этого имени — сервер ответил,
# это служебный адрес CDN/API (или подмена сертификата, если напрямую так, а через
# AWG — нормальный ответ). Блокировкой само по себе не является.
cert_mismatch() { case "$1" in 51|60) return 0 ;; esac; return 1; }

probe_failure_detail() {
    # curl exit codes are stable in both curl and the Entware curl package.
    # Keep a generic fallback because old router builds may report another code.
    local rc="$1" route="$2"
    case "$rc" in
        6) printf '%s: DNS не разрешил имя (curl 6)' "$route" ;;
        7) printf '%s: TCP-соединение отклонено или недоступно (curl 7)' "$route" ;;
        28) printf '%s: таймаут TCP/TLS (curl 28)' "$route" ;;
        35|51|53|54|58|59|60|64|66|77|80|82|83|90) printf '%s: TLS-handshake не прошёл (curl %s)' "$route" "$rc" ;;
        0) printf '%s: HTTP-ответ не получен' "$route" ;;
        *) printf '%s: сетевой запрос не выполнен (curl %s)' "$route" "$rc" ;;
    esac
}

# A TCP/TLS connection and an HTTP response prove that the route works, but a
# non-success HTTP status is still valuable diagnostic information.  Keep it
# separate from network failures so Cloudflare challenges are not misreported
# as censorship.
http_result_status() {
    case "$1" in
        2[0-9][0-9]|3[0-9][0-9]) printf 'ok' ;;
        401|403|407) printf 'http_denied' ;;
        429) printf 'http_rate_limited' ;;
        451) printf 'http_restricted' ;;
        5[0-9][0-9]) printf 'http_server_error' ;;
        4[0-9][0-9]) printf 'http_client_error' ;;
        *) printf 'http_unexpected' ;;
    esac
}

http_result_detail() {
    local code="$1" route="$2"
    case "$code" in
        401) printf '%s: HTTP 401 — требуется авторизация' "$route" ;;
        403) printf '%s: HTTP 403 — доступ отклонён сайтом/CDN (возможен Cloudflare Challenge)' "$route" ;;
        407) printf '%s: HTTP 407 — требуется авторизация прокси' "$route" ;;
        429) printf '%s: HTTP 429 — сайт временно ограничил запросы' "$route" ;;
        451) printf '%s: HTTP 451 — ресурс ограничен сервером или сетью' "$route" ;;
        5[0-9][0-9]) printf '%s: HTTP %s — ошибка сервера' "$route" "$code" ;;
        4[0-9][0-9]) printf '%s: HTTP %s — сайт ответил, но отклонил запрос к /' "$route" "$code" ;;
        *) printf '%s: HTTP %s' "$route" "$code" ;;
    esac
}

get_awg_iface() {
    local iface
    iface=$(sed -n 's/^INFACE_ENT=//p' "$KVAS_CONF" 2>/dev/null | head -1)
    case "$iface" in opkgtun*) printf '%s' "$iface";; esac
}

awg_is_up() {
    local iface="$1"
    [ -n "$iface" ] && ip link show dev "$iface" 2>/dev/null | grep -q 'UP'
}

AWG_IFACE=$(get_awg_iface)

# `all` checks the complete VPN list; `dns` checks the latest 100 observed
# DNS names; the default mixed mode remains a short diagnostic sample.
domain_filter() {
    tr '[:upper:]' '[:lower:]' | awk '
        /^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9.-]*[A-Za-z0-9]$/ && $0 !~ /\.\./ && !seen[$0]++ { print }
    '
}

# Собственные IPv4 роутера: его запросы (ipset-обход списка, эта же проверка)
# не история устройств и вытеснили бы её из «последних 100».
router_ips() {
    printf '127.0.0.1\n'
    ip -4 -o addr show 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4 }'
}

# Журнал dnsmasq (log-queries, ведётся постоянно в RAM — kvas-dns-log.dnsmasq):
# домены, запрошенные устройствами, по времени последнего запроса (старые → новые).
# Без собственных запросов роутера, *.arpa, доменов, которые dnsmasq сам
# ответил 0.0.0.0/:: (adblock, DoH-блок), и имён без IPv4 (только NODATA-IPv4/
# NXDOMAIN — напр. зонды *-netseer-ipaddr-assoc.fbcdn.net): проверять нечего.
dnsmasq_query_domains() {
    [ -s "$DNS_LOG" ] || return 0
    tail -n "${BYPASS_DNS_LOG_LINES:-20000}" "$DNS_LOG" 2>/dev/null | \
        awk -v self="$(router_ips | tr '\n' ' ')" '
            BEGIN { n = split(self, a, " "); for (i = 1; i <= n; i++) me[a[i]] = 1 }
            {
                for (i = 1; i < NF; i++) {
                    if ($i ~ /^query\[/ && $(i + 2) == "from") {
                        d = tolower($(i + 1)); src = $(i + 3)
                        if (!(src in me) && d !~ /\.arpa$/) last[d] = NR
                        break
                    }
                    if ($(i + 1) == "is") {
                        n2 = tolower($i); v = $(i + 2)
                        if (v == "0.0.0.0" || v == "::") blocked[n2] = 1
                        else if (v ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) hasip[n2] = 1
                        else if (v == "NODATA-IPv4" || v == "NXDOMAIN") noaddr[n2] = 1
                        break
                    }
                }
            }
            END { for (d in last) if (!(d in blocked) && !((d in noaddr) && !(d in hasip))) print last[d], d }
        ' | sort -n | cut -d' ' -f2
}

observed_dns_domains() {
    if adguard_querylog_active; then
        # AdGuard owns DNS: its log is authoritative and a leftover dnsmasq
        # file must not add obsolete domains to the check.
        adguard_query_domains
    else
        dnsmasq_query_domains | domain_filter
    fi
}

case "$MODE" in
    all)
        [ -f "$KVAS_LIST" ] && sed 's/^[*][.]\?//' "$KVAS_LIST" | domain_filter > "${TMP_FILE}.domains" || :
        ;;
    dns)
        observed_dns_domains | tail -n 100 > "${TMP_FILE}.domains"
        ;;
    domain)
        valid_domain "$BYPASS_DOMAIN" || exit 1
        printf '%s\n' "$BYPASS_DOMAIN" | domain_filter > "${TMP_FILE}.domains"
        ;;
    *)
        VPN_LIMIT=$(( (MAX_DOMAINS + 1) / 2 ))
        DNS_LIMIT=$(( MAX_DOMAINS - VPN_LIMIT ))
        [ -f "$KVAS_LIST" ] && sed 's/^[*][.]\?//' "$KVAS_LIST" | domain_filter | head -n "$VPN_LIMIT" > "${TMP_FILE}.vpn" || :
        observed_dns_domains | tail -n "$DNS_LIMIT" > "${TMP_FILE}.dns"
        cat "${TMP_FILE}.vpn" "${TMP_FILE}.dns" 2>/dev/null | awk '!seen[$0]++' | head -n "$MAX_DOMAINS" > "${TMP_FILE}.domains"
        ;;
esac

total=$(wc -l < "${TMP_FILE}.domains" 2>/dev/null || echo 0)
done_count=0
is_owner || exit 0
printf '%s|%s\n' "$done_count" "$total" > "$PROGRESS_FILE"

printf '{"ok":true,"running":false,"checked":[' > "$TMP_FILE"
first=1
# Статусы (UI группирует их): ok / http_client_error / no_web — сервер отвечает;
# direct_failed_awg_ok / geo_blocked_awg_ok — напрямую нет, через AWG да (кандидат в
# VPN-список); awg_failed / awg_unavailable — в списке, но через туннель не работает;
# direct_failed — нет ни так, ни так (VPN не поможет); dns_failed; http_* — HTTP-отказы.
while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    valid_domain "$domain" || continue
    entry=$(vpn_entry "$domain")
    listed=false
    [ -n "$entry" ] && listed=true
    ip=$(resolve_ipv4 "$domain")
    status=""
    detail=""
    direct=""
    tunnel=""
    direct_rc=""
    tunnel_rc=""
    direct_detail=""
    tunnel_detail=""
    response_code=""
    if [ -z "$ip" ] || [ "$ip" = "0.0.0.0" ]; then
        status="dns_failed"
        detail="DNS не вернул IPv4-адрес"
    elif [ "$listed" = true ]; then
        if awg_is_up "$AWG_IFACE"; then
            tunnel_probe=$(http_probe "$domain" "$AWG_IFACE" "$ip")
            tunnel=${tunnel_probe%%|*}
            tunnel_rc=${tunnel_probe#*|}
            if [ "$tunnel" != "000" ]; then
                response_code="$tunnel"
                status=$(http_result_status "$tunnel")
                detail=$(http_result_detail "$tunnel" "через AWG")
            elif cert_mismatch "$tunnel_rc"; then
                status="no_web"
                detail="через AWG сервер отвечает, но сертификат не для этого имени — служебный адрес, не сайт"
            else
                status="awg_failed"
                tunnel_detail=$(probe_failure_detail "$tunnel_rc" "через AWG")
                detail="в VPN-списке (${entry}), но ${tunnel_detail}"
            fi
        else
            status="awg_unavailable"
            detail="в VPN-списке (${entry}), но AWG-туннель отключён"
        fi
    else
        direct_probe=$(http_probe "$domain" "" "$ip")
        direct=${direct_probe%%|*}
        direct_rc=${direct_probe#*|}
        case "$direct" in
            403|451)
                # Отказ напрямую при ответе через AWG — геоблокировка по IP (напр.
                # JetBrains); при таком же отказе через AWG — Cloudflare/антибот.
                response_code="$direct"
                status=$(http_result_status "$direct")
                detail=$(http_result_detail "$direct" "напрямую")
                if awg_is_up "$AWG_IFACE"; then
                    tunnel_probe=$(http_probe "$domain" "$AWG_IFACE" "$ip")
                    tunnel=${tunnel_probe%%|*}
                    tunnel_rc=${tunnel_probe#*|}
                    case "$tunnel" in
                        2[0-9][0-9]|3[0-9][0-9])
                            status="geo_blocked_awg_ok"
                            detail="напрямую HTTP ${direct}, через AWG HTTP ${tunnel} — похоже на геоблокировку" ;;
                    esac
                fi
                ;;
            000)
                direct_detail=$(probe_failure_detail "$direct_rc" "напрямую")
                if awg_is_up "$AWG_IFACE"; then
                    tunnel_probe=$(http_probe "$domain" "$AWG_IFACE" "$ip")
                    tunnel=${tunnel_probe%%|*}
                    tunnel_rc=${tunnel_probe#*|}
                    if [ "$tunnel" != "000" ]; then
                        status="direct_failed_awg_ok"
                        detail="${direct_detail}; через AWG доступен (HTTP ${tunnel})"
                    elif cert_mismatch "$direct_rc" && cert_mismatch "$tunnel_rc"; then
                        status="no_web"
                        detail="сервер отвечает, но HTTPS-сертификат не для этого имени — служебный адрес CDN/API, не сайт"
                    elif cert_mismatch "$tunnel_rc"; then
                        status="direct_failed_awg_ok"
                        detail="${direct_detail}; через AWG сервер отвечает (сертификат не для этого имени)"
                    else
                        status="direct_failed"
                        tunnel_detail=$(probe_failure_detail "$tunnel_rc" "через AWG")
                        detail="${direct_detail}; ${tunnel_detail}"
                    fi
                else
                    status="direct_failed"
                    detail="${direct_detail}; AWG-туннель отключён"
                fi
                ;;
            *)
                response_code="$direct"
                status=$(http_result_status "$direct")
                detail=$(http_result_detail "$direct" "напрямую")
                ;;
        esac
    fi
    [ "$first" -eq 0 ] && printf ',' >> "$TMP_FILE"
    first=0
    printf '{"domain":%s,"in_vpn":%s,"vpn_entry":%s,"status":%s,"detail":%s,"http_code":%s,"direct_curl":%s,"awg_curl":%s}' \
        "$(json_str "$domain")" "$listed" "$(json_str "$entry")" "$(json_str "$status")" "$(json_str "$detail")" "$(json_str "$response_code")" "$(json_str "$direct_rc")" "$(json_str "$tunnel_rc")" >> "$TMP_FILE"
    done_count=$((done_count + 1))
    is_owner || exit 0
    printf '%s|%s\n' "$done_count" "$total" > "$PROGRESS_FILE"
done < "${TMP_FILE}.domains"
printf ']}\n' >> "$TMP_FILE"
rm -f "${TMP_FILE}.domains"
is_owner || exit 0
mv -f "$TMP_FILE" "$RESULT_FILE"
