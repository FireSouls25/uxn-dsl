# Standard library

`lib/` holds plain ETAL modules — no compiler magic, just functions
over the existing types, usable from any game via file-relative
imports:

```ux
import "../lib/fix16.ux"
```

Conventions: single-result functions only (ETAL has no multiple
return — multi-result algorithms are caller-composed from `u16` ops,
see `u32` below); `ALL_CAPS` constants; every module ships a
`test_<name>.ux` console harness whose expected bytes are documented
in its header and enforced by `sh lib/check.sh` (local-only, needs
SDL2 like `tests/smoke.sh`).

Library design rule (falls out of whole-program checking plus
user-declared devices): device-touching helpers are MACROS, pure
logic are functions. Macro bodies check at the call site, so
importing a lib module never forces a device on anyone — call sites
need them declared. Import your devices file first, then lib
modules; function signatures and struct layouts are order-free,
device references resolve in splice order.

## screen.ux

Screen helpers over a game-declared `Screen` device: `screen_size`,
`blit` (zero-cost macro — the `sprite` write triggers the draw, so
order is semantic), `clear`, `theme` (macro, so no forced `System`
device), `AUTO_*` bits, and named sprite/pixel mode bits decoded
from the emulator source (`SPRITE_2BPP/LAYER/FLIPY/FLIPX`,
`PIXEL_FILL/LAYER/FLIPY/FLIPX`; snake's `SPRITE_NORM` is
1bpp-from-channel-1, OR in `SPRITE_2BPP` for true 2bpp tiles).

## object.ux, anim.ux

Fixed object rows: `Obj :: struct { x, y, tile, flags }` in
`buffer objs[16]`, indices are `u16` (255 = no slot), flags are
visible/solid/layer bits. `obj_spawn/move/hide/hide_all/free`,
`obj_draw`/`draw_all` (macros), `obj_draw_mode` (explicit sprite
mode per object), `draw_all_layered` (gameplay layers 0–3 back to
front, so high slots never overdraw foreground), `OBJ_*` consts.
Animation is an `Anim` row per object (base/len/rate/tick/mode/
playing) over a shared frame table: `anim_play` (looping),
`anim_play_mode` (`ANIM_LOOP/ONCE/PINGPONG` — once holds the last
frame and stops, ping-pong bounces), `anim_stop/start/playing`,
`anim_step` (stopped rows freeze with the tile untouched).

## input.ux

Vector-latch input over game-declared `[1] u8` slots (or 1-byte
buffers when zero-page is tight): `key_latch`/`cbtn_latch`/
`mouse_latch` for the vector bodies, `key_take`/`cbtn_take`/
`mouse_take` delivering each press exactly once (reads clear;
`mouse_take` ORs live state with latched taps). Macros, so only call
sites need the devices — same doctrine as `screen.ux` — and zero
library zero-page. Edge detection stays game-side (see `mouse_poll`
and the menu polls); position ports never clear and stay raw reads.

## fmt.ux

`fmt_u8(dst, v)` writes three digits plus NUL (`7` becomes `"007"`)
into a 4-byte caller buffer: fixed width keeps columns aligned, and
subtraction loops keep every temporary in `u8`. Unsigned only;
callers own the sign.

## timer.ux

Deadline timers for UI sequencing: `timer_set(i, n)` arms one of 4
countdowns, `timer_tick()` runs once per frame, `timer_ready(i)`
reads true once the count hits zero (level semantics — a missed poll
fires late, never lost; re-arm to reuse). Main-RAM pool, zero
zero-page cost; over 255 frames chains. Indices unchecked, like all
indexing.

## lerp.ux

`lerp8(a, b, k, n)` walks byte `a` to byte `b` as `k` runs `0..n`:
`(a*(n-k) + b*k)/n`, total for all `u8` inputs (the numerator tops
out at `255*n`, always inside `u16` — no wrap, no sign discipline,
either direction). Frame counters and pixel slides; wider ranges
want `fix16`. Preconditions: `n >= 1`, `0 <= k <= n`.

## collide.ux, scene.ux, menu.ux, mouse.ux, mouse.ux

