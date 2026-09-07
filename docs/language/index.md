# Language design decisions

This page records *why* ETAL looks the way it does. The per-construct
reference lives next to it ([lexical](lexical.md), [types](types.md),
[declarations](declarations.md), [statements](statements.md),
[expressions](expressions.md)); the exact stack code each construct
produces is in [Uxn mapping](uxn-mapping.md), and what we knowingly
left out is in [limitations](limitations.md).

## 1. Typed surface, untyped machine

Uxn only knows bytes and shorts on two stacks. ETAL adds `u8`, `u16`,
`bool`, fixed arrays and pointers — not to change what runs, but to
make width mistakes compile-time errors instead of silent stack
corruption. The rule is mechanical: every expression leaves exactly as
many bytes as its type says, and the generator inserts zero-extension
(`#00 SWP`) or truncation (`NIP`) at every boundary. If you can read a
type you can predict the stack, which is the whole point.

## 2. Widening is free, narrowing is explicit-by-absence

`u8` widens to `u16` implicitly everywhere (literals, arguments,
assignments, mixed operators). The reverse never happens silently —
except one deliberate escape hatch: `varvara.console.write` truncates
to the low byte, because console I/O is inherently byte-oriented.
This mirrors the hardware (a short pushed where a byte is read just
works out on a stack machine) while keeping the common accident —
dropping the high byte of an address — a compile error.

## 3. Memory is explicit and visible

There are exactly three places data can live, each with its own
declaration, because on Uxn *where* something lives determines *how*
you touch it:

- **Zero-page** (`globals`, `groups`, locals): 256 bytes, `LDZ/STZ`
  single-byte addresses. Scarce and fast — the compiler budgets it
  and fails loudly past 256 bytes instead of silently overlapping.
- **Main RAM** (`buffer`): absolute `LDA/STA` from a fixed region.
  For anything big (grids, tails, tables).
- **ROM blobs** (`data`, assets): assembled inline, read-only,
  addressed absolutely.

No heap, no allocator, no hidden memory. The `.tal` output shows
every reservation, so `|00` overflows are reviewable, not mysterious.

## 4. Functions are subroutines, events are vectors

`fn` compiles to `JSR2`/`JMP2r` — plain Uxn subroutines, arguments on
the stack. `event` is the same shape but returns with `BRK`, which is
what makes it a Varvara vector: returning from a vector hands control
back to the emulator. This is why `main :: fn()` programs run and
halt (the entry does `;main JSR2 HALT`) while `main :: event()` games
stay in the event loop. Locals are static zero-page slots (mangled
per function), so there is deliberately no recursion or reentrancy —
matching what hand-written Uxntal programs actually do.

## 5. Macros expand to AST, not text

Uxntal `%macros` are textual substitution. ETAL macros expand to AST
*before* type checking, with parameters substituted as expressions and
labels/locals freshened per expansion. You get zero-cost inlining
with full type checking and hygiene — the common macro bugs (double
expansion label collisions, untyped pastes) become compile errors.

## 6. Modules are spliced source, like the assembler sees them

`import` inlines whole files in order, relative to the importing file,
with include-once and duplicate/cycle errors. This mirrors how
Drifblim's `~` includes behave at the `.tal` level, minus the
current-directory confusion. One namespace across the splice keeps the
mental model ("as if it were one file") exact.

## 7. Escape hatches are explicit and fenced

`raw { ... }` passes Uxntal through verbatim for the things the DSL
cannot say yet — but it lands in the data section, so it is for data
and tables, not for smuggling control flow. Anything load-bearing
belongs in the language proper; `raw` is scaffolding with a fence
around it.

## 8. The output is the documentation

Every ETAL program compiles to readable `.tal` with stable, reviewable
shapes (one construct → one idiom). `-t` exists so you never have to
trust the compiler: read the generated code, assemble it yourself,
diff it across platforms. The test suite enforces byte-identical
output for fixtures, and the portability story rests on the ROM being
identical everywhere — only the VM differs per platform.
