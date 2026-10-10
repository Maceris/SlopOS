# 0006: `std_proposal` — A Working Copy of `std` Inside SlopOS

Status: superseded by 0030
Date: 2026-10-01

## Context
SlopOS needs a great deal of standard-library code (containers, formatting, allocators,
the SlopOS branches of `io`/`os`/`time`), and building it is a large part of testing
Hemera. But this project must not modify the Hemera repository, whose `std` is still mostly
stubs and is being developed in parallel.

## Decision
- `std_proposal/` at the repository root is a copy of Hemera's `std` (copied from Hemera
  commit `aa6ceef` on 2026-10-01). For SlopOS development it **is** `std`.
- It is modified freely here. Finished packages are copied into the Hemera repo later, by
  the Hemera side, at its own pace.
- `base` is not copied; it is used directly from the Hemera repo.
- **This project never modifies the Hemera repository.** Language, `base`, compiler and
  documentation changes are requested via `hemera-feedback.md` / `hemera-proposals/`.

## Alternatives considered
- **Write directly into the Hemera repo:** `std` gets real code sooner, but mixes an
  experimental project's churn into the language repo.
- **Keep library code in `src/lib/`:** no clear path to `std`, and it would duplicate what
  `std` should provide.

## Consequences
- The compiler resolves `from "std"` to `std_proposal/` with `--package=std:<path>`
  (added to Hemera 2026-10-01).
- Upstream and here can drift; compare against Hemera's git history from the commit above
  when merging in either direction.
- `std_proposal` introduces tiers (freestanding / allocating / os) so the kernel can use
  the parts that don't need an OS.
