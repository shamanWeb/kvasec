# NOTES — карта проекта и аудит (для быстрой ориентации)

> Рабочие заметки: как устроена маршрутизация, что безопасно/небезопасно трогать,
> что уже изменено. Основной сценарий железа — см. `~/Dropbox/VPN/vpn-recovery-runbook.md`
> (сервер AmneziaWG 3.1 + роутер Keenetic с kvas и не-NDM туннелем `opkgtun10`).

## 0. КРИТИЧНО: полная цепочка «сайт из списка → тоннель» (диагностировано 2026-09-05)

Чтобы домен из списка реально шёл в тоннель для LAN-клиентов, ВСЁ должно быть на месте:
1. **DNS клиента → dnsmasq на роутере.** kvas DNAT'ит `br0:53 → 127.0.0.1:9753`
   (константа `DNS_PORT=9753` в ndm). dnsmasq ОБЯЗАН слушать на **9753** (`port=9753`
   в `/opt/etc/dnsmasq.conf`), иначе LAN-клиенты вообще без интернета (timeout).
2. **dnsmasq грузит ipset-директивы.** Нужен `conf-dir=/opt/etc/dnsmasq.d/,*.dnsmasq`
   + upstream `no-resolv` / `server=127.0.0.1#<DNS_CRYPT_PORT>`. Без conf-dir IP доменов
   не попадают в KVAS_LIST. (Всё это чинит postinst в `build.sh`, идемпотентно.)
3. **Маркировка.** Цепочка `KVAS_MARK` (mangle) + ссылки в PREROUTING (`-i br0 ... match-set
   KVAS_LIST dst -j KVAS_MARK`). ⚠️ При `--force-reinstall`/upgrade старый пакет флашит
   iptables → KVAS_MARK пропадает, и установка сама её НЕ создаёт → routing мёртв до
   `kvas update`. **Фикс:** postinst в фоне запускает `kvas init` (если `INFACE_ENT` задан).
4. **Правило + таблица:** `ip rule 99 fwmark 0xd1000 → table 1001` → `default dev opkgtun10`.

## 0a. IPv6-утечка → `ERR_NETWORK_CHANGED` (диагностировано 2026-09-07)

Симптом: Chrome часто отдаёт `ERR_NETWORK_CHANGED` на dual-stack сайтах из списка
(instagram/youtube/x). Это **клиентская** ошибка (сработал NetworkChangeNotifier), НЕ обрыв
пути на роутере (10 МБ через тоннель качаются гладко, TLS к сайтам = 200).

Причина — IPv6 мимо тоннеля:
- WAN (`eth3`) **без IPv6** (роутер сам `ping6 → Network unreachable`), но `br0` раздаёт
  клиентам **ULA** `fd36:.../64` (scope global) → клиент думает, что IPv6 у него есть.
- dnsmasq отдавал **AAAA**-записи сайтов; `KVAS_LIST` — только IPv4 (`family inet`),
  IPv6 fwmark-правила / `ip -6 route table 1001` нет → v6-трафик к kvas-доменам шёл бы мимо
  тоннеля в любом случае.
- Итог: клиент по Happy Eyeballs пробует IPv6 первым → пакеты в никуда → обрыв → откат на IPv4
  → плавающий `ERR_NETWORK_CHANGED`.

**Фикс:** `filter-AAAA` в `etc/conf/kvas-doh-block.dnsmasq` (dnsmasq 2.92 поддерживает).
Клиенты перестают получать бесполезные AAAA → всё идёт по IPv4 → kvas-домены через тоннель.
Downside ноль (v6-интернета нет). Применено на живой роутер (2026-09-07) и в репо/postinst
(файл всегда копируется в `/opt/etc/dnsmasq.d/`).

## 0b. QUIC → `ERR_QUIC_PROTOCOL_ERROR` (диагностировано 2026-09-07)

Второй источник тех же плавающих ошибок (steamdb.info и т.п.): QUIC / HTTP-3 работает по
**UDP** 443. MSS-клампинг (спасает TCP через тоннель mtu 1280) на UDP **не действует** →
крупные QUIC-пакеты не влезают и молча дропаются; на прямом пути провайдер ломает/троттлит
QUIC. Chrome не откатывается на TCP сам → `ERR_QUIC_PROTOCOL_ERROR` (или `ERR_NETWORK_CHANGED`).

**Фикс:** блок `udp/443` REJECT в FORWARD от br0 (рядом с DoT-блоком 853) → браузер мгновенно
откатывается на HTTP/2 поверх TCP (защищён MSS-клампингом, работает). Держит watcher
`S99kvas-awg-route` (секция 5) + при переустановке. Применено 2026-09-07.

## 0c. Telegram DC через тоннель (2026-09-07)

