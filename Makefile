# Единственная поддерживаемая упаковка KVAS находится в build.sh.
#
# Этот Makefile намеренно не содержит старый OpenWrt/molot-SDK recipe: тот
# дублировал metadata, postinst и раскладку файлов, из-за чего IPK из `make`
# отличался от IPK из `./build.sh`. Оставлен как удобная совместимая точка входа.

VERSION := $(strip $(shell tr -d '[:space:]' < VERSION))

.PHONY: all build ipk test verify help

all build ipk:
	./build.sh $(VERSION)

test:
	./tests/run.sh

# Быстрая локальная проверка скриптов и конфигурации workflow без публикации.
verify:
	sh -n build.sh install.sh opt/bin/main/upgrade opt/bin/monitor/adguard_querylog.sh opt/bin/monitor/bypass_check.sh opt/bin/monitor/block_watch.sh opt/bin/monitor/www/cgi-bin/manage.sh opt/bin/monitor/www/cgi-bin/data.sh
	python3 -c 'import yaml; yaml.safe_load(open(".github/workflows/build.yml", encoding="utf-8")); print("workflow YAML: OK")'

help:
	@echo "make build   — собрать kvasec_$(VERSION).ipk"
	@echo "make test    — запустить регрессионные тесты без роутера"
	@echo "make verify  — проверить shell-синтаксис и workflow YAML"
