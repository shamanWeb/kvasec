#!/bin/sh
# ---------------------------------------------------------------------------
#  Локальная сборка ipk-пакета KVASEC из текущего репозитория (Linux, без SDK).
#
#  Формат ipk: gzip(tar( debian-binary + control.tar.gz + data.tar.gz )),
#  идентичный отгружаемым релизам (проверено на v352).
#
#  Использование:
#     ./build.sh [VERSION]      # VERSION в формате MAJOR.MINOR.PATCH, по умолчанию из VERSION
#
#  Результат: ./kvasec_<VERSION>.ipk
#
#  Установка на роутер:
#     scp kvas_*.ipk root@192.168.1.1:/opt/tmp/     # порт 222 при необходимости
#     ssh root@192.168.1.1 'opkg install --force-reinstall /opt/tmp/kvas_*.ipk'
#     # затем: kvas setup   (или перезагрузка роутера)
# ---------------------------------------------------------------------------
set -eu

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

PKG_NAME='kvas'
# Версия: аргумент → файл VERSION → PKG_VERSION из Makefile.
# Имя пакета в opkg остаётся kvas для бесшовного обновления старых установок.
if [ "${1:-}" ]; then
	PKG_VERSION="$1"
elif [ -f "${REPO_DIR}/VERSION" ]; then
	PKG_VERSION="$(tr -d '[:space:]' < "${REPO_DIR}/VERSION")"
else
	PKG_VERSION="$(grep -E '^PKG_VERSION' "${REPO_DIR}/Makefile" 2>/dev/null | sed 's/.*:= *//' | tr -d '[:space:]')"
fi
[ -n "${PKG_VERSION:-}" ] || PKG_VERSION=1.2.0
echo "${PKG_VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
	echo "ERROR: version must use MAJOR.MINOR.PATCH, got: ${PKG_VERSION}" >&2
	exit 2
}

OUT_IPK="${REPO_DIR}/kvasec_${PKG_VERSION}.ipk"

echo "==> Сборка ${PKG_NAME} ${PKG_VERSION}"

BUILD="$(mktemp -d)"
trap 'rm -rf "${BUILD}"' EXIT
DATA="${BUILD}/data"
CTRL="${BUILD}/control"

mkdir -p \
	"${DATA}/opt/apps/kvas" \
	"${DATA}/opt/etc/init.d" \
	"${DATA}/opt/etc/ndm/fs.d" \
	"${DATA}/opt/etc/ndm/netfilter.d" \
	"${CTRL}"

# 1. Всё дерево пакета → /opt/apps/kvas/
cp -a "${REPO_DIR}/opt/." "${DATA}/opt/apps/kvas/"

# 2. Системные точки входа, которые читает сама прошивка (init.d/ndm),
#    дублируются в /opt/etc/ (как в отгружаемом релизе)
cp -a "${REPO_DIR}/opt/etc/init.d/S96kvas"                    "${DATA}/opt/etc/init.d/"
cp -a "${REPO_DIR}/opt/etc/init.d/S99kvas-awg-route"          "${DATA}/opt/etc/init.d/"
cp -a "${REPO_DIR}/opt/etc/ndm/fs.d/15-kvas-start.sh"         "${DATA}/opt/etc/ndm/fs.d/"
cp -a "${REPO_DIR}/opt/etc/ndm/netfilter.d/100-dns-local"     "${DATA}/opt/etc/ndm/netfilter.d/"
# 100-vpn-mark регистрируем в /opt/etc/ndm/ рядом с 100-dns-local, чтобы NDM
# пересоздавал маркировку KVAS_MARK на netfilter-сбросах (иначе выживал только
# DNS-редирект, а маркировка слетала — корень хрупкости KVAS_MARK).
cp -a "${REPO_DIR}/opt/etc/ndm/netfilter.d/100-vpn-mark"      "${DATA}/opt/etc/ndm/netfilter.d/"

