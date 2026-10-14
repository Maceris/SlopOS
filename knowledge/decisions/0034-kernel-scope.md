# 0034: Kernel Scope and Object Types

Status: accepted
Date: 2026-10-13
Related: `0008` (object lifetime), `0010`, `0011` (budgets), `0012` (root task), `0023`, `0032`

## Context
`../design/kernel.md` §2 proposed what the kernel does and which object types it has, drawing on
seL4, Zircon, QNX, MINIX 3 and L4 (§1). It was left for confirmation.

## Decision
- **The kernel's responsibilities are `../design/kernel.md` §2's table**, mechanism only: boot and
  CPUs, physical memory, address spaces, threads, dispatch and budget enforcement, the monotonic
  clock and deadlines, IPC, capabilities, interrupt routing, device access, process control, kernel
  entropy and the kernel log. Everything else is in user space, including scheduling policy,
  wall-clock time, drivers, filesystems, naming, program loading, users and sessions. No signals,
  no `fork`, no futexes.
- **Object types:** `MemoryBudget`, `CpuBudget`, `Memory`, `AddressSpace`, `Thread`, `Process`,
  `Channel`, `Port`, `Irq`, `IoPortRange`, `IommuDomain`.
- **`Process` is one type** for process, job and session: an ownership-tree node distinguished only
  by what it holds.
- **Not objects:** timers are deadlines bound to a port, notifications are channel signals or
  `port_wake`, and interception is a binding of a process to a port.
- **Long operations** (destroying a subtree, large unmaps) are split with preemption points, as
  `../design/kernel.md` §2 describes.

## Alternatives considered
See `../design/kernel.md` §1: Zircon's larger object set and overlapping transports, seL4's separate
endpoints and notifications, and user-managed capability spaces.

## Consequences
- Adding an object type needs a new decision. The ABI package's handle kinds follow this list.
- Users, jobs and sessions are `Process` nodes the root task or session manager creates
  (`0012`, `0016`).
