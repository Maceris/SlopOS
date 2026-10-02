# std_proposal

A working copy of Hemera's standard library (`std`). **For SlopOS development, this is
`std`.** Code here can be changed freely without touching the Hemera repository.
Once parts of it are properly fleshed out, they can be copied into the official repo
at our leisure.

## Rules

- **The Hemera repository is never modified from this project.** Changes to Hemera
  (`base`, compiler, docs) are requested and happen there in parallel.
- Everything SlopOS imports `from "std"` (or with no `from`) means this folder.
- `base` is *not* copied. It belongs to the language and is used straight from the Hemera repo.
- Code here is real implementation code, held to the same standard as the rest of SlopOS
  (`../knowledge/decisions/0005-scope-real-implementations.md`, `../knowledge/conventions.md`).
- To compile against this folder instead of Hemera's `std`, pass
  `--package=std:<path to std_proposal>` to the compiler.
- Every package must say which targets it supports (see below), so the kernel knows what it
  may import.

## Target Tiers (proposed)

The kernel builds with `OS == .None` and has no operating system underneath, so `std`
needs a clear split between code that needs an OS and code that doesn't:

| Tier | Needs | Usable in kernel? | Examples |
|---|---|---|---|
| **freestanding** | nothing but `base` | yes | `atomic`, `memory/result`, string utilities, containers, fixed-buffer formatting |
| **allocating** | an `Allocator` in `context` | yes, once the kernel heap exists | `string_builder`, dynamic containers, `SharedPtr` |
| **os** | system calls | no | `io`, `os`, `time`, threads, `fiber` scheduler |

Each package declares its tier as a compile-time constant, using the `Tier` enum from a
small freestanding `tiers` package:

```
PACKAGE_TIER :: tiers.Tier.Freestanding
```

A `#run` check reads these constants and rejects any import of a higher-tier package, both
inside `std_proposal` and from SlopOS (the kernel allows at most `Allocating`). See
`../knowledge/decisions/0007-house-rules-compile-time-checks.md` and
`../knowledge/hemera-proposals/reflection-checks.md`.

The `os` tier gets an `OS == .SlopOS` branch alongside Linux/Mac/Windows, which is where the
SlopOS system interface (`../knowledge/roadmap.md`, M6) plugs in.
