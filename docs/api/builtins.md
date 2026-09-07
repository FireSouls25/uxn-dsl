# Builtins

Callable without declaration or import. `print` is registered by the
type checker (`msg: &u8`, returns void); the `varvara.console.*`
family is recognized by path in code generation.

## print

```ux
print("Hello, World!\n");
```

Prints a NUL-terminated string to the console, one `DEO` per byte:

```tal
;str_0 &print_1 LDAk .Console/write DEO INC2 LDAk ?&print_1 POP2
```

- Argument must be a **string literal**. Any other argument falls
  through to `;print JSR2`, which assembles only if you defined such a
  label — in practice, an assemble error. This is intentional: the
  inline loop is the whole feature.
- Each call site gets its own loop label, so repeated prints never
  collide.
- No value is left on the stack; usable as a statement only in effect
  (the declared return type is void).

## varvara.console.write

```ux
varvara.console.write(48 + m);
```

Writes one byte to console port `0x18` (`.Console/write DEO`).
Accepts any integer expression; a `u16` argument is truncated to its
low byte (`NIP`). This is the only implicit narrowing in the language,
and it exists because console ports are inherently byte-wide.

Used pervasively in test harnesses, which print expected bytes the
test suite diffs: `varvara.console.write(48 + m);` prints ASCII digits.

## varvara.console.read

```ux
ch = varvara.console.read();
```

Reads one byte from console port `0x12` (`.Console/read DEI`),
e.g. [`console_simple.ux`](../../examples/console/console_simple.ux)
echoes one stdin byte back to the console.

## varvara.console.error

```ux
varvara.console.error(code);
```

Like `write`, but to console port `0x19` (`.Console/error DEO`),
with the same low-byte truncation.

## Gotcha: unknown foreign calls

Any other dotted path (`foo.bar(...)`) compiles to `#0000` — it pushes
zero and emits nothing else, silently. If a foreign call seems to do
nothing, check the spelling against the three names above.

## main

```ux
main :: fn() {
    on_start();
}
```

```ux
main :: event() {
    on_start();
}
```

Every program needs exactly one `main`, and its form decides the
program's fate — the entry vector is always `|0100 ;main JSR2 HALT`:

- `main :: fn()` — the call returns, execution falls into `HALT`,
  the program terminates. Use for scripts and headless test
  harnesses (which print expected bytes, then halt for the diff).
- `main :: event()` — the body ends in `BRK`, which ends the reset
  vector instead of halting, so the emulator stays in the event loop
  and vectors keep firing. Use for games (`examples/snake/main.ux`
  does exactly this so its window persists).

`brk;` anywhere else in an `event` handler ends that vector's
evaluation immediately — the standard "handled, stop here" idiom.
