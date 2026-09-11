#!/bin/sh
# Проверяет единственный путь упаковки build.sh в изолированной копии репозитория.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

cp -a "$ROOT/." "$WORK/repo"
cd "$WORK/repo"

./build.sh 1.2.42 >/dev/null
IPK=kvasec_1.2.42.ipk

test -f "$IPK"
gzip -t "$IPK"

UNPACKED="$WORK/unpacked"
mkdir -p "$UNPACKED"
tar -xzf "$IPK" -C "$UNPACKED"

tar -xOzf "$UNPACKED/control.tar.gz" ./control | grep -Fx 'Package: kvas' >/dev/null
tar -xOzf "$UNPACKED/control.tar.gz" ./control | grep -Fx 'Version: 1.2.42' >/dev/null
tar -xOzf "$UNPACKED/control.tar.gz" ./postinst | grep -F 'APP_VERSION=1.2.42' >/dev/null
tar -xOzf "$UNPACKED/control.tar.gz" ./postinst | grep -F '/opt/apps/kvas/bin/monitor/launcher.sh stop' >/dev/null
tar -xOzf "$UNPACKED/control.tar.gz" ./postinst | grep -F 'kvas-block-watch.pid' >/dev/null
tar -xOzf "$UNPACKED/control.tar.gz" ./postinst | grep -F '[b]lock_watch.sh' >/dev/null
tar -xOzf "$UNPACKED/control.tar.gz" ./postinst | grep -F 'kvas-bypass-check.pid' >/dev/null
tar -xOzf "$UNPACKED/control.tar.gz" ./postinst | grep -F '[b]ypass_check.sh' >/dev/null
tar -tzf "$UNPACKED/data.tar.gz" | grep -Fx './opt/apps/kvas/bin/kvas' >/dev/null
tar -tzf "$UNPACKED/data.tar.gz" | grep -Fx './opt/apps/kvas/bin/monitor/bypass_check.sh' >/dev/null
tar -tzf "$UNPACKED/data.tar.gz" | grep -Fx './opt/apps/kvas/bin/monitor/block_watch.sh' >/dev/null
tar -tzf "$UNPACKED/data.tar.gz" | grep -Fx './opt/etc/ndm/netfilter.d/100-vpn-mark' >/dev/null
! tar -tzf "$UNPACKED/data.tar.gz" | grep -q '/libs/vless$'
! tar -tzf "$UNPACKED/data.tar.gz" | grep -q '/S97xray$'
! tar -tzf "$UNPACKED/data.tar.gz" | grep -q '/kvas.vless$'
! tar -tzf "$UNPACKED/data.tar.gz" | grep -q '/shadowsocks.json$'
! tar -xOzf "$UNPACKED/control.tar.gz" ./control | grep -qi 'xray'
! tar -xOzf "$UNPACKED/control.tar.gz" ./control | grep -qi 'shadowsocks'
tar -xOzf "$UNPACKED/control.tar.gz" ./postinst | grep -F 'opkgtun[0-9]*)' >/dev/null
! tar -xOzf "$UNPACKED/control.tar.gz" ./postinst | grep -F 'rm -rf /opt/etc/xray' >/dev/null

if ./build.sh 1.2 >/dev/null 2>&1; then
    echo 'build.sh accepted an invalid SemVer version' >&2
    exit 1
fi
