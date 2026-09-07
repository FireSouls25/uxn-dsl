# Proposals

Assessed language improvements, ordered roughly by value over effort.
Each entry gives a verdict, the Uxn-grounded reasoning, and a concrete
design sketch. Nothing here is implemented — this is the roadmap input,
not a changelog. Cross-references to current behavior point at the
exact rules in [limitations](limitations.md).

Conventions used below: *P0* = small, isolated change; *P1* = medium,
touches two or more passes; *P2* = large or load-bearing design work.

## 1. Modular arithmetic type — accept, scoped to const modulus

**Verdict: yes.** Grid wraparound is the most re-derived snippet in
the corpus: `wrap()` covers right/down while up/left need manual
`if x == 0` guards, purely because unsigned subtraction underflows.
A true modulo fixes both directions uniformly — `(0 - 1) % 16` is
`15`, no special case — using only the existing `%` lowering
(`DIV2k MUL2 SUB2`), so no new opcodes are involved.

```ux
x: u16 mod grid;      ( sketch: bound lives with the variable )
x = x + 1;            ( wraps 15 -> 0 automatically )
x = x - 1;            ( wraps 0 -> 15 automatically )
```

Design constraints that keep it coherent:

- The modulus must be a **compile-time constant** (v1). A dynamic
  bound would need the bound stored and re-emitted per operation;
  constant bounds cover grids, rings and animation frames.
- Mixed-modulus arithmetic (`mod16 + mod20`) is a type error; mixing
  with plain `u16` coerces to plain `u16` (the result is no longer
  bounded). Comparisons yield plain `bool` as usual.
- This is a new `typ` variant flowing through sizes, promotion and
  the `expr_is_u8` rule — *P1*, not *P0*, because every sizing
  decision must learn the new case. The payoff is deleting `wrap()`
  *and* all four directional branches at once.

Status: accepted as scoped above; not scheduled.

## 2. Implicit `brk` in events — half already true; finish it via `return`

**Verdict: yes, and the first half needs no work.** Event functions
already end with an implicit `BRK` — verified in output (`@on_frame`
today ends `BRK BRK`: one manual, one generated). So trailing `brk;`
is already redundant; only *early-exit* `brk;` carries meaning.

The real gap is adjacent: bare `return;` inside an event currently
emits `JMP2r`, which pops a bogus return address because vectors are
never `JSR`-called — a genuine footgun, verified in output. The
completion of this proposal is one rule: **`return;` in an event
emits `BRK`**. Then early exits read naturally, manual `brk;`
becomes fully optional, and the dangerous lowering disappears:

```ux
on_frame :: event() {
    if state != 1 {
        return;      ( would emit BRK: safe early exit )
    }
    step();
    draw();          ( trailing BRK already implicit )
}
```

*P0*: one conditional in statement codegen plus a test. No syntax,
no type changes.

## 3. `switch`/`match` dispatch — accept, desugar first

**Verdict: yes.** `set_dir` and the `step` movement chain are
sequences of independent `if d == N` tests over mutually exclusive
values — the language cannot see the exclusivity, so it compiles
sequential comparisons that keep testing after a match. The lexer
already reserves a `match` keyword for exactly this.

```ux
match dir {
    0 => { ... }
    1 => { ... }
    _ => { ... }
}
```

Two honest halves, deliberately split:

- **Readability + exhaustiveness (v1, desugar):** lower `match` to
  the existing `if`/`elif` chain in the parser or expander. Zero
  codegen work, full existing test suite applies, and a missing
  default arm can warn. This alone is worth doing.
- **Jump tables (v2, backend optimization):** on this VM a dense
  `u8` match *can* become `base + i → LDA2 → JMP2` — O(1) instead of
  O(n) comparisons. Real, but keep perspective: at n=4 directions the
  win is nanoseconds on emulated hardware; it matters for big
  dispatchers (opcode-like interpreters, tile behavior tables), not
  for `set_dir`. Implement only for dense unsigned ranges with a
  default arm; sparse matches keep the compare chain.

Status: v1 accepted; v2 on merit per use case.

## 4. Structs over parallel arrays — accept

**Verdict: yes.** `tail_x[256]` + `tail_y[256]` move together at every
use — same index, same moment — which is a desync bug waiting for a
refactor to trigger it. Notably, the *parser already accepts*
`tail[i].x` (field chains include subscripts); only the types and
codegen don't know what it means yet.

```ux
Point :: struct { x: u16; y: u16 }
buffer tail[256]: Point;
tail[i].x = nx;      ( base + i*4, then +0 field offset )
```

Design: `struct` declares field offsets at type-check time; codegen
emits address arithmetic (`;tail`, scaled index, field offset) for
both loads and stores. Keep `group` as-is for zero-page structs;
`struct` is the value type for buffers and locals. *P1*: new decl,
field-offset environments, and the combined Index+Field codegen paths
in both directions. The shift loop collapses from two lines to one,
and the desync class disappears by construction.

