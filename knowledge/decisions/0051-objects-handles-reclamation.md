# 0051: Kernel Objects, Handle Tables and Reclamation as Built

Status: accepted
Date: 2026-10-22
Related: `0008` (object lifetime), `0010` (rights), `0015`, `0034` (object types), `0038` (system ABI),
`../roadmap.md` M5

## Context
M5's first stage builds `0008`'s objects, handle tables and quiescent-state reclamation, with the first
system calls. Building them settled what `0008` left to the implementation.

## Decision
- **Objects are named by address, in type-stable pools.** Each kind's objects come from a slab cache
  whose empty slabs are never given back, so memory that held an object of a kind only ever holds
  objects of that kind. A handle entry can then keep the object's address and generation, which is
  what `0008`'s `(pool_index, generation)` amounts to, and a lookup is a load and a compare. The
  generation sits after the slab's free-list link, so it survives the slot being free.
- **A handle is 32 bits**: the entry's index in the low 16, its generation in the high 16, so 65535
  handles per process. An entry whose generation would wrap is never reused. Lookups read an entry
  without the table's lock, rereading its tag to see it didn't change; changes take the lock.
- **Destroying an object** marks it dying, once, changes its generation, takes it off its owner's list,
  destroys what it owns or holds (a process: everything it owns; an address space: the threads in it; a
  thread: its place on a run queue), and puts it on its CPU's limbo list in the current epoch, which
  then advances.
- **Quiescent points** are returning to user mode and going idle. A CPU first switches its page
  tables to what it runs next (the kernel's own when idle), then reads the epoch, then checks that the
  thread it resumes isn't dying, and only then records the epoch. An object is freed once every online
  CPU has recorded a later epoch. So no CPU resumes a thread destroyed in an earlier epoch, and no page
  table is freed while a CPU still has it loaded. Every CPU ticks, so idle CPUs keep reporting.
- **Closing an owning handle destroys the object**; duplicating makes only non-owning handles, with
  rights the original has. `thread_exit` destroys the calling thread.
- **The system call ABI is in `slop_os`** (Hemera's `std/os/slop_os`), written by hand until it's
  generated (M5's last stage): numbers, `Handle`, `ObjectKind`, `Rights` and `HandleError`, whose tags
  start at 1, 0 being success.
- Destroying a large subtree isn't split with preemption points yet (`../design/kernel.md` §2).

## Alternatives considered
- **Pool indices in handle entries**, with a table of pools to turn them into addresses: what `0008`
  described, but an extra lookup, for no safety that type-stable memory doesn't already give.
- **A lock around every lookup:** simpler, but every system call on a handle would take it.
- **Recording the quiescent point before checking what's resumed:** a CPU could then resume a thread
  destroyed just after the check, whose memory another CPU frees in the meantime.

## Consequences
- An object's memory stays its kind's for good; a pool only grows. A kind whose objects were briefly
  numerous keeps that memory.
- Stage 2 (ports) blocks threads on these objects, keeping `(address, generation)` across waits, as
  `0008` says.
