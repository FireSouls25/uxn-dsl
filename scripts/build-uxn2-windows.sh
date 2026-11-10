#!/bin/sh
# Cross-build the Windows game VM (vendor/windows-x86_64/uxn2.exe +
# SDL2.dll) on Linux with zig, from the uxn2 checkout CI pins.
# Usage: sh scripts/build-uxn2-windows.sh [uxn2-src-dir]   (default: uxn2/)
# Same as CI's windows row: -DNDEBUG -O2, stripped, GUI subsystem (no
# console window behind the game), SDL2.dll from the official MinGW
# devel package beside the exe. Needs zig, curl, tar.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="${1:-$ROOT/uxn2}"
SDL_VER="${SDL_VER:-2.32.10}"
OUT="$ROOT/vendor/windows-x86_64"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -sSLf -o "$TMP/sdl.tgz" "https://github.com/libsdl-org/SDL/releases/download/release-$SDL_VER/SDL2-devel-$SDL_VER-mingw.tar.gz"
tar xzf "$TMP/sdl.tgz" -C "$TMP"
P="$TMP/SDL2-$SDL_VER/x86_64-w64-mingw32"
mkdir -p "$OUT"
zig cc -target x86_64-windows-gnu -DNDEBUG -O2 -g0 -s \
  -include "$ROOT/scripts/uxn2-win-compat.h" -I"$P/include/SDL2" \
  "$SRC/src/uxn2.c" -o "$OUT/uxn2.exe" \
  "$P/lib/libSDL2main.a" "$P/lib/libSDL2.dll.a" -Wl,--subsystem,windows
cp "$P/bin/SDL2.dll" "$OUT/SDL2.dll"
file "$OUT/uxn2.exe"
echo "built $OUT (SDL2 $SDL_VER)"
