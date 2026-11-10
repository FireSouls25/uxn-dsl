#!/bin/sh
# Cross-build the Windows game VM (vendor/windows-x86_64/uxn2.exe) on
# Linux with zig, from the uxn2 checkout CI pins.
# Usage: sh scripts/build-uxn2-windows.sh [uxn2-src-dir]   (default: uxn2/)
# One file, nothing beside it: SDL2 is linked statically (official
# MinGW devel package) and scripts/uxn2-embed.c wraps uxn2's main so
# `etal --target windows-x86_64` can append a ROM and ship a single
# game .exe. -DNDEBUG -O2, stripped, GUI subsystem (no console window
# behind the game). Needs zig, curl, tar.
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
CC="zig cc -target x86_64-windows-gnu"
FLAGS="-DNDEBUG -O2 -g0 -s -I$P/include/SDL2"
# uxn2.c unchanged: its main becomes uxn2_main, the wrapper owns entry.
$CC $FLAGS -include "$ROOT/scripts/uxn2-win-compat.h" -DSDL_MAIN_HANDLED -Dmain=uxn2_main \
  -c "$SRC/src/uxn2.c" -o "$TMP/uxn2.o"
$CC $FLAGS -c "$ROOT/scripts/uxn2-embed.c" -o "$TMP/embed.o"
mkdir -p "$OUT"
rm -f "$OUT/SDL2.dll"
$CC -s "$TMP/embed.o" "$TMP/uxn2.o" -o "$OUT/uxn2.exe" "$P/lib/libSDL2main.a" "$P/lib/libSDL2.a" \
  -lm -ldinput8 -ldxguid -ldxerr8 -luser32 -lgdi32 -lwinmm -limm32 -lole32 -loleaut32 \
  -lshell32 -lsetupapi -lversion -luuid -Wl,--subsystem,windows
file "$OUT/uxn2.exe"
echo "built $OUT/uxn2.exe (SDL2 $SDL_VER, static)"
