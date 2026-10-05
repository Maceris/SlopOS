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
| `//STD(missing): ...` | Calls a `std`/`base` function that doesn't exist yet. Signature is a proposal. | `//STD(missing): formatting into a fixed buffer, no allocator` |
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
errors (`decisions/0007`), not just written down. When adding a rule, add a check in
the house-rules checks package (or, if the reflection API can't express it yet, write the check against
the API we expect, marked `//HEMERA(guess)`, and list the need in
`hemera-proposals/reflection-checks.md`).

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

- **`std_proposal/`** (repo root) is SlopOS's working copy of Hemera `std`, and *is* `std`
  for this project. General-purpose code SlopOS needs (containers, fixed-buffer formatting,
  allocators, the `OS == .SlopOS` branches) goes there, written as real `std` code. See
  `../std_proposal/README.md` and `decisions/0006-std-proposal.md`.
- **The Hemera repo is never modified from this project.** Needed changes to `base`, the
  compiler or the docs are recorded in `hemera-feedback.md` / `hemera-proposals/` and made
  on the Hemera side.
