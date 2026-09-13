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
at `build/<platform>/etal`, `etal.exe` on Windows), cross-platform CI.

On `dev` (unreleased): Odin-style declarations — `name := init`
(inferred mutable), `name : type : init` (explicit constant),
`name :: init` (inferred constant), `ALL_CAPS` convention for `::`;
`const` is no longer a keyword. Modular integers (`u16 mod N`)
whose stores wrap automatically; assignments to constants are compile
errors. Two codegen fixes found along the way: global initializers
now execute before `main` (they were emitted after `HALT` and never
ran), and global stores use label form (raw `$hh` misassembles in
drifblim). Then: `return;` in events emits `BRK`, short `if`/`while`
conditions reduce via `#0000 NEQ2`, pure `for` bounds hoist to a
hidden temp, and `meta { title, author }` emits a spec-shaped ROM
metadata blob with boot-time wiring. And: whole-program function
signatures, so forward calls check fully and undefined calls fail
fast (recursion still unsupported). `match` desugars to a freshened
temp plus `if`/`elif` (integer arms, trailing `_`). Named `struct`
types with `.field` access over buffers and variables (scalar fields;
whole-value uses are compile errors). `lib/` stdlib: 8.8 fixed point
(`fix16.ux`, exact restoring division, saturating mul) and 32-bit
predicates (`u32.ux`), both console-gated. Width-soundness fixes:
`<=`/`>=` compared the wrong bytes, `&&`/`||` leaked stack on short
sides, prefix `-`/`~`/`!` missed both their space and their byte
forms, and `-> u8` callees now compose (returns sized to declaration). Graphics
phases as `lib/` modules, all console-gated: `screen.ux` (size, blit,
clear, theme, emulator-decoded mode bits), `object.ux` + `anim.ux`
(struct rows, spawn/draw, frame tables), `collide.ux` (layer rule,
cell + AABB hits), `scene.ux` + `menu.ux` (id + wipes, edge polls +
wraparound select), plus an `objdemo` game playing them together.
Lib rule: device-touching helpers are macros (checked at call sites,
so imports never force devices).
