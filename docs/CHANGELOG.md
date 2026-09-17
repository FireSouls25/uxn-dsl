# Changelog

Versioning convention: `0.x.y` until 1.0.0 (which is far off and means
"quite complete"). Within `0.x.y`:

- `x` (minor) — new working features (new syntax, targets, games).
- `y` (patch) — fixes and incremental progress, no new features.

Examples under `examples/` and vendored binaries are untracked helpers,
not versioned artifacts; the versioned unit is the compiler (`etal.opam`
says `0.1.1`, locked in `etal.opam.locked` with dune 3.24.2 on
OCaml 5.5.0).

## 0.1.1 (unreleased — first tagged version)
Compiler: typed ETAL DSL → Uxntal with functions/events, devices,
groups, data/sprites, buffers, arrays, control flow, macros, imports,
raw blocks, string printing, real SFT. Targets: `.tal` (`-t`), `.rom`
(`-r`), self-contained native bundles and single-file web pages
(default bundle mode, `--target native|web`). Vendored VMs: Linux
(glibc 2.17 floor) plus macOS-arm64, and pinned uxn5 web emulator. Snake game plus
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
so imports never force devices). Software 3D: `trig.ux`
(self-built turns256 sine table) and `gfx3d.ux` (rotate/project/DDA
wireframe) with a spinning-cube demo. Dead-function elimination
(reachable-from-main, raw disables) so libraries don't eat zero-page.
macOS row: `vendor/macos-arm64/uxn2` vendored; the compiler selects
the VM row per host OS (SDL2 runtime fix still open — see
vendor/BUILD.md). Audio: `.wav` assets (8-bit mono 44100Hz, zero
conversion), `audio.ux` (MIDI notes, square wave, one-shot sfx),
`song.ux` tick sequencer, and a Megalovania demo (web builds stay
silent — uxn5 has no audio device). Structs v2: nested structs,
fixed array fields, chained paths (`rows[i].pos.x`), and same-type
whole-value `=` (stashed-pointer byte copy; params/returns/compare
stay field-wise), with a `test_struct` console gate and golden
coverage. File device: `lib/file.ux` split-phase FileA macros
(request, inline `success` on native, `file_poll`/`file_on_event`
for the web vector; stat-first, never zero bytes), CWD-relative
paths, `test_file` round-trip gate. Font/text: `lib/font.ux`
in-repo 8×8 font (ASCII 32–126) with `draw_char` / `draw_string`
macros (`\n` rows, `?` clamp) and gated `glyph_clamp` /
`glyph_addr` math; also fixes silent stride-2 reads when indexing
string literals. Multitrack audio: `song.ux` v2 `Track` rows
through Audio0-3 (`track_next` pure per voice, `track_fire0-3`
macros, `song_tick` / `song_tick_all`; single-song API retired,
Megalovania migrated). Mouse: `lib/mouse.ux` edge polls
(`mouse_poll`, `MOUSE_*` from the SDL mapping) over a corrected
Mouse block, synthetic-state gate. Arrays: same-type/length whole
copy with `=` (assign + init); every other whole-array use is a
compile error. Scenes: pause stack (`scene_push/pop`), `scene_prev`,
layered drawing (`draw_all_layered`, `obj_draw_mode`). Diagnostics:
`file:line:col` errors with source echo and clean `etal: error:`
exit-1 (declaration granularity in the checker); `assert E;`
halts with a baked location, gated both passing and failing.
Unused-discovery warnings (globals, stored consts, locals, params,
data/assets — never functions/macros/labels) with positions.
Animation:
`Anim` rows with `LOOP/ONCE/PINGPONG` modes, `anim_stop/start`
freeze/resume plus `anim_playing` query. Inline `raw {}` in bodies
for TAL the typed surface cannot reach (golden-pinned). Data blobs
read as arrays (inline: index + whole-copy; file assets: index
only); string literals index with byte stride; `lib/string.ux`
(`strlen`/`streq`/`strcopy`) over `&u8` views. Software
3D: `trig.ux`
(self-built turns256 sine table) and `gfx3d.ux` (rotate/project/DDA
wireframe) with a spinning-cube demo. Dead-function elimination
(reachable-from-main, raw disables) so libraries don't eat zero-page.
Address decay (bare arrays and `&name` flow into pointer slots),
exact checker lines via leaf positions, and zero-page-sized branch
scaffolding: two-letter label stems plus short `@fnN` function labels
(real name in the header comment) so large programs fit drifblim's
fixed `$4800` symbol dictionary (chess needed it at ~20KB of names).
Font-bis: the `(`/`)` glyph comments nested the lexer comment and ate a
whole font row (`CHESS` rendered as `DIFTT`) — glyph names are words now
(`lparen`/`rparen`, lexical doc footgun note), and `test_font` asserts
blob content, not just address math. Input-bis: `Controller.key` polling
can't work (the VM self-clears the port between frames) — chess latches
keys/buttons in `on_key`/`on_mouse` vectors; mouse coords are window
pixels (zoom ≠ 1 miscalibrates, upstream quirk), both noted in limitations.
Chess input pass: game-drawn cursor (the VM hides the system one),
`>` selection markers with mouse hover tracking, and full keyboard
play of every menu — arrows/W/S move, Enter/Space/Z confirm — over a
latched controller-button edge mask (`cbtnbuf`, taps can't fall
between frames). Headless-harness proven: cursor follows the mouse,
arrows + Enter leave the menu, S + Space start as Black, ESC
pauses/resumes with stable stacks.
