# Сборка и установка из этого репозитория (Linux)

Этот форк собирается и ставится **напрямую из репозитория**, без Windows-папки и molot-SDK
(старый путь через Windows/molot-SDK удалён из репозитория).

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
- **автоматически:** каждый merge/push в `master` собирает IPK и публикует новую
  GitHub Release; номер = `max(VERSION, предыдущий release + 1)`;
- **вручную:** Actions → `build-and-release` → Run workflow, поле `release` = номер;
- **или** пуш тега `v27` (номер берётся из хвоста тега).

Он запускает `build.sh` и публикует ipk как Release с тегом `v1.1.9_beta-10-<N>` (make_latest).

### Пошагово: публикация нового релиза
`N` — новый номер (напр. `46`).

```sh
# 1. рабочее дерево чистое, всё закоммичено
git status --short

# 2. bump версии
printf '46\n' > VERSION
git add VERSION
git commit -m "chore: bump VERSION 45→46 (<что в релизе>)"

# 3. тег vN (только триггер CI)
git tag v46

# 4. пуш ветки + тега
git push origin build-from-repo
git push origin v46          # push тега запускает сборку
```

Дальше автоматически: CI берёт номер из хвоста тега (`v46 → 46`) → `./build.sh 46` →
публикует Release `v1.1.9_beta-10-46` (latest) → `kvas upgrade` видит его в `/releases/latest`.

Проверка после пуша:
```sh
curl -s "https://api.github.com/repos/shamanWeb/kvasec/actions/runs?per_page=1" | grep -E '"status"|"conclusion"'
curl -s "https://api.github.com/repos/shamanWeb/kvasec/releases/latest"      | grep -E '"tag_name"|"browser_download_url"'
```

Нюансы:
- **Тег `vN` — только триггер;** сам релиз выходит под именем `v1.1.9_beta-10-N`. Не путать.
- **Номер должен расти** — `upgrade` (фикс v43) не даунгрейдит: если в релизе `≤` установленного, скажет «Квас все еще свеж».
- **VERSION bump необязателен для CI** (номер идёт из тега аргументом в `build.sh`), но держим в синхроне — гигиена + fallback для локального `./build.sh` без аргумента.
- **Обычный релиз:** достаточно merge в `master`; тег вручную не нужен. CI сам выберет
  номер выше последнего опубликованного, поэтому `kvas upgrade` на роутере увидит обновление.
- **Без merge и тега:** Actions → `build-and-release` → Run workflow, ввести номер вручную (`workflow_dispatch`).
- **На боевой роутер** ставить новый ipk через `opkg install --force-reinstall` вживую, НЕ `kvas upgrade` в фоне/не-интерактивно (риск даунгрейда/зависания, был инцидент с DNS).

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
