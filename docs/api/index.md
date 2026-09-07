# ETAL stdlib & abstraction index

There is no linked standard library — an ETAL program is exactly its
own `.ux` sources plus what this reference documents. This index
covers every callable abstraction in the language and the example
corpus: builtins, devices, and every function, event, macro, group,
dataset and buffer shipped in `examples/`.

## How to grep this reference

Every entry shows its literal declaration line in code ticks, so plain
`grep` finds both the docs and the source:

```sh
grep -rn "wrap ::" docs/api/ examples/     # all wrap variants + docs
grep -rn "main ::" docs/api/ examples/     # every program entry point
grep -rn "on_frame ::" docs/api/ examples/ # every frame handler
grep -rn "macro mod16" docs/api/ examples/ # macro definitions + uses
grep -rn "device Screen" docs/api/ examples/
```

Identifier lookup order (both here and in the compiler): macro-local
bindings, then function locals/params, then globals, in splice order.

## Map

- [Builtins](builtins.md) — `print`, `varvara.console.*`, and the
  `main ::` conventions (halting script vs event-loop game).
- [Devices](devices.md) — every `device` block and port in the
  corpus: System, Console (implicit), Screen, Controller, Mouse,
  DateTime.
- [Snake game](snake.md) — `examples/snake/`: state, `logic.ux`
  functions, `main.ux` events, sprites and data.
- [Worm games](worm.md) — `examples/worm/worm.ux` (stub) and
  `worm_full.ux`: groups, datasets, handlers.
- [Test libraries](testlib.md) — `examples/tests/lib.ux`,
  `lib2.ux`, `tests/ci_lib.ux`, and what each fixture harness proves.

## Everything, one table

| Abstraction | Kind | Where | Doc |
|---|---|---|---|
| `print` | builtin fn | compiler | [builtins](builtins.md#print) |
| `varvara.console.write` | foreign fn | compiler | [builtins](builtins.md#varvaraconsolewrite) |
| `varvara.console.read` | foreign fn | compiler | [builtins](builtins.md#varvaraconsoleread) |
| `varvara.console.error` | foreign fn | compiler | [builtins](builtins.md#varvaraconsoleerror) |
| `main ::` | entry convention | convention | [builtins](builtins.md#main) |
| System / Screen / Controller / Mouse / DateTime / Console | devices | `devices.ux`, `worm.ux`, … | [devices](devices.md) |
| `wrap` | fn (snake + 2 worm variants) | snake, worm, worm_full | [snake](snake.md#wrap), [stub](worm.md#wrap-wormux-stub), [full](worm.md#wrap-worm_fullux) |
| `set_dir` | fn | snake `logic.ux` | [snake](snake.md#set_dir) |
| `next_rand` | fn | snake `logic.ux` | [snake](snake.md#next_rand) |
| `new_food` | fn | snake, worm, worm_full | [snake](snake.md#new_food), [worm](worm.md#new_food) |
| `step` | fn | snake, worm, worm_full | [snake](snake.md#step), [stub](worm.md#step-wormux-stub), [full](worm.md#step-worm_fullux) |
| `draw`, `draw_head/food/worm/score`, `clear_screen` | fns | snake, worm, worm_full | [snake](snake.md#draw), [worm](worm.md#draw) |
| `init`, `init_state`, `init_random`, `on_start`, `wire_vectors` | fns | snake, worm, worm_full | [snake](snake.md#init_state), [worm](worm.md#init) |
| `on_controller`, `on_mouse`, `on_frame` | events | snake, worm, worm_full, tests | [snake](snake.md#on_controller), [worm](worm.md#on_controller) |
| `mod16`, `add1`, `add2`, `skip_if_zero` | macros | tests, `ci_lib.ux` | [testlib](testlib.md#macros) |
| `double`, `seven`, `three` | fns | tests, `ci_lib.ux` | [testlib](testlib.md#functions) |
| `dir` / `wait` / `food` | groups | worm | [worm](worm.md#groups) |
| head/body/tail/food/digits datasets | data | worm, worm_full, snake | [worm](worm.md#datasets), [snake](snake.md#sprites) |
| `tail_x`, `tail_y`, `cells`, `words` | buffers/arrays | snake, tests | [snake](snake.md#state), [testlib](testlib.md#buffers-and-harnesses) |
| `handler`, test `on_controller` | fn/event | `test_device.ux`, `test_event.ux` | [testlib](testlib.md#test-fixtures) |
