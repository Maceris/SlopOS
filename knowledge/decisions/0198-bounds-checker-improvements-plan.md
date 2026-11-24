# 0198: Bounds Checker Improvements, Before M19, Planned

Status: accepted
Date: 2026-11-23
Related: Hemera's `docs/types.md` (*Bounds Checking*), `0197` (N2, where the powerbox needed an `if` it can't reach),
`../hemera-feedback.md`, `../roadmap.md`
Before M19

## Context
Before M19's N2 hit a counter the bounds proof lost through a loop, which the powerbox's prompt worked around with an
`if` that can't be reached. The owner asked for the bounds checker to be improved, and for the code to be scanned for
the workarounds it has made people write. A scan of 692 files (SlopOS's `src`, Hemera's `std` and `base`) counted the
shapes those workarounds take, and probes, each a function the size of the shape, sorted the proof's real gaps from
code that's only careful:

| Gap | Probe | Reach |
|---|---|---|
| **G1.** A count kept in a struct beside its fixed array (`holder.count`, `holder.name`) is never known to be at most the array's count: every use checks it again. `docs/types.md` lists it as what isn't proven | fails | about 100 checks of `x.count <= x.items.count`, in 48 files |
| **G2.** An `if` expression's value carries nothing of its branches: `n :: if a < b.count { a } else { b.count }`, then `b[0..<n]`, or a loop to `n` indexing two arrays | fails | 129 minimums written so, in 87 files; 25 loops checking their index twice; 11 `min_count` helpers |
| **G3.** A counter kept below a fixed array's count through a loop: the count's a constant, and the bound against it loosens by one each time around until it's dropped (widening without thresholds). Over a view, whose count is a term, it's proven | fails | the powerbox's unreachable `if`, and the like |
| **G4.** A field set from an expression (`holder.count = i + 1`) forgets what's known of it; set from a local, it's kept | fails | 18 copies counting `i + 1` |
| **G5.** A call forgets what's known through every pointer, even one that writes nothing (`docs/types.md`, *What Isn't*) | fails | "proven again after the calls", and fields copied to locals to keep them |

Proven already, so the workarounds for them are needless: an early return on `!read || list.count < 2` (then
`list[1]`, where seven places write `list[1 % list.count]`), an index found by a loop and compared after it, and a copy
into a fixed array counting `i + 1` in a local.

## Decision
Chosen with the owner (2026-11-23): a milestone of its own before M19, so RISC-V's code is written against it.

- **B1, the proof (G2, G3, G4).** An `if` expression's value is a term of its own, what each branch says of it joined,
  as paths that meet are. When a loop's bound keeps loosening, it's tried at the constants the loop compares against
  (fixed arrays' counts among them) before it's dropped. A store to a field is taken as an assignment to a local is.
  Front-end scenarios for each, every probe above proven, and no new E4031 anywhere.
- **B2, calls (G5).** Which functions can write memory, worked out from their bodies once all are checked, as the
  stack-pointer check works out what each gives back: a call to one that can't keeps what's known through pointers.
  A call through a function pointer, or to a foreign function, still forgets.
- **B3, declared field bounds (G1).** A field may say what bounds it, `count : usize #at_most(name.count)`: every
  store to it must be proven within that, and every read may take it as known, through pointers and across calls. The
  name and the forms it takes (a field of the same struct; `<` as well as `<=`) are settled when it's built, in
  Hemera's docs, with the formatter and the language server knowing it.
- **B4, the sweep.** Every workaround the scan finds that B1 to B3 make needless is taken out, across SlopOS's `src`
  and Hemera's `std` and `base`, each change built: guards that can't fail, indexes modulo their own count, unreachable
  `if`s, `min_count` helpers, counts copied to locals only to keep them. The scan is kept as a tool, and `docs/types.md`
  says what's proven as each stage lands.

## Alternatives considered
- **Moving stored counts into `std/containers`' `FixedArray`** instead of a field bound: no language change, but much
  rewriting, and every struct that keeps a count beside an array, including the protocols', would have to change shape.
- **Only the proof's own fixes (B1, B2)**, leaving G1's checks: the largest of the gaps would stay.
- **Cleaning up only where touched later:** the workarounds would outlive the reason for them, and teach the next reader
  that the proof needs them.
