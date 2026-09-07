# ETAL — a small typed language for the [Uxn](https://wiki.xxiivv.com/site/uxn.html) virtual machine

ETAL is a typed, C-flavored language that compiles to [Uxntal](https://wiki.xxiivv.com/site/uxntal.html),
the assembly language of the Uxn/Varvara stack-machine computer. It comes with a compiler
written in ocaml, etal (for easy tal)

## Origins & credits

Everything here stands on the work of [Hundred Rabbits](https://100r.co) (Devine Lu Linvega
and Rekka Bellum) and the Uxn community:

- [Uxn](https://wiki.xxiivv.com/site/uxn.html) — the virtual machine specification this targets.
- [Varvara](https://wiki.xxiivv.com/site/varvara.html) — the device layer (screen, controller,
  console, file, datetime…) ETAL's `device` declarations mirror.
- [Uxntal](https://wiki.xxiivv.com/site/uxntal.html) (+ [opcodes](https://wiki.xxiivv.com/site/uxntal_reference.html))
  — the output language; hand-written `.tal` (e.g. Orca) is the reference for what good output looks like.
- [uxn2](https://git.sr.ht/~rabbits/uxn2) — the reference C99/SDL2 emulator, nested under `uxn2/`
  (its own repo). Also the source of our vendored Linux VM.
- [Drifblim](https://git.sr.ht/~rabbits/drifblim) — the Uxntal assembler (ships as `drifblim.rom`,
  driven by the emulator to turn `.tal` into `.rom`).
- [uxn5](https://git.sr.ht/~rabbits/uxn5) ([live demo](https://rabbits.srht.site/uxn5/)) — the official
  JavaScript emulator powering the `--target web` output.
- [awesome-uxn](https://github.com/hundredrabbits/awesome-uxn) — the community index of emulators,
  tools, and games (our spec and tutorial sources live there).

## Prerequisites

- OCaml 5.5.0, opam 2.5.2, dune 3.24.2.
- For assembling/running: nothing extra on Linux — the VM and assembler are vendored.
- This project comes with vendored versions of uxn for Windows, Linux and MacOS.
- For the web target: a normal browser.

## Building the compiler

```sh
opam switch create etal ocaml-system      
opam install --locked --deps-only -y .    
opam exec -- dune build @all              
opam exec -- dune runtest                  
```

`dune build` puts the compiler at `build/<platform>/etal`
(`linux-x86`, `macos-arm`, `windows-x86` — exactly one populates, matching
the building machine; Windows builds `etal.exe` instead, as executables
require there). Anything that is not the compiler would go under
`build/<platform>/extra/`. Use it as `./build/linux-x86/etal …`
(substitute your platform).

## Usage

```
etal [options] <input.ux>
  -o <file>     output file (default depends on mode)
  -t            emit Uxntal source (.tal)
  -r            emit an assembled ROM (.rom)
  --target t    bundle target: native (default) or web (single .html)
  -v            verbose
```


Conventions: `main :: fn()` scripts run and halt (good for headless tests);
`main :: event()` games enter the emulator event loop and stay open.

### Running ROMs directly & emulator keys

```sh
uxn2/bin/uxn2 uxn2/bin/drifblim.rom input.tal output.rom  # assemble by hand
uxn2/bin/uxn2 output.rom              # run (add -2 for zoom, -f fullscreen)
```

In the emulator: arrows/d-pad, `F1` cycles zoom, `F11` fullscreen. The web page
has its own Zoom button and the same keyboard mapping.

### Building the VM (`uxn2/`)

```sh
cd uxn2
zig build                                         # host dev build
zig build -Dtarget=x86_64-linux-gnu.2.17 -Dsys-libdir=/usr/lib   # Linux release
zig build -Dtarget=x86_64-windows-gnu -Dsdl-prefix=<SDL2-devel>  # Windows PE
zig build -Dtarget=aarch64-macos -Dsdl-prefix=/opt/homebrew      # macOS (needs Xcode SDK)
```

`zig build` output lands in `uxn2/zig-out/`. Portability contract (glibc floor,
dependency closure) is enforced by `tests/portability.sh`.

## The DSL tour

```ux
device Screen 32 {                 ( Varvara devices )
    vector: 2  width: 2  height: 2
    auto: 1  pad: 1  x: 2  y: 2
    addr: 2  pixel: 1  sprite: 1
}

width :: 20;                       ( constants )
head_x: u16;                       ( globals live in zero-page )
group pos: u8 { x: u8  y: u8 }     ( grouped zero-page cells )

data head = file("assets/head.chr");   ( .chr 2bpp / .icn 1bpp sprite files )
data raw = [ 252 238 239 ];            ( or inline hex )
buffer tail[256]: u16;             ( main-RAM arrays, absolute addressed )

wrap :: fn(x: u16, n: u16) -> u16 {     ( functions; JSR2 calls )
    if x < n { return x; }
    return x - n;
}
on_frame :: event() {                  ( vectors end with brk, not return )
    step();
    draw();
    brk;
}

macro mod16(a: u16, b: u16) -> u16 {    ( zero-cost inline expansion )
    return a - a / b * b;
}
import "logic.ux"                  ( file-relative, recursive, cycle-checked )
raw { @table [ 00 11 22 ] }        ( balanced passthrough for hand tal )

main :: fn() {
    for i in 0..16 {               ( bounded counted loops )
        tail[i] = wrap(i + 1, 16); ( array store; u16 elements scaled )
    }
    while score < 10 { score = score + 1; }
    Screen.x = head_x << 3;        ( real SFT2 shifts )
    Screen.addr = &head;           ( sprite blits )
    Screen.sprite = 1;
    print("score: ");              ( inline NUL-terminated printer )
    varvara.console.write(48 + score);
}
```

Types are `u8`/`u16`/`bool` (with `u8 → u16` widening; narrowing truncates
explicitly-sized stores), plus fixed arrays and pointers. Locals live in
zero-page under mangled names, so functions of any size work. Anything the
DSL can't yet say can be embedded with `raw { }`.

## Testing

- `dune runtest` — lexer/parser probes plus a **golden `.tal` diff** on committed
  fixtures (`tests/ci.ux`): byte-identical output on every platform or red CI.
- Game/harness ROMs are `diff`-gated byte-for-byte (see `examples/snake/`).
- `sh tests/portability.sh` — the Linux VM contract (glibc floor, dependency
  closure, smoke boot). GitHub Actions runs all of the above on Linux, macOS
  and Windows (`.github/workflows/etal-ci.yml`).

## Documentation

Full language and toolchain docs live in [`docs/`](docs/) (plain Markdown,
ready to publish as a GitHub Pages site): design decisions, syntax reference
for every construct, the exact Uxn mapping, an honest limitations list,
toolchain guide, and an annotated Snake walkthrough.
