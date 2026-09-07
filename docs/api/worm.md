# Worm games API (`examples/worm/`)

Two programs sharing devices, groups and datasets: `worm.ux`, an
early stub whose movement/drawing are placeholders, and
`worm_full.ux`, the fuller 20×20 game with a console test harness.
Both use the same [devices](devices.md) (System/Screen/Controller/
Mouse/DateTime) and the same controller mapping as
[snake](snake.md#on_controller) (buttons 8/16/32/64/128, Escape,
Space).

## Groups

```ux
group dir: u8 {
    next: u8
}
group wait: u8 {
    from: u8
}
group food: u16 {
    dir: u8
    wait: u8
}
```

Worm-only (`worm.ux`) zero-page structs: queued direction, frame
throttle plus reload, and a food cell with heading and delay.
Accessed as `.dir/next`, `.wait/from`, `.food/dir`.

## Datasets

```ux
data body_dirs = [ 0 64 0 80 32 16 80 0 0 48 0 32 48 0 64 16 ]
data head_chr = [ 252 238 ... ]
data body_chr = [ 195 189 ... ]
data tail_chr = [ 63 111 ... ]
data food_ici = [ 0 24 24 16 ... ]
data digits_ici = [ 0 124 198 ... ]
data body = []
```

Worm-only large inline blobs (head/body/tail sprites, food animation
frames, decimal digit tiles) plus an empty `body` table. `worm_full`
keeps only two 8-byte tiles (`head_chr`, `food_ici`); snake moved to
`file()` assets instead.

## wrap — worm.ux (stub)

```ux
wrap :: fn(x: u16, n: u16) -> u16 {
    if n > x {
        return n - 1;
    }
    if x != n {
        return x - n;
    }
    return x;
}
```

Historical quirk, documented as-is: out-of-range wraps to `n - 1`,
unequal values subtract. Do not copy this; the corrected form is
[below](#wrap--worm_fullux) (and snake's `wrap`).

## wrap — worm_full.ux

```ux
wrap :: fn(x: u16, n: u16) -> u16 {
    if x < n {
        return x;
    }
    return x - n;
}
```

Half-open wrap for `0 <= x < 2n`. Exercised by the harness as
`wrap(25, 20)` (expect `5`).

## step — worm.ux (stub)

```ux
step :: fn() {
    dir = dir.next;
    head = head;
    dir_next: u8 = dir;
    ...
    label done;
    brk;
}
```

Placeholder: shuffles `head`/`tail` copies, counts `grow` down with a
`goto done` skip, speeds `wait.from` up past length 31 — then hits a
bare `brk;` inside a plain `fn`, which ends vector evaluation. Kept
as a record of the porting stage, not as an example.

## step — worm_full.ux

```ux
step :: fn() {
    dir = dir_next;
    tick = tick + 1;
    if dir == 0 {
        ...
    }
    ...
    if head_x == food_x {
        if head_y == food_y {
            grow = grow + 1;
            length = length + 1;
            new_food();
        }
    }
    ...
}
```

Real movement on a 20×20 board: right/down wrap via `wrap`, up/left
via explicit `0`-checks (unsigned underflow guard), eat detection
with growth, and the same length-31 speedup as the stub.

## new_food

```ux
new_food :: fn() {
    food = 0x0505;      ( worm.ux stub: fixed cell )
    ...
}
```

```ux
new_food :: fn() {
    food_x = (DateTime.second + tick) % width;
    ...
}
```

Stub places food at a fixed cell; `worm_full` derives it from the
wall clock plus `tick`, nudged off the head on collision.

## draw

```ux
draw :: fn() {
    clear_screen();
    draw_worm();
    draw_food();
    draw_score();
}
```

Both files share this shape; the leaves differ. Stub leaves park the
ports at fixed values (`clear_screen` fills with `0x80`,
`draw_score` sets `x/y/auto`). `worm_full` draws real sprites:
`draw_head`/`draw_food` set `auto = 0`, `addr = &head_chr` (or
`&food_ici`), position, then `sprite = 1`; its `draw` also runs a
`for i in 0..4` positioning loop before `Screen.auto = 21`.

## init

```ux
init :: fn() {
    head = 0x0303;      ( worm.ux: packed nibbles )
    ...
    Screen.vector = &on_frame;
}
```

Stub packs head/tail as `0x0303` nibbles with `dir.next` queued and
`state = 0`; `worm_full` uses separate `head_x`/`head_y` from `(3, 3)`
with `state = 1` and also runs one `step()` + `new_food()` up front.
Both arm `Screen.vector = &on_frame`.

## on_start

```ux
on_start :: fn() {
    System.r = 0xb06b;
    ...
    Screen.width = width * 8;
    Controller.vector = &on_controller;
    Mouse.vector = &on_mouse;
    init_random();
    init();
}
```

Theme, `20*8` screen, vectors, seed, init. (`worm_full` uses decimal
equivalents for the theme.)

## init_random

```ux
init_random :: fn() {
    DateTime.second = DateTime.second;
}
```

Self-assigning read that re-seeds the clock latch. Identical in both
files.

## on_controller

```ux
on_controller :: event() {
    if Controller.button == 8 {
        brk;
    }
    ...
    if Controller.key == 32 {
        ...
    }
}
```

Button dispatch with `brk` per arm, Escape exits the vector, Space
toggles `state`; the stub writes `dir`, `worm_full` writes
`dir_next`.

## on_mouse

```ux
on_mouse :: event() {
    brk;
}
```

Wired and ignored in both files.

## on_frame

```ux
on_frame :: event() {
    if state == 0 {
        brk;
    }
    if wait != 0 {
        wait = wait - 1;
        brk;
    }
    wait = wait.from;
    step();
    draw();
    brk;
}
```

Identical in both files: skip unless playing, throttle on `wait`,
then one `step()` + `draw()` per tick.

## main

```ux
main :: fn() {
    on_start();
}
```

Worm stub: boot and hand over to vectors. `worm_full` extends it into
a console harness — `wrap(25, 20)` probe plus 5 ticks printing `48 +
t` and `head_x` — whose expected bytes the suite diffs.
