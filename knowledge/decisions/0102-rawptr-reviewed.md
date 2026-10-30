# 0102: rawptr Reviewed: Each Use's Reason, and Struct Members Checked

Status: accepted
Date: 2026-10-30
Related: `0029` (checks in the build), `0100` (the house-rule checks), `0021` (KASLR)

## Context
`0100` let the 38 packages that used `rawptr` when the rule came in keep using it. Each use was reviewed for whether it
needs to be a `rawptr`. Many didn't: Hemera casts an integer, or another pointer, to a typed pointer directly, and a
format string writes an integer as an address (`%{#018x}` is what a pointer prints). And the rule only looked at what
functions use, so a struct holding a `rawptr` in a package off the list went unseen: `boot_info.BootCpu.boot_handle`.

## Decision
- **Struct members checked** (`check_raw_pointers`): a struct or union a package declares holds no `rawptr` unless
  `RAW_POINTERS` names the package. A member's type is looked through as written, into arrays, optionals, what a
  pointer points to, and a function type's parameters and results; another named type is its own package's to answer
  for.
- **What came out**:
  - `cast[ptr[T]](cast[rawptr](address))` is `cast[ptr[T]](address)`, everywhere.
  - Addresses written to logs are integers with `%{#018x}`, which prints them as before, where they were cast to
    `rawptr` to print.
  - `events_service` adds a struct's bytes to a buffer as a `u8[]` view, and gives an address in its entries as a
    `uintptr`.
  - `service_kit` and `store_builder` slice strings, where they made them from an address and a count.
  - `BootCpu.boot_handle` is a `uintptr`: the address of L0's own data, whose type only L0 knows.
  - Limine's firmware table addresses, SMBIOS entries and video modes are `u64`, as its framebuffer's address was: 0
    where there's none.
- **The list is 29 packages**, 9 fewer: `clock`, `platform`, `service_kit`, `storage_manager`, `store_builder`,
  `test_affinity`, `test_budgets`, `test_msi_dma` and `test_pager` left it. Each one left on it is there for one of four
  reasons, which `RAW_POINTERS`' comment gives:
  - an instruction, or `intrinsics.mem_copy` and `mem_zero`, takes an untyped address;
  - base's own interfaces are untyped there: the allocator's data, the clock's, the context's `user_data`, the
    carrier's `program_data` and `stack_limit`, and `capture_stack_trace`'s addresses;
  - a storage device's callbacks take an untyped context (`fat.Device`, `gpt.Disk`, `slopfs.Device`, `slopfs.Nodes`),
    since a function value captures nothing;
  - a runtime string's or view's bytes are read through `.data`, which is a `rawptr`: `cast[u8[]]` takes only a
    constant string.

## Alternatives considered
- **Generic devices** (`fat.Device[T]` with a `ptr[mut T]` context): typed, but every function of `fat` and `slopfs`
  would be generic over the device's context.
- **Contortions for `.data`**, like `&view[0]` behind a check that the view isn't empty: more code than the use it
  replaces. A typed way to a string's bytes in base would take the last reason away, and is base's to give.

## Consequences
- A struct can't bring a `rawptr` into a package off the list unseen.
- Logs print addresses as they did.
