# Uxn DSL RAG Corpus Sources

## Language & VM Specification (Highest Priority)

### Core References
- **Uxntal Reference** — https://wiki.xxiivv.com/site/uxntal_reference.html
  - Language reference manual: syntax, labels, macros, addressing modes
- **Uxntal Opcodes** — https://wiki.xxiivv.com/site/uxntal_opcodes.html
  - Full opcode list with stack notation (a b -- c d) and behavior
- **Varvara Spec** — https://wiki.xxiivv.com/site/varvara.html
  - "Operating system"/device layer: System, Console, Screen, Audio, Controller, Mouse, File, Datetime devices and ports
- **Uxntal Cheatsheet** — https://wiki.xxiivv.com/site/uxntal_cheatsheet.html
  - Compact opcode quick-reference, good for short-context lookups

### Local Documentation
- **uxntal man page** — `uxn2/doc/man/uxntal.7`
  - Comprehensive reference guide with instruction layout, stack effects, opcodes

## Tutorials (Onboarding & Explanatory)

- **Compudanzas Uxn Tutorial** — https://compudanzas.net/uxn_tutorial.html
  - Most commonly recommended beginner walkthrough
- **Learn Uxntal in Y Minutes** — https://learnxinyminutes.com/docs/uxntal/
  - Fast syntax overview, condensed chunk format
- **Uxn Implementation Guide** — https://wiki.xxiivv.com/site/uxn.html
  - Notes on implementing the VM itself (internal mechanics)

## Example Code Sources

### Project Examples (First Priority)
- **Local examples/** — `uxn2/examples/`
  - `orca.tal` — Main example program
  - `library.tal` — Library file
  - `assets.tal` — Asset definitions

### External Examples
- **RosettaCode Uxntal** — https://rosettacode.org/wiki/Category:Uxntal
  - Small, focused idiomatic snippets per programming task (sorting, string manipulation, etc.)
- **Uxn Reference Repo** — https://git.sr.ht/~rabbits/uxn
  - Demos and games (piano, life, etc.) from the reference implementation
- **awesome-uxn List** — https://github.com/hundredrabbits/awesome-uxn
  - Curated list of real community projects (games, tools, OS-like software)

## Format/Asset References (Lower Priority)

- **Sprite Format (.chr)** — https://wiki.xxiivv.com/site/sprite.html
- **Font Format (.ufx)** — https://wiki.xxiivv.com/site/font.html
- **Compression Format (.ulz)** — https://wiki.xxiivv.com/site/compression.html

## Indexing Priority

1. **Opcode reference + Uxntal reference** — Dense, exact syntax/semantics (highest value per token)
2. **Project examples/ directory** — Real, project-relevant style
3. **Compudanzas tutorial + Learn Uxntal in Y Minutes** — Explanatory prose for "why"/"how" questions
4. **RosettaCode + awesome-uxn examples** — Broader coverage, lower priority
