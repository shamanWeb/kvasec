#!/bin/sh
# Регрессия: DHCP-имена устройств (их задаёт любое устройство LAN) не ломают JSON
# route_devices / device_modes — кавычки, обратный слеш, управляющие символы, HTML.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/opt/bin/monitor/www/cgi-bin/manage.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

command -v jq >/dev/null 2>&1 || { echo "skip: jq не установлен"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 не установлен"; exit 0; }

cp "$SOURCE" "$WORK/manage.sh"
sed -i \
    -e "s|^TOKEN_DIR=.*|TOKEN_DIR=$WORK/tokens|" \
    -e "s|^KVAS_CONF_FILE=.*|KVAS_CONF_FILE=$WORK/kvas.conf|" \
    -e "s|^IOT_LOCKDOWN_LIST=.*|IOT_LOCKDOWN_LIST=$WORK/iot.list|" \
    "$WORK/manage.sh"

# Имя: "q" \ таб, \001 и <img onerror> — всё, что раньше давало невалидный JSON.
NAME=$(printf 'Te"st\\\\x\t\001<img src=x onerror=alert(1)>')
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<EOS
#!/bin/sh
case "\$*" in
    *hotspot*)  jq -n --arg n '$NAME' '{host:[{ip:"192.168.1.50",name:\$n,mac:"aa:bb:cc:dd:ee:ff",access:"permit"}]}' ;;
    *bindings*) jq -n --arg n '$NAME' '{lease:[{ip:"192.168.1.50",name:\$n}]}' ;;
esac
EOS
printf '%s\n' '#!/bin/sh' \
    '[ "$1" = "-o" ] && echo "2: br0    inet 192.168.1.1/24 brd 192.168.1.255 scope global br0"' \
    'exit 0' > "$WORK/bin/ip"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$WORK/bin/conntrack"
# awk как на роутере (busybox): экранирование в gsub у него иное, чем у mawk.
# Сам скрипт — под sh: busybox sh из Ubuntu игнорирует заглушки в PATH (берёт свои applet'ы).
# (Ubuntu-busybox собран без math в awk — тогда он in_lan не посчитает, берём системный awk.)
if command -v busybox >/dev/null 2>&1 && busybox awk 'BEGIN { print 2 ^ 8 }' 2>/dev/null | grep -qx 256; then
    printf '%s\n' '#!/bin/sh' 'exec busybox awk "$@"' > "$WORK/bin/awk"
fi
chmod +x "$WORK/bin/"*
: > "$WORK/kvas.conf"

mkdir -p "$WORK/tokens"
token=0123456789abcdef0123456789abcdef
date +%s > "$WORK/tokens/$token"

for action in route_devices device_modes; do
    out=$(PATH="$WORK/bin:$PATH" QUERY_STRING="action=$action&token=$token" REQUEST_METHOD=GET sh "$WORK/manage.sh")
    printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
names = [x["name"] for x in d["devices"]]
assert any("Te\"st" in n and "\\" in n and "<img" in n for n in names), names
' || { echo "FAIL: $action → $out"; exit 1; }
done

# Сам jesc — во всех доступных awk (в т.ч. busybox без math): результат — валидная JSON-строка.
eval "$(sed -n '/^AWK_JESC=/,/^'"'"'$/p' "$SOURCE")"
for impl in "busybox awk" mawk gawk awk; do
    command -v "${impl%% *}" >/dev/null 2>&1 || continue
    printf '%s\n' "$NAME" | $impl "$AWK_JESC"'{ printf "\"%s\"\n", jesc($0) }' \
        | python3 -c 'import json, sys; v = json.load(sys.stdin); assert "Te\"st" in v and "<img" in v, v' \
        || { echo "FAIL: jesc под $impl"; exit 1; }
done
