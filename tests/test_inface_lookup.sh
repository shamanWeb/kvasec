#!/bin/sh
# Регрессия: поиск интерфейса в inface_equals — по точному имени, не подстроке
# (opkgtun1 совпадал с opkgtun10, пустое имя — со всем файлом).
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

printf '%s\n' 'Wireguard10|opkgtun10|AWG-10' 'Wireguard1|opkgtun1|AWG-1' > "$WORK/ifeq"
{ echo "INFACE_NAMES_FILE='$WORK/ifeq'"; sed -n '/^inface_field() {/,/^}/p' "$ROOT/opt/bin/libs/main"; } > "$WORK/lib.sh"

for impl in sh "busybox sh"; do
    [ "$impl" = sh ] || command -v busybox >/dev/null 2>&1 || continue
    out=$($impl -c ". '$WORK/lib.sh'
        printf '%s;' \"\$(inface_field opkgtun1 1)\" \"\$(inface_field opkgtun10 1)\" \"\$(inface_field opkgtun1 3)\"
        inface_field '' 1 || printf 'empty-rejected'")
    [ "$out" = "Wireguard1;Wireguard10;AWG-1;empty-rejected" ] || { echo "FAIL [$impl]: $out"; exit 1; }
done

# Хук, который генерирует libs/vpn (heredoc): синтаксис и точное сравнение по $1.
hook=$(sed -n '/^\t\tcat <<EOF >"${HOOK_INFACE_FILE}"$/,/^EOF$/p' "$ROOT/opt/bin/libs/vpn" | sed '1d;$d')
export INFACE_NAMES_FILE="$WORK/ifeq"   # нужен eval-heredoc ниже
eval "cat <<EOF >\"$WORK/hook.sh\"
$hook
EOF"
sh -n "$WORK/hook.sh"
id=Wireguard1 system_name=opkgtun1 sh "$WORK/hook.sh"          # уже есть — не дублирует
id=Wireguard2 system_name=opkgtun2 sh "$WORK/hook.sh"          # нет — добавляет
printf '%s\n' 'Wireguard10|opkgtun10|AWG-10' 'Wireguard1|opkgtun1|AWG-1' 'Wireguard2|opkgtun2' | cmp - "$WORK/ifeq"
