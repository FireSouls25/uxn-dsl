# Declarations

Every ETAL file is a list of top-level declarations, compiled in order
(definition order matters for call-site code generation — see
[limitations](limitations.md)).

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

## Globals and constants

```ux
head_x: u16;            ( zero-page, sequential from $00 )
head_x: u16 = 0x0303;  ( optional initializer )

width :: 20;            ( constant: address IS the value )
```

Globals reserve zero-page bytes in declaration order; the compiler
budgets all 256 bytes and fails past the limit instead of overlapping.
Constants are labels placed at their own value (`|0014 @width`), so
referencing one pushes the value — this only carries real values for
integer and identifier constants.

Locals use the same `name: type [= init];` syntax inside functions,
but live in per-function mangled slots (see [Uxn mapping](uxn-mapping.md)).

## Data and assets

```ux
data head = [ 252 238 239 ];          ( inline bytes -> @head [ fc ee ef ] )
data head_tile = file("assets/head.chr");  ( sprite file -> same thing )
```

Inline bytes (decimal or hex, keep them 0–255) and sprite files both
become ROM blobs. `file()` accepts `.chr` (16 bytes/tile, 2bpp planar:
first 8 bytes channel one, next 8 channel two) and `.icn` (8
bytes/tile, 1bpp); sizes are validated as whole tiles at compile time
and paths resolve relative to the declaring file. Use `&name` to take
a blob's address (e.g. `Screen.addr = &head_tile;`). Blobs are not
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
