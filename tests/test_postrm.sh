#!/bin/sh
# 8.3: ветка postrm «пакет действительно удалён» — убирает маршрутизацию kvas,
# не трогает DNS; при установленном пакете (обновление) — ничего не делает.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
cp -a "$ROOT/." "$WORK/repo"; cd "$WORK/repo"
./build.sh 1.2.44 >/dev/null
mkdir -p "$WORK/u" "$WORK/bin"; tar -xzf kvasec_1.2.44.ipk -C "$WORK/u"
tar -xOzf "$WORK/u/control.tar.gz" ./postrm | sed 's/^    sleep 30$/    :/; s/) <\/dev\/null >\/dev\/null 2>&1 &$/)/' > "$WORK/postrm"

for c in ip iptables logger; do printf '#!/bin/sh\necho "%s $*" >> "%s/log"\n' "$c" "$WORK" > "$WORK/bin/$c"; done
cat > "$WORK/bin/iptables" <<EOS
#!/bin/sh
echo "iptables \$*" >> "$WORK/log"
case "\$*" in *"-S PREROUTING"*) printf '%s\n' '-P PREROUTING ACCEPT' '-A PREROUTING -j _NDM' '-A PREROUTING -i br0 -m set --match-set KVAS_LIST dst -j KVAS_MARK' '-A PREROUTING -i xfrms+ -m set --match-set KVAS_LIST dst -j KVAS_MARK' ;;
    *"-D FORWARD"*) exit 1 ;; esac
EOS
chmod +x "$WORK/bin/"*
printf '* * * * * root /opt/apps/kvas/bin/monitor/dpi_history.sh\n0 4 * * * root other\n' > "$WORK/crontab"
sed -i "s|/opt/etc/crontab|$WORK/crontab|g; s|/opt/etc/kvas.paused|$WORK/paused|g" "$WORK/postrm"

# обновление: пакет установлен → ничего
printf '#!/bin/sh\necho "kvas - 1.2.44"\n' > "$WORK/bin/opkg"; chmod +x "$WORK/bin/opkg"
PATH="$WORK/bin:$PATH" sh "$WORK/postrm"
[ ! -s "$WORK/log" ] || { echo 'FAIL: postrm убирал при установленном пакете'; cat "$WORK/log"; exit 1; }

# удаление: пакета нет → маршрутизация убрана, DNS и чужой cron не тронуты
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/opkg"
PATH="$WORK/bin:$PATH" sh "$WORK/postrm"
grep -qF 'ip rule del fwmark 0xd1000/0xd1000 lookup 1001' "$WORK/log"
grep -qF 'ip route flush table 1001' "$WORK/log"
grep -qF 'iptables -w -t mangle -D PREROUTING 3' "$WORK/log"     # прыжки по номеру, с конца
grep -qF 'iptables -w -t mangle -D PREROUTING 2' "$WORK/log"
grep -qF 'iptables -w -t mangle -X KVAS_MARK' "$WORK/log"
if grep -qE 'KVAS_DNS|nat' "$WORK/log"; then echo 'FAIL: тронут DNS'; exit 1; fi
[ "$(cat "$WORK/crontab")" = '0 4 * * * root other' ] || { echo 'FAIL: cron'; cat "$WORK/crontab"; exit 1; }
