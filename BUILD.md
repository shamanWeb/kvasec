# Сборка и установка из этого репозитория (Linux)

Этот форк собирается и ставится **напрямую из репозитория**, без Windows-папки и molot-SDK
(старый путь через Windows/molot-SDK удалён из репозитория).

Собирается **core как есть**: ядро kvas + vless + adblock + селективный роутинг.
Hysteria и failover полностью удалены из проекта.

---

## 1. Локальная сборка ipk

```sh
./build.sh            # версия MAJOR.MINOR.PATCH берётся из файла VERSION
./build.sh 1.2.0      # или явным аргументом
make build            # эквивалент ./build.sh $$(cat VERSION)
```

Результат — `kvasec_<MAJOR.MINOR.PATCH>.ipk` в корне репозитория. Внутреннее имя
пакета в opkg остаётся `kvas`, поэтому существующие команда `kvas` и установки обновляются
без переименования.

`build.sh` — единственный поддерживаемый упаковщик. `Makefile` оставлен только как
обёртка для `make build`/`make ipk`, поэтому оба способа создают идентичный IPK.
Если WebUI был включён до обновления, postinst перезапускает его, чтобы новый HTTP-handler
применился сразу, а не после ручного `kvas monitor web stop`/`web`.

Перед merge запускайте:

```sh
make test
```

Тесты не требуют роутера: они проверяют SemVer/IPK-сборку, миграционный parser updater
и защитные свойства HTTP-handler. Workflow запускает их перед публикацией Release.

Формат идентичен отгружаемым релизам: `gzip(tar( debian-binary + control.tar.gz + data.tar.gz ))`.
Всё дерево `opt/` кладётся в `/opt/apps/kvas/`, плюс системные точки входа
(`S96kvas`, `15-kvas-start.sh`, `100-dns-local`) дублируются в `/opt/etc/`.

**Важно:** `bin/libs/ndm` в репозитории нет — он генерируется `postinst` из `etc/ndm/ndm`
(поэтому правка `RULE_PRIORITY=99` в `etc/ndm/ndm` автоматически попадает в рантайм-хук).

## 2. Установка на роутер вручную

```sh
scp kvasec_*.ipk root@192.168.1.1:/opt/tmp/     # при 222-м порту: scp -P 222 -i ~/.ssh/id_ed25519 ...
ssh root@192.168.1.1 'opkg install --force-reinstall /opt/tmp/kvasec_*.ipk'
# затем на роутере:
kvas setup          # или перезагрузка роутера, чтобы применились ndm-хуки
```

Конфиг `/opt/etc/kvas.conf` при переустановке **не затирается** (засевается только при первой установке).

## 3. `kvas upgrade` из форка (GitHub Release)

`kvas upgrade` тянет крайний релиз из `github.com/shamanWeb/kvasec`
(`opt/bin/main/upgrade` → `release_url`).

### CI: сборка и публикация релиза
Workflow `.github/workflows/build.yml`:
- **автоматически:** первый merge после миграции публикует `1.2.0`, затем каждый merge/push
  в `master` увеличивает PATCH (`1.2.1`, `1.2.2`, …);
- **вручную:** Actions → `build-and-release` → Run workflow, поле `version` в формате
  `MAJOR.MINOR.PATCH`;
- **или** пуш тега `v1.2.0`.

Он запускает `build.sh` и публикует `kvasec_<version>.ipk` как Release с тегом
`v<version>` (make_latest).

### Обычный релиз: merge в `master`

Это основной путь публикации. После `1.2.0` CI увеличивает PATCH при каждом merge.
Чтобы начать новую MINOR/MAJOR-линию, предварительно задайте в `VERSION` версию больше
последней опубликованной (например, `1.3.0`); следующий merge выпустит именно её.

```sh
# 1. рабочее дерево чистое, изменения закоммичены
git status --short

# 2. merge PR в master либо запушьте подготовленный commit
git push origin master
```

Дальше CI вычисляет SemVer → запускает `./build.sh <version>` → публикует Release
`v<version>` с файлом `kvasec_<version>.ipk` как `latest`. `kvas upgrade` видит его
через `/releases/latest`.

Проверка после пуша:
```sh
curl -s "https://api.github.com/repos/shamanWeb/kvasec/actions/runs?per_page=1" | grep -E '"status"|"conclusion"'
curl -s "https://api.github.com/repos/shamanWeb/kvasec/releases/latest"      | grep -E '"tag_name"|"browser_download_url"'
```

Нюансы:
- **Тег `vX.Y.Z` — альтернативный ручной триггер;** не используйте его для обычного merge
  в `master`.
- **Версия должна расти** — `upgrade` не ставит SemVer-версию, меньшую либо равную установленной.
- **VERSION** — стартовая SemVer и версия по умолчанию для локального `./build.sh`; CI
  автоматически увеличивает PATCH после последнего SemVer-release.
- **Без merge и тега:** Actions → `build-and-release` → Run workflow, ввести номер вручную (`workflow_dispatch`).
- **Из WebUI:** кнопка «Установить обновление» запускает защищённый POST-запрос и выполняет
  `kvas upgrade` в фоне. После установки WebUI сам перезапускается; обновите страницу через
  несколько секунд. Журнал updater: `/tmp/kvas-web-upgrade.log`.

### Публичный репозиторий

Репозиторий `shamanWeb/kvasec` и его Releases публичные, поэтому `kvas upgrade` и
`install.sh` не требуют токен GitHub.

Поддержка `/opt/etc/kvas.github.token` в updater остаётся только для тех, кто использует
свой приватный fork: fine-grained PAT должен иметь право **Contents: read**, а файл — права `600`.

## 4. Версионирование
`build.sh` принимает только SemVer `MAJOR.MINOR.PATCH` из `VERSION` либо аргумента.
Для merge в `master` CI после первой публикации автоматически увеличивает PATCH. Для ручного
workflow и тегов версия задаётся явно. `kvas upgrade` сравнивает SemVer из `APP_VERSION` и
не ставит пакет с версией, меньшей либо равной установленной. Старые установки
`1.1.9_beta-10-N` корректно распознаются как `1.1.9` и обновляются до `1.2.0`.
