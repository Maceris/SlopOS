# 0038: System ABI Conventions

Status: accepted
Date: 2026-10-13
Related: `0025` (stable surfaces), `0026` (process start), `0027` (freeze timing), `0032`, `0033`

## Context
`../design/system-abi.md` §§2–8 proposed the conventions at each boundary: syscalls, process
start, libraries and C. Two questions were open: `#escaping` on syscall parameters, and a
per-thread pointer for callbacks from C.

## Decision
- **Conventions** (`../design/system-abi.md` §2):
  - **Syscalls** use a register convention generated from the typed syscall table in `slop_os`
    (§4). The number and up to six register-sized arguments go in registers, a slice takes two, and
    larger arguments go by pointer. The result is a tag (0 for success) plus up to two values,
    matching the arch interface's `SyscallResult`. The kernel preserves every other register.
  - **Process start** sets only the entry, the stack pointer and the startup-block argument, and
    zeroes everything else (§6, `0026`).
  - **Libraries** use the Hemera calling convention, pinned per version (§7).
  - **C** is reached through generated thunks (§8).
- **`#escaping` in the syscall table:** pointers the kernel keeps after a call returns (like
  `thread_create`'s `entry`, `stack` and `start`) are `#escaping` parameters. Pointers used only
  during the call aren't. A house-rule check over `slop_os` enforces that every kept pointer is
  marked.
- **No callbacks from C into Hemera for now.** SlopOS has no thread-local storage, so a callback
  can't find its carrier block. Calls from Hemera into C need nothing extra. Revisit, with one
  per-thread pointer the kernel saves, when C code is actually ported.

## Alternatives considered
- **A per-thread pointer now:** a cost on every thread for a feature nothing uses yet.
- **Leaving `#escaping` to code review:** a pointer into the stack handed to the kernel would be a
  silent use-after-return.

## Consequences
- The syscall stub generator reads `#escaping` from the table, and the check is added to the checks
  package (`0029`).
- A POSIX personality, or a ported C library with callbacks, needs this decision revisited.
