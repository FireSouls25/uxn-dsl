# Examples: Chess

`examples/chess/` is the biggest ETAL program: a playable chess game
with menu / side-select / board / pause / game-over scenes, mouse drag
plus full keyboard menus, and a built-in bot. (Like all of `examples/`
it is untracked helper code, not a versioned artifact.)

## Files

| File | Role |
|---|---|
| `devices.ux` | System, Screen (192×128), Mouse, Audio0/1, Controller, DateTime |
| `pieces.ux` | 12 `PT_*` kinds, `wtiles`/`btiles` 2bpp sprite blobs, `tile_addr` |
| `rules.ux` | board, movegen, check/mate, undo, `ai_choose`, `rand8` — no drawing |
| `game.ux` | scenes, board/panel drawing, drag, highlights, anims, sounds |
| `main.ux` | palette, mate jingle, vectors, `main :: event()` |
| `test_chess.ux` | opening count + Fool's + Scholar's mate (`140101`) |
| `test_chess2.ux` | both castles, en-passant, promotion (`01010105`) |
| `test_material.ux` | panel counter format (`+00+03+09+10+12-39`) |

## Rules core

Squares are 0–63 (`rank*8+file`, rank 0 = white home); pieces 0 empty,
1–6 white P N B R Q K, 7–12 black. `gen_moves` emits pseudo-legal
moves into `mfrom`/`mto` buffers (rays via `ray`, leapers via
`leap_to`, pawns/castling special-cased); `gen_legal` filters by
make/unmake (`do_move`/`undo_move` share undo globals, no recursion
anywhere). Promotion is always queen; draws by stalemate or the
50-move clock — no repetition tracking. Everything static and
headless-testable, which is why the rules gates print exact bytes.

## The bot (`ai_choose`)

Greedy 1-ply: score every legal move as captures by victim value ×10,
+100 for en-passant, +50 for giving check, +10000 for delivering mate,
over a `rand8` (0–7) tiebreak baseline, and play the max. Probing
(`game_status`) trashes the move list and undo slots, so candidates
are copied to `aifrom`/`aito` buffers and undo bytes stashed per
probe. Rough strength **~300–500 Elo**: punishes hanging pieces and
finds 1-move mates, but hangs its own, has no positional terms, and
can loop positions forever. Enough to beat a casual beginner's
blunders, not their attention.

## UI notes

- The VM hides the system cursor, so the game blits its own `cursor`
  tile last in every scene; the panel counter is sign + two digits
  (`mat_show` — a single `48+d` digit shows `:` past a 9-point gap).
- Input is vector-latched (`on_key`/`on_mouse` into `keybuf`/`mousebuf`
  plus a controller-button edge mask): the key port self-clears
  between frames and quick clicks fall between polls, so raw polling
  misses both. Menus share one `menu_sel` between hover and arrows/W/S
  + Enter/Space/Z.
- Every move glides over 10 frames (buffer-resident lerp, zero
  zero-page cost): the human drop arms it, and the bot reply chains
  off its last frame, so the two glides play in turn with a natural
  thinking beat. Castling slides only the king and en-passant victims
  vanish at move time.
- Menu QUIT writes nonzero `System/state`, which is what breaks the VM
  loop — a real quit. (`brk` there only ended one frame.)

## Running it

```sh
./build/linux-x86/etal examples/chess/main.ux -o /tmp/chess && /tmp/chess
```

Click (or arrows + Enter) PLAY, pick a side, drag pieces or
click-click; ESC pauses. Headless rules checks assemble the `test_*`
harnesses and diff console bytes (see `lib/check.sh` conventions).
