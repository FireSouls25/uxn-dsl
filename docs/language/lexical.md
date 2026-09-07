# Lexical structure

## Comments

Two forms, both nestable-aware where it matters:

```ux
( paren comments need whitespace on both sides )
( nested ( comments ) work )
// line comments run to end of line
```

A `(` only starts a comment when preceded *and* followed by
whitespace (or file boundaries). This keeps grouping and calls
working: `(10`, `(DateTime` and `fn()` are code, `( comment )` is a
comment. A lone `/` is always the division operator — only `//`
starts a line comment. Unterminated constructs fail loudly instead of
silently eating the file.

## Literals

| Form | Type | Example |
|---|---|---|
| Decimal integer | `u8` if 0–255, `u16` if 256–65535 | `64`, `1000` |
| Hex integer | same ranges | `0xb06b`, `0xFF` |
| String | pointer to NUL-terminated bytes | `"Hello, World!\n"` |
| `true` / `false` | `u8` (`1` / `0`) | `if state == true` |

Integers outside 0–65535 are a compile error — Uxn has no bigger
primitive. String escapes: `\n`, `\t`, `\\`, `\"`; any other
`\x` yields literal `x`.

## Identifiers and keywords

Identifiers are letters, digits and underscores (must not start with a
digit). These words are reserved:

```
fn event return if elif else while for in match let const
import raw macro buffer device goto data group label
rpush rpop rpeek brk
u8 u16 bool byte short
true false
```

`match`, `let`, `const`, `byte` and `short` are reserved for future
use and cannot be used as names today. (The AST also contains
`RawLit`, `CompoundLit` and `RawStmt` nodes, but the parser never
builds them from surface syntax — they exist for tooling.)
