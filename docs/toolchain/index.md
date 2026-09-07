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
  --target t    bundle target: native (default) or web (single .html)
  -v            verbose (declaration counts, chosen tools, output sizes)
```

Three ways out of one input, same bytes in:

| Mode | Command | Result |
|---|---|---|
| Inspect | `etal -t game.ux -o game.tal` | readable Uxntal, the compiler's contract |
| ROM | `etal -r game.ux -o game.rom` | assembled via vendored drifblim |
| Bundle (native) | `etal game.ux -o game` | self-contained executable (VM + ROM) |
| Bundle (web) | `etal --target web game.ux -o game.html` | self-contained page (uxn5 + ROM) |

`-t` and `-r` are mutually exclusive. Bundling assembles through a
temp `.tal` next to the input and cleans up after itself; assembly
failures report the assembler's exit code. Native bundles forward
extra arguments to the VM (`./game -2` boots at 2x zoom); the temp
extraction dir is removed on exit, interrupt, or termination.

## Vendor layout

```
vendor/
  linux-x86_64/uxn2   # Linux VM (glibc 2.17 floor, dynamic SDL2)
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
patches and progress. The version lives in `etal.opam` (`0.1.0`,
locked with exact deps in `etal.opam.locked`); releases are git tags
(`v0.1.0`, …) built by CI. History in [Changelog](../CHANGELOG.md).