# Права на исполнение
chmod -R +x "${DATA}/opt/apps/kvas/bin"          2>/dev/null || true
chmod -R +x "${DATA}/opt/apps/kvas/etc/init.d"   2>/dev/null || true
chmod -R +x "${DATA}/opt/apps/kvas/etc/ndm"      2>/dev/null || true
chmod +x    "${DATA}/opt/etc/init.d/S96kvas" \
            "${DATA}/opt/etc/init.d/S99kvas-awg-route" \
            "${DATA}/opt/etc/ndm/fs.d/15-kvas-start.sh" \
            "${DATA}/opt/etc/ndm/netfilter.d/100-dns-local" \
            "${DATA}/opt/etc/ndm/netfilter.d/100-vpn-mark"

INSTALLED_SIZE="$(du -sb "${DATA}" | cut -f1)"

# 3. control
cat > "${CTRL}/control" <<EOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Depends: libpcre, jq, curl, knot-dig, nano-full, cron, bind-dig, dnsmasq-full, ipset, dnscrypt-proxy2, iptables, shadowsocks-libev-ss-redir, shadowsocks-libev-config, libmbedtls
Source: https://github.com/shamanWeb/kvasec
Maintainer: shamanWeb
Architecture: all
Description: KVASEC VPN client for Keenetic (${PKG_VERSION})
Section: utils
Priority: optional
Installed-Size: ${INSTALLED_SIZE}
EOF

