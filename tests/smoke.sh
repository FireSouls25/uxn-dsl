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
# file() assets resolve against the declaring file, so the fixture's
# .wav travels with it (same reason a moved project keeps building).
cp "$ROOT/tests/blip.wav" "$SMOKEDIR/"

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

# 3. Web target must resolve vendor/uxn5 AND ship the two things the
#    page needs that uxn5 does not have: the Audio device (upstream
#    uxn5 has none, so every note write went nowhere) and the
#    window-size controls (upstream opens at a fixed 2x). Asserted
#    from OUTSIDE the repo, so web/ has to be found by the same
#    exe-relative walk-up as vendor/.
"$ETAL" --target web "$SMOKEDIR/ci.ux" -o "$SMOKEDIR/c.html" \
  || fail "etal --target web failed (uxn5 not resolved?)"
[ -s "$SMOKEDIR/c.html" ] || fail "empty html output"

# 3a. Audio: the device, the 0x30-0x60 routing, the gesture unlock, and
#     the main-RAM exposure the renderer reads samples through.
grep -q 'function Audio(emu)' "$SMOKEDIR/c.html" \
  || fail "web bundle has no Audio device (uxn5 ships none; web/audio.js not embedded?)"
grep -q 'emulator.audio = new Audio(emulator)' "$SMOKEDIR/c.html" \
  || fail "web bundle does not instantiate the Audio device"
grep -q '(port & 0xf0) >= 0x30 && (port & 0xf0) <= 0x60' "$SMOKEDIR/c.html" \
  || fail "web bundle does not route the four Varvara voice pages to Audio"
grep -q 'this.mem = new Uint8Array(0x10000)' "$SMOKEDIR/c.html" \
  || fail "web bundle does not expose main RAM for sample playback"
grep -q 'emulator.audio.unlock()' "$SMOKEDIR/c.html" \
  || fail "web bundle never resumes the AudioContext on a gesture"
echo "web audio ok"

# 3b. Window size: all five modes present, and fit is the default.
for mode in fit 1 2 3 full; do
  grep -q "data-mode=\"$mode\"" "$SMOKEDIR/c.html" \
    || fail "web bundle missing size control '$mode'"
done
grep -q 'const ETAL_VIEW = "fit"' "$SMOKEDIR/c.html" \
  || fail "web bundle does not default to fit-to-display"
echo "web sizing ok"

# 3c. The step-budget patch must survive alongside the ram patch.
grep -q 'let steps = 0x800000' "$SMOKEDIR/c.html" \
  || fail "web bundle lost the uxn5 step-budget patch"

# 3d. --scale chooses the starting mode; an unknown value is refused.
"$ETAL" --target web --scale full "$SMOKEDIR/ci.ux" -o "$SMOKEDIR/full.html" \
  || fail "etal --target web --scale full failed"
grep -q 'const ETAL_VIEW = "full"' "$SMOKEDIR/full.html" \
  || fail "--scale full did not reach the page"
if "$ETAL" --target web --scale 7 "$SMOKEDIR/ci.ux" -o "$SMOKEDIR/bad.html" 2>/dev/null; then
  fail "etal accepted an unknown --scale value"
fi
echo "web scale flag ok"

# 3e. The HTML must be byte-identical across runs, same determinism
#     contract as the ROM. Same basename in two directories: the page
#     title embeds the output filename, so differing names would
#     differ legitimately.
mkdir -p "$SMOKEDIR/r1" "$SMOKEDIR/r2"
"$ETAL" --target web "$SMOKEDIR/ci.ux" -o "$SMOKEDIR/r1/same.html" \
  || fail "second etal --target web failed"
"$ETAL" --target web "$SMOKEDIR/ci.ux" -o "$SMOKEDIR/r2/same.html" \
  || fail "third etal --target web failed"
cmp "$SMOKEDIR/r1/same.html" "$SMOKEDIR/r2/same.html" \
  || fail "non-deterministic web bundle"

echo "web target ok"

echo SMOKE-OK
