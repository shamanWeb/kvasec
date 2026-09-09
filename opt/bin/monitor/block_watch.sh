#!/bin/sh
# Keep only one minute of likely blocked TCP attempts.  Conntrack UNREPLIED is
# a heuristic, not proof of censorship: a host or firewall may simply be down.
set -u
EVENTS=${BLOCK_WATCH_EVENTS:-/tmp/kvas-block-watch.events}
PID_FILE=${BLOCK_WATCH_PID:-/tmp/kvas-block-watch.pid}
INTERVAL=${BLOCK_WATCH_INTERVAL:-5}
WINDOW=60
ROUTER_IP=${BLOCK_WATCH_ROUTER_IP:-$(ip -4 addr show br0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)}
umask 077
trap 'rm -f "$PID_FILE"' EXIT HUP INT TERM
printf '%s\n' "$$" > "$PID_FILE"
: > "$EVENTS"

append_once() {
    # $1 type, $2 key, $3 value; retain repeated attempts only once per window.
    grep -Fq "|$1|$2|$3" "$EVENTS" 2>/dev/null || printf '%s|%s|%s|%s\n' "$(date +%s)" "$1" "$2" "$3" >> "$EVENTS"
}

while :; do
    now=$(date +%s)
    # DNS replies map an address back to a requested domain.  logread is used
    # because the old monitor DNS file can intentionally be empty.
    if command -v logread >/dev/null 2>&1; then
        logread 2>/dev/null | tail -300 | sed -n 's/.*reply \([^ ]*\) is \([0-9.]*\).*/\2|\1/p' | \
        while IFS='|' read -r ip domain; do
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
        /UNREPLIED/ && $3=="tcp" {
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
        append_once fail "$src" "$destination"
    done
    awk -F'|' -v cutoff=$((now - WINDOW)) '$1 >= cutoff' "$EVENTS" > "${EVENTS}.tmp" && mv -f "${EVENTS}.tmp" "$EVENTS"
    sleep "$INTERVAL"
done
