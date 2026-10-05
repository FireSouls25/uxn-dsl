# Toolchain

## Building the compiler

Prerequisites: OCaml ≥ 5.0 with opam, and dune ≥ 3.24 (exact pins in
`etal.opam.locked`: OCaml 5.5.0, dune 3.24.2).

```sh
opam switch create etal ocaml-system   # or your existing 5.x switch
opam install --locked --deps-only -y . # exact pinned deps
opam exec -- dune build @all           # compiler per platform, see below
opam exec -- dune runtest              # lexer/parser probes + golden diff
```

`dune build` leaves everything under `_build/` — never in `src/`.
The compiler binary is additionally copied to `build/<platform>/etal`
(`linux-x86`, `macos-arm`, `windows-x86`; exactly one populates, matching
the building machine; Windows builds `etal.exe` instead, as executables
require there), so `./build/linux-x86/etal …` always works
(substitute your platform). Anything that is not the compiler would go
under `build/<platform>/extra/`.

## The `etal` CLI

```
etal [options] <input.ux>
  -o <file>     output file (default depends on mode)
  -t            emit Uxntal source (.tal)
  -r            emit an assembled ROM (.rom)
  --target t    bundle target: native (host row, default), web (single .html),
                or explicit VM row (linux-x86_64, linux-aarch64,
                macos-arm64, macos-x86_64, windows-x86_64)
  --list-targets list known rows + vendored status (backend discovery)
  --scale s     window size: fit (default), 1, 2, 3 or full
  --fullscreen  start fullscreen
  -v            verbose (declaration counts, chosen tools, output sizes)
```

Three ways out of one input, same bytes in:

| Mode | Command | Result |
|---|---|---|
| Inspect | `etal -t game.ux -o game.tal` | readable Uxntal, the compiler's contract |
| ROM | `etal -r game.ux -o game.rom` | assembled via vendored drifblim |
| Bundle (native, host) | `etal game.ux -o game` | self-contained executable (host VM + ROM) |
| Bundle (explicit row) | `etal --target macos-arm64 game.ux -o game` | same ROM + that row's VM (unix rows: sh+tar.gz; windows: zip with `run.bat`) |
| Bundle (web) | `etal --target web game.ux -o game.html` | self-contained page (uxn5 + ROM) |

`-t` and `-r` are mutually exclusive. Assembly always runs under the
host VM (a foreign binary cannot execute here); `--target` only
selects the packaged VM — so one Linux backend serves every download
option (`etal --list-targets` reports which rows are vendored).
Bundling assembles through a
temp `.tal` next to the input and cleans up after itself; assembly
failures report the assembler's exit code. Unix bundles forward
extra arguments to the VM (`./game -2` boots at 2x zoom); the temp
extraction dir is removed on exit, interrupt, or termination.

## Window size

`--scale` picks how big the bundle's window is, and `--fullscreen`
adds fullscreen on top. It is about the window around the ROM's
screen, never the ROM's own `Screen.width`/`Screen.height`.

| Value | Web page | Native (uxn2) |
|---|---|---|
| `fit` (default) | opens at the largest whole-number scale that fits the viewport, re-fitting when the window or the ROM's screen size changes | no flag: the window manager sizes it, and uxn2's own zoom key still cycles 1-3x |
| `1` / `2` / `3` | opens at that fixed scale, and ignores later resizes (the choice is yours to make, so it is not taken back) | `2` passes `-2`; `3` passes `-2` because uxn2's CLI has no `-3` -- its in-app key reaches 3x from 2x |
| `full` | the canvas takes the whole viewport | -- |
| `--fullscreen` | same as `full` unless `--scale` says otherwise | passes `-f` |

Two deliberate limits. **Whole numbers only**: a fractional scale
gives a pixel-art tile a different number of device pixels on
alternating rows, which is what `image-rendering: pixelated` exists
to prevent. **Width is the target, height is the constraint**: the
scale is the largest integer that fits both axes, so a tall game is
never pushed off the bottom of the screen.

uxn2's CLI is genuinely tiny (`usage: uxn2 -v | [-f -2] file.rom`),
so the native mapping is a translation, not a pass-through: 1x is the
default, `-2` is 2x, and there is no `-1`. Anything else (`fit`,
`full`, `1`, `3`) means "no flag".

The web page gets its own size buttons in the meta bar -- Fit, 1x, 2x,
3x, Fullscreen -- and remembers the choice in `localStorage`, so
changing the window size never needs a rebuild. The vendored Zoom
button and the ctrl+B / alt+S / shift+Start / home shortcut still work
and go through the same controller.

## Audio in web bundles

Upstream uxn5 has **no Audio device**: `vendor/uxn5/src/devices/` is
console, controller, datetime, mouse, screen, system, and `emu.js`
routes only port pages `0x00`, `0x10`, `0x20` and `0xc0`. A web
bundle therefore never heard anything -- a write to `Audio0.pitch`
landed in raw device memory and stopped there. `web/audio.js` adds
the missing device, wired in from the boot script so `vendor/` stays
byte-identical to the pinned upstream checkout.