# 4. postinst
#    - генерирует bin/libs/ndm из etc/ndm/ndm (несёт RULE_PRIORITY=99);
#    - конфиги засеваются ТОЛЬКО при первой установке (upgrade не затирает).
cat > "${CTRL}/postinst" <<POSTINST
#!/bin/sh
if [ "\$1" = "configure" ] || [ -z "\$1" ]; then
    mkdir -p /opt/etc/ndm/watch.d /opt/etc/dnsmasq.d /opt/etc/adblock /opt/etc/xray /opt/var/log
    chown root:root /opt/etc/ndm/watch.d 2>/dev/null

    # A shell script that is running during opkg upgrade keeps executing its
    # deleted old inode. Stop the temporary block watcher, otherwise its lock
    # remains and prevents the new package version from starting it.
    watch_pid_file=/tmp/kvas-block-watch.pid
    watch_lock_dir=/tmp/kvas-block-watch.lock.d
    watch_dns_conf=/opt/etc/dnsmasq.d/kvas-monitor-dns.dnsmasq
    bypass_pid_file=/tmp/kvas-bypass-check.pid
    bypass_lock_file=/tmp/kvas-bypass-check.lock
    bypass_lock_dir=/tmp/kvas-bypass-check.lock.d
    # Releases before the dedicated PID file used the lock file as PID storage.
    [ -s "\${bypass_pid_file}" ] || bypass_pid_file="\${bypass_lock_file}"
    if [ -s "\${bypass_pid_file}" ]; then
        bypass_pid=\$(cat "\${bypass_pid_file}" 2>/dev/null)
        case "\${bypass_pid}" in
            *[!0-9]*|'') ;;
            *)
                if [ -r "/proc/\${bypass_pid}/cmdline" ] && \
                    tr '\000' ' ' < "/proc/\${bypass_pid}/cmdline" | grep -q '[b]ypass_check.sh'; then
                    kill "\${bypass_pid}" 2>/dev/null || true
                    for bypass_wait in 1 2 3; do
                        kill -0 "\${bypass_pid}" 2>/dev/null || break
                        sleep 1
                    done
                fi
                ;;
        esac
    fi
    rm -f /tmp/kvas-bypass-check.pid "\${bypass_lock_file}" /tmp/kvas-bypass-check.progress /tmp/kvas-bypass-check.json /tmp/kvas-bypass-check.log
    rmdir "\${bypass_lock_dir}" 2>/dev/null || true
    if [ -s "\${watch_pid_file}" ]; then
        watch_pid=\$(cat "\${watch_pid_file}" 2>/dev/null)
        case "\${watch_pid}" in
            *[!0-9]*|'') ;;
            *)
                if [ -r "/proc/\${watch_pid}/cmdline" ] && \
                    tr '\000' ' ' < "/proc/\${watch_pid}/cmdline" | grep -q '[b]lock_watch.sh'; then
                    kill "\${watch_pid}" 2>/dev/null || true
                    for watch_wait in 1 2 3; do
                        kill -0 "\${watch_pid}" 2>/dev/null || break
                        sleep 1
                    done
                fi
                ;;
        esac
    fi
    rm -f "\${watch_pid_file}" /tmp/kvas-block-watch.events /tmp/kvas-dns.log
    rmdir "\${watch_lock_dir}" 2>/dev/null || true
    if [ -f "\${watch_dns_conf}" ]; then
        rm -f "\${watch_dns_conf}"
        [ -x /opt/etc/init.d/S56dnsmasq ] && /opt/etc/init.d/S56dnsmasq restart >/dev/null 2>&1
    fi

    ln -sf /opt/apps/kvas/bin/kvas /opt/bin/kvas

    # bin/libs/ndm генерируется из etc/ndm/ndm — так фикс RULE_PRIORITY попадает в рантайм-хук
    cp -f /opt/apps/kvas/etc/ndm/ndm /opt/apps/kvas/bin/libs/ndm

    # Значения по умолчанию только при первой установке (не затираем конфиг при upgrade)
    [ -f /opt/etc/kvas.conf ]            || cp -f /opt/apps/kvas/etc/conf/kvas.conf     /opt/etc/kvas.conf
    [ -f /opt/etc/kvas.list ]            || cp -f /opt/apps/kvas/etc/conf/kvas.list     /opt/etc/kvas.list
    [ -f /opt/etc/adblock/sources.list ] || cp -f /opt/apps/kvas/etc/conf/adblock.sources /opt/etc/adblock/sources.list

    # dnsmasq.conf: добавляем необходимые директивы если их нет.
    # conf-dir — загружает ipset=/домен/ правила из dnsmasq.d/kvas.dnsmasq.
    # server + no-resolv — форвардим через dnscrypt-proxy (порт из kvas.conf).
    # port=9753 — ОБЯЗАТЕЛЬНО: kvas DNAT'ит LAN-запросы (br0:53) на 127.0.0.1:9753
    #   (константа DNS_PORT=9753 в etc/ndm/ndm). Если dnsmasq слушает на 53, а не
    #   на 9753 — LAN-клиенты получают timeout, интернет на устройствах «не работает».
    dnsmasq_conf=/opt/etc/dnsmasq.conf
    touch "\${dnsmasq_conf}"
    grep -q 'conf-dir=/opt/etc/dnsmasq.d' "\${dnsmasq_conf}" 2>/dev/null || \
        echo 'conf-dir=/opt/etc/dnsmasq.d/,*.dnsmasq' >> "\${dnsmasq_conf}"
    if ! grep -q '^server=' "\${dnsmasq_conf}" 2>/dev/null; then
        dns_crypt_port=\$(grep '^DNS_CRYPT_PORT=' /opt/etc/kvas.conf 2>/dev/null | cut -d= -f2)
        dns_crypt_port=\${dns_crypt_port:-9153}
        printf 'no-resolv\nserver=127.0.0.1#%s\n' "\${dns_crypt_port}" >> "\${dnsmasq_conf}"
    fi
    if ! grep -q '^port=9753' "\${dnsmasq_conf}" 2>/dev/null; then
        sed -i '/^port=/d' "\${dnsmasq_conf}"
        echo 'port=9753' >> "\${dnsmasq_conf}"
    fi

    # Блокировка DoH: сниппет с именами публичных DoH-серверов -> 0.0.0.0,
    # чтобы браузеры не обходили dnsmasq (DoT/853 глушит watcher в iptables).
    cp -f /opt/apps/kvas/etc/conf/kvas-doh-block.dnsmasq /opt/etc/dnsmasq.d/kvas-doh-block.dnsmasq 2>/dev/null

    chmod -R +x /opt/apps/kvas/bin/*        2>/dev/null
    chmod -R +x /opt/apps/kvas/etc/init.d/* 2>/dev/null
    chmod -R +x /opt/apps/kvas/etc/ndm/*    2>/dev/null

    kvas_conf=/opt/etc/kvas.conf
    touch "\${kvas_conf}"
    if grep -q "^APP_VERSION=" "\${kvas_conf}" 2>/dev/null; then
        sed -i "s/^APP_VERSION=.*/APP_VERSION=${PKG_VERSION}/" "\${kvas_conf}"
    else
        echo "APP_VERSION=${PKG_VERSION}" >> "\${kvas_conf}"
    fi
    # В прежнем формате номер сборки хранился отдельно в APP_RELEASE.
    # SemVer теперь целиком в APP_VERSION; очищаем старое значение при миграции.
    if grep -q "^APP_RELEASE=" "\${kvas_conf}" 2>/dev/null; then
        sed -i "s/^APP_RELEASE=.*/APP_RELEASE=/" "\${kvas_conf}"
    else
        echo "APP_RELEASE=" >> "\${kvas_conf}"
    fi

    # Пересоздаём маршрутизацию kvas ПОСЛЕ установки (в фоне).
    # Критично: при --force-reinstall/upgrade старый пакет при удалении флашит
    # iptables (цепочка KVAS_MARK пропадает), а установка сама правила не создаёт →
    # selective-routing не работает до ручного 'kvas update'. init пересоздаёт
    # KVAS_MARK, таблицу 1001, ip rule (fwmark→1001) и наполняет ipset.
    # Запускается только если интерфейс уже настроен (INFACE_ENT задан);
    # на чистой установке маршрутизацию поднимет 'kvas setup'.
    if grep -q '^INFACE_ENT=.\+' "\${kvas_conf}" 2>/dev/null; then
        /opt/apps/kvas/bin/kvas init >/dev/null 2>&1 &
    fi

    # Watcher маршрутизации для НЕ-NDM AmneziaWG-туннеля (opkgtunNN).
    # Держит default/rule/KVAS_MARK при переподключении туннеля и сбросах NDM.
    # Для не-opkgtun интерфейсов демон сам сразу выходит — ставим всегда.
    chmod +x /opt/etc/init.d/S99kvas-awg-route 2>/dev/null
    /opt/etc/init.d/S99kvas-awg-route restart >/dev/null 2>&1 &

    # Web UI: если был включён, обязательно останавливаем старый socat/handler
    # перед стартом. Иначе `kvas monitor web` видит занятый порт и после upgrade
    # продолжает обслуживать старый handler из /tmp.
    if [ -f /opt/etc/kvas-monitor-web-enabled ]; then
        /opt/apps/kvas/bin/monitor/launcher.sh stop >/dev/null 2>&1
        /opt/apps/kvas/bin/kvas monitor web >/dev/null 2>&1 &
    fi
fi
exit 0
POSTINST
chmod +x "${CTRL}/postinst"

# 5. Упаковка (root:root, чтобы opkg ставил от root)
echo '2.0' > "${BUILD}/debian-binary"
tar --owner=0 --group=0 -czf "${BUILD}/control.tar.gz" -C "${CTRL}" .
tar --owner=0 --group=0 -czf "${BUILD}/data.tar.gz"    -C "${DATA}" ./opt
rm -f "${OUT_IPK}"
tar --owner=0 --group=0 -czf "${OUT_IPK}" -C "${BUILD}" ./debian-binary ./control.tar.gz ./data.tar.gz

echo "==> Готово: ${OUT_IPK}"
ls -l "${OUT_IPK}"
