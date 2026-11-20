#!/bin/sh
# Регрессия 2.3/2.5: сброс немаркированных соединений LAN → KVAS_LIST.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
mkdir -p "$WORK/bin"

cat > "$WORK/bin/conntrack" <<EOS
#!/bin/sh
case "\$1" in
    -L) cat <<'L'
tcp 6 300 ESTABLISHED src=192.168.1.50 dst=1.1.1.1 sport=1 dport=443 src=1.1.1.1 dst=10.8.1.3 mark=0
tcp 6 300 ESTABLISHED src=192.168.1.50 dst=1.1.1.1 sport=2 dport=443 src=1.1.1.1 dst=10.8.1.3 mark=0
tcp 6 300 ESTABLISHED src=192.168.1.94 dst=1.1.1.1 sport=3 dport=443 mark=0
tcp 6 300 ESTABLISHED src=192.168.1.1 dst=1.1.1.1 sport=4 dport=443 mark=0
tcp 6 300 ESTABLISHED src=192.168.1.50 dst=8.8.8.8 sport=5 dport=443 mark=0
L
    ;;
    -D) echo "\$*" >> "$WORK/deleted" ;;
esac
EOS
printf '%s\n' '#!/bin/sh' '[ "$2" = KVAS_LIST ] && [ "$3" = 1.1.1.1 ]' > "$WORK/bin/ipset"
printf '%s\n' '#!/bin/sh' 'echo "2: br0    inet 192.168.1.1/24 brd 192.168.1.255 scope global br0"' > "$WORK/bin/ip"
chmod +x "$WORK/bin/"*
printf '%s\n' 'route_excluded_ip=192.168.1.94/32+192.168.1.95' > "$WORK/kvas.conf"

# скрипт сам ставит PATH с /opt/sbin впереди — подкладываем заглушки через копию
sed "s|^export PATH=.*|export PATH=\"$WORK/bin:\$PATH\"|" "$ROOT/opt/bin/main/purge_unmarked" > "$WORK/purge"
n=$(KVAS_CONF_FILE="$WORK/kvas.conf" sh "$WORK/purge")
[ "$n" = 1 ] || { echo "FAIL: сброшено $n (ожидалась 1 пара src→dst)"; exit 1; }
grep -qx -- '-D -m 0 -s 192.168.1.50 -d 1.1.1.1' "$WORK/deleted" || { echo 'FAIL: не та пара'; cat "$WORK/deleted"; exit 1; }
if grep -qE '192.168.1.94|192.168.1.1 |8.8.8.8' "$WORK/deleted"; then echo 'FAIL: тронуты исключения'; exit 1; fi

# нет conntrack — тихо 0
printf '%s\n' '#!/bin/sh' 'exit 0' > "$WORK/bin/conntrack"; rm -f "$WORK/bin/conntrack"
out=$(PATH="/usr/bin:/bin" KVAS_CONF_FILE="$WORK/kvas.conf" sh -c "sed 's|^export PATH=.*|export PATH=/nonexistent|' '$ROOT/opt/bin/main/purge_unmarked' | sh")
[ "$out" = 0 ] || { echo "FAIL: без conntrack вывел '$out'"; exit 1; }
