#!/bin/sh
#------------------------------------------------------------------------------
#	ПАКЕТ KVASEC — сборщик истории DPI-интерференции
#------------------------------------------------------------------------------
#
# Раз в минуту (из cron) снимает счётчики RX-дропов на туннельном интерфейсе
# opkgtunNN и пишет точку истории для графика в веб-мониторе. Дропы на приёмной
# стороне туннеля = пакеты, испорченные DPI (РКН/ТСПУ) на пути — прямой след
# блокировки/троттлинга (на сервере awg0 они = 0, т.к. порча идёт к клиенту).
#
# Кольцевой файл: 1440 точек = 24 часа при шаге в 1 минуту.
#------------------------------------------------------------------------------

IFACE=$(sed -n 's/^INFACE_ENT=//p' /opt/etc/kvas.conf 2>/dev/null | tr -d ' \r')
[ -z "${IFACE}" ] && IFACE=opkgtun10
STAT="/sys/class/net/${IFACE}/statistics"
HIST=/opt/tmp/dpi-history.jsonl
PREV=/opt/tmp/dpi-history.prev
MAX=1440

[ -d "${STAT}" ] || exit 0

drop=$(cat "${STAT}/rx_dropped" 2>/dev/null || echo 0)
pkts=$(cat "${STAT}/rx_packets" 2>/dev/null || echo 0)
now=$(date +%s)

rate=0; loss=0
if [ -f "${PREV}" ]; then
	read -r p_drop p_pkts p_time < "${PREV}"
	dd=$((drop - p_drop)); dp=$((pkts - p_pkts)); dt=$((now - p_time))
	# dd<0 => счётчик сбросился (реконнект туннеля) — точку считаем нулевой
	if [ "${dd}" -ge 0 ] && [ "${dt}" -gt 0 ]; then
		rate=$((dd * 60 / dt))
		[ $((dp + dd)) -gt 0 ] && loss=$((dd * 100 / (dp + dd)))
	fi
fi
echo "${drop} ${pkts} ${now}" > "${PREV}"

echo "{\"t\":${now},\"rate\":${rate},\"loss\":${loss}}" >> "${HIST}"

# Обрезаем до последних MAX точек (24 часа)
if [ "$(wc -l < "${HIST}" 2>/dev/null || echo 0)" -gt "${MAX}" ]; then
	tail -n "${MAX}" "${HIST}" > "${HIST}.tmp" && mv -f "${HIST}.tmp" "${HIST}"
fi
