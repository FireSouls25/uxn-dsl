# Declarations

Every ETAL file is a list of top-level declarations. Function
signatures are collected whole-program before checking, so call
order is free (definition order only matters for zero-page layout
and entry emission) — but recursion stays unsupported, see
[limitations](limitations.md).

## Devices

```ux
device Screen 32 {
    vector: 2
    width: 2
    height: 2
    x: 2
    y: 2
    sprite: 1
}
```

Declares a Varvara device: a page number plus named ports with byte
sizes. Every device automatically gets a 2-byte `vector` port, so you
may omit it. Emits the assembler's device table
(`|20 @Screen/vector $2 &width $2 …`) and enables typed port access:

```ux
Screen.width = 128;      ( value .Screen/width DEO2 )
x: u16 = Screen.width;   ( .Screen/width DEI2 )
```

A 1-byte port uses `DEI`/`DEO`, a 2-byte port `DEI2`/`DEO2`. Values
assigned to ports are sized to fit. Reading a 2-byte port's high byte
(or writing its low byte) triggers the device effect, per Uxn
semantics — ETAL does not hide this; it just spells it.

The `Console` device at page `0x10` is predeclared with the standard
ports, so `varvara.console.write(b)` works with no declaration. Do
not redeclare it.

## Groups

```ux
group pos: u8 {
    x: u8
    y: u8
}
```

A zero-page struct: a base value plus contiguous named fields,
addressed as `.pos/x`. The base itself is an ordinary variable of the
given type. Groups are how Uxntal's `@label &field $n` idiom is
spelled with types attached; field offsets follow field sizes.

## Variables and constants (Odin-style)

The second symbol decides mutability — there is no `const` keyword:

```ux
head_x: u16;            ( explicit type, mutable )
head_x: u16 = 0x0303;   ( explicit type, mutable, optional initializer )
tries := 0;             ( inferred type, mutable: u16, from the literal )
LIMIT : u16 : 20;       ( explicit type, constant )
WIDTH :: 20;            ( inferred type, constant: address IS the value )
```

- `name : type [= init];` — mutable variable (global: zero-page from
  `$00` in declaration order; local: per-function mangled slot).
  Global initializers run at startup, before `main` is called.
- `name := init;` — same, with the type inferred from the initializer
  (literals by range, identifiers by copy, calls by return type;
  `void` is rejected). `for`-loop variables stay explicitly `u16`.
- `name : type : init;` — constant with a checked type: zero-page
  storage initialized once, and any assignment to it is a compile
  error. Reads like a variable.
- `name :: init;` — constant without storage: a label placed at its
  own value (`|0014 @WIDTH`), so referencing it pushes the value at
  zero cost. Only integer and identifier initializers carry real
  values this way.

Convention (not enforced): `::` constants are `ALL_CAPS`, like the
`WIDTH` above; variables are `snake_case`. Locals use the same four
forms inside functions.

## ROM metadata

```ux
meta { title: "Snake", author: "you" }
```

Top-level only, at most once per program (a second block anywhere in
the import splice is a duplicate-definition error). Emits a
`@etal_meta` blob in the Varvara shape (`00 "Title" 0a "Author" 00`)
plus a boot-time `;etal_meta .System/metadata DEO2` write so
emulators pick it up. If the program doesn't declare its own `System`
device, a minimal table is emitted for the wiring. Both fields are
required, non-empty, and NUL-free; unknown fields are rejected.

## Globals and layout

Globals reserve zero-page bytes in declaration order; the compiler
budgets all 256 bytes and fails past the limit instead of overlapping.

## Data and assets

```ux
data head = [ 252 238 239 ];          ( inline bytes -> @head [ fc ee ef ] )
data head_tile = file("assets/head.chr");  ( sprite file -> same thing )
data blip = file("blip.wav");             ( 8-bit mono 44100Hz -> samples )
```

Inline bytes (decimal or hex, keep them 0–255) and sprite files both
become ROM blobs. `file()` accepts `.chr` (16 bytes/tile, 2bpp planar:
first 8 bytes channel one, next 8 channel two) and `.icn` (8
bytes/tile, 1bpp); sizes are validated as whole tiles at compile time
and paths resolve relative to the declaring file. `.wav` accepts
canonical 8-bit mono PCM at 44100Hz — exactly what Uxn plays
natively, so samples embed with zero conversion; anything else
(stereo, 16-bit, other rates, non-PCM) is a compile error, never a
silent resample. Use `&name` to take a blob's address (e.g.
`Screen.addr = &head_tile;`, `Audio0.addr = &blip;`). Blobs are not
indexable — see [limitations](limitations.md).

