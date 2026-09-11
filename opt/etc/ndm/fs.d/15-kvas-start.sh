#!/bin/sh

if [ "${1}" = 'start' ] ; then
	. /opt/apps/kvas/bin/libs/ndm

	# стартуем ipset'ы до старта DNS-серверов
	ip4__ipset__create_list

	# запускаем все opkg-сервисы (dropbear, dnsmasq, kvas, awg-manager, watcher…)
	[ -x /opt/etc/init.d/rc.unslung ] && /opt/etc/init.d/rc.unslung start &
fi
