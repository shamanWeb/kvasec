#!/bin/sh
# Проверяет фактические helper-функции updater для старого и нового имени IPK.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UPGRADE="$ROOT/opt/bin/main/upgrade"

# The legacy cleanup scanned the entire router filesystem and was unused.
if grep -q '^rm_tmp_cache(){' "$UPGRADE" || grep -Eq '^[[:space:]]*find[[:space:]]+/' "$UPGRADE" || grep -Fq 'xargs rm -rf' "$UPGRADE"; then
    echo 'unsafe legacy cleanup remains in upgrade' >&2
    exit 1
fi

FUNCTIONS=$(sed -n '/^get_package_name(){/,/^select_release_from_list(){/{ /^select_release_from_list(){/!p }' "$UPGRADE")

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