`layers_hit` (same layer and at least one solid — edible food,
solid walls, pass-through ghosts), `obj_cell_hit` (8px cells),
`obj_aabb_hit` (explicit sizes). Scenes are a game-side
`match scene` dispatch; the module holds the id, `scene_prev`,
`scene_go`, `wipe`, and an 8-deep pause stack (`scene_push/pop`
— pop resumes exactly where the game was; over/underflow
ignored). Menus are edge polls (`menu_poll` — call once per
frame), `menu_items/next/prev` with wraparound; act on `poll & MASK`
idioms, never equality. Mouse is the same edge shape over
game-read state (`mouse_poll(Mouse.state)`, `MOUSE_LEFT/MIDDLE/
RIGHT/X1` from the emulator's SDL mapping); position and scroll
stay raw port reads (scroll is one-shot with inverted Y) — live
clicks need a display, so the gate feeds synthetic states. The
`examples/objdemo/` game (untracked, like the other examples)
plays all phases together: title menu, animated player, layered
walls, score-to-win, game-over loop.

## fix16.ux

8.8 signed fixed point over `u16` shorts, modeled on fix16.tal: range -128 <= x < 128, `#8000` is invalid input.
Operations saturate at `#7fff`/`#8001` instead of wrapping;
division by zero saturates; negative quotients truncate toward zero.
Two intentional divergences from fix16.tal, both fixes: `floor`
of a negative fraction rounds to the true floor (theirs clears the
low byte, overshooting to `-2` for `-0.5`), and `round` saturates
`127.5` to `#7fff` (theirs wraps to `#8000`).

| Kind | Functions |
|---|---|
| constants | `X16_ZERO ONE MINUS_ONE PI HALF_PI E MAXIMUM MINIMUM` |
| arithmetic | `x16_add sub neg mul div` (signed; exact restoring division) |
| compare | `x16_eq ne lt lteq gt gteq min max` |
| convert | `x16_from_int` (0–127, saturates), `x16_to_int` (truncate toward zero, as `u16` bits), `x16_is_whole floor ceil round` (half-even) |

Not yet ported (they need a short-blob story for their tables):
`sin`/`cos`/`tan`/`log`/`sqrt`.

## u32.ux

32-bit predicates over `(ahi, alo)` short pairs, modeled on
math32.tal: `u32_eq ne is_zero non_zero lt lteq gt gteq` plus
`u8_bitcount`/`u16_bitcount`. Predicates only, because arithmetic
needs two shorts out and ETAL functions return one.
Compose it at the call site instead:

```ux
lo: u16 = alo + blo;             ( wraps mod 65536 )
carry: u16 = 0;
if lo < alo { carry = 1; }
hi: u16 = ahi + bhi + carry;
```

Multi-result returns (out-params or tuple returns) would obsolete
this pattern; until then the predicates plus three-line call sites
cover scores, timers and RNG state.

## trig.ux

Turns256 sine/cosine over a self-built table: angles are `u8`
turns (0–255 = full circle), values fix16. `trig_init()` builds a
65-entry quarter table at boot with 3-term Taylor (worst error
±1 LSB, verified against a bit-exact model), quadrants mirror it,
so `cos256(a)` is `sin256(a+64)` — free via `u8` wraparound. No
bulk literals, no new syntax: the table generates itself from
`fix16.ux`. `sin256`/`cos256`, `taylor_sin` (exposed for testing).

## audio.ux, song.ux

Uxn pitch bytes are MIDI note numbers (verified against the
emulator source: 69 renders 441Hz; 0–107 audible, 108+ silent;
high bit = play once, clear = loop); samples are unsigned 8-bit
mono at 44100Hz. `audio.ux` holds `NOTE_C1`–`NOTE_B7` plus `REST`,
a stock 32-byte square wave (`sq32`), and a fire-and-forget `sfx`
(one-shot voice). `song.ux` is a four-voice tick sequencer over `Track` rows
(`notes: [24] Note` plus per-voice cursor, sample and envelope —
struct v2 in action): `track_next(t)` advances voice `t` and returns
the fired pitch or REST — no ports touched, headless-testable;
`track_fire0/1/2/3` macros write Audio0-3 (macros, so only fired
voices need their device declared); `song_tick()` drives voice 0,
`song_tick_all()` (a macro, same reason) drives all four. Long
samples play ~1:1 at middle C. Rests sustain through the envelope
tail (no hard stops v1). Needs the `Audio` devices fired (copy
block in `audio.ux` header); web builds are silent (uxn5 has no
audio device).

## file.ux

Varvara FileA helpers (verified against the emulator source:
native operations run inline inside the DEO — `fread`/`fwrite`/
`stat`/`unlink` with the count in `success`; web completes later
through the File vector). One split-phase API covers both:
`file_read_req` / `file_write_req` / `file_stat_req` /
`file_delete_req` macros initiate (setting `file_pending`),
`FileA.success` answers at once on native, and `file_poll()` /
`file_on_event()` (for the game's `FileA.vector` handler) record
completion portably into `file_done`/`file_result`. Stat reports
into RAM: `len` lowercase hex digits of size (`000a`), `-` for
dirs, `!` for missing, `?` for oversize; reading a directory
yields `HHHH<TAB>name[/]<NL>` lines. Never request zero bytes (a
zero `success` reads as "not done yet" — stat first). Needs the
`FileA` device (copy block in `file.ux` header); paths resolve
against the emulator's working directory.

## font.ux

8×8 1bpp text over a game-declared Screen: `font8x8` holds printable
ASCII 32–126 (95 glyphs × 8 rows, MSB-first, 760 bytes — the import
cost), `draw_char` / `draw_char_mode` blit one cell (any byte is
safe: `glyph_clamp` folds outside 32–126 to `?`), and
`draw_string` walks a NUL-terminated string — literal or buffer, 8px
per cell, `\n` starting the next row. `glyph_addr` is the pure
address math both macros share (gated headlessly in `test_font`;
glyph shapes are eyeballed from the `@font8x8` blob). Needs the
`Screen` device at call sites only.

## string.ux

NUL-terminated strings over `&u8` addresses: literals, `&blob`
data, and address globals (`msg: &u8 = "hi";`) flow into
`strlen` / `streq` (pure) and `strcopy` (macro into a caller
buffer — never a literal). Buffers do not convert to addresses,
so length/count loops over them stay game-side (three lines, as
in the harness). No concatenation, no slicing, no headers.

## gfx3d.ux

Software 3D wireframe (Varvara has no 3D): model units are pixels
as fix16, projection is the standard pinhole (`s = dist/(z+dist)`).
`Vec3` model/work buffers plus `Proj` output (`vset`,
`frame_begin` — rotation is destructive, so re-scratch every
frame), `rot_y`/`rot_x` (fix16, in place), `project(dist, cx, cy)`,
`plot` (macro: 600 pixels/frame cost no `JSR2` each), `edge`
(DDA: one fix16 divide up front, adds per pixel, both endpoints
plotted). Keep the model in front of the camera: `dist` must
exceed the largest rotated radius AND `dist + radius` must stay
under 128 (fix16 signed range) — a ±32px cube wants `dist` around
72. The `examples/cube3d/` demo spins all of this at 60Hz.