## 5. Ring buffer type — accept as library first, correct the framing

**Verdict: yes, but not for performance.** An O(n) shift over ≤256
shorts per frame is noise even on slow hardware — the honest wins
are deleting the manual shift loop and the `seg_len` bookkeeping that
surrounds it, i.e. fewer places for off-by-one bugs.

```ux
ring tail[256]: Point;   ( sketch )
tail.push_front(nx, ny);
tail.pop_back();
```

Crucially, a ring for this game still needs **indexed reads**
(self-collision scans the whole tail), so it cannot be an opaque
queue: head/tail indices plus modular indexing, with random access
preserved. Recommended path: implement it first as plain ETAL
functions over a buffer (`push/shift` helpers prove the API against
the existing gates), and only promote to a native type if the pattern
repeats elsewhere. The native version would also be the place to get
full-board (`seg_len == 256`) handling in one well-tested spot.

## 6. Draw-call sugar — agree with the problem, not the builtin

**Verdict: the hazard is real; a `Screen`-specific builtin is the
wrong fix.** Device effects trigger on specific port writes (the
sprite blit reads `addr`/`x`/`y`/`auto` at the moment `sprite` is
written), so order is semantic, not stylistic — reordering really
does draw wrong. But hardcoding one device into the language breaks
the design rule that devices are user-declared data (see [design
decisions](../language/index.md)).

What works *today*, with zero compiler changes:

```ux
macro blit(x: u16, y: u16) {
    Screen.x = x;
    Screen.y = y;
    Screen.addr = &body_tile;
    Screen.sprite = 1;
}
```

Order lives in one reviewed place; every call site is one line; the
macro expander type-checks the body. Longer term, if this pattern
spreads to audio/file ports, the general mechanism to consider is
port-order annotations on `device` blocks or atomic multi-port
writes — not per-device builtins. (This hazard is now also listed in
[limitations](limitations.md).)

## 7. Type inference with `:=` — accept, resolved at type-check

