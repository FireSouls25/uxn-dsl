#!/bin/sh
# Build the Linux x86_64 game VM (vendor/linux-x86_64/uxn2) with zig:
# glibc 2.17 floor, SDL2 dynamic (the player's distro package), and
# scripts/uxn2-embed.c around uxn2's main so `etal --target
# linux-x86_64` can append a ROM and ship one executable.
# Usage: sh scripts/build-uxn2-linux.sh [uxn2-src-dir]   (default: uxn2/)
# Needs zig and SDL2 headers + libSDL2.so on this machine (link only).
# Check the result with: sh tests/portability.sh vendor/linux-x86_64/uxn2
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="${1:-$ROOT/uxn2}"
SDL_INC="${SDL_INC:-/usr/include/SDL2}"
SDL_LIB="${SDL_LIB:-/usr/lib}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CC="zig cc -target x86_64-linux-gnu.2.17"
FLAGS="-DNDEBUG -O2 -g0 -D_REENTRANT -I$SDL_INC"
$CC $FLAGS -DSDL_MAIN_HANDLED -Dmain=uxn2_main -c "$SRC/src/uxn2.c" -o "$TMP/uxn2.o"
$CC $FLAGS -c "$ROOT/scripts/uxn2-embed.c" -o "$TMP/embed.o"
# libSDL2.so's own deps (dlopen@GLIBC_2.34 on new distros) resolve on
# the player's machine, not here.
$CC -s "$TMP/embed.o" "$TMP/uxn2.o" -o "$ROOT/vendor/linux-x86_64/uxn2" \
  -L"$SDL_LIB" -lSDL2 -lpthread -Wl,--allow-shlib-undefined
file "$ROOT/vendor/linux-x86_64/uxn2"
