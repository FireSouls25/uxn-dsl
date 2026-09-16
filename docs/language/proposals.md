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
(obsolete — implemented on `dev`: `x: u16 mod N` with stores reduced
via the `%` lowering; see [types](types.md#modular-integers).)

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
(obsolete — implemented on `dev`: bare `return;` emits `BRK` in
events, `JMP2r` elsewhere; see [statements](statements.md).)

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
(obsolete — v1 implemented on `dev`: parser builds `Match`,
expander lowers to a freshened temp + if/elif chain with
single-evaluation; integer arms plus trailing `_`; see
[statements](statements.md).)

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
(obsolete — implemented on `dev` as scoped, plus locals and strict
whole-value rejection; see [declarations](declarations.md). v2 on
`dev`: nested structs, fixed array fields, chained paths and
same-type whole-value `=` via a stashed-pointer byte copy; params,
returns and comparison stay field-wise.)

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
(obsolete — implemented on `dev` exactly as sketched, as an
elaborate-then-check pass; see [declarations](declarations.md).)

---

## What Varvara/Uxn can still do that ETAL doesn't serve yet

The language covers compute, control flow, memory, sprites and input
well. The remaining gaps cluster around devices and UI text — fitting,
since this machine is centered on direct UI work:

 - **Audio.** Landed on `dev`: `data x = file("*.wav")` embeds
  8-bit mono 44100Hz samples with zero conversion (anything else is
  a compile error); `lib/audio.ux` has MIDI note consts, a stock
  square wave and one-shot `sfx`; `lib/song.ux` sequences `Track`
  rows through Audio0-3 (`track_next` pure per voice,
  `track_fire0-3` macros so unfired voices need no device,
  `song_tick` / `song_tick_all`). A `sound` sketch (one-shot blip
  on eat, using a tiny square-wave blob) is the right first artifact.
 - **Text.** Landed on `dev`: `lib/font.ux` is an in-repo 8×8
  1bpp font (printable ASCII 32–126, 760 bytes) plus `draw_char` /
  `draw_string` blit macros reusing the reviewed-macro pattern
  (`\n` newlines, out-of-range clamps to `?`), with pure
  `glyph_clamp` / `glyph_addr` fns gated headlessly. Scores and
  menus draw from buffers or literals; the compiler still has no
  font feature, per the library-first recommendation.
- **Sprite/pixel mode bits.** The `Screen/sprite` mode nibble (1bpp
  vs 2bpp, layer, flips) and `pixel` fill bits are currently magic
  numbers (`Screen.sprite = 1`). Named `::` constants already express
  these — what's missing is documentation mapping each bit, which
  belongs in [devices](../api/devices.md) alongside the
  port tables.
 - **File device.** Landed on `dev`: `lib/file.ux` has split-phase
  FileA macros (`file_read/write/stat/delete_req` initiate,
  `FileA.success` answers inline on native, `file_poll` /
  `file_on_event` complete portably for the web vector) over a
  game-declared `device FileA 160` block (see [devices](../api/devices.md)).
  Never request zero bytes (zero `success` reads as pending — stat
  first); paths are CWD-relative. `lib/test_file.ux` gates a full
  write/stat/read/poll/delete round-trip.
 - **Mouse.** Landed on `dev`: `lib/mouse.ux` has `MOUSE_*` masks
  (from the emulator's SDL mapping) and `mouse_poll` edge detection
  mirroring `menu_poll`, over a corrected `device Mouse 144` block
  (scroll at 9a/9c is one-shot with inverted Y — the old
  `chord`/`scrolly_hb` block in games was never read). Position
  stays a raw port read; live clicks need a display, so the gate
  feeds synthetic states.
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
(obsolete — implemented on `dev` as `codegen_cond`, exempting only
raw literals of unknowable width; see [statements](statements.md).)

## 9. Pre-pass function signatures (P0)

Calls to not-yet-defined functions silently skip arity checks and
argument promotion, because signatures are recorded in declaration
order in both the type checker and the generator — the same reason
macros needed whole-program collection. Fix it the same way: collect
all `FuncDecl` signatures before either pass. This deliberately does
*not* enable recursion (locals stay static; that limitation stands) —
it only makes call checking order-independent.
(obsolete — implemented on `dev`: pre-pass in checker, elaborator
and generator; undefined calls are now a compile error too.)

## 10. Data blobs as read-only arrays (P1)

Today `head_chr[3]` fails (`Undefined variable` — data names are never
registered), and worse, a bare `head_chr` expression silently compiles
to a zero-page read of a main-RAM label. Register every `DataDecl` as
`TypArray (TypU8, len)` in both environments: indexing then works
through the existing address math (`;head_chr`, scaled index, `LDA`),
and bare array idents should decay to their address (C-like) instead
of emitting garbage. Small, coherent, and it removes a silent
miscompile.
(obsolete — implemented on `dev`: inline blobs register as
`TypArray (TypU8, len)` (indexable, whole-copyable), file assets as
`(TypU8, 0)` (indexed access only — length is assembly-time, so
whole-copy is a loud error); bare blob values hit the array-value
rules instead of miscompiling. Address decay done too: arrays flow
into matching `&u8`/`&u16` parameters and initializers (the address
moves; plain `u16` still rejected), so `strlen(sbuf)` just works.)

## 11. `assert` for self-checking harnesses (P1, pairs with 12)

Harnesses currently print bytes for an external diff. An `assert E;`
statement would compile to: evaluate, skip on true, else
`print("assert failed\n")` + `brk` — failing tests halt loudly with
no outside tooling. Useless without locations, which is why it ships
with the next item.
(obsolete — implemented on `dev`: `assert E;` totals the condition,
prints `assert failed at file:line:col` (location baked at parse)
and `BRK`-halts; conditions mirror `if`; see
[statements](statements.md). check.sh gates a passing harness plus
the failing message via a location-aware gate.)

## 12. Source positions in errors (P1)

The lexer tracks line/col and drops them: tokens carry no positions,
so every error is a bare `failwith`. Thread positions from lexer
through parser (tokens become `token * pos`, failures report
`line:col` plus the source line), and `assert` messages become file
references instead of shrugs. Mechanical across `parser.ml`, large
UX payoff, zero language change.
(obsolete — implemented on `dev` with cheaper mechanics than
sketched: positions ride a parallel array (no token/match changes),
the parser prefixes every error via a shadowed `failwith`, the
loader merges per-file name tables (dup errors cite both lines),
and the checker/expander prefix via declaration context; `main`
prints one `etal: error:` line plus the source line and exits 1.
Checker errors point at the containing declaration — exact
use-site lines need AST-wide positions, still open.)

## 13. Unused-definition warnings (P1)

Track references during checking/generation (idents read, functions
called, labels targeted, blobs addressed — counting `AddrOf`, or
every vector handler would false-positive) and warn at the end for
never-used globals, locals, functions, labels and data. drifblim
already warns on unused *tal* labels; this catches dead ETAL a whole
pass earlier, with names attached.
(obsolete — implemented on `dev` as name-mentioned-equals-used
counting at the checker: warns unused globals, stored constants,
locals, parameters, data and assets with positions, to stderr at
exit 0. Skips functions (DCE prunes them by design), free `::`
constants (zero bytes), labels (zero cost, drifblim covers),
macros, buffers, devices, groups and structs; skips whole programs
containing raw; shadowing conflates (sound, occasionally quiet).
Gated by a location-aware `check_warn`.)

## 14. Hoist pure `for` bounds (P0)

The end bound re-evaluates every iteration. Hoist it into a hidden
freshened temp evaluated once — but only for syntactically pure
bounds (literals, idents, constants); anything that could call or
store keeps current evaluate-each-time semantics, documented as
such. The purity predicate is the entire design; the rest is one
temp slot.
(obsolete — implemented on `dev` for literal/variable/constant
bounds; call/store bounds keep evaluate-each-time; see
[statements](statements.md).)

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
(obsolete — implemented on `dev`: blob in the spec shape
(`00 title 0a author 00` + `$2` reserve), boot-time
`System/metadata` write, auto System table when undeclared, dup and
shape validation; see [declarations](declarations.md).)

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