It is a faithful port of uxn2's renderer (`uxn2/src/uxn2.c`, the
"Audio" section), so a ROM sounds the same on both VMs: the same
`advances` table, the same `NOTE_PERIOD`/`ADSR_STEP` math, the same
envelope, the same single-cycle vs sample-repeat period choice, and
the same "high nibble is the left channel" volume convention. Two
adaptations, both forced by the host:

* samples are rendered up front into an `AudioBuffer` rather than on
  demand, so a note needs a length cap (8s);
* uxn2 accumulates into `Sint16` while Web Audio wants floats in
  [-1, 1], so the output is scaled by the `Sint16` full scale --
  without that every note clips flat.

The port map is uxn2's (`&dev[0x30]`...`&dev[0x60]`, DEO on `pitch`,
DEI on `position` and `output`). The `nxu` audio *proposals* in the
corpus move `volume` and add a `mode` port; they are not what the
vendored VM implements, so they are not what this implements.

Browsers refuse to start audio without a gesture, so the context is
created lazily and resumed on the first pointer or key event. A page
nobody touches is silent; a page somebody plays makes noise.

## Support files

`web/` ships next to the binary and is found by the same exe-relative
walk-up as `vendor/`, so a release tarball needs no extra plumbing.

```
web/
  audio.js    # the Audio device uxn5 lacks
  view.js     # window sizing: fit / 1x / 2x / 3x / full
```

Two bundle-time patches are applied to the in-memory copy of
`vendor/uxn5/src/uxn.js`, leaving the vendored file pristine: the
per-vector step cap (`0x80000` -> `0x800000`, so chess's AI is not
truncated mid make/unmake) and `const ram` -> `const ram = this.mem`,
because the Audio device has to read the ROM to resample a note and
`ram` is otherwise a closure local with no accessor.

## Vendor layout

```
vendor/
  linux-x86_64/uxn2   # Linux VM (glibc 2.17 floor, dynamic SDL2)
  macos-arm64/uxn2    # macOS arm64 VM (see BUILD.md SDL2 note)
  windows-x86_64/     # TODO: uxn2.exe + SDL2.dll (zip carrier ready)
  shared/drifblim.rom # the assembler — itself a ROM, so portable
  uxn5/               # JS emulator for --target web (pinned, see PIN)
  BUILD.md            # provenance + per-OS build instructions
```

The compiler finds these relative to its own location (walking up
through `build/<platform>/`, `_build/…/` and legacy layouts), falling back to a
`uxn2/bin` checkout. Nothing is ever fetched at build time.

## Building the VM (`uxn2/build.zig`)

Same C sources, same `-DNDEBUG -O2` intent on every platform; only
the toolchain and system libraries change. Run from `uxn2/`:

```sh
zig build                                         # host dev build
zig build -Dtarget=x86_64-linux-gnu.2.17 -Dsys-libdir=/usr/lib   # Linux release
zig build -Dtarget=x86_64-windows-gnu -Dsdl-prefix=<SDL2-devel>  # Windows PE
zig build -Dtarget=aarch64-macos -Dsdl-prefix=/opt/homebrew      # macOS (needs Xcode SDK)
```

- `-Dsdl-prefix=<dir>` points at an SDL2 install (`<dir>/include/SDL2`,
  `<dir>/lib`; default `/usr`, e.g. `/opt/homebrew` on Apple Silicon).
- `-Dsys-libdir=a:b:c` adds extra `-L` search paths. Native builds
  need nothing; release cross-builds pass theirs (Debian/Ubuntu need
  the multiarch dir). Output lands in `uxn2/zig-out/`.
- SDL2 stays dynamic everywhere (upstream's documented prerequisite);
  the Linux release additionally pins glibc 2.17 for distro reach.

## Testing strategy

- `dune runtest` — lexer/parser probes plus a **golden `.tal` diff**:
  committed `tests/ci.ux` must compile to byte-identical
  `tests/ci_expected.tal` on every platform. This is the
  host-independence gate and needs no VM.
- Fixture ROMs under `examples/` are `diff`-gated byte-for-byte
  against real emulator runs (console bytes compared exactly).
- `sh tests/smoke.sh` — local-only assembler smoke: `-r` from outside the
  repo (exe-relative `vendor/` resolution), deterministic ROM bytes, web target.
- `sh tests/portability.sh` — the Linux VM contract: glibc floor,
  dependency closure, no direct X11/ALSA references, smoke boot.
- GitHub Actions (`.github/workflows/etal-ci.yml`) runs build, probes and
  the golden diff on Linux, macOS and Windows; VM-dependent gates
  stay local. Releases are cut from git tags and ship the compiler
  plus the `vendor/` tree per OS.

## Versioning

`0.x.y` until a far-off 1.0.0: `x` = new working features, `y` =
patches and progress. The version lives in `etal.opam` (`0.1.1`,
locked with exact deps in `etal.opam.locked`); releases are git tags
(`v0.1.1`, …) built by CI. History in [Changelog](../CHANGELOG.md).
