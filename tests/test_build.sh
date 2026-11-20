#!/bin/sh
# Проверяет единственный путь упаковки build.sh в изолированной копии репозитория.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

cp -a "$ROOT/." "$WORK/repo"
cd "$WORK/repo"

# Неотслеживаемый мусор в opt/ не попадает в пакет; права не зависят от umask.
echo junk > opt/bin/zz-untracked.bak
( umask 077; ./build.sh 1.2.42 >/dev/null )
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
tar -tzf "$UNPACKED/data.tar.gz" | grep -Fx './opt/apps/kvas/bin/main/parental_dns' >/dev/null
tar -tzf "$UNPACKED/data.tar.gz" | grep -Fx './opt/etc/ndm/netfilter.d/100-vpn-mark' >/dev/null
if tar -tzf "$UNPACKED/data.tar.gz" | grep -q '/libs/vless$'; then echo "FAIL: test_build.sh:37" >&2; exit 1; fi
if tar -tzf "$UNPACKED/data.tar.gz" | grep -q '/S97xray$'; then echo "FAIL: test_build.sh:38" >&2; exit 1; fi
if tar -tzf "$UNPACKED/data.tar.gz" | grep -q '/kvas.vless$'; then echo "FAIL: test_build.sh:39" >&2; exit 1; fi
if tar -tzf "$UNPACKED/data.tar.gz" | grep -q '/shadowsocks.json$'; then echo "FAIL: test_build.sh:40" >&2; exit 1; fi
if tar -xOzf "$UNPACKED/control.tar.gz" ./control | grep -qi 'xray'; then echo "FAIL: test_build.sh:41" >&2; exit 1; fi
if tar -xOzf "$UNPACKED/control.tar.gz" ./control | grep -qi 'shadowsocks'; then echo "FAIL: test_build.sh:42" >&2; exit 1; fi
tar -xOzf "$UNPACKED/control.tar.gz" ./postinst | grep -F 'opkgtun[0-9]*)' >/dev/null
if tar -xOzf "$UNPACKED/control.tar.gz" ./postinst | grep -F 'rm -rf /opt/etc/xray' >/dev/null; then echo "FAIL: test_build.sh:44" >&2; exit 1; fi

if ./build.sh 1.2 >/dev/null 2>&1; then
    echo 'build.sh accepted an invalid SemVer version' >&2
    exit 1
fi

# 8.2: только файлы под git, фиксированные права
if tar -tzf "$UNPACKED/data.tar.gz" | grep -F 'zz-untracked.bak' >/dev/null; then echo "FAIL: test_build.sh:52" >&2; exit 1; fi
tar -tvzf "$UNPACKED/data.tar.gz" | awk '$1 ~ /^d/ && $1 != "drwxr-xr-x" { bad = 1 } END { exit bad }'
tar -tvzf "$UNPACKED/data.tar.gz" ./opt/apps/kvas/bin/kvas | grep -q '^-rwxr-xr-x'
tar -tvzf "$UNPACKED/data.tar.gz" ./opt/apps/kvas/etc/conf/kvas.help | grep -q '^-rw-r--r--'

# Отслеживаемый файл удалён из рабочей копии → сборка падает, а не выпускает пакет без него
rm -f opt/etc/conf/kvas.help
if ./build.sh 1.2.43 >/dev/null 2>&1; then echo 'FAIL: build ignored a missing tracked file' >&2; exit 1; fi
git checkout -q -- opt/etc/conf/kvas.help

# 2.8: копии сторожа в init.d (rc.unslung запускает все S*) обезвреживаются
tar -xOzf "$UNPACKED/control.tar.gz" ./postinst | grep -F 'for _old in /opt/etc/init.d/S99kvas-awg-route.*; do' >/dev/null
tar -xOzf "$UNPACKED/control.tar.gz" ./postinst | grep -F '[ -f "${_old}" ] && chmod -x "${_old}"' >/dev/null

# 8.3: prerm/postrm — postrm убирает маршрутизацию только если пакета действительно нет
tar -tzf "$UNPACKED/control.tar.gz" | grep -qx './prerm'
tar -tzf "$UNPACKED/control.tar.gz" | grep -qx './postrm'
tar -xOzf "$UNPACKED/control.tar.gz" ./prerm | grep -F 'S99kvas-awg-route stop' >/dev/null
tar -xOzf "$UNPACKED/control.tar.gz" ./postrm | grep -F "opkg list-installed 2>/dev/null | grep -q '^kvas ' && exit 0" >/dev/null
if tar -xOzf "$UNPACKED/control.tar.gz" ./postrm | grep -qE 'KVAS_DNS|dnsmasq.d'; then echo 'FAIL: postrm трогает DNS' >&2; exit 1; fi
