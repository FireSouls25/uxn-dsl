# Statements

Every statement ends with `;`. Conditions accept `bool`, `u8` or `u16`
(truthy = nonzero), but prefer real comparisons — see
[limitations](limitations.md) on bare-`u16` conditions.

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

## For

```ux
for i in 0..height {
    draw_row(i);
}
```

Half-open range `[start, end)`: the loop variable (always `u16`,
fresh per loop) runs from `start` while `< end`. Bounds may be any
`u8`/`u16` expressions, but note the end bound is re-evaluated every
iteration — hoist anything costly or effectful.

## Return, goto, labels, brk

```ux
return x;        ( leave with a value on the stack )
return;          ( leave void )
goto done;       ( !&done )
label done;      ( &done — or `label done:` )
brk;             ( BRK: end the current vector )
```

`brk` ends the *vector*, not the function: it belongs in `event`
handlers (including `main :: event()`), never on a plain `fn` path —
a `BRK` inside reset-vector code returns to the emulator early and
your `HALT` never runs. Labels are function-scoped (`&`-labels);
gotos may only target the same function.

## Blocks and declarations

```ux
{
    tmp: u16 = x + 1;
    acc = acc + tmp;
}
```

Braces open a scope for `name: type [= init];` locals. Locals are
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
