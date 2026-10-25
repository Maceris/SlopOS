# Proposal: Relative Pointers and Endian-Specific Types

Status: **decided and built** (2026-10-24): every proposal below was taken, with one addition, that a relative
pointer set to point at itself fails the store's check like one too far away, since its offset would be 0. As built,
in Hemera's `docs/types.md` (*Relative Pointers*, *Endian-Specific Types*), and `hemera-feedback.md`. Raised by the survey of Hemera's docs against its compiler (`hemera-feedback.md`,
*Hemera's docs against its compiler*). Section 4 of the feedback file lists both features as a strong fit for SlopOS,
but `types.md` only names them, and the compiler only has their sizes. Both need decisions about what the language
means before the compiler can do them properly, so they come here first (`CLAUDE.md`, hard rule 1).

## Where SlopOS needs them

- Relative pointers: shared-memory IPC rings and on-disk structures that are mapped at different addresses in
  different processes.
- Endian-specific integers: virtio (little-endian), network headers (big-endian), and disk formats. These matter on
  every architecture, even if every target SlopOS runs on is little-endian.

## Endian-specific types

What `types.md` says: `u32be` and the others exist, and widen to larger types with the same endianness and
signedness. What the compiler does: stores them in the CPU's order, so they act like the native types.

Questions:

1. **Representation.** Proposed: a `u32be` is stored big-endian in memory, always. That's the point of the type:
   `bit_cast`, a `#packed` struct field, or a `view_of` over a device buffer sees the bytes in that order.
2. **Arithmetic.** Option A: none on the type itself. It converts to and from its native type (`cast`, or
   implicitly to the native type), and code computes on that. Option B: arithmetic, done by swapping, operating,
   and swapping back. A is simpler and keeps the cost of a swap visible. B matches the docs' "will cast up to
   larger fixed sizes of the same endianness". Proposed: A, plus comparisons with `==`/`!=`, which need no swap.
3. **Implicit conversion.** Proposed: a `u32be` converts implicitly to `u32` and wider native types when it's read,
   and a native value needs an explicit `cast` to become one. That way a store that swaps shows in the source.
4. **The target's own order.** On a little-endian target, `u32le` is `u32` laid out the same, but is it the same
   type? Proposed: no, a distinct type, so code means the same thing on every target.

## Relative pointers

What `types.md` says: `relptrN[T]` holds an offset from its own address, and allows arithmetic. What the compiler
does: the sizes are right, there's no way to set one from a `ptr` (E4015), and `cast` followed by `^` gives
invalid MLIR.

Questions:

1. **Base.** The offset is from the relative pointer's own address (as `types.md` says), not from a separate base.
   This means a relative pointer can only be read in place: a copy in a local is relative to the local.
2. **Assigning.** Proposed: assigning a `ptr[T]` to a `relptrN[T]` field or element stores the difference between
   their addresses. It's an error if the difference doesn't fit: a run-time check, through
   `context.assertion_handler`, unless the bounds prover can show it fits. Assigning to a local is an error,
   since a local is never where the pointed-to memory is.
3. **Reading.** `r^` and `r.field` go through it as through a `ptr[T]`, from wherever it is stored. Converting to a
   `ptr[T]` is implicit when it's read from a place, and an error on a copy (see 1).
4. **Null.** Option A: offset 0 is null, so `relptrN[T]` is like a `rawptr`, and `relptrN[T]?` is the optional.
   Option B: never null, like `ptr[T]`, and `relptrN[T]?` uses 0 for `None` (a pointer to itself is never
   useful). Proposed: B, to match `ptr[T]`.
5. **Memory-safety checks.** A relative pointer can't point into the stack, since it's only for shared or
   on-disk memory. Proposed: storing a local value in one is an error, as storing through a pointer is.
6. **Arithmetic.** `types.md` says relative pointers allow it. Proposed: drop that, and keep arithmetic to `rawptr`.
   SlopOS's uses only need to set and follow them.

## What's needed after the decision

`docs/types.md` (both sections, and *Implicit Casting*), then the compiler (checking and generation), with hosted
tests: `bit_cast` of each endian type, a `#packed` struct with one big-endian field, and a ring of nodes linked by
`relptr32` that's copied to another address and walked there.
