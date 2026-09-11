#!/bin/sh
# Helpers for AdGuard Home's JSON-lines query log.  dnsmasq is stopped when
# AdGuard is the primary resolver, so monitor scripts must not depend on its
# `log-queries` output in that mode.

ADGUARD_QUERY_LOG=${ADGUARD_QUERY_LOG:-/opt/etc/AdGuardHome/data/querylog.json}

# A query log can remain on disk after AdGuard Home is stopped.  Never use
# that stale history while dnsmasq is the active resolver.  The override is
# used only by isolated regression tests.
adguard_querylog_active() {
    case "${KVAS_ADGUARD_QUERYLOG_ACTIVE:-auto}" in
        1|true|yes) return 0 ;;
        0|false|no) return 1 ;;
    esac
    pidof AdGuardHome >/dev/null 2>&1
}

adguard_query_domains() {
    adguard_querylog_active || return 0
    [ -s "$ADGUARD_QUERY_LOG" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -r '.QH // empty' "$ADGUARD_QUERY_LOG" 2>/dev/null
}

# Emit IPv4 answer mappings as `address|requested-domain`.  The Answer member
# is a base64-encoded DNS response, therefore we parse its DNS records instead
# of guessing IP-like byte sequences from the binary packet.
adguard_answer_ipv4() {
    domain=$1
    answer=$2
    command -v base64 >/dev/null 2>&1 || return 0
    # BusyBox od lacks GNU's -An/-t switches.  hexdump is provided by Entware
    # (and emits a plain decimal byte stream on both router and desktop).
    command -v hexdump >/dev/null 2>&1 || return 0
    printf '%s' "$answer" | base64 -d 2>/dev/null | hexdump -v -e '1/1 "%u "' 2>/dev/null | \
    awk -v domain="$domain" '
        { for (i = 1; i <= NF; i++) b[++n] = $i }
        function u16(i) { return b[i] * 256 + b[i + 1] }
        function skip_name(i, l) {
            while (i <= n) {
                l = b[i]
                if (l == 0) return i + 1
                if (l >= 192) return i + 2
                i += l + 1
            }
            return n + 1
        }
        END {
            if (n < 12) exit
            qd = u16(5); an = u16(7); p = 13
            for (q = 0; q < qd; q++) { p = skip_name(p) + 4 }
            for (a = 0; a < an && p <= n; a++) {
                p = skip_name(p)
                if (p + 9 > n) exit
                type = u16(p); class = u16(p + 2); len = u16(p + 8); data = p + 10
                if (type == 1 && class == 1 && len == 4 && data + 3 <= n)
                    print b[data] "." b[data + 1] "." b[data + 2] "." b[data + 3] "|" domain
                p = data + len
            }
        }'
}

adguard_query_mappings() {
    adguard_querylog_active || return 0
    [ -s "$ADGUARD_QUERY_LOG" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -r 'select(.QH != null and .Answer != null) | [.QH, .Answer] | @tsv' "$ADGUARD_QUERY_LOG" 2>/dev/null | \
    tail -300 | while IFS='	' read -r domain answer; do
        [ -n "$domain" ] && [ -n "$answer" ] && adguard_answer_ipv4 "$domain" "$answer"
    done
}
