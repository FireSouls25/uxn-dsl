#!/bin/sh
# Portability gate for the vendored Linux VM.
# Asserts the binary stays within the portability contract:
#   1. glibc floor <= 2.17 (runs on ~2014+ distros)
#   2. NEEDED closure limited to stable system libs (SDL2/libc/ld/pthread)
#   3. no direct dynamic refs to X11/ALSA families (those must resolve
#      transitively via the target machine's own SDL2)
#   4. ELF x86-64 that actually starts (`-v` smoke test)
# Usage: sh src/tests/portability.sh [path/to/uxn2]
# Exit nonzero with a message on the first violation.
set -e

BIN="${1:-vendor/linux-x86_64/uxn2}"
[ -x "$BIN" ] || { echo "FAIL: not executable: $BIN" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

file "$BIN" | grep -q "ELF 64-bit.*x86-64" \
  || fail "not an ELF x86-64 binary: $(file -b "$BIN" | head -n 1)"

# 1. glibc floor: highest GLIBC_* version required by our own symbols.
MAXGLIBC=$(readelf -V "$BIN" 2>/dev/null | grep -o "GLIBC_[0-9.]*" \
  | sort -Vu | tail -n 1)
[ -n "$MAXGLIBC" ] || fail "no GLIBC version requirements found"
echo "glibc floor: $MAXGLIBC"
case "$MAXGLIBC" in
  GLIBC_2.1[0-7]|GLIBC_2.[0-9]|GLIBC_2.1[0-7].*) ;;
  *) fail "glibc floor $MAXGLIBC exceeds 2.17 contract" ;;
esac

# 2. NEEDED allowlist.
UNEXPECTED=$(readelf -d "$BIN" 2>/dev/null \
  | grep NEEDED | grep -o "\[.*\]" | tr -d "[]" \
  | grep -v -x -e "libSDL2-2.0.so.0" -e "libc.so.6" \
    -e "ld-linux-x86-64.so.2" -e "libpthread.so.0" \
    -e "libm.so.6" -e "libdl.so.2" || true)
[ -z "$UNEXPECTED" ] \
  || fail "unexpected NEEDED entries (closure grew): $UNEXPECTED"
echo "NEEDED closure ok"

# 3. No direct X11/ALSA-family refs (must come via target's SDL2).
# Case-sensitive prefixes: X11 API starts X+Uppercase, ALSA snd_/pa_.
DIRECT=$(readelf --dyn-syms "$BIN" 2>/dev/null \
  | grep " UND " | grep -E " UND (X[A-Z]|Xcursor|Xrandr|Xfixes|Xss|Xinerama|snd_|pa_)" \
  || true)
[ -z "$DIRECT" ] \
  || fail "direct X11/ALSA refs (must resolve via SDL2): $DIRECT"
echo "no direct X11/ALSA refs"

# 4. Smoke test: starts and reports its version.
"$BIN" -v >/dev/null 2>&1 || fail "binary failed to start (-v)"
echo "smoke test ok ($("$BIN" -v 2>&1 | head -n 1))"

echo "PORTABILITY-OK: $BIN"
