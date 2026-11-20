#!/bin/sh
# Регрессия 2.4: kvas pause останавливает сторож (и он не стартует до unpause),
# хуки уносятся в бэкап и возвращаются парами (раньше путались имена).
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
if command -v busybox >/dev/null 2>&1; then RUN="busybox sh"; else RUN="bash"; fi
E="$WORK/etc"
mkdir -p "$E/ndm/iflayerchanged.d" "$E/ndm/ifstatechanged.d" "$E/ndm/netfilter.d" "$E/init.d" "$WORK/bak"
for f in ndm/iflayerchanged.d/100-kvas-vpn ndm/iflayerchanged.d/kvas-ips-reset ndm/ifstatechanged.d/100-kvas-vpn ndm/netfilter.d/100-vpn-mark; do
    echo "$f" > "$E/$f"
done
printf '#!/bin/sh\necho "watcher $1" >> "%s/calls"\n' "$WORK" > "$E/init.d/S99kvas-awg-route"; chmod +x "$E/init.d/S99kvas-awg-route"
{
    echo "KVAS_BACKUP_PATH='$WORK/bak'"
    echo 'ready() { :; }; when_ok() { :; }; when_bad() { echo BAD >&2; }'
    echo "ip4__flush() { echo \"flush \$1\" >> '$WORK/calls'; }; cmd_kvas_init() { echo init >> '$WORK/calls'; }; restart_all_services() { :; }"
    echo "ip4__chain__delete_jump() { echo \"deljump \$2\" >> '$WORK/calls'; }; ip4__chain__delete() { echo \"delchain \$2\" >> '$WORK/calls'; }"
    echo "TABLE_MARK=mangle; CHAIN_MARK=KVAS_MARK"
    sed -n '/^KVAS_PAUSED_FLAG=/,/^cmd_pause_kvas(){/p' "$ROOT/opt/bin/main/setup" | sed '$d'
    sed -n '/^cmd_pause_kvas(){/,/^}/p; /^cmd_unpause_kvas(){/,/^}/p' "$ROOT/opt/bin/main/setup"
} | sed "s|/opt/etc/|$E/|g" > "$WORK/lib.sh"

$RUN -c ". '$WORK/lib.sh'; cmd_pause_kvas"
[ -f "$E/kvas.paused" ]                                   || { echo 'FAIL: нет флага паузы'; exit 1; }
grep -qx 'watcher cleanup' "$WORK/calls"                  || { echo 'FAIL: сторож не остановлен'; exit 1; }
for f in 100-kvas-vpn-layer kvas-ips-reset-layer 100-kvas-vpn-state 100-vpn-mark; do
    [ -f "$WORK/bak/$f" ] || { echo "FAIL: $f не в бэкапе"; ls "$WORK/bak"; exit 1; }
done
[ ! -f "$E/ndm/netfilter.d/100-vpn-mark" ]                || { echo 'FAIL: хук остался'; exit 1; }
# только маршрутизация: DNS-перехват (chain/jump KVAS_DNS) и ipset не трогаем
grep -qx 'flush net ip table' "$WORK/calls"               || { echo 'FAIL: пауза чистит не только маршрутизацию'; cat "$WORK/calls"; exit 1; }
grep -qx 'deljump KVAS_MARK' "$WORK/calls" && grep -qx 'delchain KVAS_MARK' "$WORK/calls" || { echo 'FAIL: KVAS_MARK не снят'; exit 1; }

$RUN -c ". '$WORK/lib.sh'; cmd_unpause_kvas"
[ ! -f "$E/kvas.paused" ]                                 || { echo 'FAIL: флаг не снят'; exit 1; }
for f in ndm/iflayerchanged.d/100-kvas-vpn ndm/iflayerchanged.d/kvas-ips-reset ndm/ifstatechanged.d/100-kvas-vpn ndm/netfilter.d/100-vpn-mark; do
    grep -qx "$f" "$E/$f" || { echo "FAIL: $f не вернулся на место"; exit 1; }
done
tail -2 "$WORK/calls" | tr '\n' ' ' | grep -q 'init watcher start' || { echo 'FAIL: unpause'; cat "$WORK/calls"; exit 1; }

# сторож не стартует при флаге паузы
W="$ROOT/opt/etc/init.d/S99kvas-awg-route"
grep -A3 '^start() {' "$W" | grep -qF 'if [ -f "$PAUSED" ]; then' || { echo 'FAIL: start не смотрит флаг'; exit 1; }
grep -qF 'cleanup) cleanup ;;' "$W"
