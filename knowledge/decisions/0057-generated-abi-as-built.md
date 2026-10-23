# 0057: The Generated ABI as Built

Status: accepted
Date: 2026-10-23
Related: `../design/system-abi.md` §4 (the syscall table is data), `0015` (typed handles), `0025` and `0027`
(ABI stability), `0034` (kernel objects), `../hemera-proposals/code-insertion.md` (phase 6, first users),
`../roadmap.md` M5

## Context
M5's fourth stage, last part (4d). `../design/system-abi.md` §4 has one table of typed declarations
generate the user-space stubs, the kernel's dispatch and the interception bits. Until now the calls were
an enum of numbers with register-shaped arguments, the kernel decoded each call's registers by hand, and
programs (so far, the kernel's boot tests) called by number. Hemera's code insertion (`#insert`, phases 1
to 5) now makes generating them possible without text.

## Decision
Chosen with the project's owner:
- **The table is a struct of function types**, `slop_os.Syscalls`: a field's position is its call's number,
  append-only from v1. Reflection over it generates the rest.
- **Fully typed calls**: a distinct handle type per kind (`0015`), `Handle` where any kind goes; buffers as
  slices; results as `Result[T, E]`, `T` at most two words. Errors stay enums: the two calls that report a
  size with an error (`channel_read`, `channel_take_handles`) write it through a pointer argument.
- **The kernel's dispatch and decoding are generated**: the kernel implements one typed handler per call,
  `sys_<name>`, and the generated dispatch decodes registers into its arguments and encodes its result.
- **The boot tests call through the generated stubs**, so every test exercises them.

As built:
- **Generated in `slop_os`** (`syscall_table.hsc`): `SYSCALL_<NAME>` constants, the stubs (`#no_context`, so
  they work before a program has a context), and `syscall_dispatch()`, statements the kernel inserts into
  its dispatch function. The `Syscall` enum is gone: generating it would need enum members named by
  `#insert`, which Hemera doesn't have, and the constants serve the same purpose.
- **The dispatch's contract**: where it's inserted provides `registers`, `thread` and `number`, and `word`,
  `buffer` and `answered`; handlers take a `UserBuffer` (address and count) for a slice and a `u64` for a
  pointer, since both are the caller's memory, never dereferenced directly. Code inserted by a plain
  `#insert` sees the names where it lands, which is what lets the kernel provide them.
- **A call that blocks** gives back any result; the kernel writes the result only if the thread is still its
  CPU's current one after the handler, which only that CPU changes, and otherwise the wait's completion
  writes it.
- **The per-kind code is generated too** (the code-insertion proposal's last first user): `KernelObjects`, a
  struct with a field per kind of object, typed with the object, generates each kind's pool (pools are now
  indexed by kind) and the calls of its `destroy_` and `release_` functions.
- **Tests map the kernel's code** for their user mode, since the stubs are anywhere in it.

## Alternatives considered
- **Declarations marked `#syscall(number)`**: reads like functions, but needs a new directive and collecting
  them from the package.
- **Typed handles only, buffers as address and count**: less churn, but the stubs would take raw addresses.
- **Generating only the jump by number**: each handler would still decode its own registers, the part most
  prone to mistakes.

## Consequences
- Adding a call is a field in the table and a `sys_` handler in the kernel; a mismatch is a compile error.
- From v1, fields are only ever appended.
- Hemera gaps met on the way, logged in `../hemera-feedback.md`: no `(expr).field`, no
  `Result[T, E].Variant(...)`, enum shorthand not inferred as a generic call's argument, no `#insert` for an
  enum member's or a struct member's name, and view parameters' `mut` lost in reflection.
- Fixed in Hemera on the way (`0047`): a quote's `#insert` of patterns, cases, fields, variants or members
  now puts their items among the quoted match's, switch's or type's; and printing a quote gives each
  `#insert` its own operand whatever order the printer reaches them in.
