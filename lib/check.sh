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

# check_cwd <harness> <expected-lowercase-hex> <stray-file>
# Like check, but runs the ROM with CWD inside TMPD (the File device
# resolves paths against the emulator's working directory), then
# asserts the harness cleaned up its stray file.
check_cwd() {
  name=$1
  want=$2
  stray=$3
  "$ETAL" -r "$ROOT/lib/$name.ux" -o "$TMPD/$name.rom" \
    || fail "$name: assembly failed"
  got=$(cd "$TMPD" && SDL_VIDEODRIVER=dummy "$ROOT/vendor/linux-x86_64/uxn2" "$TMPD/$name.rom" \
    | od -A n -t x1 | tr -d ' \n')
  [ "$got" = "$want" ] || fail "$name: got $got want $want"
  [ ! -e "$TMPD/$stray" ] || fail "$name: stray file left behind: $stray"
  echo "$name ok"
}

check test_u32 31303131303131303131303439
check test_song 3c437f7f3e7f7f433c7f7f7f3e437f7f
check test_struct 0b212c37424d2c580a
check test_fix16 010006000040fe00060000027fff001a00800180004001000355fe8000557fff000003000100ff0000000200010002007fffff0000000100fe00010080010200ff0001007fff00000001ffff0002ffff05007f007fff
check test_screen 00a00090006400c8012c
check test_object 00000001000b00153030303131313000000000
check test_anim 006400c800c8012c012c006400160021002100000021003700420037002c003700640064000000c80001
check test_scene 0000000200100000002000010000000200050002000700050005000700020005
check test_trig 0000006200b500ec01010000010100b500b50101000000b5ff4b0000feffff4bff4bfeff0000ff4b00b5
check_cwd test_file 0a04303030610a30313233343536373839010a010121 etalfilet.bin
check test_font 3f3f20417e3f3f08f0
check test_mouse 0100020000010403
check test_assert 41

# check_brk <harness> <line> <col>: the ROM must print
# `assert failed at <path>:<line>:<col>` and then idle (BRK never
# exits). Runs headless in the background, kills after a beat,
# and builds the expected bytes from its own path (locations are
# absolute). POSIX sleep/kill only — no GNU timeout.
check_brk() {
  name=$1
  line=$2
  col=$3
  "$ETAL" -r "$ROOT/lib/$name.ux" -o "$TMPD/$name.rom" \
    || fail "$name: assembly failed"
  SDL_VIDEODRIVER=dummy "$ROOT/vendor/linux-x86_64/uxn2" "$TMPD/$name.rom" \
    > "$TMPD/$name.out" 2>&1 &
  pid=$!
  sleep 1
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  got=$(od -A n -t x1 "$TMPD/$name.out" | tr -d ' \n')
  want=$(printf 'assert failed at %s/lib/%s.ux:%s:%s\n' "$ROOT" "$name" "$line" "$col" \
    | od -A n -t x1 | tr -d ' \n')
  [ "$got" = "$want" ] || fail "$name: got $got want $want"
  echo "$name ok"
}
check_brk test_assert_fail 5 5
check test_gfx3d 0680068079800680068079807980798029e029e0562029e029e056205620562029e029e00680068029e0562006807980562029e0798006805620562079807980fe121f09400066c91db6512540007eb940000fc981ee1f0940003ab2624a5125
