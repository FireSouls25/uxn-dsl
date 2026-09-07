# Limitations

Honest list of what ETAL cannot do (yet), and why. Nothing here fails
silently at runtime — most items are compile errors; the few that are
not are marked **footgun**.

## Memory and scope

- **No recursion or reentrancy.** Locals are static zero-page slots,
  so a function calling itself (or an event interrupting a function
  that shares its locals) corrupts state. The compiler does not check
  this — **footgun**; keep call graphs acyclic.
- **256-byte zero-page budget**, shared by globals, groups and all
  spilled locals. Overflow is a compile error naming the byte count.
- **Buffers live at fixed addresses** from `0x2000` upward and must
  fit below 64K. There is no allocator and no custom layout (no `|addr`
  control).
- **No local arrays** (`x: [4] u8` inside a function is rejected at
  indexing time), no array literals or initializers, **no bounds
  checks** — out-of-range indexing corrupts silently, like the hardware.

## Types and values

- **No implicit narrowing.** A `u16` never silently becomes a `u8`;
  only `varvara.console.write/error` truncate (low byte). Restructure
  or mask instead.
- **Bare-`u16` conditions are wrong**: `while counter` tests only the
  low byte and leaves a byte on the stack — **footgun**. Always write
  a comparison (`while counter != 0`).
- **`for` bounds re-evaluate every iteration** and the loop variable
  is always `u16`, even over `u8` ranges.
- **Integers are 0–65535, unsigned.** No negatives, no signed shifts
  or division (right shifts are logical; `x - y` wraps). Division and
  modulo by zero yield zero, per Uxn semantics.
- **Shift amounts are masked mod 16.**
- **`&&` / `||` are bitwise**, not short-circuiting; both sides always
  evaluate.
- **Data bytes are unchecked**: keep inline `data` values in 0–255 or
  the emitted hex is garbage. (Assets are validated as whole tiles.)
- **Data blobs are not indexable** — take `&blob` and do address
  arithmetic, or copy bytes into a buffer first.
- **Constants only carry values** for integer and identifier forms;
  anything else degrades to `|0000`.

## Order and placement

- **Define functions before use.** Signatures are recorded in order,
  so a forward call skips arity checks and argument promotion.
  (Macros are the exception: collected whole-program first.)
- **Macro bodies cannot capture caller locals** (params, globals and
  their own locals only); a statement-macro `return <expr>;` discards
  the value, a bare `return;` returns from the caller.
- **`raw { }` lands in the data section**: fine for tables, wrong for
  tal `%macros` (they would land after use sites). Legacy bare `raw`
  reads to end-of-file and must stay last.
- **`brk` ends the vector, not the function.** It belongs in `event`
  handlers only — a `BRK` on a plain `fn` path (including `main ::
  fn()`) returns to the emulator early.
- **Multi-port device writes are order-sensitive.** A sprite blit
  reads `addr`/`x`/`y`/`auto` at the moment `sprite` is written, so
  reordering those assignments draws wrong — the compiler does not
  check this. Keep each blit in one reviewed macro or function.
- **Bare `return;` in an `event` emits `JMP2r`, not `BRK`.**
  Vectors are never `JSR`-called, so that pops a bogus return
  address — use `brk;` for early exits until `return;` is taught
  the difference (see [proposals](proposals.md)).

## Surface gaps

- Reserved but unused keywords: `match`, `let`, `const`, `byte`,
  `short`. The `RawLit`, `CompoundLit` and `RawStmt` AST nodes exist
  but no syntax builds them.
- No string variables or concatenation — only literals, `print`, and
  the raw console ports. Escape set is `\n \t \\ \"` (other `\x`
  yields literal `x`).
- The `Console` device is predeclared; redeclaring it collides.
- Devices beyond console/screen/controller/mouse/datetime/file
  (notably audio) have no helpers — declare ports by hand and use
  raw device ops.

If a limitation blocks something real, the intended fix is almost
always a small, typed construct — not a bigger escape hatch. That's
also a good way to contribute.
