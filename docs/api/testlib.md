# Test libraries and fixtures

Small shared modules plus one-purpose harnesses. Every harness prints
a fixed byte string that the suite diffs — the expected bytes are
quoted from each file's own header comment.

## Macros

```ux
macro mod16(a: u16, b: u16) -> u16 {
    return a - a / b * b;
}
```

Defined identically in `examples/tests/lib.ux`,
`examples/tests/test_macro.ux` and `tests/ci_lib.ux`: Euclidean-style
remainder without a remainder opcode (`DIV2k MUL2 SUB2`). Canonical
example of a single-`return` value macro; `mod16(17, 5)` is `2`.

```ux
macro add1(x: u16) -> u16 {
    return x + 1;
}

macro add2(x: u16) -> u16 {
    return add1(x) + 1;
}
```

`examples/tests/test_macro.ux`. Nested expansion (`add2` expands
`add1` inside its own body); `add2(5)` is `7`.

```ux
macro skip_if_zero(v: u16) {
    if v == 0 {
        goto done_skip;
    }
    varvara.console.write(65);
    label done_skip;
}
```

`examples/tests/test_macro.ux`. Statement macro with a label/goto
pair: expanded twice (`skip_if_zero(0)` prints nothing,
`skip_if_zero(5)` prints `65`), which is exactly what proves label
freshening (`done_skip__m3`, `done_skip__m4` in the output).

## Functions

```ux
seven :: fn() -> u16 {
    return 7;
}
```

```ux
three :: fn() -> u16 {
    return 3;
}
```

```ux
double :: fn(x: u16) -> u16 {
    return x + x;
}
```

`seven` lives in `examples/tests/lib.ux`, `three` in the
import-it-twice `examples/tests/lib2.ux`, `double` in
`tests/ci_lib.ux` next to `ten :: 10;`. Plain zero/one-argument
functions used to pin call codegen (`;seven JSR2`, argument
promotion) in harness outputs.

## Buffers and harnesses

```ux
buffer cells[16]: u8;
buffer words[8]: u16;

small: [4] u8;
```

`examples/tests/test_array.ux`: main-RAM buffers plus one zero-page
array, exercising `u8`/`u16` loads and stores, variable indices, and
low-byte truncation on console write. Expected bytes:
`41 42 43 44 e9` (`"ABCD\xe9"` — `words[1]` is 1001, printed as
`0xe9`).

```ux
main :: fn() {
    print("Hi!\n");
    x: u16 = 1 << 3;
    ...
}
```

`examples/tests/test_shift_print.ux`: constant and dynamic `SFT2`
plus the inline string printer. Expected bytes:
`48 69 21 0a 42 79 65 2e 0a 38 32 38` (`"Hi!\nBye.\n828"`).

```ux
main :: fn() {
    m: u16 = mod16(17, 5);
    ...
    varvara.console.write(48 + m);
    ...
}
```

`examples/tests/test_import.ux` (with `lib.ux` importing `lib2.ux`,
and importing both — the diamond include-once proof): expected bytes
`32 37 35 33` (`"2753"`). `examples/tests/test_macro.ux` (above,
plus a `raw { @raw_marker [ aa bb ] }` passthrough block): expected
bytes `32 32 41 42 30` (`"22AB0"`).

```ux
data box = file("assets/tilde.chr");
data dot = file("assets/dot.icn");
```

`examples/tests/test_asset.ux`: one 2bpp tile and one 1bpp tile
embedded from files, addressed with `Screen.addr = &box;` (plus a
minimal `Screen` block). Expected byte: `32` (`"2"`).

`tests/ci.ux` (+ `ci_lib.ux`) is the committed CI fixture: imports,
macros, functions, buffers, loops and `print` in one file, diffed
against `tests/ci_expected.tal` by `dune runtest` on every platform.

## Test fixtures

```ux
handler :: fn() {
    x: u16 = Mouse.x;
    b: u8 = Controller.button;
    Screen.x = x;
    Screen.sprite = b;
}
```

`examples/tests/test_device.ux`: reduced device blocks (only used
ports declared) with a plain-`fn` handler installed via
`Screen.vector = &handler;`.

```ux
on_controller :: event() {
    b: u8 = Controller.button;
    if b == 8 {
        brk;
    }
}
```

`examples/tests/test_event.ux`: minimal event with a local port read
and conditional `brk`.

```ux
main :: fn() {
    ch: u8 = 0;
    ch = varvara.console.read();
    varvara.console.write(ch);
}
```

`examples/console/console_simple.ux`: console echo. `examples/hello/hello.ux`
is the one-liner `varvara.console.write("Hello, World!\n");` — note
this writes a single byte (the low byte of the string's address; use
`print("...")` for real strings — see [builtins](builtins.md)). Both
`cycle_a.ux` / `cycle_b.ux` import each other and exist only to fail
with a cyclic-import error.
