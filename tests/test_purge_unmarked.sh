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
tcp 6 300 ESTABLISHED src=192.168.2.7 dst=1.1.1.1 sport=6 dport=443 mark=0
tcp 6 300 ESTABLISHED src=192.168.1.40 dst=1.1.1.1 sport=7 dport=443 mark=0
tcp 6 300 ESTABLISHED src=172.16.5.9 dst=1.1.1.1 sport=8 dport=443 mark=0
L
    ;;
    -D) echo "\$*" >> "$WORK/deleted" ;;
esac
EOS
printf '%s\n' '#!/bin/sh' '[ "$2" = KVAS_LIST ] && [ "$3" = 1.1.1.1 ]' > "$WORK/bin/ipset"
# br1 (гостевая, 192.168.2.0/24) без прыжка в KVAS_MARK — её клиентов не трогаем;
# xfrms+ — IPsec-клиенты (172.16.x, без своего интерфейса-подсети) — трогаем.
printf '%s\n' '#!/bin/sh' 'echo "2: br0    inet 192.168.1.1/24 brd 192.168.1.255 scope global br0"' 'echo "3: br1    inet 192.168.2.1/24 brd 192.168.2.255 scope global br1"' > "$WORK/bin/ip"
printf '%s\n' '#!/bin/sh' 'echo "-P PREROUTING ACCEPT"' 'echo "-A PREROUTING -i br0 -j KVAS_MARK"' 'echo "-A PREROUTING -i xfrms+ -j KVAS_MARK"' > "$WORK/bin/iptables"
chmod +x "$WORK/bin/"*
# Исключения: IP/32, IP и подсеть (192.168.1.32/28 = .32–.47 → .40 не трогаем)
printf '%s\n' 'route_excluded_ip=192.168.1.94/32+192.168.1.95+192.168.1.32/28' > "$WORK/kvas.conf"

# скрипт сам ставит PATH с /opt/sbin впереди — подкладываем заглушки через копию
sed "s|^export PATH=.*|export PATH=\"$WORK/bin:\$PATH\"|" "$ROOT/opt/bin/main/purge_unmarked" > "$WORK/purge"
n=$(KVAS_CONF_FILE="$WORK/kvas.conf" sh "$WORK/purge")
[ "$n" = 2 ] || { echo "FAIL: сброшено $n (ожидались 2 пары src→dst)"; cat "$WORK/deleted"; exit 1; }
grep -qx -- '-D -m 0 -s 192.168.1.50 -d 1.1.1.1' "$WORK/deleted" || { echo 'FAIL: не та пара'; cat "$WORK/deleted"; exit 1; }
grep -qx -- '-D -m 0 -s 172.16.5.9 -d 1.1.1.1' "$WORK/deleted" || { echo 'FAIL: IPsec-клиент (xfrms+) не сброшен'; cat "$WORK/deleted"; exit 1; }
if grep -qE '192.168.1.94|192.168.1.1 |8.8.8.8|192.168.2.7|192.168.1.40' "$WORK/deleted"; then echo 'FAIL: тронуты исключения'; cat "$WORK/deleted"; exit 1; fi

# нет прыжков в KVAS_MARK — метить нечего, ничего не сбрасываем
rm -f "$WORK/deleted"
printf '%s\n' '#!/bin/sh' 'echo "-P PREROUTING ACCEPT"' > "$WORK/bin/iptables"
n=$(KVAS_CONF_FILE="$WORK/kvas.conf" sh "$WORK/purge")
[ "$n" = 0 ] && [ ! -e "$WORK/deleted" ] || { echo "FAIL: без прыжков сброшено $n"; exit 1; }

# iptables -S PREROUTING оборвался на ndmmark до прыжков (ловушка Keenetic), но KVAS_MARK
# жива — сбрасываем как для br0, а не молча ничего
rm -f "$WORK/deleted"
cat > "$WORK/bin/iptables" <<'IPT'
#!/bin/sh
case "$*" in
    *KVAS_MARK*) echo "-N KVAS_MARK"; echo "-A KVAS_MARK -j CONNMARK --save-mark" ;;
    *) echo "-P PREROUTING ACCEPT"; echo "Can't find library for match \`ndmmark'" >&2; exit 1 ;;
esac
IPT
chmod +x "$WORK/bin/iptables"
n=$(KVAS_CONF_FILE="$WORK/kvas.conf" sh "$WORK/purge")
grep -qx -- '-D -m 0 -s 192.168.1.50 -d 1.1.1.1' "$WORK/deleted" || { echo "FAIL: при обрыве дампа ничего не сброшено ($n)"; exit 1; }
if grep -q '192.168.2.7' "$WORK/deleted"; then echo 'FAIL: при обрыве тронута гостевая br1'; exit 1; fi

# нет conntrack — тихо 0
printf '%s\n' '#!/bin/sh' 'exit 0' > "$WORK/bin/conntrack"; rm -f "$WORK/bin/conntrack"
out=$(PATH="/usr/bin:/bin" KVAS_CONF_FILE="$WORK/kvas.conf" sh -c "sed 's|^export PATH=.*|export PATH=/nonexistent|' '$ROOT/opt/bin/main/purge_unmarked' | sh")
[ "$out" = 0 ] || { echo "FAIL: без conntrack вывел '$out'"; exit 1; }

