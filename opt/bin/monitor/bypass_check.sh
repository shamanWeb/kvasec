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
MAX_DOMAINS=${BYPASS_MAX_DOMAINS:-40}
MODE=${BYPASS_MODE:-mixed}
KVAS_CONF=${KVAS_CONF:-/opt/etc/kvas.conf}
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
    # $1 domain, $2 optional outgoing interface. A 4xx response still proves that
    # the resource was reached (many sites reject curl or HEAD requests).
    local domain="$1" iface="${2:-}" code
    if [ -n "$iface" ]; then
        code=$(curl -sS -L -r 0-0 --connect-timeout 4 --max-time 8 \
            --interface "$iface" -o /dev/null -w '%{http_code}' "https://${domain}/" 2>/dev/null)
    else
        code=$(curl -sS -L -r 0-0 --connect-timeout 4 --max-time 8 \
            -o /dev/null -w '%{http_code}' "https://${domain}/" 2>/dev/null)
    fi
    case "$code" in [1-5][0-9][0-9]) printf '%s' "$code";; *) printf '000';; esac
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

case "$MODE" in
    all)
        [ -f "$KVAS_LIST" ] && sed 's/^[*][.]\?//' "$KVAS_LIST" | domain_filter > "${TMP_FILE}.domains" || :
        ;;
    dns)
        {
            [ -s "$DNS_LOG" ] && tail -2000 "$DNS_LOG" 2>/dev/null
            command -v logread >/dev/null 2>&1 && logread 2>/dev/null | grep 'dnsmasq.*query\[A'
        } | sed -n 's/.*query\[A[^]]*\] \([^ ]*\) from.*/\1/p' | domain_filter | tail -n 100 > "${TMP_FILE}.domains"
        ;;
    *)
        VPN_LIMIT=$(( (MAX_DOMAINS + 1) / 2 ))
        DNS_LIMIT=$(( MAX_DOMAINS - VPN_LIMIT ))
        [ -f "$KVAS_LIST" ] && sed 's/^[*][.]\?//' "$KVAS_LIST" | domain_filter | head -n "$VPN_LIMIT" > "${TMP_FILE}.vpn" || :
        {
            [ -s "$DNS_LOG" ] && tail -1000 "$DNS_LOG" 2>/dev/null
            command -v logread >/dev/null 2>&1 && logread 2>/dev/null | grep 'dnsmasq.*query\[A'
        } | sed -n 's/.*query\[A[^]]*\] \([^ ]*\) from.*/\1/p' | domain_filter | head -n "$DNS_LIMIT" > "${TMP_FILE}.dns"
        cat "${TMP_FILE}.vpn" "${TMP_FILE}.dns" 2>/dev/null | awk '!seen[$0]++' | head -n "$MAX_DOMAINS" > "${TMP_FILE}.domains"
        ;;
esac

total=$(wc -l < "${TMP_FILE}.domains" 2>/dev/null || echo 0)
done_count=0
printf '%s|%s\n' "$done_count" "$total" > "$PROGRESS_FILE"

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
        if awg_is_up "$AWG_IFACE"; then
            tunnel=$(http_code "$domain" "$AWG_IFACE")
            if [ "$tunnel" = "000" ]; then
                status="awg_failed"
                detail="в VPN-списке, но через AWG недоступен"
            else
                status="ok"
                detail="доступен через AWG (HTTP ${tunnel})"
            fi
        else
            status="awg_unavailable"
            detail="в VPN-списке, но AWG-туннель отключён"
        fi
    else
        direct=$(http_code "$domain")
        if [ "$direct" = "000" ]; then
            if awg_is_up "$AWG_IFACE"; then
                tunnel=$(http_code "$domain" "$AWG_IFACE")
                if [ "$tunnel" = "000" ]; then
                    status="direct_failed"
                    detail="напрямую и через VPN недоступен"
                else
                    status="direct_failed_awg_ok"
                    detail="напрямую недоступен; через AWG доступен (HTTP ${tunnel})"
                fi
            else
                status="direct_failed"
                detail="напрямую недоступен; AWG-туннель отключён"
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
    done_count=$((done_count + 1))
    printf '%s|%s\n' "$done_count" "$total" > "$PROGRESS_FILE"
done < "${TMP_FILE}.domains"
printf ']}\n' >> "$TMP_FILE"
rm -f "${TMP_FILE}.domains"
mv -f "$TMP_FILE" "$RESULT_FILE"
