# 0124: 9f1, Code Shared, as Built

Status: accepted
Date: 2026-10-31
Related: `0123` (9f's plan), `0094` (code shared from the store), `0120`, `0121` (libraries)

## Context
`0123`'s first part: boot modules' code shared as the store's is, and a library's copy of `base` sharing the program's
process state, so `service_kit` can export the functions that reserve addresses.

## Decision
- **Boot modules' code**: the root task gives each program's module copy `RIGHT_MEMORY_EXECUTE`, which the kernel
  allows on a boot module's memory since `0120`, so `os.launch` passes the executable with it and the process builder
  maps its code from the module rather than copying it; and it gives the process builder the module itself when it
  loads the entropy service and the process manager. Every boot-set program's code is mapped from one copy now.
- **A library's process state** (Hemera): in a library, `intrinsics.process_state()` reads a pointer, its own state
  at first; the interface record's new last field, `process_state`, says where that pointer is, and
  `runtime.bind_libraries` points it at the program's. The record's magic is `HEMERAI2`, so a library built before is
  refused rather than misread. Hemera's typed-library test checks the library sees the program's state.
- **`service_kit`** exports `text_of` and `read_records` too, all nine of its functions.

## Alternatives considered
- **Passing the state on each call**, as `Context` is: every export would change type for what only `base` needs.

## Consequences
- What `base` keeps per process, a SlopOS program's reserved addresses, its startup block, the arguments on the hosts,
  is one for the program and its libraries.
- The frames a boot-set program's code takes are still not counted by any test.
