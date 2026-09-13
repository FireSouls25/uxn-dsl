# Expressions

Precedence, highest to lowest (each level left-associative except
comparisons, which do not chain):

| Level | Operators |
|---|---|
| postfix | `f(...)`, `a[i]`, `a.b` |
| unary | `&x` (address-of), `-x`, `~x`, `!x` |
| multiplicative | `*`, `/`, `%` |
| additive | `+`, `-` |
| shift | `<<`, `>>` |
| bitwise AND | `&` |
| bitwise XOR | `^` |
| bitwise OR | `\|` |
| comparison | `==`, `!=`, `<`, `>`, `<=`, `>=` |
| logical AND / OR | `&&`, `\|\|` |

## Operators and their Uxntal

| ETAL | Uxntal (bytes) | Uxntal (shorts) | Notes |
|---|---|---|---|
| `+ - * /` | `ADD SUB MUL DIV` | `ADD2 SUB2 MUL2 DIV2` | `/` by zero yields 0 |
| `%` | `DIVk MUL SUB` | `DIV2k MUL2 SUB2` | remainder idiom, no opcode |
| `& \| ^` | `AND ORA EOR` | `AND2 ORA2 EOR2` | |
| `== != < >` | `EQU NEQ LTH GTH` | `EQU2 NEQ2 LTH2 GTH2` | always `00`/`01` |
| `<= >=` | `GTH #00 EQU` | `GTH2 #00 EQU` | negated strict compare, then test |
| `&& \|\|` | `AND` / `ORA` | each side `#0000 NEQ2` first | total: any widths combine safely |
| `<< n`, `>> n` | `SFT2` with folded `#n0`/`#0n` | same | amounts masked mod 16 |
| `x << y` (dynamic) | `y #40 SFT` then `SFT2` | same | amount to high nibble |
| `-x` | `#00 SWP SUB` | `#0000 SWP2 SUB2` | width follows the operand |
| `~x` | `#ff EOR` | `#ffff EOR2` | width follows the operand |
| `!x` | `#00 EQU` | `#0000 EQU2` | width follows the operand |

Comparisons (and only comparisons) use byte ops when both sides are
bytes; everything else runs at short width with automatic promotion
(`#00 SWP` zero-extends) — except `-x`/`~x`/`!x`, which keep their
operand's width, and `&&`/`||`, which reduce each side to one byte
first. `if`/`while` conditions get the same treatment, so short
conditions test the full value. Division and shifts are logical
(unsigned); there are no signed operations, matching the hardware.
A `-> u8` callee leaves one byte and callers compose accordingly;
`return expr` is sized to the declared return type.

## Calls, indexing, fields

```ux
draw_row(y);            ( ;draw_row JSR2, args promoted to param sizes )
Screen.x = x;           ( device port store )
b = Controller.button;  ( device port load )
tail[i] = v;            ( STA/STA2: value pushed first, address on top )
v = tail[i + 1];        ( LDA/LDA2; u16 elements scale the index by 2 )
p.x = p.x + 1;          ( group field access, same as devices )
pts[i].x = nx;          ( struct row field: base + i*size, then offset )
Screen.vector = &on_frame;  ( address-of a label )
```

Call arguments are checked (arity plus `u8 → u16` widening,
order-independent since signatures pre-pass) and promoted to the
declared parameter sizes at the call site; calling an undefined
function is a compile error. Indexing needs a global array or buffer
(locals are not indexable) and a `u8`/`u16` index. Assigning to a
device or group field always type-checks — the port/field
declaration is the contract.

## Assignment

`=` plus all compound forms (`+= -= *= /= %= &= |= ^= <<= >>=`,
desugared to `x = x op v`). Targets are variables, fields, and
indexed elements. The right-hand side is sized to the destination
(zero-extended or truncated); a `u16` value into a `u8` variable is a
type error — there is no silent narrowing.
