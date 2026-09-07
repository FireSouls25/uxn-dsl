# Snake game API (`examples/snake/`)

Playable Snake split across `devices.ux` (devices), `sprites.ux`
(tiles), `logic.ux` (state + rules + drawing) and `main.ux` (vectors +
startup). Two harnesses reuse the same files: `test_snake.ux`
(7 deterministic ticks) and `test_input.ux` (input-guard proof).

## State

```ux
head_x: u16;  head_y: u16;      ( head cell, grid coords )
food_x: u16;  food_y: u16;      ( food cell )
dir: u8;      dir_next: u8;     ( committed + queued direction: 0 up, 1 right, 2 down, 3 left )
seg_len: u16;                   ( segment count, head included )
grow: u8;                       ( pending growth ticks )
score: u8;                      ( foods eaten )
state: u8;                      ( 0 paused, 1 playing, 2 dead, 3 complete )
wait: u8;     wait_from: u8;    ( frame throttle + its reload value )
seed: u16;    tick: u16;        ( RNG state + step counter )
grid :: 16;                     ( board is grid × grid cells )
```

## `tail_x` / `tail_y`

```ux
buffer tail_x[256]: u16;
buffer tail_y[256]: u16;
```

The tail ring in main RAM: `tail_x[0..seg_len]` hold segments
oldest→newest, head last. 256 entries × 2 bytes × 2 buffers sit at
`|2000`/`|2200`.

## Sprites

```ux
data head_tile = file("assets/head.chr");
data body_tile = file("assets/body.chr");
data food_tile = file("assets/food.chr");
```

One 2bpp CHR tile each (16 bytes: 8 channel-one + 8 channel-two),
drawn with `Screen.addr = &head_tile;` and `Screen.sprite = 1;`.

## wrap

```ux
wrap :: fn(x: u16, n: u16) -> u16 {
    if x < n {
        return x;
    }
    return x - n;
}
```

Half-open wrap for `0 <= x < 2n`: identity inside the board, single
subtract on overflow. Used for right/down moves; up/left use explicit
`0`-checks instead (wrapping `0 - 1` as unsigned would underflow).

## set_dir

```ux
set_dir :: fn(d: u8) {
    if d == 0 {
        if dir_next != 2 {
            dir_next = 0;
        }
    }
    ...
}
```

Queues a direction unless it is a 180° reversal of the queued one
(up↔down, left↔right). Checked against `dir_next`, not `dir`, so a
legal quick double-turn (e.g. up-then-left while moving right) still
applies. Without this guard a reversal steps the head into its own
neck and dies — the exact bug `test_input.ux` pins down.

## next_rand

```ux
next_rand :: fn() -> u16 {
    seed = seed * 251 + 31;
    return seed;
}
```

Tiny LCG over the full `u16` range (wrapping multiply). Callers take
`% grid`.

## new_food

```ux
new_food :: fn() {
    tries: u16 = 0;
    while tries < 64 {
        food_x = next_rand() % grid;
        food_y = next_rand() % grid;
        ...
        if hit == 0 {
            return;
        }
        tries = tries + 1;
    }
}
```

Rejection sampling: random cell, rescan the whole tail (`for i in
0..seg_len`), keep it on first miss, give up after 64 tries (food
stays where it was — board is full or nearly).

## step

```ux
step :: fn() {
    if state != 1 {
        return;
    }
    dir = dir_next;
    tick = tick + 1;
    ...
}
```

One tick, in order: ignore unless playing; commit direction; move the
head with wrap; if growing, consume one `grow`, else shift the tail
left (dropping the oldest segment); self-collision check sets
`state = 2` and returns; a full 256-segment board sets `state = 3`;
append the head; eating (`nx == food_x` and `ny == food_y`) bumps
`score`, adds 2 growth, respawns food.

## draw

```ux
draw :: fn() {
    Screen.x = 0;
    Screen.y = 0;
    Screen.pixel = 128;
    ...
    for i in 0..seg_len {
        Screen.x = tail_x[i] << 3;
        ...
    }
    ...
}
```

Clear-fill, food sprite, one body blit per segment, head blit on top.
Cell→pixel is `<< 3` (one `#30 SFT2`).

## init_random

```ux
init_random :: fn() {
    seed = DateTime.second + DateTime.minute * 256;
}
```

Wall-clock seed for interactive play. Harnesses overwrite `seed`
afterwards (`seed = 4660;`) for determinism.

## init_state

```ux
init_state :: fn() {
    head_x = 8;
    head_y = 8;
    ...
    food_x = 11;
    food_y = 8;
}
```

Full reset without touching vectors: head center-ish moving right,
one segment, scripted first meal three cells ahead, throttle loaded.
Space-pressed-after-death calls this, so any game restarts cleanly.

## on_controller

```ux
on_controller :: event() {
    if Controller.button == 8 {
        brk;
    }
    if Controller.button == 16 {
        set_dir(0);
        brk;
    }
    ...
}
```

In `main.ux`. Button 8 exits the vector; d-pad routes through
`set_dir`; space cycles playing → paused → resumed, or `init_state()`
from dead/complete. Every arm ends in `brk`.

## on_mouse

```ux
on_mouse :: event() {
    brk;
}
```

Wired but unused — the mouse does nothing (yet).

## on_frame

```ux
on_frame :: event() {
    if state != 1 {
        brk;
    }
    if wait != 0 {
        wait = wait - 1;
        brk;
    }
    wait = wait_from;
    step();
    draw();
    brk;
}
```

In `main.ux`. Only runs while playing; the `wait`/`wait_from`
throttle turns 60Hz frames into game ticks; then one `step` + `draw`
per tick.

## wire_vectors

```ux
wire_vectors :: fn() {
    Screen.vector = &on_frame;
    Controller.vector = &on_controller;
}
```

In `main.ux`. Arms both vectors with function addresses. (`Mouse`
has no vector wired — see `on_mouse` above.)

## on_start

```ux
on_start :: fn() {
    System.r = 45163;
    ...
    Screen.width = 128;
    Screen.height = 128;
    ...
    init_random();
    init_state();
    wire_vectors();
}
```

In `main.ux`. Palette theme, 128×128 screen, cursor home,
background fill, seed, state, vectors — in that order.

## main

```ux
main :: event() {
    on_start();
}
```

In `main.ux`. An event, so boot ends in `BRK` and the window persists
in the event loop. (The `fn` + halting variant lives in
`test_snake.ux`, which drives `step()`/`draw()` directly.)
