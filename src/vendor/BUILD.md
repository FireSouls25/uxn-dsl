# Vendored VMs — provenance & per-platform build instructions

The `.rom` is portable; only the VM half of a bundle varies per
platform. Portability contract for `linux-x86_64/uxn2`, enforced by
`src/tests/portability.sh`:

- glibc floor <= 2.17 (`readelf -V` max requirement),
- `NEEDED` limited to SDL2/libc/ld-linux/pthread (+libm/libdl),
- no direct dynamic refs to X11/ALSA families (those resolve
  transitively via the target machine's own SDL2),
- `-v` smoke test passes.

Layout:

```
src/vendor/
  linux-x86_64/uxn2        # ELF x86-64 (dynamic SDL2, see below)
  shared/drifblim.rom      # platform-independent (it is a ROM)
  uxn5/                    # web emulator (see PIN)
  macos-<arch>/uxn2        # TODO: built on a Mac (instructions below)
  windows-x86_64/          # TODO: MinGW cross-build (instructions below)
```

## Same flags on every platform?

Same **source** (`uxn2/src/uxn2.c` in this repo) and same intent
(`-DNDEBUG -O2`, stripped), but never literally the same command:
each OS needs its own compiler and its own SDL2 provisioning, and
produces its own binary format (ELF / Mach-O / PE). That is normal
and does not affect the game: identical `.ux` still yields identical
`.rom` everywhere (gated). Record every new binary below with its
provenance (command, compiler + SDL2 versions, `file` output).

## Building the VM: uxn2/build.zig (zig 0.16.0+)

All platforms build from the same `uxn2/src/uxn2.c` via `uxn2/build.zig`
(run from `uxn2/`). SDL2 is a **dynamic** system dependency everywhere
(see below); same sources, same `-DNDEBUG -O2` intent per platform.

```
cd uxn2
zig build                                            # host dev build
zig build -Dtarget=x86_64-linux-gnu.2.17 -Dsys-libdir=/usr/lib
                                                     # Linux release
zig build -Dtarget=x86_64-windows-gnu -Dsdl-prefix=<SDL2-devel>
                                                     # Windows PE
zig build -Dtarget=aarch64-macos                     # macOS (needs SDK)
```

Options: `-Dsdl-prefix=<dir>` (SDL2 root: `<dir>/include/SDL2` +
`<dir>/lib`; default `/usr`), `-Dsys-libdir=a:b:c` (extra `-L`
dirs; native builds need nothing, release cross-builds pass
theirs — e.g. Debian needs `/usr/lib/x86_64-linux-gnu`).
`zig build -h` lists everything including per-target notes.

SDL2 is a dynamic rationale: upstream's documented prerequisite on
every OS; distro-patched security; SDL2 2.x API stability. System
backend libs (X11/ALSA/...) stay dynamic too. Fully-static builds
were tried and dropped: no static SDL2/X11/ALSA archives ship on
stock distros, and static audio backends break runtime dlopen.

## linux-x86_64 (done, verified)

`zig build -Dtarget=x86_64-linux-gnu.2.17 -Dsys-libdir=/usr/lib`
(Zig 0.16.0, this machine):

- Floor proof: max requirement in `readelf -V` is `GLIBC_2.17`
  (~2014+ distros). `ldd` shows dynamic SDL2 + libc/X11/ALSA.
- The bundle stub preflights (`uxn2 -v`) and prints SDL2 install
  help when the library is absent.

## Old-distro execution proof (done 2026-09-06, re-runnable)

Beyond the static gate (`src/tests/portability.sh`), the binary was
executed inside Ubuntu 18.04 userspace (glibc 2.27, SDL 2.0.5 from
Debian stretch):

- negative control: the previous gcc build (floor 2.34) fails with
  ``version `GLIBC_2.34' not found`` — the environment discriminates;
- positive: the vendored binary boots and runs the console gate ROM
  byte-identically (`Hi!\nBye.\n828`), under `SDL_VIDEODRIVER=dummy`.

Recipe (all artifacts in `/tmp`, nothing committed):

```
# 1. Rootfs (checksum against published SHA256SUMS):
curl -O http://cdimage.ubuntu.com/ubuntu-base/releases/18.04/release/ubuntu-base-18.04.5-base-amd64.tar.gz
mkdir /tmp/u1804 && tar -xzf ubuntu-base-18.04.5-base-amd64.tar.gz -C /tmp/u1804
# 2. Stretch SDL2 2.0.5 + dependency closure from archive.debian.org
#    (libsdl2, X11 set, ALSA/pulse/sndio, wayland, xkbcommon, …):
#    resolve soname->package via stretch Packages, extract .debs to /tmp/u1804
# 3. Stage the VM + a test ROM in /tmp/oldtest, then:
bwrap --unshare-user --uid 0 --gid 0 \
  --bind /tmp/u1804 / --bind /tmp/oldtest /test \
  --dev /dev --proc /proc \
  --setenv PATH /usr/bin:/bin --setenv HOME /test \
  --setenv SDL_VIDEODRIVER dummy \
  /test/uxn2-new /test/gate.rom | od -An -tx1   # expect gate bytes
```

## macOS (TODO — needs a Mac; you volunteered one)

On the Mac, from this repo's `uxn2/` directory:

```
# 0. SDL2 for your arch (arm64 Apple Silicon shown; Intel similar):
brew install sdl2
sdl2-config --version        # record it

# 1. Build with the same release intent as Linux:
cc $(sdl2-config --cflags) -DNDEBUG -O2 -g0 -s src/uxn2.c \
  -o /tmp/uxn2-macos $(sdl2-config --libs)

# 2. Verify + collect provenance:
file /tmp/uxn2-macos        # want: Mach-O 64-bit (arm64 or x86_64)
/tmp/uxn2-macos -v          # want: version line, exit 0
otool -L /tmp/uxn2-macos    # record SDL2 linkage (dynamic .dylib expected)
uname -m                    # record arch
cc --version                # record compiler
```

Then, back on Linux:

```
mkdir -p src/vendor/macos-<arch>   # e.g. macos-arm64
cp /tmp/uxn2-macos src/vendor/macos-<arch>/uxn2
```

- Universal2 (both archs, best UX): build on each arch and
  `lipo -create uxn2-arm64 uxn2-x86_64 -output uxn2` (or
  `cc -arch x86_64 -arch arm64 ...` if both SDL2 archs are present).
- Sign ad-hoc so it runs at all: `codesign -s - uxn2`
  (on the Mac). Paid Apple signatures are out of scope.
- First launch of a downloaded bundle will hit Gatekeeper
  quarantine; documented user escape hatches: right-click → Open,
  or `xattr -d com.apple.quarantine <file>`.
- SDL2 note: Homebrew SDL2 is dynamic. Either keep it (users
  `brew install sdl2`, stub message already covers macOS) or later:
  static SDL2 build, or co-ship `libSDL2-2.0.0.dylib` in the bundle
  payload next to the binary (payload tarballs already support
  sibling files).

## windows-x86_64 (TODO — MinGW headers ship with zig)

Vendored choice: MinGW-w64 build of **our** `uxn2.c` (same codebase
and CLI contract as Linux/Mac; permissive license — unlike the
all-rights-reserved `uxn32.c`). No MinGW install needed; SDL2 comes
from the SDL2-devel mingw tarball (libsdl.org):

```
# 0. Unpack https://github.com/libsdl-org/SDL/releases SDL2-devel-*-mingw.tar.gz,
#    note its x86_64-w64-mingw32 dir; optionally export PKG_CONFIG_PATH to its
#    lib/pkgconfig so zig picks SDL2 flags from there instead of the host.
# 1. From uxn2/:
zig build -Dtarget=x86_64-windows-gnu -Dsdl-prefix=<devel>/x86_64-w64-mingw32
# 2. Verify:
file zig-out/bin/uxn2.exe       # want: PE32+ x86-64
wine zig-out/bin/uxn2.exe -v    # smoke test without a Windows box (needs wine)
```

- Co-ship `SDL2.dll` (from the devel package's `bin/`) beside the
  exe in the payload — Windows finds DLLs next to the executable,
  no install needed. (The Windows `.exe` carrier is a separate
  planned step; the VM row plugs into it unchanged.)

## uxn5 pin (web)

`src/vendor/uxn5` = upstream `https://git.sr.ht/~rabbits/uxn5`
at commit recorded in `src/vendor/uxn5/PIN`, ISC license in
`src/vendor/uxn5/LICENSE` (notice stamped into every game.html).
