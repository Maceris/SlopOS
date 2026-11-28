# 0203: ABI v1 Is Declared

Status: accepted
Date: 2026-11-27
Related: `0025` (what stability means from v1), `0027` (no freezing until the design is thorough, and v1 its own
record), `0201` (M20, the comparison), `0202` (M21, the review and the owner's choices before v1),
`../design/system-abi.md`, `../../docs/specs/abi_v1.x86_64.txt`, `abi_v1.aarch64.txt`, `abi_v1.riscv64.txt`

## Context
`0027` left v1 until the OS design was fairly thorough and development well under way, and asked for its own record
once every surface in `../design/system-abi.md` §1 had been reviewed. By the end of M21 the system has its kernel on
three architectures, storage, networking, a GUI, audio, debugging and a libc, and the surfaces were gone over twice
before being frozen: M20's 20m and 20n, then M21's 21b and 21c, which made the owner's last changes (`0202`, *Settled
with the owner*: CPU features at 1024 bits, the rights split, limits read at run time, `StopInfo` and `CpuBudgetInfo`
size-prefixed, the register order declared), and 21i's review of them.

## Decision
- **ABI v1 is declared**: `ABI_VERSION` 16, the count continued from 15. Every row of `../design/system-abi.md` §1 is
  stable from it, by `0025`'s rules: system calls appended and never renumbered or changed, layouts growing only
  where they're size-prefixed (`GROWABLE`: `StartupBlock`, `ThreadDebug`, `StopInfo`, `CpuBudgetInfo`), and new
  constants, types and enum members added.
- **v1 is frozen in files**, one for each architecture, as the package differs by architecture
  (`THREAD_REGISTERS`, the register order): `docs/specs/abi_v1.<arch>.txt`, the package's description as
  `src/tools/abi_description` writes it. They're written once, now, and never again.
- **A unit test keeps the promise**: `tools/unit_tests.py` compares each architecture's built description with its v1
  file by `0025`'s rules (`abi_description --compare`, not exact), as well as exactly with
  `docs/specs/abi_description.<arch>.txt`, which is still rewritten for every change made on purpose. A change v1
  forbids fails however the second files are rewritten.
- **`ABI_VERSION` only grows**: the comparison takes a larger one as allowed, and a smaller one as forbidden. A later
  version keeps every promise of the earlier ones; it says only that more is there.
- **A program refuses only an older kernel**, as since 20n: base's runtime ends a program whose startup block's
  version is older than its own with `EXIT_WRONG_ABI` (256); a newer kernel starts it.
- **What stays unstable** is what §1 leaves out: kernel internals, `std`'s own API, and the Hemera calling convention
  between separately compiled libraries, which stays pinned by version rather than frozen (§7), so a library built for
  another convention is another hash.

## Alternatives considered
- **v1 at 1, numbered afresh**: tidier, but 1 to 15 already numbered earlier layouts, and a count that only grows
  can't take one for another. The owner chose 16 (`0202`).
- **Comparing against the previous release only**, as `0025` first put it: there's no release process yet, and a
  description rewritten with each change would let a break through as easily as the change itself. A frozen file per
  version can't be rewritten by accident.
- **Leaving v1 for a later milestone**: nothing planned changes a system call, and every month of rebuilding
  everything together postpones what v1 is for, programs built apart from the system.

## Consequences
- A system call is changed by adding one: a new number, with the old one kept, answering `NoSuchCall` (7) if it's
  ever taken away. Its declaration stays in the package, so the comparison still finds it.
- A layout that isn't size-prefixed is fixed for good. A struct that has to grow is a new struct, with a new call to
  take it.
- Programs built against v1 run on every later kernel. Programs need not be rebuilt with the system, though SlopOS's
  own still are.
- A v2, if one ever comes, gets its own `abi_v2.<arch>.txt`, compared against v1's as these are.
