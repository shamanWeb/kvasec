#!/bin/sh
# Запускает все локальные регрессионные тесты без роутера.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

for test_file in "$ROOT"/tests/test_*.sh; do
    [ -f "$test_file" ] || continue
    echo "==> $(basename "$test_file")"
    sh "$test_file"
done

echo "==> all tests passed"