Telegram коннектится по **хардкод-IP дата-центров**, а НЕ по DNS → `kvas add` по домену его не
завернёт. Добавлены официальные подсети (`core.telegram.org/resources/cidr.txt`, IPv4):
`91.105.192.0/23 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.56.0/22
95.161.64.0/20 149.154.160.0/20`. `KVAS_LIST` — `hash:net`, принимает CIDR.

Персистентность в ДВА слоя:
1. дописаны в `/opt/etc/kvas.list` (грузятся `main/ipset` на boot/update);
2. **watcher `S99kvas-awg-route` секция 6** проверяет и при необходимости добавляет их в `KVAS_LIST`
   (сентинел по `149.154.160.0/20`). Это надёжнее: `main/ipset` добавляет с `timeout 0`, что
   **падает на сете без timeout-поддержки** (текущий live-сет именно такой; `create_list`
   создаёт с `timeout 86400`, но watcher-heavy окружение может пересоздать иначе). Watcher
   добавляет без timeout → работает всегда. Секция 6 хардкодит подсети → и свежая
   переустановка получает Telegram-маршрутизацию из коробки.

Проверка: TCP-connect к `149.154.167.51` через `--interface opkgtun10` проходит (0.1с), напрямую
— timeout. (TLS/HTTP curl’ом не идёт — Telegram DC говорят по MTProto, не HTTPS; это норма.)
5. **DNS-кэш КЛИЕНТА.** Если клиент резолвил домен ДО добавления — у него старый IP, которого
   нет в ipset → идёт мимо тоннеля. На клиенте: `resolvectl flush-caches` / `ipconfig /flushdns`.
