#!/bin/sh
# Регрессия: неинтерактивные подкоманды заквасок (их вызывает WebUI) и правка
# секций tags.list без порчи соседних секций.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

if command -v busybox >/dev/null 2>&1; then RUN="busybox sh"; else RUN="bash"; fi

cat > "$WORK/env.sh" <<EOS
error() { echo "ERR: \$*" >&2; }; warning() { :; }; ready() { :; }; when_ok() { :; }; print_line() { :; }
cmd_import_hosts() { cp "\$1" "$WORK/imported"; }
del_multy_hosts() { printf '%s\n' "\$1" > "$WORK/deleted"; }
. "$ROOT/opt/bin/libs/tags" 2>/dev/null
TAGS_FILE="$WORK/tags.list"
EOS

reset() {
    printf '%s\n' '[google]' 'google.com' '  gstatic.com  ' '# comment' '' '[youtube]' 'youtube.com' '[docker]' 'docker.io' > "$WORK/tags.list"
}
run() { $RUN -c ". '$WORK/env.sh'; $1"; }

# 4.4: удаление секции не трогает заголовок следующей
reset
run 'cmd_tags_delete google'
printf '%s\n' '[youtube]' 'youtube.com' '[docker]' 'docker.io' | cmp - "$WORK/tags.list"
reset
run 'cmd_tags_delete youtube'
printf '%s\n' '[google]' 'google.com' '  gstatic.com  ' '# comment' '' '[docker]' 'docker.io' | cmp - "$WORK/tags.list"
! run 'cmd_tags_delete nothere' 2>/dev/null

# удаление домена из секции — точно и только в своей секции
reset
printf '%s\n' '[a]' 'x.com' 'xycom' '[b]' 'x.com' > "$WORK/tags.list"
run '_tags_section_rewrite a deldomain x.com'
printf '%s\n' '[a]' 'xycom' '[b]' 'x.com' | cmp - "$WORK/tags.list"
! run '_tags_section_rewrite a deldomain nothere.com'

# edit-save: заменяет содержимое, соседей не трогает
reset
run 'cmd_tags_edit_save youtube yt.be youtu.be'
printf '%s\n' '[google]' 'google.com' '  gstatic.com  ' '# comment' '' '[youtube]' 'yt.be' 'youtu.be' '[docker]' 'docker.io' | cmp - "$WORK/tags.list"

# create: новый тег, дубль и плохое имя отклоняются
reset
run 'cmd_tags_create my-tag a.com b.com'
run 'get_tag_domain_list my-tag' | tr '\n' ' ' | grep -Fx 'a.com b.com ' >/dev/null
! run 'cmd_tags_create google z.com' 2>/dev/null
! run 'cmd_tags_create "a]b" z.com' 2>/dev/null

# add-protect / del-protect: домены секции без комментариев и пробелов
reset
run 'cmd_tags_add_protect google'
printf '%s\n' 'google.com' 'gstatic.com' | cmp - "$WORK/imported"
run 'cmd_tags_del_protect google'
grep -Fx 'google.com gstatic.com ' "$WORK/deleted" >/dev/null
! run 'cmd_tags_add_protect nothere' 2>/dev/null

# kvas передаёт код возврата подкоманды (раньше всегда 0 — WebUI рапортовал успех)
grep -F 'add-protect)	cmd_tags_add_protect "${3}"; _rc=$? ;;' "$ROOT/opt/bin/kvas" >/dev/null
tail -1 "$ROOT/opt/bin/kvas" | grep -Fx 'exit "${_rc:-0}"' >/dev/null
