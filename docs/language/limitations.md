# Limitations

Honest list of what ETAL cannot do (yet), and why. Nothing here fails
silently at runtime — most items are compile errors; the few that are
not are marked **footgun**.

## Memory and scope

- **No recursion or reentrancy.** Locals are static zero-page slots,
  so a function calling itself (or an event interrupting a function
  that shares its locals) corrupts state. The compiler does not check
  this — **footgun**; keep call graphs acyclic.
- **Valued functions must `return expr` explicitly.** Falling off the
  end leaves whatever is on the stack; callers read the declared
  width, so an omitted return is garbage, not zero — **footgun**.
- **256-byte zero-page budget**, shared by globals, groups and all
  spilled locals. Only functions reachable from `main` budget slots
  (dead-function elimination runs after checking, so unused code
  must still type-check). Overflow is a compile error naming the
  byte count.
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
- **Bare-`u16` conditions are total now**: a short condition is
  reduced with `#0000 NEQ2`, so the full value is tested and no byte
  leaks. (Raw `raw`-literal conditions are exempt — their width is
  unknowable — and `&&` / `||` stay bitwise, below.)
- **`for` end bounds**: syntactically pure bounds (literals,
  variables, constants) evaluate once up front; anything that could
  call or store re-evaluates every iteration. A body that assigns to
  a pure bound variable still iterates to the entry value. The loop
  variable is always `u16`, even over `u8` ranges.
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
- **Structs are v1**: scalar `u8`/`u16`/`bool` fields only (no
  nesting, `mod`, arrays or pointers); no struct params, returns,
  or whole-value operations (assign/compare/pass/return a struct
  and the compiler tells you to use fields); struct types must be
  declared before use. `match` is desugared dispatch (no jump
  tables) over integer literals plus trailing `_`.
- **Constants only carry values** for integer and identifier forms;
  anything else degrades to `|0000`.

## Order and placement

- **Define-before-use is gone for calls, not for recursion.**
  Function signatures are collected whole-program before checking, so
  forward calls get full arity, type and promotion checking. Calling
  an undefined function is a compile error. Recursion (direct or
  mutual) still assembles but corrupts static locals at runtime —
  keep call graphs acyclic. (Macros were already order-independent:
  collected whole-program first.)
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
- **Valued `return x;` in an `event` still emits `JMP2r`.** Bare
  `return;` is safe (emits `BRK`), but returning a value from a
  vector pops a bogus address — vectors are never `JSR`-called.
  Restructure so events only use bare returns.

## Surface gaps

- Drifblim rejects some `@label` names (`face` observed — `Name
  invalid` at assembly): rename the datum. Prefer distinctive
  asset names (`hero0`, not `face0`).
- Reserved but unused keywords: `let`, `byte`,
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
