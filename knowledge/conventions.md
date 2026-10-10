# Conventions: Writing Hemera Before the Compiler Can Build It

SlopOS code is written now, against a language and standard library that are still being
designed. These conventions keep that code honest and turn it into searchable evidence
for `hemera-feedback.md`.

## Marker Comments

Every marker is greppable, so the feedback log can be regenerated from the source.

| Marker | Meaning | Example |
|---|---|---|
| `//HEMERA(gap): ...` | The language can't express this yet. Code is written the way it *should* look. | `//HEMERA(gap): needs an interrupt calling convention` |
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
  (kernel: `context.user_data` → `PerCpu`, see `hemera-feedback.md`).

## House Rules Are Checks

Project rules are enforced by `#run` code that reflects over packages and reports compile
errors (`decisions/0007`), not just written down. When adding a rule, add a function to
the house-rules checks package and call it from `check_program`, which the build package
registers with `compiler.add_check` (`decisions/0029`). The API is Hemera's
`base/compiler`; if it can't express a rule yet, write the check against the API we expect,
marked `//HEMERA(gap)` or `//HEMERA(guess)`, and list the need in
`hemera-proposals/reflection-checks.md`.

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

  The tier check (`decisions/0029`, `hemera-proposals/reflection-checks.md`) rejects any
  import of a higher tier, inside `std` and from SlopOS. The `Os` tier gets an
  `OS == .SlopOS` branch next to Linux/Mac/Windows (roadmap M6).
- **The Hemera repo outside `apps/` may be changed.** `base/`, `std/`, `examples/` and `docs/`
  are edited directly and committed in the Hemera repo, with `docs/` updated alongside. The
  compiler (`apps/`) is not changed from this project: what it must implement is recorded in
  `hemera-feedback.md` and, when it needs a design, `hemera-proposals/`.
