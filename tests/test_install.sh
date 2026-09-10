#!/bin/sh
# Проверяет bootstrap-установщик без сети и роутера.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
INSTALL="$ROOT/install.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

sh -n "$INSTALL"
grep -F 'releases/latest' "$INSTALL" >/dev/null
grep -F 'wget -qO-' "$INSTALL" >/dev/null
grep -F 'kvasec_[0-9][0-9.]*\.ipk' "$INSTALL" >/dev/null
grep -F 'SHA-256 mismatch' "$INSTALL" >/dev/null
grep -F 'opkg install --force-reinstall' "$INSTALL" >/dev/null
grep -F 'KVAS_GITHUB_TOKEN' "$INSTALL" >/dev/null

# CI must publish the checksum that the bootstrap installer consumes.
grep -F 'sha256sum "kvasec_${{ steps.rel.outputs.version }}.ipk"' "$ROOT/.github/workflows/build.yml" >/dev/null
grep -F 'kvasec_${{ steps.rel.outputs.version }}.ipk.sha256' "$ROOT/.github/workflows/build.yml" >/dev/null

# A complete mock run verifies API parsing, checksum validation and the opkg
# hand-off without requiring a router or internet access.
mkdir -p "$WORK/bin" "$WORK/tmp"
printf '%s\n' '#!/bin/sh' 'echo 0' > "$WORK/bin/id"
printf '%s\n' \
  '#!/bin/sh' \
  'out=""; prev=""; for arg in "$@"; do [ "$prev" = "-o" ] && out="$arg"; prev="$arg"; done' \
  'case "$*" in' \
  '  *releases/latest*) echo '\''{"browser_download_url":"https://example.invalid/kvasec_1.2.3.ipk"}'\'' > "$out" ;;' \
  '  *.sha256*) printf "%s  kvasec_1.2.3.ipk\\n" "$(printf payload | sha256sum | awk '\''{print $1}'\'')" > "$out" ;;' \
  '  *) printf payload > "$out" ;;' \
  'esac' > "$WORK/bin/curl"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "$*" > "$TEST_OPKG_ARGS"' > "$WORK/bin/opkg"
chmod +x "$WORK/bin/id" "$WORK/bin/curl" "$WORK/bin/opkg"
TEST_OPKG_ARGS="$WORK/opkg.args" PATH="$WORK/bin:$PATH" KVAS_TMP_DIR="$WORK/tmp" sh "$INSTALL" > "$WORK/output"
grep -F 'SHA-256 verified.' "$WORK/output" >/dev/null
grep -F 'install --force-reinstall' "$WORK/opkg.args" >/dev/null
