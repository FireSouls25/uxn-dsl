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

## CI builds them (no Mac or Windows machine needed)

`.github/workflows/etal-ci.yml` → job `build-vm` compiles upstream
uxn2 (pinned commit in the job env) on GitHub's own runners:
`macos-latest` (arm64), `macos-15-intel` (x86_64) with Homebrew SDL2,
and `windows-latest` with MSYS2 MinGW-w64 + SDL2 (`SDL2.dll` shipped
beside `uxn2.exe`). It runs on version tags and on manual runs
(Actions → etal-ci → Run workflow). The release job drops each VM into
`vendor/<row>/` of every release package, so a Linux backend using
that release can bundle games for every OS. A VM that fails to build
doesn't block the release; that row just stays unvendored. The
manual recipes below remain the way to build one locally.

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

## linux-x86_64 (done, verified; single-file since 2026-11-10)

`vendor/linux-x86_64/uxn2` is built by `scripts/build-uxn2-linux.sh`
(zig 0.17, `-target x86_64-linux-gnu.2.17`, uxn2 at the CI pin) with
`scripts/uxn2-embed.c` around uxn2's main, so `etal --target
linux-x86_64` writes `[uxn2][rom][footer]` as one executable ELF
(format: see windows-x86_64 below). Without a footer it is plain
uxn2, which is what the compiler assembles with on Linux hosts.
SDL2 stays dynamic (`NEEDED`: libSDL2-2.0.so.0, libc; glibc floor
2.14); `tests/portability.sh vendor/linux-x86_64/uxn2` passes. The
linux-aarch64 row gets the same wrapper from CI's build-vm; a VM
without it (older releases) makes etal fall back to the sh stub.

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

## macos-arm64 (committed copy is a stopgap; CI builds the real one)

The committed `vendor/macos-arm64/uxn2` (built on a MacBook Air,
2026-09-13) is **not portable**: `LC_BUILD_VERSION minos 26.6.2` (it
refuses older macOS) and it links `@rpath/SDL2.framework` with only
`/usr/lib` as rpath, so it does not load on a stock Mac even with
`brew install sdl2`. Releases replace it: CI's `build-vm`
(macos-latest) builds SDL2 2.32.10 from source as a **static**
library with `MACOSX_DEPLOYMENT_TARGET=11.0`, links uxn2 against it,
ad-hoc signs it, and fails unless `otool -L` lists only
`/System/Library/` and `/usr/lib/` entries. Result: runs on macOS 11+
with nothing installed. The `etal` compiler selects this row on
Darwin/arm64 (`host_row` in `src/target/target_native.ml`).
`macos-x86_64` is not a target for now.

## windows-x86_64 (done 2026-11-10, verified under wine 11.21)

`vendor/windows-x86_64/uxn2.exe`: one file, nothing beside it.
Cross-built on Linux by `scripts/build-uxn2-windows.sh` (zig 0.17
`zig cc -target x86_64-windows-gnu`, uxn2 at the CI pin, SDL2 2.32.10
MinGW devel package, linked **statically**). CI's MSYS2 row builds
the same thing with gcc.

- Upstream uxn2.c is compiled unchanged with two defines:
  `-include scripts/uxn2-win-compat.h` (POSIX `mkdir(path, mode)` →
  MinGW `_mkdir(path)`) and `-DSDL_MAIN_HANDLED -Dmain=uxn2_main`.
  `scripts/uxn2-embed.c` owns the entry point: if the exe ends in an
  `ETALROM1` footer it runs the ROM stored before it (written to a
  temp file, removed on exit), else it is plain uxn2 (which is how a
  Windows-host etal assembles).
- `etal --target windows-x86_64` writes `[uxn2.exe][rom][footer]` as
  the game `.exe` (format in `bundle_windows_exe`,
  src/target/target_native.ml); the 2× window / fullscreen choice is
  a footer flag.
- `file`: PE32+ (GUI) x86-64, about 1.8 MB. Imports: Windows system
  DLLs only (KERNEL32, USER32, GDI32, SHELL32, WINMM, SETUPAPI,
  OLE32, OLEAUT32, IMM32, VERSION, ADVAPI32) and the Universal CRT
  (`api-ms-win-crt-*`, built into Windows 10+).
- Verified under wine: `-v`; plain mode with a ROM that prints and
  writes `sub/out.txt` through the File device (creates the folder);
  the same ROM embedded (temp file cleaned up after); the chess
  example as a single etal-built `.exe`. A killed process leaves its
  temp ROM (tens of KB) in `%TEMP%`.

## uxn5 pin (web)

`src/vendor/uxn5` = upstream `https://git.sr.ht/~rabbits/uxn5`
at commit recorded in `src/vendor/uxn5/PIN`, ISC license in
`src/vendor/uxn5/LICENSE` (notice stamped into every game.html).