## Buffers and arrays

```ux
buffer tail[256]: u16;   ( main RAM, absolute addressed )
grid: [64] u8;           ( small zero-page array )
```

`buffer` reserves main-RAM space (from `0x2000` upward, sequentially)
for anything too big for zero-page — grids, tails, tables. Small
fixed arrays can also live in zero-page with `[N] T` globals. Both
are read and written with identical syntax:

```ux
tail[i] = nx;            ( STA/STA2 with scaled index )
v: u16 = tail[i + 1];    ( LDA/LDA2; u16 elements scale by 2 )
```

Only global arrays and buffers are indexable; there are no array
literals or initializers, and no bounds checks — like the hardware.

## Structs

```ux
Point :: struct { x: u16; y: u8; };

buffer pts[64]: Point;   ( 64 rows × 3 bytes, main RAM )
p: Point;                ( one row, zero-page slot )

pts[i].x = nx;           ( base + i*3, then +0 field offset )
py: u8 = p.y;            ( slot address + 2 )
```

```ux
Note :: struct { pitch: u8; len: u8; };
Track :: struct { notes: [8] Note; vol: u8; };

buffer tracks[4]: Track;
t: Track;

tracks[i].notes[2].pitch = 60;   ( chained: row + field + element )
t.vol = 200;
t = tracks[0];                   ( whole-value copy, same type )
```

A `struct` declares field offsets at type-check time (v2 fields are
scalars, previously-declared structs, or fixed arrays of either —
no `mod`, no pointers; order matters, so forward references and
cycles fail as unknown types). Paths chain through nesting and
arrays, and same-type struct values copy whole with `=` — but
comparing, passing or returning a whole struct is still a compile
error with a field-directed message. Struct-typed variables take no
initializer (declare bare, then copy or assign fields); buffers of
structs are the fix for parallel-array desync. A trailing `;` after
the closing brace is accepted.

## Functions and events

```ux
wrap :: fn(x: u16, n: u16) -> u16 {
    if x < n { return x; }
    return x - n;
}

on_frame :: event() {
    step();
    draw();
    brk;
}
```

Functions are Uxn subroutines (`JSR2` in, `JMP2r` out, arguments on the
stack). Events are vector handlers: identical shape, but they return
with `BRK`, handing control back to the emulator. The program entry
calls `;main JSR2` then halts — so `main :: fn()` scripts run and
exit, while `main :: event()` games stay in the event loop.
`return;` returns void early; falling off the end returns implicitly.
There is no recursion or reentrancy (static locals — see
[limitations](limitations.md)).

Two builtins exist without declaration: `print("...")`, which inlines
a loop writing a NUL-terminated string to the console, and
`varvara.console.write(b)` / `.read()` / `.error`, the raw console
ports.

## Macros

```ux
macro mod16(a: u16, b: u16) -> u16 {
    return a - a / b * b;
}
```

Macros expand to AST before type checking: zero-cost inlining with
full type checking. A single-`return` body may be used as an
expression; any body may be spliced as a statement (a returned value
is then discarded, a bare `return;` returns from the caller). Labels,
gotos and macro-local bindings are freshened per expansion, so double
expansion cannot collide; macro bodies may use parameters, globals and
their own locals, but not the caller's locals. Recursive macros are
rejected. Unlike Uxntal `%macros`, order does not matter — macros are
collected from the whole program before expansion.

## Imports

```ux
import "logic.ux"
```

Splices another file's declarations in order, relative to the
importing file (not the current directory — a deliberate difference
from Drifblim's `~`). Recursive, include-once (diamonds are fine),
with errors for missing files, cycles, and duplicate top-level
definitions across the splice (one shared namespace, as if it were a
single file).

## Raw blocks

```ux
raw {
@table [ 00 11 22 ]
}
```

Captures one balanced `{ ... }` block (brace-aware of strings and
comments) and emits it verbatim with the data section. Intended for
data and tables the DSL cannot express — not for smuggling control
flow, since placement after the code means tal `%macros` pasted this
way would land after their use sites. (A legacy bare-`raw` form reads
to end-of-file and must stay last; prefer the block form.)
