# Standard library

`lib/` holds plain ETAL modules — no compiler magic, just functions
over the existing types, usable from any game via file-relative
imports:

```ux
import "../lib/fix16.ux"
```

Conventions: single-result functions only (ETAL has no multiple
return — multi-result algorithms are caller-composed from `u16` ops,
see `u32` below); `ALL_CAPS` constants; every module ships a
`test_<name>.ux` console harness whose expected bytes are documented
in its header and enforced by `sh lib/check.sh` (local-only, needs
SDL2 like `tests/smoke.sh`).

## fix16.ux

8.8 signed fixed point over `u16` shorts, modeled on fix16.tal: range -128 <= x < 128, `#8000` is invalid input.
Operations saturate at `#7fff`/`#8001` instead of wrapping;
division by zero saturates; negative quotients truncate toward zero.
Two intentional divergences from fix16.tal, both fixes: `floor`
of a negative fraction rounds to the true floor (theirs clears the
low byte, overshooting to `-2` for `-0.5`), and `round` saturates
`127.5` to `#7fff` (theirs wraps to `#8000`).

| Kind | Functions |
|---|---|
| constants | `X16_ZERO ONE MINUS_ONE PI HALF_PI E MAXIMUM MINIMUM` |
| arithmetic | `x16_add sub neg mul div` (signed; exact restoring division) |
| compare | `x16_eq ne lt lteq gt gteq min max` |
| convert | `x16_from_int` (0–127, saturates), `x16_to_int` (truncate toward zero, as `u16` bits), `x16_is_whole floor ceil round` (half-even) |

Not yet ported (they need a short-blob story for their tables):
`sin`/`cos`/`tan`/`log`/`sqrt`.

## u32.ux

32-bit predicates over `(ahi, alo)` short pairs, modeled on
math32.tal: `u32_eq ne is_zero non_zero lt lteq gt gteq` plus
`u8_bitcount`/`u16_bitcount`. Predicates only, because arithmetic
needs two shorts out and ETAL functions return one.
Compose it at the call site instead:

```ux
lo: u16 = alo + blo;             ( wraps mod 65536 )
carry: u16 = 0;
if lo < alo { carry = 1; }
hi: u16 = ahi + bhi + carry;
```

Multi-result returns (out-params or tuple returns) would obsolete
this pattern; until then the predicates plus three-line call sites
cover scores, timers and RNG state.
