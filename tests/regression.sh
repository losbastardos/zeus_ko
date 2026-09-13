#!/usr/bin/env bash
# ============================================================
# Copyright (c) 2026 Marek Suchy <marek.suchy@gmail.com>
# Vsetky prava vyhradene / All rights reserved.
# ============================================================

set -euo pipefail

cd "$(dirname "$0")/.."

backup="$(mktemp)"
cp chess.ini "$backup"
cleanup() {
    cp "$backup" chess.ini
    rm -f "$backup"
}
trap cleanup EXIT

sed -i 's/^language=.*/language=en/' chess.ini

./build.sh >/dev/null

out1="$(mktemp)"
printf '2\n\nexit\n' | ./chess >"$out1"
grep -q 'Invalid input' "$out1"
rm -f "$out1"

out2="$(mktemp)"
printf '1\n1\n2\nexit\n' | ./chess >"$out2"
grep -q 'You play: Black' "$out2"
grep -q 'h   g   f   e   d   c   b   a' "$out2"
rm -f "$out2"

echo 'regression tests passed'
