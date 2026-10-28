# Единственная поддерживаемая упаковка KVAS находится в build.sh.
#
# Этот Makefile намеренно не содержит старый OpenWrt/molot-SDK recipe: тот
# дублировал metadata, postinst и раскладку файлов, из-за чего IPK из `make`
# отличался от IPK из `./build.sh`. Оставлен как удобная совместимая точка входа.

VERSION := $(strip $(shell tr -d '[:space:]' < VERSION))

.PHONY: all build ipk test verify lint help

all build ipk:
	./build.sh $(VERSION)

test:
	./tests/run.sh

# Быстрая локальная проверка скриптов и конфигурации workflow без публикации.
verify:
	sh -n build.sh install.sh opt/bin/main/upgrade opt/bin/monitor/adguard_querylog.sh opt/bin/monitor/bypass_check.sh opt/bin/monitor/block_watch.sh opt/bin/monitor/www/cgi-bin/manage.sh opt/bin/monitor/www/cgi-bin/data.sh
	python3 -c 'import yaml; yaml.safe_load(open(".github/workflows/build.yml", encoding="utf-8")); print("workflow YAML: OK")'

# Статический анализ shell-скриптов. Общие правила — в .shellcheckrc.
# ROUTER_SCRIPTS исполняются BusyBox ash на роутере → диалект busybox (нужен shellcheck >= 0.10);
# HOST_SCRIPTS — на ПК/CI → диалект по shebang. По умолчанию warning; style — строже.
LINT_SEVERITY ?= warning
SH_SHEBANG = '^\#!.*/(env )?(ba|a)?sh'
ROUTER_SCRIPTS = install.sh $(shell grep -rlE $(SH_SHEBANG) opt 2>/dev/null)
HOST_SCRIPTS = build.sh $(shell grep -rlE $(SH_SHEBANG) tests 2>/dev/null)

lint:
	@v=$$(shellcheck --version 2>/dev/null | sed -n 's/^version: //p'); \
	if [ -z "$$v" ] || [ "$$(printf '%s\n' 0.10.0 "$$v" | sort -V | head -1)" != 0.10.0 ]; then \
		echo "нужен shellcheck >= 0.10 (сейчас: $${v:-не установлен}); в Ubuntu 24.04 apt даёт 0.9 —" >&2; \
		echo "возьмите релиз с https://github.com/koalaman/shellcheck/releases" >&2; exit 1; \
	fi
	shellcheck -S $(LINT_SEVERITY) -s busybox $(ROUTER_SCRIPTS)
	shellcheck -S $(LINT_SEVERITY) $(HOST_SCRIPTS)

help:
	@echo "make build   — собрать kvasec_$(VERSION).ipk"
	@echo "make test    — запустить регрессионные тесты без роутера"
	@echo "make verify  — проверить shell-синтаксис и workflow YAML"
	@echo "make lint    — shellcheck по всем sh-скриптам (LINT_SEVERITY=error|warning|style)"
