# 0041: Receive Buffers and Per-Carrier State in `std`

Status: accepted
Date: 2026-10-13
Related: `0023` (cheap threads), `0026` (carrier register), `0035` (IPC), `0037`, `0040`

## Context
Two questions about `std`'s SlopOS layer were open:
- `std` copies every message out of its ring before validating it (`../design/ipc.md` §2). Messages
  can be up to 64 KiB, but a fiber's first stack segment is 1 KiB, so copying a large message into
  a stack buffer would force a large segment allocation.
- Hemera's pattern for per-carrier state (allocator caches, a `Random` per carrier, the scheduler's
  port) is an array indexed by `current_thread_index()`. Something has to assign those indices on
  SlopOS, and the per-thread page the kernel shares (`../design/scheduling.md` §3) has to be
  reachable.

## Decision
- **Receive buffers:** `std` copies a message of up to **256 bytes** into a stack buffer, and a
  larger one into a buffer each connection keeps on the heap, grown as needed. A large message never
  lands on a fiber's stack. The threshold is revisited once there are measurements.
- **Carrier indices:** `std`'s thread entry stub assigns each carrier its index from a process-wide
  free list, so indices stay dense and are reused when threads exit, and can index arrays.
- **The kernel's per-thread page stays separate from the carrier block.** Its layout belongs to the
  ABI package (`slop_os`), while the carrier block's is private to each program's `std` (`0026`).
  `std` keeps a pointer to each thread's page in its own per-carrier array.

## Alternatives considered
- **Always copying into a heap buffer:** one allocation per message even for small ones.
- **Sparse indices** (the thread's handle value, say): arrays indexed by them waste memory or need
  hashing.
- **The per-thread page inside the carrier block:** would tie a kernel-defined layout to a
  structure that each program's `std` version may lay out differently.

## Consequences
- A connection holds at most one large receive buffer, charged to the process's memory budget.
- The per-thread page's layout is an ABI surface, designed with the scheduler's per-thread hints
  (`../design/scheduling.md` §5).
