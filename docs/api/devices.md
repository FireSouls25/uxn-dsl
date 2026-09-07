# Devices

A `device` block declares one Varvara device page: a base address plus
named ports with byte sizes. Every device automatically gets a 2-byte
`vector` port (omit it or declare it — same result). Reads compile to
`.Dev/port DEI` (`DEI2` for 2-byte ports), writes to `value
.Dev/port DEO` (`DEO2`), so device effects fire exactly as the
[Varvara spec](https://wiki.xxiivv.com/site/varvara.html) describes.

## Console (implicit, page `0x10`)

```ux
|10 @Console/vector $2 &read $1 &pad $4 &type $1 &write $1 &error $1
```

Predeclared by the compiler in every program — never redeclare it.
`&write $1` is port `0x18` (what `print` and `varvara.console.write`
target), `&read $1` is port `0x12`, `&error $1` is port `0x19`.

## `device System 0`

```ux
device System 0 {
    vector: 2
    expansion: 2
    wst: 1
    rst: 1
    metadata: 2
    r: 2
    g: 2
    b: 2
    debug: 1
    state: 1
}
```

The machine itself. Games use `System.r/g/b` for the palette theme
(snake: `45163`, `32876`, `16508`; worm stub: `0xb06b`, `0x806c`,
`0x407c`) and `System/vector` implicitly at boot. Declared in
`examples/snake/devices.ux` and `examples/worm/worm.ux`.

## `device Screen 32`

```ux
device Screen 32 {
    vector: 2
    width: 2
    height: 2
    auto: 1
    pad: 1
    x: 2
    y: 2
    addr: 2
    pixel: 1
    sprite: 1
}
```

The framebuffer. Typical setup (`on_start`): `Screen.width` /
`Screen.height` (snake: 128×128; worm stub: `width * 8`), then per
sprite: `Screen.x` / `Screen.y` in pixels, `Screen.addr = &tile`,
`Screen.sprite` with the blit mode/color. `Screen.pixel` fills
(`clear_screen` uses `128`, i.e. fill mode). `Screen.vector =
&on_frame` arms the 60Hz frame handler. Reduced blocks (test
fixtures) may omit ports they never touch — e.g.
`examples/tests/test_device.ux` declares only
`width/height/x/y/addr/pixel/sprite`, and `test_event.ux`'s Controller
only `button`.

## `device Controller 128`

```ux
device Controller 128 {
    vector: 2
    button: 1
    key: 1
}
```

Button byte (bitmask) and last key. The corpus convention, asserted by
the games:

| Value | Meaning |
|---|---|
| `button == 8` | Start/quit-ish (both games `brk` out) |
| `button == 16` / `32` / `64` / `128` | d-pad: up / down / left / right |
| `key == 27` | Escape |
| `key == 32` | Space (pause/resume/restart) |

Snake maps them through `set_dir` (with 180°-turn rejection);
`worm.ux` writes `dir` directly.

## `device Mouse 144`

```ux
device Mouse 144 {
    vector: 2
    x: 2
    y: 2
    state: 1
    chord: 1
    pad: 4
    scrolly: 1
    scrolly_hb: 1
    scrolly_lb: 1
}
```

Declared (and vectored to a `brk`-only `on_mouse`) in both games;
neither game reads it yet. `test_device.ux` shows the smaller shape
(`x`, `y`, `state`) with a `handler :: fn()` that copies
`Mouse.x` → `Screen.x`.

## `device DateTime 192`

```ux
device DateTime 192 {
    year: 2
    month: 1
    day: 1
    hour: 1
    minute: 1
    second: 1
    dotw: 1
    doty: 2
    isdst: 1
}
```

Wall clock. Both games seed RNG from it (`seed = DateTime.second +
DateTime.minute * 256` in snake; `DateTime.second =
DateTime.second` in the worm stub). Test harnesses pin `seed`
afterwards for determinism.
