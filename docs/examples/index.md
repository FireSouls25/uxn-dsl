# Examples: Snake

`examples/snake/` is the complete reference program: a playable Snake
game plus a deterministic test harness, split the way real ETAL
projects split.

## Files

| File | Role |
|---|---|
| `devices.ux` | the four devices both targets share (System, Screen, Controller, DateTime) |
| `sprites.ux` | three `data … = file("assets/*.chr")` 2bpp sprite tiles |
| `assets/{head,body,food}.chr` | 16 bytes each: 8 bytes channel one, 8 bytes channel two |
| `logic.ux` | state, movement, food, collision, drawing — no vectors |
| `main.ux` | vectors + startup; `main :: event()` stays in the event loop |
| `test_snake.ux` | headless harness: fixed seed, 7 ticks, prints, halts |
| `test_input.ux` | input-guard harness: reversal rejection, legal turns |

## How it maps to the language

- **State** is globals (`head_x: u16`, `score: u8`, …) plus two
  `buffer tail_x[256]: u16` rings in main RAM — the classic
  small-scalars-in-zero-page, big-arrays-in-buffers split.
- **Movement** (`step`) mixes both bound styles: explicit edge checks
  for up/left (where `0 - 1` would wrap) and the `wrap` helper for
  right/down. The tail shifts with `tail_x[i] = tail_x[i + 1]` and
  grows by skipping the shift — array store and indexed load in one
  routine.
- **Food** (`new_food`) is rejection sampling: an LCG (`seed * 251 +
  31`) modulo the grid, retried while it hits the tail, bounded at 64
  tries. Interactive runs seed from `DateTime`; the harness pins
  `seed = 4660` so every run is identical.
- **Input** (`set_dir`) rejects 180° reversals against the queued
  direction — the bug that once suicided the snake is now a tested
  property (`test_input.ux` asserts the exact bytes).
- **Death and winning** are just states (`2`/`3`); space pauses,
  resumes, or restarts via `init_state()`, and `on_frame` only steps
  while `state == 1`.
- **Drawing** (`draw`) is one clear-fill plus sprite blits:
  `Screen.addr = &food_tile` with `Screen.x = food_x << 3` — the
  `<< 3` folds to a single `#30 SFT2`, the cell-to-pixel idiom.
- **Vectors** (`main.ux`) do nothing but route: controller buttons to
  `set_dir`, the frame tick to throttled `step(); draw();`, each
  ending in `brk`.

## Running it

```sh
./bin/etal examples/snake/main.ux -o /tmp/snake && /tmp/snake -2
./bin/etal --target web examples/snake/main.ux -o /tmp/snake.html
```

Arrows steer, space pauses/resumes/restarts. The harness variant
(`test_snake.ux`, a `main :: fn()` that halts) prints
`53 09 08 00 …` — head positions and score per tick — which the test
suite diffs byte-for-byte.
