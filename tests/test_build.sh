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
tar -tzf "$UNPACKED/data.tar.gz" | grep -Fx './opt/apps/kvas/bin/kvas' >/dev/null
tar -tzf "$UNPACKED/data.tar.gz" | grep -Fx './opt/etc/ndm/netfilter.d/100-vpn-mark' >/dev/null

if ./build.sh 1.2 >/dev/null 2>&1; then
    echo 'build.sh accepted an invalid SemVer version' >&2
    exit 1
fi
