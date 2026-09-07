# Types

| Type | Size | Meaning on the stack |
|---|---|---|
| `u8` | 1 byte | a single stack byte, 0–255 |
| `u16` | 2 bytes | a big-endian short, high byte deeper |
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
