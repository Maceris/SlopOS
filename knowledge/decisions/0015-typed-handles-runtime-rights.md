# 0015: Handle Types Name Object Kinds; Kernel Rights Are Runtime Values

Status: accepted
Date: 2026-10-02

## Context
Hemera types could carry rights (`Dir[ReadOnly]`, `Handle[Memory, READ | WRITE]`) to catch
misuse at compile time. Across a process boundary a type is only the sender's promise, so
the kernel and servers enforce rights at runtime regardless. Putting kernel rights bits in
types would need type parameters that take values, which Hemera doesn't have.

## Decision
- **Kernel handles are `distinct` types per object kind**: `Memory`, `Thread`, `Process`,
  `MemoryBudget`, `Channel[P]` and so on. Kinds can't be confused with each other or with
  integers.
- **Kernel rights bits (`0010`) are runtime values**, checked by the kernel at every syscall
  and queryable by the holder. They don't appear in types.
- **Server-defined rights are protocol types.** A narrower capability is a connection
  speaking a narrower protocol (`ReadOnlyDir` vs `Dir`).
- **No value-parameterized types are proposed to Hemera for this.** Two reasons: generics
  would then behave differently for structs and functions, and since types are values in
  Hemera, a type parameter that is a value would be ambiguous without new syntax.

## Alternatives considered
- **Hand-written distinct types for common attenuations** (`ReadOnlyMemory`): possible later
  if a specific case proves error-prone. Not adopted as a general scheme.
- **Rights in types via value-parameterized generics:** rejected for the reasons above.

## Consequences
- A rights mistake on a kernel handle shows up as a runtime `Result` error
  (`MissingRight`), not a compile error.
- Protocol types carry most of the rights that matter to applications, so they still get
  compile-time help where it counts.
