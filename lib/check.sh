#!/bin/sh
# Stdlib gates: assemble each lib harness with the given compiler,
# run it headless, and diff console bytes against expectations.
# The same byte strings live in the harness file headers (human
# documentation); this script enforces them. Local-only: needs SDL2
# for the vendored VM, like tests/smoke.sh.
# Usage: sh lib/check.sh [path/to/etal]
# Exit nonzero with a message on the first mismatch.
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ETAL="${1:-$ROOT/build/linux-x86/etal}"
[ -x "$ETAL" ] || { echo "FAIL: not executable: $ETAL" >&2; exit 1; }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT INT TERM

fail() { echo "FAIL: $1" >&2; exit 1; }

# check <harness> <expected-lowercase-hex>
check() {
  name=$1
  want=$2
  "$ETAL" -r "$ROOT/lib/$name.ux" -o "$TMPD/$name.rom" \
    || fail "$name: assembly failed"
  got=$(SDL_VIDEODRIVER=dummy "$ROOT/vendor/linux-x86_64/uxn2" "$TMPD/$name.rom" \
    | od -A n -t x1 | tr -d ' \n')
  [ "$got" = "$want" ] || fail "$name: got $got want $want"
  echo "$name ok"
}

check test_u32 31303131303131303131303439
check test_fix16 010006000040fe00060000027fff001a00800180004001000355fe8000557fff000003000100ff0000000200010002007fffff0000000100fe00010080010200ff0001007fff00000001ffff0002ffff05007f007fff
