# Uxn mapping

How each ETAL construct becomes stack code. Read this with the
[Uxntal opcode reference](https://wiki.xxiivv.com/site/uxntal_reference.html)
open — ETAL invents no new semantics, it only chooses idioms.

## Stack discipline

Every expression leaves exactly `sizeof(type)` bytes: 1 for `u8`,
`bool` and byte ports/fields/elements; 2 for `u16`, addresses, and
short ports/fields/elements. Mixed-width operations promote the
narrow side (`#00 SWP` zero-extends a byte to a short); storing a
wide value into a narrow slot truncates (`NIP` keeps the low byte).
Comparisons always leave one `00`/`01` byte. If you can read the
types, you can simulate the stack by hand — the test suite does
exactly this against real ROMs.

## Program layout

```
|00                 zero-page reservations (@name $n, groups inline)
%RTN %EMIT %HALT    tiny macros; %\0 %\s %\n literals
|10 @Console/...    always-predeclared console device
|xxxx @const        integer constants (the address IS the value)
|page @Device...    device tables in declaration order
|0100 ;main JSR2    entry: call main, then HALT, then BRK
@fn ... JMP2r       functions; @event ... BRK for vectors
@data [ hh ... ]    blobs, then |addr @buf $n buffers, then strings
```

## Variables and scope

Globals reserve zero-page bytes sequentially from `$00`; the
compiler counts all 256 and fails past the limit. Locals (including
parameters and `for` variables) live in the same zero-page under
mangled names (`step__nx`), which is why functions of any size work
— relative `LDR/STR` addressing (limited to ±127 bytes) is never
used. The price is static storage: no recursion, no reentrancy.

Integer constants are labels placed at their own address, so `;name`
pushes the value for free. Identifier constants alias addresses;
anything else degrades to `|0000`.

## Control flow labels

All generated labels are function-scoped `&`-labels with per-function
counters (`if_then_1`, `while_cont_2`, `for_end_3`, `print_4`), so
nested and sequential constructs can never collide. User `label`/`goto`
compile straight to `&`/`!&` in the same scope.

## Devices, sprites and the screen

Ports compile to exactly one device op: `.Dev/port DEI` (or `DEI2`)
to read, `value .Dev/port DEO` (or `DEO2`) to write. The 2-byte form
is what triggers device effects, per Uxn semantics. Sprites are plain
ROM blobs (`@tile [ ... ]`); drawing is `Screen.addr = &tile` plus
`Screen/sprite DEO`, with `Screen.x/y` computed in pixels
(`cell << 3` folds to one `#30 SFT2`). See the
[Varvara spec](https://wiki.xxiivv.com/site/varvara.html) for what
each port does — ETAL adds no abstraction over it.

## Strings and printing

`"..."` becomes a NUL-terminated blob (`@str_N`) with `\s`/`\n`-style
escapes for the assembler. `print("...")` inlines the canonical loop
(`;str &loop LDAk .Console/write DEO INC2 LDAk ?&loop POP2`).
`varvara.console.write(b)` is a single `DEO` to port `0x18`.

## What the entry does

`|0100 ;main JSR2 HALT BRK`: reset calls `main`, and a returned `fn`
falls into `HALT` (exit). An `event` main instead ends its own
vector with `BRK`, so the emulator keeps running vectors — that one
opcode is the entire difference between a script and a game.