6. **DoH/DoT-обход.** Браузеры (Chrome/Firefox) по умолчанию шлют DNS через свой DoH-сервер
   мимо dnsmasq → домены не попадают в ipset. Закрыто: `kvas-doh-block.dnsmasq` (имена DoH-серверов
   → 0.0.0.0, ставится postinst'ом в dnsmasq.d) + watcher держит iptables REJECT DoT (tcp/udp 853, br0).

Массовое добавление доменов: писать прямо в `/opt/etc/kvas.list` (dedup `grep -qxF`),
затем `bin/main/dnsmasq` (регенерация директив) + рестарт dnsmasq. НЕ через heredoc+pipe
одновременно (stdin-конфликт: `while read` съест строки скрипта).

**Регистрация NDM-хуков:** NDM вызывает только хуки из `/opt/etc/ndm/` (НЕ из `/opt/apps/kvas/etc/ndm/`).
build.sh кладёт туда `100-dns-local` + `100-vpn-mark` (иначе KVAS_MARK слетала на сбросах NDM и не
восстанавливалась). `kvas test` для opkgtun* использует прямую проверку туннеля (`awg_tunnel_check`),
а не NDM RCI — не даёт ложного «ОСТАНОВЛЕНО».

## 1. Как устроена маршрутизация (то, что «идёт в тоннель»)

- **Метка / таблица:** `MARK_NUM=0xd1000` → `ROUTE_TABLE_ID=1001`, правило `ip rule fwmark 0xd1000 lookup 1001`
  с `RULE_PRIORITY=99` (должно стоять ВЫШЕ system rule 104 `from all lookup 4098`, иначе трафик
  KVAS_LIST перехватывается раньше и уходит в WAN). Схемы `0xffffaaa`/`4096` в коде НЕТ — вестигиально.
  Файл: `opt/etc/ndm/ndm:22-24`.
- **Списки:**
  - `opt/etc/kvas.list` (на роутере `/opt/etc/kvas.list`) — список доменов/IP («белый список»).
  - ipset `KVAS_LIST` — резолвнутые IP. Домены → IP кладёт **dnsmasq** по директивам
    `ipset=/домен/KVAS_LIST` из `/opt/etc/dnsmasq.d/kvas.dnsmasq` (генерит `bin/main/dnsmasq`).
  - IP-литералы/подсети из kvas.list кладёт `bin/main/ipset` напрямую (timeout 0).
- **Кто наполняет таблицу 1001** (`ip4__route__add_table`, `ndm:1149`): вызывается из
  - `link_up()` (`bin/libs/ndm_d:60`) ← NDM-хуки `netfilter.d/100-vpn-mark`,
    `ifstatechanged.d/100-kvas-vpn` (по `INFACE_CLI`);
  - `ip4__mark__create_chain` (`ndm:531`) — при СОЗДАНИИ MARK-цепочки (после её флаша).
- **⚠️ Не-NDM туннели (AmneziaWG `opkgtunNN`):** создаются awg-manager'ом в обход NDM →
  NDM-хуки НЕ срабатывают → таблицу 1001/правило/KVAS_MARK kvas сам не держит после
  переподключения туннеля и сбросов NDM-firewall. Решает watcher-демон
  **`opt/etc/init.d/S99kvas-awg-route`** (теперь В ПАКЕТЕ, ставится и стартует из postinst).
  Каждые 5с держит: (1) `default via <ip> dev opkgtunNN` в table 1001/4096; (2) `ip rule
  fwmark 0xd1000 -> table 1001` (prio 99); (3) цепочку KVAS_MARK — при пропаже пересоздаёт
  через `100-vpn-mark`. Для не-opkgtun интерфейсов сразу выходит. Лог: `/opt/tmp/kvas-awg-route.log`.
  (Исторически был ручным артефактом runbook §7.1 — теперь заведён в репо.)
- **Ложные тревоги (не авария):** `kvas test` / `check_vpn` опрашивают состояние через NDM RCI
  (`localhost:79/rci/...`) по `INFACE_CLI` → для `opkgtun10` (вне NDM) вернут «ОСТАНОВЛЕНО/пусто»,
  хотя туннель работает. Проверять надо `ip route get ... mark 0xd1000`, `ip route show table 1001`.

## 2. `kvas update` — безопасность списка маршрутизации

`kvas update` → `bin/main/update` → `cmd_kvas_init update` (`bin/libs/vpn:148`):
`update_iptables` (флаш chain+table → пересоздание MARK-цепочки восстанавливает table 1001 + rule)
→ `update_ipset` → `update_adblock` → `all_services_restart` (рестарт dnsmasq/dnscrypt).

- **Список НЕ теряется:** `kvas.list` открывается только на чтение; ipset `KVAS_LIST` НЕ флашится
  (`ip4__ipset__create` при существующем наборе сразу выходит, `ndm:247-249`) → динамически
  добавленные IP доменов выживают апдейт.

## 3. Текущее состояние репозитория

Ключевые изменения ниже находятся в исходниках репозитория и входят в IPK, собранный через
`build.sh`. Не используйте этот раздел как индикатор `git status`: актуальное состояние
рабочего дерева всегда проверяется самой командой Git.

- `build.sh` + `.github/workflows/build.yml` + `VERSION` + `BUILD.md` — сборка/установка из этого репо.
- Merge/push в `master` автоматически публикует GitHub Release с номером выше предыдущего.
- `bin/main/upgrade`: `release_url` → `shamanWeb/kvasec` + поддержка токена приватного репо.
- Чистка репо (удалены Windows/Jenkins-сборка, старые ipk, backup).
- `bin/kvas` ветка `add`: инкрементально — домен работает сразу (`ipset__fill_by_domain`),
  тяжёлое (регенерация директив + `main/ipset` + рестарт DNS) в фон.
- `etc/ndm/ndm`: `RULE_PRIORITY` 1778→99.
- `etc/ndm/ndm` `ip4__route__add_table` (~1165): флашить table 1001 только если default НЕ смотрит
  на нужный `dev` (а не при текстовом несовпадении с `via ...`) — убирает лишний флаш на каждом
  `kvas update` для opkgtun10 и «драку» с watcher'ом.
- `bin/libs/vpn` `cmd_kvas_init`: НЕ звать `reset_all_connection` при `stage=update` (тоннель уже
  поднят; бунс интерфейса/xray только рвал связь; правила и так пересоздаются в `update_iptables`).

## 4. Открытые вопросы / НЕ трогать «в лоб»

- **`bin/libs/main:256` опечатка `[ ${DNS_ENABLE} = fasle ]`** (должно `false`). НЕ править одним словом!
  Сейчас опечатка = «пропустить предпроверку DNS и просто резолвить». «Исправление» активирует
  `is_dns_server_online` (`main:185`), которая: (а) парсит порт через `${1/#/:}` — bash-подстановка,
  в BusyBox ash не работает; (б) видит только ЛОКАЛЬНЫЙ listener. При неуспехе — `exit 1`, а функция
  вызывается из `ipset__fill_by_domain` (**`kvas add`**), `dns__get_ips_by_domain`, `check`, `hosts` —
  `exit 1` в sourced-функции убьёт всю команду. Чинить только КОМПЛЕКСНО: починить `is_dns_server_online`
  + заменить `exit 1` на `return 1`.
- `reset_all_connection` для non-NDM: `curl rci/interface/opkgtun10/up` — no-op (мелочь, оставлено).

## 5. Сборка / установка (кратко; подробно — `BUILD.md`)

- `./build.sh [X.Y.Z]` — SemVer из аргумента / `VERSION` / `Makefile`. Merge в `master`
  увеличивает PATCH-часть и публикует `kvasec_<X.Y.Z>.ipk` автоматически.
  `bin/libs/ndm` генерится postinst'ом из `etc/ndm/ndm` (несёт RULE_PRIORITY).
- Ставим `opkg install --force-reinstall`, затем `kvas setup` или ребут.
- Собираем **core** (Hysteria и failover удалены из проекта).
- **Важно:** git-дерево `opt/` ≠ отгружаемый ipk апстрима (тот собирался на Windows `lastest/`,
  дрейф двусторонний). Правки в этом репо не влияют на апстрим-релизы автоматически.
