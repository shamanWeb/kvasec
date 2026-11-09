#!/bin/sh
# Проверяет фактические helper-функции updater для старого и нового имени IPK.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
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

# verify_package must reject an HTTP error page saved as .ipk (GitHub 504 once
# made upgrade uninstall the working package) and a checksum mismatch, and
# accept a real ipk-shaped archive with a matching sha256.
VERIFY=$(sed -n '/^verify_package(){/,/^}/p' "$UPGRADE")
VT=$(mktemp -d); trap 'rm -rf "$VT"' EXIT
printf '<html><body><h1>504 Gateway Time-out</h1></body></html>\n' >"$VT/bad.ipk"
mkdir "$VT/pkg"; echo 2.0 >"$VT/pkg/debian-binary"
tar -czf "$VT/pkg/data.tar.gz" -C "$VT/pkg" debian-binary
tar -czf "$VT/good.ipk" -C "$VT/pkg" ./debian-binary ./data.tar.gz
GOOD_SUM=$(sha256sum "$VT/good.ipk" | cut -d' ' -f1)
run_verify() {  # $1 = ipk, $2 = checksum served by the "release" ('' = no .sha256 asset)
    SUM="$2" sh -c "package_url=x
gh_download(){ [ -n \"\$SUM\" ] && echo \"\$SUM  f\" >\"\$2\"; }
$VERIFY
verify_package \"\$1\"" _ "$1"
}
run_verify "$VT/bad.ipk" '' && exit 1
run_verify "$VT/good.ipk" deadbeef && exit 1
run_verify "$VT/good.ipk" "$GOOD_SUM"
run_verify "$VT/good.ipk" ''
exit 0
