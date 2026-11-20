#!/bin/sh
# Регрессия: adblock add и hosts del сравнивают домены/IP точно, а не подстрокой.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# libs используют ${var//x/} (ash/bash) — как на роутере
if command -v busybox >/dev/null 2>&1; then RUN="busybox sh"; else RUN="bash"; fi

extract() { sed -n "/^$2(){/,/^}/p" "$ROOT/opt/bin/libs/$1"; }

cat > "$WORK/stubs.sh" <<EOS
exit_when_adguard_on() { eval "\$1=0"; }
ready() { :; }; when_ok() { :; }; when_bad() { :; }; warning() { :; }; error() { :; }; print_line() { :; }
restart_dns_service() { :; }
dns_server_restart() { echo "\$1" > "$WORK/restarted"; }
ADBLOCK_BLOCK_FILE="$WORK/block.list"
ADBLOCK_HOSTS_FILE="$WORK/ads.list"
ADBLOCK_LIST_EXCEPTION="$WORK/exception.list"
HOSTS_FILE="$WORK/hosts"
EOS
{ cat "$WORK/stubs.sh"
  extract adblock cmd_ads_add_host | sed "s|/opt/apps/kvas/bin/main/parental_dns|true|"
  extract hosts cmd_hosts_one_del
} > "$WORK/lib.sh"

# adblock add ya.ru: "0.0.0.0 ya.ru.example" — не он; исключения xvk.com/notya.ru не трогаем
printf '%s\n' '0.0.0.0 ya.ru.example' > "$WORK/ads.list"
printf '%s\n' 'ya.ru' 'mail.ya.ru' 'notya.ru' 'xvk.com' > "$WORK/exception.list"
: > "$WORK/block.list"
$RUN -c ". '$WORK/lib.sh'; cmd_ads_add_host ya.ru"
grep -qx '0.0.0.0 ya.ru' "$WORK/ads.list" || { echo 'FAIL: ya.ru не добавлен в ads.list'; exit 1; }
printf '%s\n' 'notya.ru' 'xvk.com' | cmp - "$WORK/exception.list" || { echo 'FAIL: exception.list'; exit 1; }
# повторный add не дублирует запись
$RUN -c ". '$WORK/lib.sh'; cmd_ads_add_host ya.ru"
[ "$(grep -cx '0.0.0.0 ya.ru' "$WORK/ads.list")" -eq 1 ] || { echo 'FAIL: дубль в ads.list'; exit 1; }

# hosts del 1.1.1.1 не трогает 1.1.1.10 и 1x1x1x1; перезапускает DNS
printf '%s\n' '1.1.1.1 one.example' '1.1.1.10 ten.example' '9.9.9.9 1x1x1x1.example' > "$WORK/hosts"
$RUN -c ". '$WORK/lib.sh'; cmd_hosts_one_del 1.1.1.1"
printf '%s\n' '1.1.1.10 ten.example' '9.9.9.9 1x1x1x1.example' | cmp - "$WORK/hosts" || { echo 'FAIL: hosts del'; exit 1; }
grep -qx '1.1.1.1' "$WORK/restarted" || { echo 'FAIL: DNS не перезапущен'; exit 1; }
$RUN -c ". '$WORK/lib.sh'; cmd_hosts_one_del ten.example"
printf '%s\n' '9.9.9.9 1x1x1x1.example' | cmp - "$WORK/hosts" || { echo 'FAIL: hosts del by name'; exit 1; }
