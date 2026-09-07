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
| `<= >=` | `GTHk INC EQU` | `GTH2k INC2 EQU` | negated strict compare |
| `&& \|\|` | `AND` / `ORA` | — | bitwise, both sides evaluated |
| `<< n`, `>> n` | `SFT2` with folded `#n0`/`#0n` | same | amounts masked mod 16 |
| `x << y` (dynamic) | `y #40 SFT` then `SFT2` | same | amount to high nibble |
| `-x` | `#0000 SWP2 SUB2` | | wrap-around |
| `~x` | `#ffff EOR2` | | |
| `!x` | `#0000 EQU2` | | |

Comparisons (and only comparisons) use byte ops when both sides are
bytes; everything else runs at short width with automatic promotion
(`#00 SWP` zero-extends). Division and shifts are logical (unsigned);
there are no signed operations, matching the hardware.

## Calls, indexing, fields

```ux
draw_row(y);            ( ;draw_row JSR2, args promoted to param sizes )
Screen.x = x;           ( device port store )
b = Controller.button;  ( device port load )
tail[i] = v;            ( STA/STA2: value pushed first, address on top )
v = tail[i + 1];        ( LDA/LDA2; u16 elements scale the index by 2 )
p.x = p.x + 1;          ( group field access, same as devices )
Screen.vector = &on_frame;  ( address-of a label )
```

Call arguments are checked (arity plus `u8 → u16` widening) and
promoted to the declared parameter sizes at the call site. Indexing
needs a global array or buffer (locals are not indexable) and a
`u8`/`u16` index. Assigning to a device or group field always
type-checks — the port/field declaration is the contract.

## Assignment

`=` plus all compound forms (`+= -= *= /= %= &= |= ^= <<= >>=`,
desugared to `x = x op v`). Targets are variables, fields, and
indexed elements. The right-hand side is sized to the destination
(zero-extended or truncated); a `u16` value into a `u8` variable is a
type error — there is no silent narrowing.