**Verdict: yes.** `tries: u16 = 0;` repeats what the literal already
says. The clean design point: parse `name := expr` into a pending
declaration and resolve its type in the *type checker* (which already
computes every expression's type), then flow through the normal
`VarDecl` path:

```ux
tries := 0;          ( u16, from the literal rule )
c := five;           ( copies the constant's type )
```

Rules that keep it predictable: literals infer by the existing
literal-typing rule; identifiers copy; anything else infers its
expression type, with `void` rejected. `for`-loop variables stay
explicitly `u16` (the loop rule, not inference). Macro-expanded code
works unchanged since expansion precedes checking. Lexer cost is one
token (`:=` currently lexes as `:` + `=` and fails in the parser, so
nothing valid changes meaning). *P0–P1*: one token, one AST node,
type-side resolution, freshening already handles the new binder.

---

## What Varvara/Uxn can still do that ETAL doesn't serve yet

The language covers compute, control flow, memory, sprites and input
well. The remaining gaps cluster around devices and UI text — fitting,
since this machine is centered on direct UI work:

- **Audio.** No helpers exist, but nothing blocks it either: declare
  the Audio ports and write sample addresses, lengths, `ADSR` and
  `pitch` exactly like screen ports. A `sound` sketch (one-shot blip
  on eat, using a tiny square-wave blob) is the right first artifact.
- **Text.** There is no font story: no glyph tables, no
  `draw_char`/`draw_string`. Orca-style games need these for scores
  and menus. Recommended as a *library* (`font.ux`: an 8×8 font blob
  plus blit routines reusing proposal 6's macro pattern), not a
  compiler feature.
- **Sprite/pixel mode bits.** The `Screen/sprite` mode nibble (1bpp
  vs 2bpp, layer, flips) and `pixel` fill bits are currently magic
  numbers (`Screen.sprite = 1`). Named `::` constants already express
  these — what's missing is documentation mapping each bit, which
  belongs in [devices](../api/devices.md) alongside the
  port tables.
- **File device.** Directory listings, chunked reads/writes and the
  append/delete protocol all work through declared ports today, but
  the vector-driven async pattern (request on one vector, consume on
  another) wants a callback-door idiom documented before anyone
  should rely on it. Genuine future work, not a gap in primitives.
- **Mouse.** Declared and vectored, never read by any game. Usable
  today via `Mouse.x/y DEI2`; no sugar proposed until a game needs it.
- **System/expansion banks.** Fill/copy operations beyond 64K are
  unexposed. Out of scope until a program outgrows addressable
  memory; when it does, expose the three ops, not the raw ports.

---

# Part II — maintainer suggestions

Second batch, from working in the implementation. Same format:
verdict, Uxn-grounded reasoning, concrete sketch, effort. Nothing
here is implemented.

## 8. Total boolean conditions (correctness, P0)

Bare-`u16` conditions are listed in [limitations](limitations.md) as
a footgun (low-byte test plus a leaked byte), but the fix is small
enough to just do: in `If`/`While` codegen, after emitting the
condition, append `#0000 NEQ2` unless the expression provably leaves
exactly one byte (the existing `expr_is_u8` rule already answers
that: literals ≤255, `u8` bindings, comparisons, `!`, byte ports and
byte elements). Anything else is treated as a short — which is sound
for every case including `u16` arithmetic and short-width `&&`/`||`
results. No syntax, no type changes; every existing program keeps its
bytes except the previously-broken ones.

## 9. Pre-pass function signatures (P0)

Calls to not-yet-defined functions silently skip arity checks and
argument promotion, because signatures are recorded in declaration
order in both the type checker and the generator — the same reason
macros needed whole-program collection. Fix it the same way: collect
all `FuncDecl` signatures before either pass. This deliberately does
*not* enable recursion (locals stay static; that limitation stands) —
it only makes call checking order-independent.

## 10. Data blobs as read-only arrays (P1)

Today `head_chr[3]` fails (`Undefined variable` — data names are never
registered), and worse, a bare `head_chr` expression silently compiles
to a zero-page read of a main-RAM label. Register every `DataDecl` as
`TypArray (TypU8, len)` in both environments: indexing then works
through the existing address math (`;head_chr`, scaled index, `LDA`),
and bare array idents should decay to their address (C-like) instead
of emitting garbage. Small, coherent, and it removes a silent
miscompile.

## 11. `assert` for self-checking harnesses (P1, pairs with 12)

Harnesses currently print bytes for an external diff. An `assert E;`
statement would compile to: evaluate, skip on true, else
`print("assert failed\n")` + `brk` — failing tests halt loudly with
no outside tooling. Useless without locations, which is why it ships
with the next item.

## 12. Source positions in errors (P1)

The lexer tracks line/col and drops them: tokens carry no positions,
so every error is a bare `failwith`. Thread positions from lexer
through parser (tokens become `token * pos`, failures report
`line:col` plus the source line), and `assert` messages become file
references instead of shrugs. Mechanical across `parser.ml`, large
UX payoff, zero language change.

## 13. Unused-definition warnings (P1)

Track references during checking/generation (idents read, functions
called, labels targeted, blobs addressed — counting `AddrOf`, or
every vector handler would false-positive) and warn at the end for
never-used globals, locals, functions, labels and data. drifblim
already warns on unused *tal* labels; this catches dead ETAL a whole
pass earlier, with names attached.

## 14. Hoist pure `for` bounds (P0)

The end bound re-evaluates every iteration. Hoist it into a hidden
freshened temp evaluated once — but only for syntactically pure
bounds (literals, idents, constants); anything that could call or
store keeps current evaluate-each-time semantics, documented as
such. The purity predicate is the entire design; the rest is one
temp slot.

## 15. `meta {}` block for ROM metadata (P0, UI-relevant)

Verified working today by hand: `System.metadata = &meta;` with a
`data meta = [...]` blob emits exactly `;meta .System/metadata
DEO2`. The sugar just removes the ceremony:

```ux
meta { title: "Snake", author: "..." }
```

Emits the blob plus the wiring. Exact blob layout to be pinned
against the Varvara metadata doc during implementation — the
mechanism is proven, the format needs one spec check.

## 16. Button-mask input idiom (docs now, `match` later)

`main.ux` tests `==` per button with a `brk` per arm, so combined
presses (up+right = `0x90`) match nothing — diagonals are impossible.
No compiler change needed to fix the pattern; this works today and
belongs in the examples:

```ux
b: u8 = Controller.button;
if b & 16 != 0 { ... }   ( up held, regardless of other bits )
```

Longer term this is evidence for `match` guards (proposal 3): plain
equality dispatch preserves the gap, bitmask arms would close it.

## Deliberately not proposed

- **Signed arithmetic.** The hardware has none; `Neg`-as-`0-x` plus
  unsigned ops cover real games. Full signed emulation is library
  territory if anyone ever needs it.
- **Heap, GC, classes, exceptions.** No runtime exists to implement
  them with, and adding one would betray the "what you write is what
  runs" contract.
- **String variables and concatenation.** Needs a fat-pointer
  representation decision; literals plus `print` cover current games.
- **Recursion.** Static zero-page locals are the design; document,
  don't fight.
- **Custom entry/layout control.** The fixed `;main JSR2 HALT`
  vector is load-bearing for tooling (harnesses assume
  halt-after-main); leave it fixed.
