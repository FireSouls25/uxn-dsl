# Changelog

Versioning convention: `0.x.y` until 1.0.0 (which is far off and means
"quite complete"). Within `0.x.y`:

- `x` (minor) — new working features (new syntax, targets, games).
- `y` (patch) — fixes and incremental progress, no new features.

Examples under `examples/` and vendored binaries are untracked helpers,
not versioned artifacts; the versioned unit is the compiler (`etal.opam`
says `0.1.0`, locked in `etal.opam.locked` with dune 3.24.2 on
OCaml 5.5.0).

## 0.1.0 (unreleased — first tagged version)

Compiler: typed ETAL DSL → Uxntal with functions/events, devices,
groups, data/sprites, buffers, arrays, control flow, macros, imports,
raw blocks, string printing, real SFT. Targets: `.tal` (`-t`), `.rom`
(`-r`), self-contained native bundles and single-file web pages
(default bundle mode, `--target native|web`). Vendored Linux VM
(glibc 2.17 floor) and pinned uxn5 web emulator. Snake game plus
`diff`-gated fixture suite. Dune + opam build (`dune build`, binary
at `bin/etal`), cross-platform CI.
