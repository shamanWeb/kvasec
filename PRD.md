# PRD: KVAS — селективный VPN-роутинг для Keenetic (форк под AmneziaWG)

**Версия:** 1.1.9_beta-10-41+
**Репозиторий:** https://github.com/shamanWeb/kvasec (личный форк)
**Основа:** https://github.com/qzeleza/kvas (Apache 2.0)
**Железо:** Keenetic (aarch64), KeeneticOS 5.x + Entware
**Сценарий эксплуатации:** `~/Dropbox/VPN/vpn-recovery-runbook.md`

> Глубокая карта маршрутизации и «ловушки» — в `NOTES.md`. Сборка/установка — в `BUILD.md`.
> Этот файл — верхнеуровневое описание проекта, целей и статуса.

---

## 1. Что это и зачем

CLI-обвязка для роутеров Keenetic: **селективный роутинг LAN по списку доменов** — трафик к
доменам из белого списка идёт в VPN-тоннель, остальное — напрямую через провайдера.

Связка: **ipset** + **dnsmasq (wildcard)** + **dnscrypt-proxy2** (+ опционально AdGuardHome).
dnsmasq по директивам `ipset=/домен/KVAS_LIST` кладёт резолвнутые IP доменов в ipset,
iptables метит трафик к этим IP, `ip rule` заворачивает помеченное в отдельную таблицу
маршрутизации на VPN-интерфейс.

**Отличие этого форка:**
- адаптирован под **AmneziaWG-туннель** (`opkgtunNN`), который создаётся awg-manager'ом
  **в обход NDM** — из-за чего штатные механизмы kvas требуют доработок (см. §2, §6);
- собирается и ставится **напрямую из репозитория** (`build.sh`), без Windows/molot-SDK;
- **Hysteria 2 и Failover удалены** — не поддерживаются. Остаётся ядро + VLESS + adblock.

## 2. Как работает маршрутизация (кратко)

Полная цепочка «сайт из списка → тоннель» и требования — в `NOTES.md §0`. Ключевое:

| Звено | Значение |
|---|---|
| Метка трафика | `MARK_NUM=0xd1000` |
| Таблица маршрутов | `ROUTE_TABLE_ID=1001` |
| Правило | `ip rule fwmark 0xd1000 lookup 1001`, `RULE_PRIORITY=99` (выше system rule 104) |
| Цепочка маркировки | `KVAS_MARK` (mangle), ссылки в PREROUTING по `match-set KVAS_LIST dst` |
| DNS клиента | DNAT `br0:53 → 127.0.0.1:9753`; dnsmasq слушает **9753** |
| Список доменов | `/opt/etc/kvas.list`; ipset `KVAS_LIST` наполняется dnsmasq'ом |

**Не-NDM opkgtunNN:** NDM-события kvas не приходят → таблицу 1001, правило и `KVAS_MARK`
надо восстанавливать самостоятельно. Это делает watcher-демон `S99kvas-awg-route`
(в пакете, стартует из postinst) — держит их каждые 5с. Дополнительно `100-vpn-mark`
зарегистрирован в `/opt/etc/ndm/` для нативного пересоздания на сбросах NDM-firewall.

## 3. Сборка и установка (подробно — `BUILD.md`)

- **Локально:** `./build.sh [N]` → `kvas_1.1.9_beta-10-<N>_all.ipk` (номер из `VERSION`).
- **CI:** `.github/workflows/build.yml` собирает и публикует GitHub Release при пуше тега `vN`.
- **На роутер:** `opkg install --force-reinstall`; postinst сам поднимает DNS (9753/conf-dir/DoH),
  маршрутизацию (`kvas init`) и watcher.
- **`kvas upgrade`** тянет крайний релиз из `shamanWeb/kvasec` (токен для приватного репо —
  `/opt/etc/kvas.github.token`).

postinst настраивает `/opt/etc/dnsmasq.conf` идемпотентно: `port=9753`,
`conf-dir=/opt/etc/dnsmasq.d/,*.dnsmasq`, `server=127.0.0.1#<DNS_CRYPT_PORT>`,
подключает `kvas-doh-block.dnsmasq` (глушит DoH-серверы), не затирает существующий конфиг.

