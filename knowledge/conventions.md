# Conventions: Writing SlopOS's Hemera

SlopOS code is written to build and run, against a language, compiler and standard library that
are still being built; where the compiler falls short, it's extended (`decisions/0047`). These
conventions keep the code honest and turn what it finds into searchable evidence for
`hemera-feedback.md`.

## Marker Comments

Every marker is greppable, so the feedback log can be regenerated from the source.

| Marker | Meaning | Example |
|---|---|---|
| `//HEMERA(gap): ...` | The language can't express this yet, and fixing that is deliberately left for later (say why). Prefer extending the compiler now (`decisions/0047`). | `//HEMERA(gap): needs an interrupt calling convention` |
| `//HEMERA(guess): ...` | Syntax or semantics aren't documented; this is our best guess. | `//HEMERA(guess): directive placement after loop` |
| `//HEMERA(friction): ...` | Works, but is clumsy. Worth a language/library change? | `//HEMERA(friction): unused 'old' just to test CAS success` |
| `//STD(missing): ...` | Calls a `std`/`base` function that doesn't exist yet. Signature is a proposal. Prefer writing it in Hemera's `std`/`base`; use the marker only when deferring. | `//STD(missing): formatting into a fixed buffer, no allocator` |
| `//SPEC: ...` | Where the hardware/format definition comes from. Required on every hardware structure. | `//SPEC: Intel SDM Vol. 3A §4.5, Table 4-20` |
| `//TODO(name): ...` | Ordinary unfinished work (same style as the Hemera repo). | |

`grep -rn "HEMERA(" src/` should always give an up-to-date list of language issues.

## Code Style
- Follow Hemera's `docs/coding_guidelines.md` (a function does exactly one thing) and
  `docs/formatting.md`.
- Packages follow `docs/packages.md`: a folder per package, `package` statement in every file.
- No mutable globals, so all state is reached through parameters or `context`
  (kernel: `intrinsics.carrier().program_data` → `PerCpu`, `../docs/architecture/layers.md` L1).

## House Rules Are Checks

Project rules are enforced by `#run` code that reflects over packages and reports compile
errors (`decisions/0007`), not just written down. When adding a rule, add a function to
the house-rules checks package and call it from `check_program`, which the build package
registers with `compiler.add_check` (`decisions/0029`). The API is Hemera's
`base/compiler`; if it can't express a rule yet, extend it, or, when that's deliberately left for
later, mark the check `//HEMERA(gap)` and log the need in `hemera-feedback.md`.

## Hardware and Binary Structures
- Use explicit-endian types (`u32le`) for anything whose layout is defined externally (disk,
  wire, firmware tables). Native types only for in-memory, CPU-defined structures.
- Every such struct gets a compile-time layout check next to its definition:
  ```
  GdtEntry :: struct #packed { /* ... */ }
  #assert size_of(GdtEntry) == 8             //SPEC: Intel SDM Vol. 3A §3.4.5
  ```
  This stresses compile-time execution and catches layout mistakes the day the compiler works.
- Bit-packed fields: integers + generated/handwritten accessors on a `distinct` type for now
  (`hemera-proposals/bitfields.md`, Option A).

## Errors
- Fallible functions return `Result[T, E]` (or an optional), with `E` a tagged union specific
  to that subsystem. No sentinel values.
- Not-yet-implemented paths return an explicit `NotSupported` variant, never a fake success.
- Every kernel resource that can run out has a named failure point (`robustness.Point`, decisions/0096, 0104): a
  `fails(.Point)` (`kernel/faults.hsc`), or `robustness.fails` with the frame allocator's `faults`, where it's taken,
  before anything is changed, so a sweep (`boot_tests.py --robustness`) runs its error path. A new kind of resource
  gets a new point.
- A call's error is handled where it can happen, never discarded where the program then waits for what the call
  would have set up: a `port_bind` that fails means a wait that would never end.

## Tests
- Pure logic (allocators, parsers, containers, formatting) gets tests in the package's
  `test/` folder, written to run on the host once the compiler works.
- Hemera has no documented test framework yet. Note what's needed with `//STD(missing)`.

## Where Library Code Lives

- **Hemera's `std/`** is the `std` SlopOS uses (`decisions/0030`). General-purpose code SlopOS
  needs (containers, fixed-buffer formatting, allocators, the `OS == .SlopOS` branches) goes
  there, written as real `std` code following Hemera's conventions. SlopOS-specific code stays
  in `src/`.
- **`std` tiers.** The kernel builds with `OS == .None`, so every `std` package declares what
  it needs as `PACKAGE_TIER :: tiers.Tier.<Tier>`, from a small freestanding `tiers` package:

  | Tier | Needs | Usable in kernel? | Examples |
  |---|---|---|---|
  | `Freestanding` | nothing but `base` | yes | `atomic`, `memory/result`, string utilities, containers, fixed-buffer formatting |
  | `Allocating` | an `Allocator` in `context` | yes, once the kernel heap exists | `string_builder`, dynamic containers, `SharedPtr` |
  | `Os` | system calls | no | `io`, `os`, `time`, threads, the `fiber` scheduler |

  The tier check (`decisions/0029`, `src/checks`) rejects any
  import of a higher tier, inside `std` and from SlopOS. The `Os` tier gets an
  `OS == .SlopOS` branch next to Linux/Mac/Windows (roadmap M6).
- **The Hemera repo outside `apps/` may be changed.** `base/`, `std/`, `examples/` and `docs/`
  are edited directly and committed in the Hemera repo, with `docs/` updated alongside. The
  compiler (`apps/`) is extended as SlopOS needs it, with tests (`decisions/0047`); language
  design is proposed in `hemera-proposals/` and decided with the Hemera author first.
