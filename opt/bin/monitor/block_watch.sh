#!/bin/sh
# Keep only one minute of likely blocked TCP attempts.  Conntrack UNREPLIED is
# a heuristic, not proof of censorship: a host or firewall may simply be down.
set -u
EVENTS=${BLOCK_WATCH_EVENTS:-/tmp/kvas-block-watch.events}
PID_FILE=${BLOCK_WATCH_PID:-/tmp/kvas-block-watch.pid}
LOCK_DIR=${BLOCK_WATCH_LOCK_DIR:-/tmp/kvas-block-watch.lock.d}
DNS_CONF=${BLOCK_WATCH_DNS_CONF:-/opt/etc/dnsmasq.d/kvas-monitor-dns.dnsmasq}
DNS_LOG=${BLOCK_WATCH_DNS_LOG:-/tmp/kvas-dns.log}
DNS_RESTART_BIN=${BLOCK_WATCH_DNS_RESTART_BIN:-/opt/etc/init.d/S56dnsmasq}
INTERVAL=${BLOCK_WATCH_INTERVAL:-5}
WINDOW=60
MAP_WINDOW=600
ROUTER_IP=${BLOCK_WATCH_ROUTER_IP:-$(ip -4 addr show br0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)}
# shellcheck source=adguard_querylog.sh
. "$(dirname "$0")/adguard_querylog.sh"
umask 077
if [ ! -d "$LOCK_DIR" ] && ! mkdir "$LOCK_DIR" 2>/dev/null; then
    exit 1
fi

reload_dnsmasq() {
    # dnsmasq only rereads hosts on HUP; log-queries and log-facility are
    # startup options, so a short restart is required when toggling capture.
    [ -x "$DNS_RESTART_BIN" ] && "$DNS_RESTART_BIN" restart >/dev/null 2>&1
}

# DNS history is opt-in and exists only while this watcher is active.  Keeping
# it in a separate drop-in avoids changing the user's dnsmasq.conf.
enable_dns_capture() {
    # AdGuard owns DNS and already keeps a bounded query log.  Restarting a
    # stopped dnsmasq here would conflict with port 53 and break resolution.
    adguard_querylog_active && return 0
    mkdir -p "$(dirname "$DNS_CONF")" || return 1
    : > "$DNS_LOG" || return 1
    chown nobody:nobody "$DNS_LOG" 2>/dev/null || true
    chmod 600 "$DNS_LOG" 2>/dev/null || true
    tmp_conf="${DNS_CONF}.$$"
    ( umask 077; printf 'log-queries=extra\nlog-facility=%s\n' "$DNS_LOG" > "$tmp_conf" ) || return 1
    mv -f "$tmp_conf" "$DNS_CONF" || return 1
    reload_dnsmasq
}

disable_dns_capture() {
    adguard_querylog_active && { rm -f "$DNS_LOG"; return 0; }
    rm -f "$DNS_CONF"
    reload_dnsmasq || true
    rm -f "$DNS_LOG"
}

cleanup() {
    trap - EXIT HUP INT TERM
    disable_dns_capture
    rm -f "$PID_FILE"
    rmdir "$LOCK_DIR" 2>/dev/null
    exit 0
}
trap cleanup EXIT HUP INT TERM
printf '%s\n' "$$" > "$PID_FILE"
: > "$EVENTS"
enable_dns_capture || exit 1

append_once() {
    # $1 type, $2 key, $3 value; retain repeated attempts only once per window.
    grep -Fq "|$1|$2|$3" "$EVENTS" 2>/dev/null || printf '%s|%s|%s|%s\n' "$(date +%s)" "$1" "$2" "$3" >> "$EVENTS"
}

reverse_name() {
    # PTR is only a best-effort owner hint: it cannot identify the exact site
    # on a shared CDN address.  It is useful when a VPN client bypasses the
    # router DNS and therefore there is no DNS name to correlate.
    local ip="$1" name
    command -v dig >/dev/null 2>&1 || return 0
    name=$(dig +time=2 +tries=1 +short -x "$ip" 2>/dev/null | head -1 | sed 's/\.$//')
    printf '%s\n' "$name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$' || return 0
    printf '%s' "$name"
}

while :; do
    now=$(date +%s)
    # DNS replies map an address back to a requested domain.  The dedicated
    # file is used while this watcher runs; logread keeps compatibility with
    # older installations which already send dnsmasq logs to syslog.
    {
        [ -s "$DNS_LOG" ] && tail -300 "$DNS_LOG" 2>/dev/null
        command -v logread >/dev/null 2>&1 && logread 2>/dev/null | tail -300
    } | sed -n 's/.*reply \([^ ]*\) is \([0-9.]*\).*/\2|\1/p' | \
    while IFS='|' read -r ip domain; do
        [ -n "$ip" ] && [ -n "$domain" ] && append_once map "$ip" "$domain"
    done
    # With AdGuard enabled dnsmasq has no reply log.  Decode A records from
    # AdGuard's query log to retain domain labels in the TCP failure view.
    if adguard_querylog_active; then
        adguard_query_mappings | while IFS='|' read -r ip domain; do
            [ -n "$ip" ] && [ -n "$domain" ] && append_once map "$ip" "$domain"
        done
    fi
    if command -v conntrack >/dev/null 2>&1; then
        ct=$(conntrack -L 2>/dev/null)
    else
        ct=$(cat /proc/net/nf_conntrack 2>/dev/null || true)
    fi
    printf '%s\n' "$ct" | awk -v router="$ROUTER_IP" '
        function non_public(ip, a) {
            split(ip, a, ".")
            return a[1]==0 || a[1]==10 || a[1]==127 || a[1]>=224 ||
                (a[1]==169 && a[2]==254) ||
                (a[1]==172 && a[2]>=16 && a[2]<=31) || a[1]==192 && a[2]==168
        }
        # conntrack -L begins with "tcp 6 …"; /proc/net/nf_conntrack
        # begins with "ipv4 2 tcp 6 …".  Support both formats.
        /UNREPLIED/ && ($1=="tcp" || $3=="tcp") {
            s=d=p=""
            for(i=1;i<=NF;i++) {
                if($i~/^src=/&&!s){sub(/^src=/,"",$i);s=$i}
                if($i~/^dst=/&&!d){sub(/^dst=/,"",$i);d=$i}
                if($i~/^dport=/&&!p){sub(/^dport=/,"",$i);p=$i}
            }
            if(s && d && p && s!=router && !non_public(d)) print s"|"d":"p
        }
    ' | \
    while IFS='|' read -r src destination; do
        destination_ip=${destination%:*}
        # DNS mappings take precedence.  Only look up PTR for IPs that have
        # never been seen in DNS and have no cached owner hint yet.
        if ! grep -Fq "|map|${destination_ip}|" "$EVENTS" 2>/dev/null && \
           ! grep -Fq "|ptr|${destination_ip}|" "$EVENTS" 2>/dev/null; then
            ptr=$(reverse_name "$destination_ip")
            [ -n "$ptr" ] && append_once ptr "$destination_ip" "$ptr"
        fi
        append_once fail "$src" "$destination"
    done
    awk -F'|' -v fail_cutoff=$((now - WINDOW)) -v map_cutoff=$((now - MAP_WINDOW)) '
        ($2 == "map" || $2 == "ptr") { if ($1 >= map_cutoff) print; next }
        $1 >= fail_cutoff
    ' "$EVENTS" > "${EVENTS}.tmp" && mv -f "${EVENTS}.tmp" "$EVENTS"
    sleep "$INTERVAL"
done
