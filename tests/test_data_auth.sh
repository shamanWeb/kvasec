#!/bin/sh
# Мониторинг трафика не должен отвечать до проверки токена WebUI.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
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
