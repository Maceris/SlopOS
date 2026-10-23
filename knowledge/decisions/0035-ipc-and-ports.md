# 0035: IPC Through Shared Rings and Ports

Status: accepted
Date: 2026-10-13
Related: `0008`, `0011`, `0024` (direct and kernel access), `0025` (ABI), `0034`

## Context
`../design/ipc.md` proposed asynchronous channels over shared-memory rings, with ports as the one
wait mechanism, following the open questions' direction toward asynchronous IPC.

## Decision
- **Channels** (`../design/ipc.md` §2): two single-producer, single-consumer rings per channel, one
  per direction, in a memory object mapped into both processes. Sending and receiving needs no
  syscall. The kernel only rings doorbells, transfers handles and raises signals.
- **Messages** are at most half the ring, capped at 64 KiB. Bigger data goes in a shared memory
  object referenced by the message.
- **The default ring is 2 KiB per direction**, one page for both. Tuning waits for measurements.
- **Ports** (`../design/ipc.md` §3) are the single wait mechanism: readiness packets for channels,
  completion packets for kernel events (timers, IRQs, process events, faults, interception stops).
  Packet storage is reserved when something is bound, so the kernel never allocates on a notify.
- **Blocking, RPC and `call()` are `std` code**, with a combined notify-and-wait syscall for
  synchronous-RPC latency (`../design/ipc.md` §5).
- Ring, header and packet layouts are ABI surfaces in `slop_os` (`0025`, `0033`).

## Alternatives considered
See `../design/ipc.md` and `../design/kernel.md` §1: synchronous-only IPC (L4, QNX), kernel-copied
message buffers (Zircon), and fixed small messages (MINIX 3).

## Consequences
- IPC performance depends on shared memory and doorbells, not on syscall cost.
- Recorded processes use the same rings through syscalls (`0024`).

## Amendment (2026-10-22): The Default Ring
Each ring has 128 bytes of indices besides its bytes, so 2 KiB each way doesn't fit one page. The
default is **1 KiB each way**, which with both rings' indices fits one page; messages up to 512 bytes
by default. A channel can still ask for bigger rings (`0053`).
