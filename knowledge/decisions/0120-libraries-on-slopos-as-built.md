# 0120: 9e1, Libraries on SlopOS, as Built

Status: accepted
Date: 2026-10-31
Related: `0119` (9e's plan), `0045` (content-addressed libraries), `0069` (test programs),
`../hemera-proposals/typed-linking.md`

## Context
`0119` has the program's runtime bind its typed libraries from grants, `library:<file>`, given by whoever launches it,
the library's text mapped shared from the memory given and its data copied. 9e1 is that on SlopOS, with a test program
bound to a small library and refused a changed one.

## Decision
- **The build** makes every folder in `src/libraries` a SlopOS `DynamicLibrary`, `<name>.library` beside the programs,
  for the programs' architecture. Which program links which library is the build's table `PROGRAM_LIBRARIES`, by name;
  for now only `test_libraries` links `greeting`. `std/schema`, which the compiler loads into a library's build without
  an import, counts as `std` for the house rules.
- **`base`'s loader** (`runtime/slop_os_libraries.hsc`): the grant `library:<file>` the program's import table names,
  its whole file mapped read-only to read; each `PT_LOAD` that isn't written mapped straight from the grant's memory,
  read/execute or read-only, so every process using the library shares its frames; each that is written copied into
  memory of the program's own, read/write. Only relative relocations are applied, and only within those copies; any
  other kind, or one into what's shared, refuses the library. Its interface record is at its entry, as on Linux, and
  `bind_libraries` checks it as on the hosts. There's no call to change a mapping's protection, so relocated data stays
  writable.
- **Launching**: `std`'s `LaunchOptions` has `libraries`, each a file name and its memory, given as `library:<file>`.
  The root task gives every test program each `.library` boot module, with `RIGHT_MEMORY_EXECUTE`; the runtime binds
  those it imports and ignores the rest.
- **The kernel** lets a boot module's memory be mapped read/execute, never written, as a handle with
  `RIGHT_MEMORY_EXECUTE` allows; it was read-only, which a library's text can't be mapped as.
- **`boot.py`** carries the `.library` files as modules, on the ISO and in the boot disk's generation.
- **Tests**: `test_libraries` binds `greeting` and calls its three exports (a sum, text the caller's `Context` allocates,
  a constant its relocations point to). With `test_changed_library`, the root task gives `greeting_changed.library` in
  `greeting.library`'s place, `add` of other types, and the runtime stops the program with 1 before `main`.

## Alternatives considered
- **Copying the whole library into each process**: no kernel change, but nothing shared, which is the point of `0045`.
- **A window over the module allowing execute**: the same result with an object more per library; the module's own
  memory is never written, so allowing execute there keeps W^X.

## Consequences
- The runtime's error output is dropped on SlopOS, so a refused library shows only as exit code 1; sending it to the
  debug log, when the program has one, is left for later.
- 9e2 next: `service_kit` as a library, given by the supervisor and the process manager's launches too.
