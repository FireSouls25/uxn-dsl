# WASM future (alternative export target)

Stock Uxn stays default. No fork. This note records the tooling
for a future `--target wasm` row, so adoption is a new backend
module plus a row — the same shape as `native` and `web` today
(see [Toolchain](index.md), `src/main.ml`, `src/target/target.ml`,
`src/target/target_native.ml`, `src/target/target_web.ml`).

Today's pipeline (unchanged):

```
.ux --etal--> .tal --drifblim--> .rom --bundle--> native exe | web .html
```

WASM would slot in as one more bundle row, fed either by a new
WAT emitter or by compiling the existing C VM. Both keep the
front end (`Loader`, `Expand`, `Elab`, `Types`, `Dce`) untouched;
only codegen/bundle grow.

## Tool catalog (2026 versions where known)

### wat / wasm-tools (wat2wasm, validate, print, strip)

- Role: text-format entry point. A future WAT emitter (`etal -t`
  today emits `.tal`; a WASM row emits `.wat`) assembles with
  `wat2wasm` / `wasm-tools parse`, checks with `wasm-tools
  validate`, inspects with `wasm-tools print`.
- Pipeline stage: WAT emit -> validate -> `.wasm`.
- Dockerfile: `wasm-tools` static binary (pin 1.x tag, 2026-era).
- Artifact: `.wasm` (plus `.wat` kept for inspection, like `.tal`).

### binaryen (wasm-opt)

- Role: size/speed optimizer after validation, before bundling.
  Typical: `wasm-opt -Oz --strip-debug -o game.opt.wasm game.wasm`.
- Pipeline stage: validate -> opt -> bundle.
- Dockerfile: `binaryen` release tarball (pin tag; provides `wasm-opt`).
- Artifact: smaller `.wasm`; no behavior change.

### wabt (wasm2c, wasm-validate, wat2wasm)

- Role: second validator (`wasm-validate`, `wasm-interp` for
  probes) and the `wasm2c` escape hatch: transpiles `.wasm` to
  portable C for rows with no WASM runtime.
- Pipeline stage: validate; opt-adjacent (`wasm2c` instead of bundle).
- Dockerfile: `wabt` release tarball (pin 1.0.x-era tag).
- Artifact: `.wasm` validated, or generated `.c/.h` via `wasm2c`.

### Runtimes: wasmtime 46–48 LTS / wasmer 6–7 / WAMR / wasm3

- Role: execute and smoke-test the built `.wasm` headlessly.
  Any one suffices for CI; wasmtime is the default pick (WASI
  coverage + LTS line 46–48).
  - wasmtime 46–48 LTS: CLI + Rust/Python/Node embeds.
  - wasmer 6–7: alternative CLI/runtime, package registry.
  - WAMR (`iwasm` + `wamrc` AOT): tiny embed target, matches the
    Uxn size story better than full JITs.
  - wasm3: smallest interpreter; slowest, but good as a floor test
    ("runs even here").
- Pipeline stage: post-bundle smoke (`wasmtime game.wasm`, `iwasm`).
- Dockerfile: one runtime only (wasmtime LTS recommended);
  `ENV WASMTIME_VERSION=48` style pin, verify checksum.
- Artifact: exit code + console bytes (same `diff`-gate style as
  the existing fixture-ROM checks).

### wasi-sdk 24 / 30 + WASI p1 / p2

- Role: only needed for the shortcut path — compiling the
  existing C VM (`uxn2/`, same sources `uxn2/build.zig` builds
  natively) to WASM instead of writing a WAT emitter.
  `wasi-sdk` provides clang+sysroot; target `wasm32-wasip1`
  (stable, what to ship) over `wasm32-wasip2` (newer, churn).
- Pipeline stage: alternative bundle input (C VM -> `.wasm`
  wrapping the assembled `.rom`, same ROM bytes as native/web).
- Dockerfile: `wasi-sdk-24` or `-30` tarball + `WASI_SYSROOT`;
  keep SDL2 out (headless; screen/audio become imports, below).
- Artifact: `uxn.wasm` (VM) + embedded or sidecar `.rom`.

### emcc 6.0.x SDL2 path

- Role: the other shortcut — Emscripten builds the C VM with its
  bundled SDL2 to a browser page. Reuses the dynamic-SDL2
  assumption already in `target_native.ml` / `vendor/BUILD.md`,
  but pays the Emscripten runtime.
- Pipeline stage: C VM -> `.html` + `.wasm` + `.js` glue.
- Dockerfile: `emscripten/emsdk:6.0.x` image (pin minor);
  `emcc -O2 -s USE_SDL=2 -s WASM=1`.
- Artifact: Emscripten page (`.html`/`.js`/`.wasm` set) — heavier
  than the current uxn5 single-`.html` bundle, so strictly a
  fallback.

### wasm-pack / wasm-bindgen (glue)

- Role: only if the WASM row needs JS glue beyond what
  `target_web.ml` already hand-rolls (today: vanilla JS, no wasm
  payload). `wasm-bindgen` generates the import/export shims;
  `wasm-pack` packages them for npm/browser.
- Pipeline stage: bundle (`.wasm` + generated `.js`/`.d.ts`).
- Dockerfile: `rustup` + `wasm-pack` cargo install (pin version);
  only installed if the glue path is chosen.
- Artifact: `.wasm` + JS loader snippet (embedded into a
  single `.html` the way uxn5 + base64 ROM are today).

### node / python wasmtime (smoke tests)

