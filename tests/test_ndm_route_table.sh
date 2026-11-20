#!/bin/sh
# Регрессия 2.2: ip4__route__add_table не стирает fail-closed «unreachable default».
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
if command -v busybox >/dev/null 2>&1; then RUN="busybox sh"; else RUN="bash"; fi
T="$WORK/table"; mkdir -p "$WORK/bin"

# эмулятор `ip route` для одной таблицы; dev opkgtun10 недоступен при IFACE_DOWN=1
cat > "$WORK/bin/ip" <<'EOS'
#!/bin/sh
[ "$1" = "-4" ] && shift
[ "$1" = route ] || exit 0; shift
cmd="$1"; shift
args=$(printf '%s ' "$@" | sed 's/table [0-9]* //; s/ $//')
case "$cmd" in
    show)  cat "$TBL" 2>/dev/null ;;
    flush) : > "$TBL" ;;
    add)   case "$args" in *"dev opkgtun10"*) [ "${IFACE_DOWN:-0}" = 1 ] && exit 2 ;; esac
           grep -qxF -- "$args" "$TBL" 2>/dev/null && exit 2; echo "$args" >> "$TBL" ;;
esac
EOS
chmod +x "$WORK/bin/ip"
export TBL="$T"

{
    sed '/^\. \/opt\/apps\/kvas\/bin\/libs\/main/d' "$ROOT/opt/etc/ndm/ndm"
    cat <<'EOS'
log_warning() { :; }; error() { :; }; ip4__route__flush_cache() { :; }
get_config_value() { case "$1" in INFACE_ENT) echo opkgtun10 ;; *) echo "" ;; esac; }
get_ip_by_inface() { [ "${IFACE_DOWN:-0}" = 1 ] || echo 10.8.1.3; }
get_net_by_ip() { echo 10.8.1.0/24; }
EOS
} | sed "s|/opt/sbin/ip |$WORK/bin/ip |g" > "$WORK/lib.sh"
add_table() { $RUN -c ". '$WORK/lib.sh'; ip4__route__add_table" >/dev/null 2>&1 || true; }

# A) туннель лёг: в таблице только fail-closed → он должен ОСТАТЬСЯ (раньше flush → пусто)
printf '%s\n' 'unreachable default metric 4000' > "$T"
IFACE_DOWN=1 add_table
grep -qx 'unreachable default metric 4000' "$T" || { echo 'FAIL A: fail-closed стёрт'; cat "$T"; exit 1; }

# B) туннель поднялся: добавлен default dev opkgtun10, fail-closed на месте
add_table
grep -q '^default dev opkgtun10' "$T"                 || { echo 'FAIL B: нет default'; cat "$T"; exit 1; }
grep -qx 'unreachable default metric 4000' "$T"      || { echo 'FAIL B: нет fail-closed'; exit 1; }

# C) таблица пустая → fail-closed появляется даже если туннель лежит
: > "$T"; IFACE_DOWN=1 add_table
grep -qx 'unreachable default metric 4000' "$T"      || { echo 'FAIL C'; exit 1; }

# D) default смотрит не туда → flush, но fail-closed возвращён
printf '%s\n' 'default dev eth3' 'unreachable default metric 4000' > "$T"
IFACE_DOWN=1 add_table
if grep -q 'dev eth3' "$T"; then echo 'FAIL D: чужой default остался'; exit 1; fi
grep -qx 'unreachable default metric 4000' "$T"      || { echo 'FAIL D: нет fail-closed после flush'; exit 1; }

# E) рабочая таблица не трогается
printf '%s\n' 'default dev opkgtun10 scope link' '10.8.1.0/24 via 10.8.1.3' 'unreachable default metric 4000' > "$T"
cp "$T" "$WORK/before"; add_table
cmp "$WORK/before" "$T" || { echo 'FAIL E: рабочая таблица изменена'; cat "$T"; exit 1; }
