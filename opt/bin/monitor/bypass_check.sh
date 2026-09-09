#!/bin/sh
# One-shot accessibility check for the WebUI.  It is deliberately capped: the
# router must not continuously scan sites or turn one click into hundreds of
# outbound requests.

set -u

KVAS_LIST=${KVAS_LIST:-/opt/etc/kvas.list}
DNS_LOG=${DNS_LOG:-/tmp/kvas-dns.log}
RESULT_FILE=${BYPASS_RESULT_FILE:-/tmp/kvas-bypass-check.json}
LOCK_FILE=${BYPASS_LOCK_FILE:-/tmp/kvas-bypass-check.lock}
LOCK_DIR=${BYPASS_LOCK_DIR:-${LOCK_FILE}.d}
MAX_DOMAINS=${BYPASS_MAX_DOMAINS:-40}
SOCKS_ADDR=${BYPASS_SOCKS_ADDR:-127.0.0.1:1097}
TMP_FILE="${RESULT_FILE}.$$"

umask 077
trap 'rm -f "$TMP_FILE" "$LOCK_FILE" "${TMP_FILE}.domains" "${TMP_FILE}.vpn" "${TMP_FILE}.dns"; rmdir "$LOCK_DIR" 2>/dev/null' EXIT HUP INT TERM
printf '%s\n' "$$" > "$LOCK_FILE"

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

in_vpn_list() {
    local domain="$1"
    [ -f "$KVAS_LIST" ] || return 1
    grep -Eq "^([*][.]?)?${domain}$" "$KVAS_LIST" 2>/dev/null
}

resolve_ipv4() {
    local domain="$1" out
    if command -v dig >/dev/null 2>&1; then
        out=$(dig +time=2 +tries=1 +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
    else
        out=$(nslookup "$domain" 127.0.0.1 2>/dev/null | awk '/^Address: / {print $2} /^Address [0-9]+: / {print $3}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)
    fi
    printf '%s' "$out"
}

http_code() {
    # $1 domain, $2 optional SOCKS address.  A 4xx response still proves that
    # the resource was reached (many sites reject curl or HEAD requests).
    local domain="$1" proxy="${2:-}" code
    if [ -n "$proxy" ]; then
        code=$(curl -sS -L -r 0-0 --connect-timeout 4 --max-time 8 \
            --socks5-hostname "$proxy" -o /dev/null -w '%{http_code}' "https://${domain}/" 2>/dev/null)
    else
        code=$(curl -sS -L -r 0-0 --connect-timeout 4 --max-time 8 \
            -o /dev/null -w '%{http_code}' "https://${domain}/" 2>/dev/null)
    fi
    case "$code" in [1-5][0-9][0-9]) printf '%s' "$code";; *) printf '000';; esac
}

has_socks() {
    if command -v ss >/dev/null 2>&1; then
        ss -tln 2>/dev/null | grep -q ':1097 ' && return 0
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | grep -q ':1097 ' && return 0
    fi
    return 1
}

# Reserve half the budget for newly observed DNS domains.  Without this split,
# a large kvas.list would hide every candidate that is not yet routed via VPN.
VPN_LIMIT=$(( (MAX_DOMAINS + 1) / 2 ))
DNS_LIMIT=$(( MAX_DOMAINS - VPN_LIMIT ))
domain_filter() {
    tr '[:upper:]' '[:lower:]' | awk '
        /^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9.-]*[A-Za-z0-9]$/ && $0 !~ /\.\./ && !seen[$0]++ { print }
    '
}

[ -f "$KVAS_LIST" ] && sed 's/^[*][.]\?//' "$KVAS_LIST" | domain_filter | head -n "$VPN_LIMIT" > "${TMP_FILE}.vpn" || :
{
    [ -s "$DNS_LOG" ] && tail -1000 "$DNS_LOG" 2>/dev/null
    command -v logread >/dev/null 2>&1 && logread 2>/dev/null | grep 'dnsmasq.*query\[A'
} | sed -n 's/.*query\[A[^]]*\] \([^ ]*\) from.*/\1/p' | domain_filter | head -n "$DNS_LIMIT" > "${TMP_FILE}.dns"

cat "${TMP_FILE}.vpn" "${TMP_FILE}.dns" 2>/dev/null | awk '!seen[$0]++' | head -n "$MAX_DOMAINS" > "${TMP_FILE}.domains"

printf '{"ok":true,"running":false,"checked":[' > "$TMP_FILE"
first=1
while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    valid_domain "$domain" || continue
    listed=false
    in_vpn_list "$domain" && listed=true
    ip=$(resolve_ipv4 "$domain")
    status=""
    detail=""
    direct=""
    tunnel=""
    if [ -z "$ip" ] || [ "$ip" = "0.0.0.0" ]; then
        status="dns_failed"
        detail="DNS не вернул адрес"
    elif [ "$listed" = true ]; then
        if has_socks; then
            tunnel=$(http_code "$domain" "$SOCKS_ADDR")
            if [ "$tunnel" = "000" ]; then
                status="vpn_failed"
                detail="в VPN-списке, но через туннель недоступен"
            else
                status="ok"
                detail="доступен через VPN (HTTP ${tunnel})"
            fi
        else
            status="tunnel_unavailable"
            detail="в VPN-списке, но SOCKS-туннель не запущен"
        fi
    else
        direct=$(http_code "$domain")
        if [ "$direct" = "000" ]; then
            if has_socks; then
                tunnel=$(http_code "$domain" "$SOCKS_ADDR")
                if [ "$tunnel" = "000" ]; then
                    status="direct_failed"
                    detail="напрямую и через VPN недоступен"
                else
                    status="direct_failed_tunnel_ok"
                    detail="напрямую недоступен; через VPN доступен (HTTP ${tunnel})"
                fi
            else
                status="direct_failed"
                detail="напрямую недоступен; VPN-туннель не запущен"
            fi
        else
            status="ok"
            detail="доступен напрямую (HTTP ${direct})"
        fi
    fi
    [ "$first" -eq 0 ] && printf ',' >> "$TMP_FILE"
    first=0
    printf '{"domain":%s,"in_vpn":%s,"status":%s,"detail":%s}' \
        "$(json_str "$domain")" "$listed" "$(json_str "$status")" "$(json_str "$detail")" >> "$TMP_FILE"
done < "${TMP_FILE}.domains"
printf ']}\n' >> "$TMP_FILE"
rm -f "${TMP_FILE}.domains"
mv -f "$TMP_FILE" "$RESULT_FILE"
