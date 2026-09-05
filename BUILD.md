# Сборка и установка из этого репозитория (Linux)

Этот форк собирается и ставится **напрямую из репозитория**, без Windows-папки и molot-SDK
(старый путь через `build_fixed.ps1` / `builder/` — см. `PRD.md`, оставлен для истории).

Собирается **core как есть**: ядро kvas + vless + adblock + селективный роутинг.
Hysteria и failover полностью удалены из проекта.

---

## 1. Локальная сборка ipk

```sh
./build.sh            # номер релиза берётся из файла VERSION
./build.sh 27         # или явным аргументом
```

Результат — `kvas_1.1.9_beta-10-<N>_all.ipk` в корне репозитория.

Формат идентичен отгружаемым релизам: `gzip(tar( debian-binary + control.tar.gz + data.tar.gz ))`.
Всё дерево `opt/` кладётся в `/opt/apps/kvas/`, плюс системные точки входа
(`S96kvas`, `15-kvas-start.sh`, `100-dns-local`) дублируются в `/opt/etc/`.

**Важно:** `bin/libs/ndm` в репозитории нет — он генерируется `postinst` из `etc/ndm/ndm`
(поэтому правка `RULE_PRIORITY=99` в `etc/ndm/ndm` автоматически попадает в рантайм-хук).

## 2. Установка на роутер вручную

```sh
scp kvas_1.1.9_beta-10-*.ipk root@192.168.1.1:/opt/tmp/     # при 222-м порту: scp -P 222 -i ~/.ssh/id_ed25519 ...
ssh root@192.168.1.1 'opkg install --force-reinstall /opt/tmp/kvas_1.1.9_beta-10-*.ipk'
# затем на роутере:
kvas setup          # или перезагрузка роутера, чтобы применились ndm-хуки
```

Конфиг `/opt/etc/kvas.conf` при переустановке **не затирается** (засевается только при первой установке).

## 3. `kvas upgrade` из форка (GitHub Release)

`kvas upgrade` тянет крайний релиз из `github.com/shamanWeb/kvasec`
(`opt/bin/main/upgrade` → `release_url`).

### CI: сборка и публикация релиза
Workflow `.github/workflows/build.yml`:
- **вручную:** Actions → `build-and-release` → Run workflow, поле `release` = номер;
- **или** пуш тега `v27` (номер берётся из хвоста тега).

Он запускает `build.sh` и публикует ipk как Release с тегом `v1.1.9_beta-10-<N>` (make_latest).

### Приватный репозиторий → нужен токен на роутере
Т.к. репозиторий приватный, `kvas upgrade` не увидит релизы без авторизации. Положите на роутер
fine-grained PAT (права **Contents: read** на `shamanWeb/kvasec`) одной строкой:

```sh
echo 'github_pat_XXXX' > /opt/etc/kvas.github.token
chmod 600 /opt/etc/kvas.github.token
```

`upgrade` подхватит его (заголовок `Authorization: Bearer …`, загрузка ассета через octet-stream).
Без файла токена команда работает только если релизы публичные.
> Альтернатива без токенов на роутерах: публиковать ipk в отдельный **публичный** repo и указать его в `release_url`.

## 4. Версионирование
`build.sh` и CI берут номер из файла `VERSION` (либо из аргумента / хвоста тега).
Поднимайте номер в `VERSION` перед каждым релизом — иначе `kvas upgrade` посчитает,
что «обновлений нет» (сравнение по `APP_VERSION`/`APP_RELEASE`).