## 4. Структура пакета (значимое)

```
opt/
├── bin/
│   ├── kvas                      # точка входа CLI
│   ├── libs/{main,vpn,vless,check,debug,route,tags,adblock,hosts,update,ndm_d,monitor,keen_api}
│   ├── main/{setup,upgrade,update,adblock,dnsmasq,ipset,ipset_domain,check_vpn,adguard}
│   └── monitor/                  # Web UI (socat httpd + cgi-bin/manage.sh + www/index.html)
├── etc/
│   ├── conf/{kvas.conf,kvas.list,dnsmasq.conf,kvas-doh-block.dnsmasq,adblock.sources,...}
│   ├── init.d/{S96kvas, S99kvas-awg-route(watcher), S97xray, S99adguard}
│   └── ndm/                      # хуки NDM (netfilter.d/100-vpn-mark и 100-dns-local → /opt/etc/ndm)
```
`bin/libs/ndm` генерируется postinst'ом из `etc/ndm/ndm` (несёт `RULE_PRIORITY`).

## 5. Основные команды

```
kvas setup                     # настройка после установки
kvas add domain.ru [d2 ...]    # добавить домен(ы) в список (инкрементально, тяжёлое в фон)
kvas del domain.ru             # удалить
kvas list | search <str>       # показать/искать список
kvas import <file>             # массовый импорт доменов
kvas test                      # диагностика (для opkgtun* — прямая проверка туннеля)
kvas update                    # обновить ipset/маршруты
kvas upgrade                   # обновить пакет из GitHub-релиза форка
kvas monitor web [stop]        # Web UI на :8085 (управление списком, автозапуск после ребута)
kvas vpn set vless             # переключение на VLESS
kvas route add|del full|list|exclude <IP>   # роутинг по IP/устройствам
kvas adblock on|off|add|del    # блокировка рекламы
```

## 6. Известные проблемы / статус

| Тема | Статус |
|---|---|
| DNS клиента без интернета (dnsmasq не на 9753) | ✅ решено (postinst ставит `port=9753`) |
| IP доменов не попадают в ipset (нет conf-dir) | ✅ решено (postinst) |
| `KVAS_MARK` слетает после установки/сбросов NDM | ✅ решено (postinst `kvas init` + watcher + регистрация `100-vpn-mark`) |
| Лишний флаш table 1001 / бунс тоннеля при `kvas update` | ✅ решено (правки `ndm`/`cmd_kvas_init`) |
| DoH/DoT-обход браузерами | ✅ решено (dnsmasq DoH-блок + iptables DoT 853) |
| `kvas test` ложное «ОСТАНОВЛЕНО» для opkgtun | ✅ решено (`awg_tunnel_check`) |
| Сохранность `kvas.list` при `kvas upgrade` | ✅ backup/restore в коде (не проверено live) |
| `uninstall full` может ронять интернет | ⚠️ не проверено (PRD-наследие) |
| Опечатка `fasle` в `libs/main:256` | ⚠️ НЕ править наивно (см. `NOTES.md §4`) |

## 7. Changelog (этот форк)

- **v41** — полностью удалены Hysteria и Failover; вычищены копирайты.
- **v39** — автозапуск Web UI после ребута (флаг в `/opt/etc`).
- **v37** — регистрация `100-vpn-mark` в `/opt/etc/ndm/` (нативный хил `KVAS_MARK`).
- **v36** — прямая проверка AmneziaWG-туннеля в `kvas test`.
- **v35** — блокировка DoH/DoT.
- **v34** — фикс пути `100-vpn-mark` в watcher'е.
- **v33** — watcher `S99kvas-awg-route` заведён в пакет (self-heal rule/KVAS_MARK).
- **v32** — postinst `kvas init` (маршрутизация без ручного update).
- **v31** — postinst `port=9753`.
- **v30** — postinst настройка dnsmasq.conf.
- **v28–29** — опциональная загрузка либ; upgrade из форка (последний ipk).
- **v27** — сборка/установка из репозитория (`build.sh` + CI + upgrade), RULE_PRIORITY=99,
  фикс флаша table 1001 и бунса при update, инкрементальный `kvas add`.
