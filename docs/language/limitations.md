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
- **Buffers are reserved after code, assets, and strings**, in declaration
  order. Their addresses are resolved by the assembler, not fixed at
  `0x2000`. The complete program and buffers must fit below 64K.
  There is no runtime allocator or custom layout control.
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
- **Integers are 0–65535, unsigned — plus `i8`/`i16`.** Negatives
  come from unary minus on literals (`-5` is `i8`) or signed
  arithmetic; ordered comparisons flip the sign bit, shifts stay
  logical, and cross-sign mixing is an error with a named bridge.
  Signed `/` and `%` are rejected (Uxn divides unsigned). Unsigned
  division and modulo by zero yield zero, per Uxn semantics; `x - y`
  wraps either way.
- **Shift amounts are masked mod 16.**
- **`&&` / `||` are bitwise**, not short-circuiting; both sides always
  evaluate.
- **Data bytes are unchecked**: keep inline `data` values in 0–255 or
  the emitted hex is garbage. (Assets are validated as whole tiles.)
- **Data blobs read as arrays**: inline blobs index and
  whole-copy; file assets index element-wise but never whole-copy
  (length is assembly-time). Buffers and blobs never convert to
  `&u8` call arguments — loop or copy explicitly.
- **Structs are v2**: scalar/`struct`/fixed-array fields (no `mod`,
  no pointers; inner structs declared first, so cycles can't form);
  chained paths (`a.b.c`, `rows[i].pos.x`, `t.notes[2].pitch`) and
  same-type whole-value `=` (byte copy) compile. Still errors: struct
  params, returns, comparison, and whole-value argument passing —
  pass fields. Struct types must be declared before use. `match` is
  desugared dispatch (no jump tables) over integer literals plus
  trailing `_`.
- **Whole arrays copy with `=`** (same element type and length —
  the struct byte-copy lowering), in assignments and initializers.
  Every other whole-array use (return, `rpush`, call arguments,
  comparisons, bare statements, mismatched copies) is a compile
  error: arrays never touch the stack, only `arr[i]` compiles.
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
- **Top-level `raw { }` lands in the data section**: fine for
  tables, wrong for tal `%macros` (they would land after use
  sites) — use body-level `raw {}` for inline code. Legacy bare
  `raw` reads to end-of-file and must stay last.
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
  asset names (`hero0`, not `face0`). Single-hex-letter-plus-digits
  (`f66`, `a1`) is also rejected as hex-looking — the compiler's
  `@fnN` function aliases use the `fn` prefix for this reason.
- Drifblim's symbol dictionary is fixed at `$4800` (18,432 bytes,
  ~4 bytes overhead per entry): every `@name` and `scope/sub` label
  name counts. Programs around ~700 branch labels with long function
  names overflow it (`Symbols exceeded`); the compiler answers with
  short `@fnN` function labels and two-letter branch stems, good for
  roughly 4× the chess program's label load. Past that, shorten
  hot function names or flatten nested `if`s into `&&` chains.
- Reserved but unused keywords: `let`, `byte`,
`short`. The `RawLit` and `CompoundLit` AST nodes exist
but no syntax builds them (`RawStmt` does — `raw {}` blocks).
- No string concatenation or slicing — `&u8` views (literals,
  `&blob`, address globals) with `lib/string.ux` (`strlen`/`streq`/
  `strcopy`), plus literals, `print`, and the raw console ports.
  Escape set is `\n \t \\ \"` (other `\x` yields literal `x`).
- The `Console` device is predeclared; redeclaring it collides.
- **Polling `Controller.key` never sees a key.** The VM zeroes the
  port right after firing the controller vector (uxn2.c
  `controller_key`), i.e. between frames — latch it in an
  `on_key :: event()` into a global instead (chess `keybuf`). Same
  for sub-frame mouse clicks: OR-accumulate `Mouse.state` in an
  `on_mouse` vector (`mousebuf`), since a quick down+up between two
  frame polls is otherwise invisible.
- **Mouse coordinates are window pixels.** At zoom ≠ 1 (F1 cycles
  1–3) the VM reports unscaled positions, so clicks miscalibrate by
  the zoom factor — upstream uxn2 behavior, not an ETAL bug. Play at
  zoom 1 (or scale the hit-test if you ship a default zoom).
- **The VM hides the system cursor** over the window
  (`SDL_ShowCursor` off in uxn2.c), so without a drawn cursor the
  mouse visibly vanishes on top of the game — uxn games draw their
  own (chess blits a `cursor` tile last in every scene draw).
- Devices beyond console/screen/controller/mouse/datetime/file
  (other than audio — see `lib/audio.ux`, `lib/song.ux` — FileA —
  see `lib/file.ux` — and mouse edges — see `lib/mouse.ux`) have no
  helpers — declare ports by hand and use raw device ops.

If a limitation blocks something real, the intended fix is almost
always a small, typed construct — not a bigger escape hatch. That's
also a good way to contribute.
