# 0032: The Shape of the Arch Interface

Status: accepted (2026-10-13)
Date: 2026-10-13
Related: `0002` (layers), `0007`/`0029` (conformance check), `0023` (one kernel stack per CPU),
`0026` (carrier register), `0031` (BootInfo)

## Context
`0002` puts everything architecture-specific in the kernel behind a compile-time arch interface.
The spec is `../../docs/specs/arch_interface.md`. Drafting it meant deciding how much the
interface has to cover, and most of that is decided by how the kernel core behaves rather than by
the hardware.

## Decision
1. **Two directions.** L1 implements `arch_interface` for L2. L2 implements `kernel_entry`, which
   L1's entry stubs call directly by name (Hemera allows circular imports), so no handler is
   reached through a function pointer.
2. **The kernel runs with interrupts disabled.** They're enabled only in `idle`. Preemption
   points poll `interrupt_pending`. Every interrupt therefore arrives from user mode or idle, and
   no handler returns into kernel code, except for critical events (NMI, machine check, double
   fault) on their own stacks. This follows from run-to-completion (`0023`).
3. **The kernel never accesses memory through a user address.** It translates through the
   address space's page table and uses the direct map. User-access protection (SMAP, PAN,
   `SUM`) stays on permanently, and the arch layer needs no recovery from faults on user memory.
4. **Per-architecture types are named in the interface, defined by each architecture.**
   `UserRegisters`, `VectorState`, `ArchCpu`, `ArchSystem` and `PageTable` are empty structs in
   `arch_interface`. The conformance check matches them by name, and compares every other type
   exactly. L2 embeds them by value (it knows their size at compile time) and never reads their
   fields.
5. **L1 never allocates.** Page-table frames come from a small reserve L2 fills (`TableFrames`),
   and emptied tables go back through `FreedTables`, so L2 can charge budgets (`0011`) and keep
   every call bounded. One call maps or unmaps one page.
6. **Saved user registers stay where the entry stub put them,** on the CPU's kernel stack. L2
   copies them into the thread's control block only when it switches threads.
7. **TLB shootdown is L2's.** L1 flushes the local TLB from a `TlbBatch`, and sends IPIs.
8. **Device interrupts are message-signaled first** (PCIe MSI/MSI-X, which virtio uses). Wired
   interrupts wait for a way for the platform service to describe interrupt controllers to the
   kernel.

## Alternatives considered
- **Handlers as function pointers registered with L1:** an indirect call on every entry, which
  `0007` already rejected for the interface's other direction.
- **Interrupts enabled in the kernel:** lower latency between preemption points, but handlers
  would have to return into arbitrary kernel code, and every kernel path would have to be
  interrupt-safe.
- **Copying from user addresses with fault recovery** (Linux's exception tables): faster for
  large copies, but needs compiler support for recovery points that Hemera doesn't have, and
  makes every user access a potential fault inside the kernel.
- **Portable register and page-table types** (for example registers as `u64[N]`): one less
  conformance rule, but every architecture's layout would leak into L2 as index constants.
- **L1 allocates page-table frames itself:** simpler calls, but L1 would need an allocator and
  budget accounting.

## Consequences
- The conformance check (`0029`, in `src/checks`) needs the
  placeholder rule.
- Interrupt latency in the kernel is bounded by the distance between preemption points, which
  `0023` already requires to be short.
- Kernel code that reads user memory always goes through translation, so the IPC paths that
  read rings in kernel mode (`../design/ipc.md` §6) pay for a page-table walk per page touched.
- `BootInfo` gains the kernel image's segments, so L2 can map its own image without linker
  symbols (`../../docs/specs/boot_info.md`).
