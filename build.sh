#!/bin/sh
# ---------------------------------------------------------------------------
#  Локальная сборка ipk-пакета KVAS из текущего репозитория (Linux, без SDK).
#
#  Формат ipk: gzip(tar( debian-binary + control.tar.gz + data.tar.gz )),
#  идентичный отгружаемым релизам (проверено на v352).
#
#  Использование:
#     ./build.sh [RELEASE]      # RELEASE — номер сборки, по умолчанию из VERSION
#
#  Результат: ./kvas_<VERSION>-<RELEASE>_all.ipk
#
#  Установка на роутер:
#     scp kvas_*.ipk root@192.168.1.1:/opt/tmp/     # порт 222 при необходимости
#     ssh root@192.168.1.1 'opkg install --force-reinstall /opt/tmp/kvas_*.ipk'
#     # затем: kvas setup   (или перезагрузка роутера)
# ---------------------------------------------------------------------------
set -eu

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

PKG_NAME='kvas'
PKG_VERSION='1.1.9_beta-10'
# Номер релиза: аргумент → файл VERSION → PKG_RELEASE из Makefile → 0
if [ "${1:-}" ]; then
	PKG_RELEASE="$1"
elif [ -f "${REPO_DIR}/VERSION" ]; then
	PKG_RELEASE="$(cat "${REPO_DIR}/VERSION")"
else
	PKG_RELEASE="$(grep -E '^PKG_RELEASE' "${REPO_DIR}/Makefile" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
	[ "${PKG_RELEASE}" ] || PKG_RELEASE=0
fi

FULL_VERSION="${PKG_VERSION}-${PKG_RELEASE}"
OUT_IPK="${REPO_DIR}/${PKG_NAME}_${FULL_VERSION}_all.ipk"

echo "==> Сборка ${PKG_NAME} ${FULL_VERSION}"

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
cp -a "${REPO_DIR}/opt/etc/ndm/fs.d/15-kvas-start.sh"         "${DATA}/opt/etc/ndm/fs.d/"
cp -a "${REPO_DIR}/opt/etc/ndm/netfilter.d/100-dns-local"     "${DATA}/opt/etc/ndm/netfilter.d/"

# Права на исполнение
chmod -R +x "${DATA}/opt/apps/kvas/bin"          2>/dev/null || true
chmod -R +x "${DATA}/opt/apps/kvas/etc/init.d"   2>/dev/null || true
chmod -R +x "${DATA}/opt/apps/kvas/etc/ndm"      2>/dev/null || true
chmod +x    "${DATA}/opt/etc/init.d/S96kvas" \
            "${DATA}/opt/etc/ndm/fs.d/15-kvas-start.sh" \
            "${DATA}/opt/etc/ndm/netfilter.d/100-dns-local"

INSTALLED_SIZE="$(du -sb "${DATA}" | cut -f1)"

# 3. control
cat > "${CTRL}/control" <<EOF
Package: ${PKG_NAME}
Version: ${FULL_VERSION}
Depends: libpcre, jq, curl, knot-dig, nano-full, cron, bind-dig, dnsmasq-full, ipset, dnscrypt-proxy2, iptables, shadowsocks-libev-ss-redir, shadowsocks-libev-config, libmbedtls
Source: https://github.com/shamanWeb/kvasec
Maintainer: shamanWeb
Architecture: all
Description: VPN клиент для Keenetic (${FULL_VERSION})
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
    if grep -q "^APP_RELEASE=" "\${kvas_conf}" 2>/dev/null; then
        sed -i "s/^APP_RELEASE=.*/APP_RELEASE=${PKG_RELEASE}/" "\${kvas_conf}"
    else
        echo "APP_RELEASE=${PKG_RELEASE}" >> "\${kvas_conf}"
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
