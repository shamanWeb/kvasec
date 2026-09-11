#!/bin/sh
# Статические гарантии: публичный путь KVASEC использует только AmneziaWG.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

for file in opt/bin/kvas opt/bin/libs/vpn opt/bin/main/setup opt/etc/init.d/S96kvas opt/etc/ndm/ndm; do
    sh -n "$file"
done

! grep -q '/libs/vless' opt/bin/kvas opt/bin/libs/vpn
! grep -q 'is_vless_over_proxy_enabled' opt/etc/ndm/ndm
! grep -qiE 'VLESS|Xray|ShadowSocks' opt/bin/monitor/www/index.html opt/etc/conf/kvas.help
grep -Fq 'opkgtun*) vpn_on' opt/bin/libs/vpn
grep -q "Поддерживается только туннель AmneziaWG" opt/bin/libs/vpn
grep -q 'opkgtun\[0-9\]\*)' build.sh
