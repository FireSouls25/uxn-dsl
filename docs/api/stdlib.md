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
`obj_draw`/`draw_all` (macros), `OBJ_*` consts. Animation is frame
tables plus per-object base/len/rate/tick with `anim_play/step`.

## collide.ux, scene.ux, menu.ux

`layers_hit` (same layer and at least one solid — edible food,
solid walls, pass-through ghosts), `obj_cell_hit` (8px cells),
`obj_aabb_hit` (explicit sizes). Scenes are a game-side
`match scene` dispatch; the module holds the id, `scene_go`, and
`wipe`. Menus are edge polls (`menu_poll` — call once per frame),
`menu_items/next/prev` with wraparound; act on `poll & MASK`
idioms, never equality. The `examples/objdemo/` game (untracked,
like the other examples) plays all phases together: title menu,
animated player, layered walls, score-to-win, game-over loop.

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
