#!/bin/sh
# Assembler smoke gate for the etal compiler + vendor/ tree pairing.
# Asserts, from OUTSIDE the repo (so only exe-relative vendor/
# resolution can save it — no CWD fallback):
#   1. `etal -r` assembles a ROM via the vendored uxn2 + drifblim.rom
#   2. two runs are byte-identical (deterministic assembly)
#   3. `--target web` resolves the vendored uxn5 emulator
# Local-only: the vendored VM links SDL2 dynamically and stock CI
# runners don't have it (same reason as tests/portability.sh).
# Usage: sh tests/smoke.sh [path/to/etal]
# Exit nonzero with a message on the first violation.
set -e

ROOT=$(dirname "$0")/..
ETAL="${1:-$ROOT/build/linux-x86/etal}"
[ -x "$ETAL" ] || { echo "FAIL: not executable: $ETAL" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

SMOKEDIR=$(mktemp -d)
trap 'rm -rf "$SMOKEDIR"' EXIT INT TERM
cp "$ROOT/tests/ci.ux" "$ROOT/tests/ci_lib.ux" "$SMOKEDIR/"

# 1+2. Assemble twice from outside the repo; outputs must be
# non-empty and byte-identical.
"$ETAL" -r "$SMOKEDIR/ci.ux" -o "$SMOKEDIR/a.rom" \
  || fail "etal -r failed (uxn2/drifblim not resolved?)"
[ -s "$SMOKEDIR/a.rom" ] || fail "empty ROM output"
"$ETAL" -r "$SMOKEDIR/ci.ux" -o "$SMOKEDIR/b.rom" \
  || fail "second etal -r failed"
cmp "$SMOKEDIR/a.rom" "$SMOKEDIR/b.rom" \
  || fail "non-deterministic assembly"
echo "assembly ok + deterministic: $(wc -c < "$SMOKEDIR/a.rom") bytes"

# 3. Web target must resolve vendor/uxn5.
"$ETAL" --target web "$SMOKEDIR/ci.ux" -o "$SMOKEDIR/c.html" \
  || fail "etal --target web failed (uxn5 not resolved?)"
[ -s "$SMOKEDIR/c.html" ] || fail "empty html output"
echo "web target ok"

echo SMOKE-OK