- Role: headless CI gate, no browser. Node (`@wasmtime/runtime`)
  or Python (`wasmtime` pip) loads the built `.wasm`, feeds
  scripted device bytes, asserts console output — the WASM twin
  of `tests/smoke.sh` and the fixture-ROM `diff` gates.
- Pipeline stage: post-build test (same gate as `dune runtest`).
- Dockerfile: `node:22` or `python:3.12-slim` + `wasmtime` package
  matching the CLI LTS above.
- Artifact: pass/fail only; no shipped bytes.

## ETAL concept -> WASM equivalent

Types per [Types](../language/types.md); footguns per
[Limitations](../language/limitations.md).

| ETAL concept | WASM equivalent | Notes |
|---|---|---|
| `u8` / `u16` arithmetic, `&` `\|` `^` `<<` `>>` | `i32` + mask (`& 0xff` / `& 0xffff`) | WASM has no i8/i16; mask after each op. `u16 mod N` keeps its `%`-lowering (`DIV`-based, exact per types doc). |
| `i8` / `i16`, signed compare | `i32` + sign-bit flip for ordered compare | Shifts stay logical; signed `/` `%` stay rejected (Uxn divides unsigned). |
| `f32` / `f64` (new, no ETAL source yet) | `f32` / `f64` directly | Only reason to touch floats; Uxn core never needs them. |
| zero-page locals (256-byte budget, static slots) | WASM `local`s (hot fns) or linear-memory frame | No recursion today (**footgun** in limitations) maps cleanly: fixed frames, no stack-machine needed. |
| buffers / `data` blobs / file assets | linear memory + `data` segments | Buffers already "reserved after code" by the assembler; WAT emit fixes the base instead. 64K ceiling stays. |
| devices + ports (`Screen`, `Audio0`, `Controller`, `Mouse`, `Console`; game-declared per `lib/screen.ux`, `lib/audio.ux`, `lib/input.ux`) | `import` functions (port write = call, port read = call/return) | Device-touching helpers are macros at call sites today; same boundary becomes the import boundary. Screen blit order (`x`/`y`/`addr` then `sprite`) stays order-sensitive. |
| events (`on_key`, `on_mouse`, frame vectors; `brk` ends the vector) | exported functions called by the host | Bare `return;` (`BRK`) becomes a plain function return; valued `return x;` in events stays an error (same rule as now). |
| Controller/Mouse latch pattern (`key_latch`, `cbtn_latch`, `mouse_latch` in `lib/input.ux`) | host queues events, guest exports latch/take fns | Polling still sees nothing between frames; the latch vectors become imported-event exports. |
| `print` / console write, `assert` | WASI `fd_write` (or a `console.log` import in browser) + `unreachable` on assert fail | `console.write/error` truncate to low byte today; same truncation at the import. |
| `raw {}` blocks | inline WAT passthrough (future) or rejected | Top-level `raw` landing in the data section stays a data-section concern. |
| `--list-targets` rows | new `wasm` (+ maybe `wasm-wasi`, `wasm-web`) rows | Backend discovery unchanged: one Linux image serves every row; assembly still runs under the host VM. |

## Minimal viable toolchain

For a first WASM row, install exactly this and nothing else:

1. `wasm-tools` (parse/validate) + `wabt` (`wasm-validate` cross-check).
2. `binaryen` (`wasm-opt -Oz`).
3. `wasmtime` 46–48 LTS (headless smoke tests).
4. Node **or** Python `wasmtime` binding (CI harness).

That covers WAT emit -> validate -> opt -> bundle -> smoke.
Add `wasi-sdk` 24/30 **or** `emcc` 6.0.x only if the shortcut
(compile the C VM) is chosen over a WAT emitter; add
`wasm-pack`/`wasm-bindgen` only if hand-rolled JS glue (current
`target_web.ml` style) proves insufficient. Prefer WASI p1 until
p2 stabilizes.

Backend `Dockerfile` sketch (one Linux image serves all rows,
per [Toolchain](index.md)):

```dockerfile
# pinned tool versions; checksums verified at build
ARG WASM_TOOLS=1.x WABT=1.0.x BINARYEN=1xx WASMTIME=48
RUN install wasm-tools wasm-opt wabt wasmtime
# smoke layer only:
RUN pip install wasmtime==$(match WASMTIME)  # or node equivalent
# shortcut path only (pick at most one):
# COPY wasi-sdk-30 ...
# FROM emscripten/emsdk:6.0.x ...
```

New artifacts next to today's (`game`, `game.zip`, `game.html`):

- `game.wasm` (+ optional sidecar `.rom`, or ROM embedded as a
  data segment),
- `game.wasm.html` shell (JS loader + `.wasm`, mirroring the
  single-file web bundle),
- `.wat` inspection file (the `.tal` equivalent).

## What NOT to use

- **Bevy (or any full game engine) as the WASM runtime.** Raw
  22–33 MB / ~8 MB transferred for a hello-world page — orders
  of magnitude over the tiny-games pitch (a ROM is KBs; uxn5 is
  a few JS files; even Emscripten-SDL2 is lighter than Bevy).
  Device access here is a handful of imports (screen blit,
  audio pitch, input latch, console bytes); an engine buys
  nothing and costs the whole value proposition. Same reason to
  prefer `iwasm`/`wasm3` over a JIT where embedding matters.

## Positioning

Stock Uxn first: Uxntal (`.tal`) remains the compiler's
contract, the ROM remains the portable artifact, and native +
uxn5-web remain the default bundles. WASM is an additional
export for stores/hosts that require it — evaluated by whether
it keeps games tiny, readable, and portable, or not shipped.
