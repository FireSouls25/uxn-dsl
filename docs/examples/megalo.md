# Examples: Megalovania audio demo

`examples/megalo/` is the end-to-end audio program: a 20-note loop on
a square-wave lead (Audio0, sequenced by `song_tick`) plus a one-shot
`.wav` blip cue (Audio1). It exercises `.wav` assets, `lib/audio.ux`
and `lib/song.ux` together. Needs speakers — and a display for the
frame vector (web builds run silently: uxn5 has no audio device).

## Files

| File | Role |
|---|---|
| `devices.ux` | Audio0 (ports `30`), Audio1 (ports `40`), Screen (`20`, frame vector only — nothing is drawn) |
| `main.ux` | note table setup, `on_frame :: event()` calls `song_tick()` |
| `blip.wav` | 4410 samples = 0.1s of 8-bit mono 44100Hz PCM, embedded with zero conversion |

## How it maps to the language

- **Notes** are a `song[24]: Note` table (`pitch` + `len` in frames):
  16 = 8th, 32 = quarter at ~112 BPM. 14×16 + 6×32 = 416 frames ≈
  6.9s per loop.
- **Sequencing** is one call per frame (`song_tick()`); attacks touch
  the Audio0 ports, sustain ticks let the envelope tail ring, so
  quarters sound longer than 8ths.
- **The blip** is a `data blip = file("blip.wav")` asset played once
  at unity rate: `length = 4410` (the whole sample), `pitch = 188`
  (`NOTE_C4` + 128: middle C, high bit = play once).
- **Entry** is `main :: event()`, so the VM stays in the event loop
  instead of halting.

## Running it

```sh
./build/linux-x86/etal examples/megalo/main.ux -o /tmp/megalo && /tmp/megalo
./build/linux-x86/etal -r examples/megalo/main.ux -o /tmp/megalo.rom
./build/linux-x86/etal --target web examples/megalo/main.ux -o /tmp/megalo.html
```

Ear check: one blip at startup, then the square-lead loop repeating
every ~7s. The web page animates frames but stays silent. Headless
health check (no speakers needed):

```sh
timeout 3 env SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
  ./vendor/linux-x86_64/uxn2 /tmp/megalo.rom
```

Killed by the timeout (exit 124) with zero output means healthy: the
event loop idles, nothing crashes, nothing prints.
