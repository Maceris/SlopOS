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

## As Built: B1, the proof
- **An `if` expression** of an integer type is a term of its own, which each branch says is its value, joined where
  they meet: `n :: if want < text.count { want } else { text.count }` is at most `text.count`.
- **A loop's bound** that keeps loosening past the first four times is tried at the constants the function compares
  against, a step either side, before it's dropped: a counter kept below a fixed array's constant count keeps it.
- **A store into one field** of what a local reaches keeps what's known of its other fields when their bytes are apart:
  a path's member steps say where each member is, a `#union`'s all at 0.

## As Built: B2, calls
Each body is proven where it's checked, quietly; one that isn't is proven again once every body is checked, knowing
which functions write no memory but their own locals: a greatest fixed point over the calls, so functions that call
each other stay in it. A call through a function value, to a foreign function or to an intrinsic may write anything.

## As Built: B3, bounded fields
`count #at_most(name.count) : usize`, the bound a fixed array field's count or a constant (Hemera's `docs/types.md`,
*Bounded Fields*). Known wherever the field's read, through pointers and after calls; every store, compound assignment
and struct literal is proven to keep it (E4048, *Field bound not kept*), and its address can't be taken. A view's or a
dynamic array's count can't bound it (E4014). `compiler.StructMember` says it, at compile time and run time; a value
read from raw bytes is trusted as an enum's is, so `std/os`'s generated validators and base's schema reader check it.

## As Built: B4, the sweep
- **What the sweep needed of the proof:**
  - An element at any index keeps its array's place, so a store into one array of a struct keeps its sibling fields.
  - A store into a local's own field doesn't forget what's known through pointers.
  - `a - b`, with `b` at least 0 and at most `a`, is at most `a`, and `-=` so keeps a field's bound.
  - A range's end changed in the loop's body is still what the index is below.
  - An integer read through a pointer is a term of its own.
  - Forgetting one term keeps what it implied of the others.
  - A function's integer result is summarized as at most a constant, or at most what an array or integer parameter
    was on entry, so `count = copy(&into, bytes)` keeps `#at_most(into.count)`.
- **102 bounded fields:** 87 in SlopOS, 15 in `std` and `base`.
- **The guards:** of 226 guards the scan found, 80 are gone and 146 are put back, each where a build said the
  proof needs it. Every SlopOS target, tool and unit test package, and Hemera's tests, were rebuilt after each round.
- **Indexes modulo their own count:** 21 are gone. Nine are kept:
  - In fat, recording (4), the supervisor and x509, the index isn't below the count.
  - In two AML tests, the count is checked by `testing.require(...)?`, which the proof can't see through.
- **A test that needs a count past its bound** (system_records' over-full list of installations) writes it through a
  pointer to the record, as a list read from the config store could be. The validator still rejects it.
- **Code changed so the proof sees it, not just checks dropped:**
  - Delivery loops take their snapshots or compute what's left before the send.
  - Copies return the count they copied instead of the count they were given. One of these was a real bug: the
    terminal service stored the logged-in user's name's whole count, however much of it fit, and clamped it only
    where it was used.
  - `std/fuzzing` and `std/testing` cut a replayed case's count, `read_bytes`' count, to the room it's in. The proof
    can't see that a view returned through a source is within the room. Working it out from `source.at` and the
    case's count instead was wrong: the case grows as the test reads past it. The property tests' shrinking output
    caught that.
  - Removals shrink a count before logging it.
  - slopfs's volume checks what it reads against the room it has, and reports Corrupt otherwise.
- **The scan is kept**, `tools/bounds_workarounds.py`:
  - No `x.count <= x.items.count` recheck is left.
  - The `<` checks left decide whether there's room to add one.
  - The eight loops checking their index twice index two different arrays.
  - The nine `min_count` calls left cap a width at 40 columns.
