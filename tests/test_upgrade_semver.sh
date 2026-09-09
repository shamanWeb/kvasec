#!/bin/sh
# Проверяет фактические helper-функции updater для старого и нового имени IPK.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UPGRADE="$ROOT/opt/bin/main/upgrade"

FUNCTIONS=$(sed -n '/^get_package_name(){/,/^rm_tmp_cache(){/{ /^rm_tmp_cache(){/!p }' "$UPGRADE")

result=$(sh -c "$FUNCTIONS
printf '%s|%s|%s|%s\\n' \\
  \"\$(get_package_version kvasec_1.2.0.ipk)\" \\
  \"\$(get_package_version kvas_1.1.9_beta-10-44_all.ipk)\" \\
  \"\$(version_key 1.2.0)\" \\
  \"\$(version_key 1.2.17)\"")

[ "$result" = '1.2.0|1.1.9|1002000|1002017' ] || {
    echo "unexpected SemVer parser result: $result" >&2
    exit 1
}
