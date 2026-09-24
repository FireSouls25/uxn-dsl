# Statements

Every statement ends with `;`. Conditions accept `bool`, `u8` or `u16`
(truthy = nonzero); a short condition is reduced with `#0000 NEQ2`
first, so the full value is tested and nothing leaks — but prefer
real comparisons anyway.

## If / elif / else

```ux
if x == 0 {
    ...
} elif x == 1 {
    ...
} else {
    ...
}
```

Compiles to the standard `?&then` / `!&else` conditional-jump shape.
Any number of `elif` branches; `else` optional.

## While

```ux
while wait != 0 {
    wait = wait - 1;
}
```

`&loop <cond> ?&cont !&end &cont <body> !&loop &end`. The condition
is evaluated on every iteration — avoid side effects in it.

## Match

```ux
match dir {
    0 => { ... }
    1 => { ... }
    _ => { ... }
}
```

Integer-literal arms plus one optional trailing `_` default, each a
brace block. Lowers to a freshened temp plus an `if`/`elif` chain, so
the scrutinee evaluates exactly once and all existing gates apply.
A lone default is just its body. No jump tables yet (proposal 3 v2):
dispatch is O(n) comparisons, fine for directions and menu picks,
not for opcode interpreters.

## For

```ux
for i in 0..height {
    draw_row(i);
}
```

Half-open range `[start, end)`: the loop variable (always `u16`,
fresh per loop) runs from `start` while `< end`. Bounds may be any
`u8`/`u16` expressions. A syntactically pure end bound (literal,
variable, constant) is evaluated once up front; anything that could
call or store is re-evaluated every iteration as before. Note the
pure case freezes the entry value: a body that assigns to the bound
variable still iterates to the entry bound.

## Return, goto, labels, brk

```ux
return x;        ( leave with a value on the stack )
return;          ( leave void: BRK in an event, JMP2r in a fn )
goto done;       ( !&done )
label done;      ( &done — or `label done:` )
brk;             ( BRK: end the current vector )
```

A bare `return;` is the safe early exit everywhere: inside `event`
handlers it emits `BRK` (vectors are never `JSR`-called, so `JMP2r`
would pop a bogus address); in plain functions it emits `JMP2r`.
`brk` ends the *vector*, not the function: it belongs in `event`
handlers (including `main :: event()`), never on a plain `fn` path —
a `BRK` inside reset-vector code returns to the emulator early and
your `HALT` never runs. Labels are function-scoped (`&`-labels);
gotos may only target the same function.

## Discard (`_ =`)

```ux
_ = obj_spawn(10, 20, 100, flags);   ( evaluate, pop, keep going )
```

A valued call as a bare statement warns (`discarded return value` —
usually a lost update, and for getters a leaked stack slot per call).
When the value is genuinely unneeded but the call's side effect is
the point, say so with `_ =`: evaluates the expression, then `POP`
or `POP2` by width. Dropping `void` is an error (drop the call
itself instead), as are whole structs/arrays (they never sit on the
stack as values).

## Assert

```ux
assert x == 2;   ( silent when true; prints `assert failed at
                   file:line:col` and halts when false )
```

Self-checking harnesses without outside tooling: the condition
(`bool`/`u8`/`u16`, like `if`) totals to one byte; on false the
baked location prints and `BRK` aborts to the emulator — even
inside a plain `fn`, where halting (not returning) is the point.
Asserts in macro bodies report the macro's definition site, not
the call site.

## Blocks and declarations

```ux
{
    tmp: u16 = x + 1;
    acc = acc + tmp;
}
```

Braces open a scope for locals in any of the four declaration
forms (`: type =`, `:=`, `: type :`, `::`). Locals are
zero-page slots (mangled per function), shared on redeclaration, and
visible for the rest of the enclosing scope — there is no shadowing
discipline beyond "innermost declaration wins the name".

## Return-stack juggling

```ux
rpush x;    ( STH/STH2: move top of working stack to return stack )
rpop;       ( STHr: move it back )
rpeek;      ( STHkr: copy it back, keeping the return-stack copy )
```

Direct access to Uxn's second stack, sized by the value (bytes take
`STH`, shorts `STH2`). Useful for saving values across calls without
spending zero-page on them.
