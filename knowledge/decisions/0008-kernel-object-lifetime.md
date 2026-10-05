# 0008: Kernel Handle Tables, Single-Owner Objects and Generational Handles

Status: accepted
Date: 2026-10-02

## Context
Principle 1 (no ambient authority) needs a kernel representation for capabilities, and
principle 4 (everything is owned; kill the owner, reclaim it all) needs a lifetime rule for
the objects they refer to. The two reference designs:

- **Zircon:** a per-process handle table; the kernel picks handle values; objects are
  reference-counted and live as long as any handle or internal reference exists. There is no
  general revocation.
- **seL4:** user-managed CSpaces built from CNodes; no kernel heap (objects are retyped
  from Untyped memory); lifetime and revocation through the capability derivation tree.

Handle tables are much easier to program against. But Zircon's lifetime model depends on
reference counting, which Hemera has no automatic support for (no shared pointers or
destructors). It also conflicts with principle 4: under reference counting an object
outlives its creator for as long as anyone holds it, and nothing can be revoked.

## Decision
**Representation: a kernel-managed handle table per process.**
- User space sees a handle as an opaque `distinct` 32-bit value chosen by the kernel. It
  encodes a table index plus a per-entry generation, so a closed or reused handle value
  fails lookup instead of aliasing another object.
- A table entry holds `(pool_index, object_generation, rights)`. Duplicating a handle with
  fewer rights (attenuation) creates a new entry and touches no shared state.

**Lifetime: every kernel object has exactly one owner.**
- The owner is a node in the ownership tree (process → job → session). The handle that
  carries ownership is marked as owning. Every other handle to the object is a
  non-owning reference.
- Ownership moves only explicitly, by transferring the owning handle over IPC.
- Destroying an object (closing the owning handle, or destroying its owner) finalizes it at
  once. Killing a node destroys everything it owns, recursively.
- No general-purpose reference counting in the kernel.

**Storage: typed pools with generation counters.**
- Each object type lives in its own pool of slots. Each slot has a generation counter.
- Lookup compares the handle entry's `object_generation` with the slot's. A mismatch
  returns `ObjectGone`.
- Destroying an object increments its slot's generation. Every outstanding handle to it,
  in every process, goes stale at that moment. **Destroying an object is revoking it.**
- If a slot's generation would wrap around, the slot is retired and never reused.

**Concurrency: quiescent-state reclamation.**
- A destroyed slot goes on a per-CPU limbo list. It returns to the free list only after
  every CPU has passed a quiescent point (return to user mode, or idle) since the
  destruction.
- Kernel code must not keep a pointer to a kernel object across a quiescent point.
  Blocking operations keep `(pool_index, generation)` instead, and re-resolve it on wakeup.
  Destroying an object wakes its waiters, which then see `ObjectGone`.
- In return, a lookup is a plain load and compare: no atomics and no pin counts.

**References between kernel objects:**
- **Child → parent** (thread → process, mapping → address space): a plain pointer. It is
  always valid because the ownership tree destroys children before parents.
- **Two-ended objects** (channels): one object owning both ends, each end owned
  independently. The object is freed when both ends are closed. This uses a fixed
  "end 0 open / end 1 open" field, not a counter.
- **Cross-tree references** (e.g. process B maps memory owned by process A): stored as
  `(pool_index, generation)` and checked on use, exactly like a handle.

## Alternatives considered
- **seL4 CSpaces / CNodes:** strongest kernel memory accounting and built-in revocation.
  Rejected because user space must allocate slots and manage the CSpace layout, which is
  notoriously error-prone. Its main benefit (accounted kernel memory) can be had in other
  ways (see the open questions on budgets).
- **Zircon-style reference counting, written by hand** (atomic retain/release, `defer`
  for releases): workable, but it brings reference-counting semantics with it. Objects
  outlive their owner, there's no revocation, and principle 4 isn't met.
- **Type-stable pools plus per-object lock and generation recheck**, instead of quiescent
  reclamation: no grace period, but every lookup takes a lock.
- **Transient pin counts during syscalls:** easy to get right with `defer`, but adds two
  atomic operations to every syscall. Kept as a fallback for any object that turns out to
  need it.

## Consequences
- Every operation on a handle can fail with `ObjectGone`, and programs must handle it. This
  matches principle 7, and restartable services (`../problems-and-directions.md` §2) make
  this case routine anyway.
- "Duplicate a handle" no longer means shared ownership. To keep something alive, a
  process must own it or ask its owner to keep it.
- Revoking a whole object costs nothing extra. Revoking *one recipient's* copy while
  keeping the object alive is not covered and needs forwarders or service-side revocation.
- Kernel code follows a firm rule: no object pointers across quiescent points, and only
  child → parent pointers stored in object fields. This is a candidate house-rule check
  (`0007`), if reflection can express it.
- Idle and tickless CPUs must still report quiescent states, or reclamation stalls.
- Per-CPU limbo lists tie into per-CPU kernel state (`../hemera-feedback.md`).
- Exercises Hemera's `distinct`, `defer`, `or_return`, atomics and `Result` together on a
  hot path. Report how it goes in `../hemera-feedback.md`.
