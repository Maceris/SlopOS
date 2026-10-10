# 0030: Use Hemera's `std` Directly, and Change the Hemera Repo Outside `apps/`

Status: accepted
Date: 2026-10-09
Supersedes: `0006`

## Context
`0006` kept a working copy of `std` inside SlopOS (`std_proposal/`) and forbade changing the
Hemera repository, so that Hemera could adopt changes at its own pace. In practice the copy
drifted, every change had to be upstreamed by hand, and proposals for `base` and `docs` waited
on a second pass on the Hemera side even when they were small and already agreed. Copying
back and forth became the bottleneck.

## Decision
- **SlopOS uses Hemera's own `std`.** The working copy is removed. Imports `from "std"` (or with
  no `from`) resolve to the Hemera repo's `std/`, with no `--package` remapping.
- **This project may change the Hemera repository, except `apps/`.** `base/`, `std/`,
  `examples/` and `docs/` are edited directly, as part of SlopOS work. `apps/` (the compiler,
  formatter and language server) is not.
- **What goes where:**
  - General-purpose library code, including the `OS == .SlopOS` branches and the `std` tiers
    (freestanding / allocating / os, declared per package as `PACKAGE_TIER`), goes in
    Hemera's `std/`, written as real `std` code.
  - Declarations in `base/` (types, `---` intrinsics, `base/compiler` API) can be added
    directly. Anything the compiler must implement (a new intrinsic, a builtin, filling in
    reflection data, a new directive or syntax) also gets an entry in
    `hemera-feedback.md`, and a design in `hemera-proposals/` when it's more than a line,
    because the compiler work happens in `apps/`, outside this project.
  - `docs/` is updated alongside every `base`/`std` change, so the docs describe what exists.
    A change to language semantics that the compiler must implement is proposed first
    (`hemera-proposals/`), and `docs/` updated once it's agreed.
- **Changes to the Hemera repo follow Hemera's conventions** (`docs/coding_guidelines.md`,
  its comment and `//TODO(name)` style) and are committed in the Hemera repository, separately
  from SlopOS commits. SlopOS-specific code stays out of Hemera except where `std` is meant to
  hold it (the `OS == .SlopOS` branches).
- `hemera-feedback.md` stays the evidence log: what Hemera made easy, hard or impossible,
  including changes this project made to Hemera and why.

## Alternatives considered
- **Keep `std_proposal` (`0006`):** isolates churn, but the copying cost is already higher than
  the churn it avoids, and the two copies were drifting.
- **Allow changes to `apps/` too:** faster for small compiler fixes, but the compiler is Hemera's
  core engineering work and is developed separately; SlopOS's job is to put pressure on it, not
  to change it.

## Consequences
- `std_proposal/` is deleted once its remaining differences are merged into Hemera's `std`
  (as of this decision, only `time/time.hsc`, which uses `runtime.Instant`).
- `base/runtime/thread.hsc` and other upstream `#else //TODO unsupported` branches can be fixed
  directly for `OS == .None` and `OS == .SlopOS`.
- Hemera's `std` gains the tiers package and a `PACKAGE_TIER` in every package; the tier check
  (`0029`) runs over Hemera's `std` itself.
- Marker comments still apply: `//STD(missing)` now means "not written yet" rather than "waiting
  on upstream", and should be rare, since the fix is usually to write it in `std/`.
