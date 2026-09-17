#!/bin/sh
# Headless-graphics gate for chess: real pixels from the vendored uxn5
# core (no browser), covering render, input vectors, both move glides,
# stack stability, and quit-by-state. Complements check.sh (console
# bytes) the way eyeballs complement unit tests.
# Local-only: needs node (PATH or nix) plus ImageMagick for the PNG
# eyeball copies (PPMs are always written); stock CI runners have
# neither, same reason as tests/check.sh's SDL2 gate.
# Usage: sh tests/pixels.sh [path/to/etal]
# Exit nonzero with a message on the first violation. Shots land in
# tests/pixels/out/ (gitignored).
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ETAL="${1:-$ROOT/build/linux-x86/etal}"
# Resolve a relative etal path now: the build below cds into
# examples/chess, which would break it.
case "$ETAL" in
/*) ;;
*) ETAL="$(pwd)/$ETAL" ;;
esac
[ -x "$ETAL" ] || { echo "FAIL: not executable: $ETAL" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

if command -v node >/dev/null 2>&1; then
  NODE="node"
elif command -v nix >/dev/null 2>&1; then
  echo "(no node in PATH; using nix-provided nodejs)"
  NODE="nix shell nixpkgs#nodejs --command node"
else
  fail "need node (or nix for nixpkgs#nodejs)"
fi

OUT="$ROOT/tests/pixels/out"
mkdir -p "$OUT"
TMPD=$(mktemp -d)
# drifblim leaves a .sym beside every ROM it writes (etal only removes
# its own .tal/.rom temps), and its path buffers are $3f bytes, so
# build from inside examples/chess with a relative path (realistic
# usage, and absolute repo paths overflow drifblim's buffer).
trap 'rm -rf "$TMPD"; rm -f "$ROOT"/examples/chess/etal*.rom.sym' EXIT INT TERM

(cd "$ROOT/examples/chess" && "$ETAL" -r main.ux -o "$TMPD/chess.rom") \
  || fail "chess assembly failed"

# shellcheck disable=SC2086
$NODE "$ROOT/tests/pixels/chess.cjs" "$ROOT" "$OUT" "$TMPD/chess.rom" \
  || fail "chess pixel scenario failed"

if command -v convert >/dev/null 2>&1; then
  for p in "$OUT"/chess-*.ppm; do
    convert "$p" "${p%.ppm}.png" 2>/dev/null || true
  done
  echo "shots: $OUT/chess-{menu,color,board,moved}.png"
else
  echo "(no ImageMagick; shots stay PPM in $OUT)"
fi

echo PIXELS-OK
