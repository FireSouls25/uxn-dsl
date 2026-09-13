# Types

| Type | Size | Meaning on the stack |
|---|---|---|
| `u8` | 1 byte | a single stack byte, 0–255 |
| `u16` | 2 bytes | a big-endian short, high byte deeper |
| `u16 mod N` | 2 bytes | a short always in `[0, N)` — stores wrap |
| `u8 mod N` | 1 byte | a byte always in `[0, N)` — stores wrap |
| `bool` | 1 byte | `0x00` or `0x01` (guaranteed by comparisons) |
| `void` | 0 bytes | no value (statements, void calls) |
| `[N] T` | N × sizeof(T) | fixed array (only `u8`/`u16`/`bool` elements) |
| `&T` | 2 bytes | address of a `T` |

## Literal typing

Integer literals take the smallest type that fits: 0–255 is `u8`,
256–65535 is `u16`. This is why `Screen.x = 0` just works (the `0`
widens) while `Screen.x = 1000` also works (already a short).

## Operator typing

Arithmetic (`+ - * / %`) and bitwise (`& | ^ << >>`) operators yield
`u8` when **both** sides are `u8`, otherwise `u16` — mixed operands
promote. Comparisons (`== != < > <= >=`) and `&&`/`||` yield `bool`.

Note: `&&` and `||` are bitwise `AND`/`ORA`, not short-circuiting —
they evaluate both sides, like everything else on a stack machine.

## Modular integers

```ux
x: u16 mod 16;     ( grid coordinate: always 0-15 )
x = x + 1;         ( 15 -> 0, no branch )
x = x - 1;         ( 0 -> 15, no special case )
```

The bound lives with the variable: every store into it is reduced
with the existing `%` lowering (`DIV2k MUL2 SUB2`), so no new opcodes
are involved. The modulus must be a compile-time literal fitting the
base (`u8`: 1–256, `u16`: 1–65535).

Typing rules: same-modulus arithmetic stays bounded (width widens);
**mixed moduli are a type error** (`mod16 + mod20` — reduce one side
with `%` first); mixing with plain integers coerces to plain (the
result is no longer bounded, but storing it back re-wraps); bitwise
operators decay to the plain base; comparisons yield `bool` as usual.
A mod value flows wherever its base fits — including `u8` slots when
the modulus is ≤ 256 — and plain values may be passed to mod-typed
function parameters (reduced on entry). Mod types live on variables
only: buffer elements, group fields and bases reject them.

Exactness note: reduction is `DIV`-based, so it is exact for `+`/`-`
when operands are in range (subtraction can never overflow: Uxn wraps
mod 65536 first, and `(x mod 65536) mod m` is `x mod m`). `*` can
overflow 16 bits before reducing when `m*m ≥ 65536` — keep products
small or reduce an operand with `%` first.

## Widening and narrowing

`u8` widens to `u16` implicitly: initializers, assignments, call
arguments, and mixed operators. There is **no implicit narrowing**:
assigning a `u16` to a `u8` is a type error. The single exception is
`varvara.console.write` / `error`, which truncate to the low byte,
because console ports are inherently byte-wide.

## Truthiness

`if`, `elif` and `while` accept `bool`, `u8` or `u16`. Prefer real
comparisons (`x != 0`); see [limitations](limitations.md) for what a
bare `u16` condition does.
