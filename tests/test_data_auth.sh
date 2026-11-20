#!/bin/sh
# Мониторинг трафика не должен отвечать до проверки токена WebUI.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/opt/bin/monitor/www/cgi-bin/data.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

mkdir -p "$WORK/tokens"
sed "s|^TOKEN_DIR=.*|TOKEN_DIR=$WORK/tokens|" "$SOURCE" > "$WORK/data.sh"

QUERY_STRING='action=status' sh "$WORK/data.sh" | grep -F 'auth required' >/dev/null
token=0123456789abcdef0123456789abcdef
date +%s > "$WORK/tokens/$token"
QUERY_STRING="action=status&token=$token" sh "$WORK/data.sh" | grep -F '"socat":' >/dev/null
QUERY_STRING='action=status' HTTP_X_KVAS_TOKEN="$token" sh "$WORK/data.sh" | grep -F '"socat":' >/dev/null

# Параметры фильтра идут в grep -E / аргументы conntrack — только ожидаемые символы.
data() { QUERY_STRING="action=data&token=$token&$1" sh "$WORK/data.sh"; }
data 'ips=1.2.3.4|.*' | grep -F 'invalid ips' >/dev/null
data 'ips=1.2.3.4&port=53|.*' | grep -F 'invalid port' >/dev/null
data 'ips=1.2.3.4&proto=-L' | grep -F 'invalid proto' >/dev/null
data 'ips=1.2.3.4,5.6.7.8&port=443&proto=tcp&conntrack=0' | grep -F '"connections":' >/dev/null
# без ips — прежний ответ «no ips specified», а не «invalid ips»
QUERY_STRING="action=data&token=$token" sh "$WORK/data.sh" | grep -F 'no ips specified' >/dev/null
