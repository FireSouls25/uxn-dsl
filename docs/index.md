# ETAL documentation

ETAL is a small typed language that compiles to
[Uxntal](https://wiki.xxiivv.com/site/uxntal.html), the assembly language of the
[Uxn](https://wiki.xxiivv.com/site/uxn.html) stack-machine computer. It gives Uxn
programs functions, events, devices, sprites, buffers, control flow, macros and
modules — and compiles them down to plain `.tal` you can inspect, assemble with
[Drifblim](https://wiki.xxiivv.com/site/drifblim.html), and run on any Uxn/Varvara
emulator.

## Sixty seconds

```ux
device Screen 32 {
    vector: 2  width: 2  height: 2
    auto: 1  pad: 1  x: 2  y: 2
    addr: 2  pixel: 1  sprite: 1
}

main :: fn() {
    Screen.width = 128;
    Screen.height = 128;
    Screen.x = 64;
    Screen.y = 64;
    Screen.pixel = 1;
}
```

```sh
etal -t hello.ux -o hello.tal   # read the generated Uxntal
etal -r hello.ux -o hello.rom   # assemble to a ROM
etal hello.ux -o hello          # single-file native executable
etal --target web hello.ux -o hello.html  # single self-contained web page
```

## How it works

```
.ux sources --lex--> tokens --parse--> AST --expand--> macros gone
  --typecheck--> checked AST --codegen--> .tal --drifblim--> .rom
  --bundle--> native executable | web page
```

Every stage is deliberately boring: the lexer, parser, type checker and code
generator are separate passes (`src/{lexer,parser,sem,codegen}/`), macros expand to AST *before*
type checking, and imports splice whole files together before anything else
runs. There is no runtime, no standard library linked into your ROM beyond a
handful of `%`-macros and the entry vector — what you write is what runs.

## Map

- [Language](language/) — design decisions, then the full reference:
  - [Lexical structure](language/lexical.md) — comments, literals, keywords
  - [Types](language/types.md) — `u8`, `u16`, `bool`, arrays, pointers
  - [Declarations](language/declarations.md) — devices, groups, globals,
    data, assets, buffers, functions, events, macros, imports, raw blocks
  - [Statements](language/statements.md) — control flow and friends
  - [Expressions](language/expressions.md) — precedence and operators
  - [Uxn mapping](language/uxn-mapping.md) — how it all becomes stack code
  - [Limitations](language/limitations.md) — honest list of what ETAL
    cannot do (yet), and why
  - [Proposals](language/proposals.md) — assessed improvements (modular
    types, `match`, structs, rings, inference…) and unserved Varvara
    territory
- [Toolchain](toolchain/) — building the compiler and the VM, CLI modes,
  vendor layout, testing strategy, versioning
- [Examples](examples/) — annotated walkthrough of the Snake game
- [API index](api/) — every builtin, device, function, event, macro
  and dataset in the language and corpus, grepable by declaration
- [Changelog](CHANGELOG.md) — version history and the `0.x.y` convention
- [RAG corpus sources](sources.md) — upstream references this documentation
  is checked against (Uxntal reference, opcodes, Varvara spec, tutorials)
