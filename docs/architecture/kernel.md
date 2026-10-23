# The Kernel Core as Built

What the kernel core (L2, `layers.md`) does so far, roadmap M1 to M5's third stage, and where its code is. What's not
built yet is listed at the end. The interfaces it builds on are specified in `../specs/boot_info.md` and
`../specs/arch_interface.md`; choices and alternatives are in `../../knowledge/decisions/`, cited by
number.

## Boot

The boot adapter (`src/boot/limine`) turns Limine's responses into `BootInfo` and calls `boot`
(`src/kernel/kernel.hsc`) on the boot CPU, which:
1. reads its command line, logs what it booted with, and stops on a CPU below x86-64-v3 (`0003`);
2. makes the frame allocator from the memory map, and its own state (`Kernel`) in frames from it, with
   the heap, the clock and the thread cache;
3. copies what it keeps of `BootInfo`: the CPUs, and where boot memory is;
4. sets up the boot CPU (`PerCpu`, descriptor tables, entries, the local APIC);
5. builds its own page tables and switches to them, then places the kernel window;
6. starts the framebuffer console, the timer and the other CPUs, each of which switches to the kernel's
   page tables, starts its own timer, and goes idle;
7. asks every CPU to leave its boot stack; the last to do so reclaims boot memory;
8. runs what its command line asks for, and goes idle.

Every CPU has a `PerCpu` block, found through the carrier register (`intrinsics.carrier().program_data`),
with its context, which every entry runs with: the kernel heap as its allocator, the kernel's clock,
the kernel logger, and an assertion handler that stops the kernel.

## Memory

- **Frames** (`src/kernel/frames`): a buddy allocator over the RAM in the memory map, blocks of 4 KiB to
  1 GiB, with a per-CPU cache of single frames in front of it.
- **The kernel's address space** (`src/kernel/address_space.hsc`, `0048`), shared by every address space
  as its kernel half:
  - the direct map of RAM, never executable, the kernel image's frames read-only there,
    framebuffers write-combining;
  - the kernel image, each segment with its own protection; nothing is both writable and executable;
  - the kernel window (`src/kernel/window.hsc`, `0049`): 64 GiB for device registers and other mappings
    of the kernel's own, uncached for devices.
- **KASLR** (`0021`): Limine loads the image at a random base and puts the direct map at a random
  1 GiB-aligned offset; the kernel places its window at a random 1 GiB boundary.
- **The slab allocator** (`src/kernel/slab`): caches of same-sized objects, with a per-CPU magazine in
  front of each. Threads come from one.
- **The heap** (`src/kernel/heap.hsc`): Hemera's `Allocator` for the kernel. Sizes up to 2 KiB come from
  slab caches of power-of-two classes, larger ones from frames; a block's class is picked by size and
  alignment, which freeing passes too.
- **TLB shootdown** (`src/kernel/shootdown.hsc`): after a kernel mapping changes, every online CPU
  flushes it before what it mapped is used again. One at a time, never with another lock held.
- **User address spaces** (`src/kernel/spaces.hsc`): their own page tables below the shared kernel half,
  each with its own PCID where the CPU has them.

## Objects, Handles and System Calls

- **Objects** (`src/kernel/objects.hsc`, `0008`, `0051`): processes, threads and address spaces so far, each
  owned by a process and kept in a type-stable pool of its kind. Destroying one revokes every handle to it,
  destroys what it owns, and frees its memory once every CPU has passed a quiescent point.
- **Processes** (`src/kernel/processes.hsc`): nodes of the ownership tree, each with what it owns and its
  handle table. Destroying one destroys its whole subtree.
- **Handle tables** (`src/kernel/handles.hsc`): per process, entries with rights and an owning flag,
  looked up without a lock.
- **System calls** (`src/kernel/syscalls.hsc`): the calls in `../specs/system_calls.md`, on the calling
  thread's process's handles.
- **Ports** (`src/kernel/ports.hsc`, `0052`): bindings with keys, wake and timer packets, and threads that
  block on them. A woken thread finishes its wait when it next runs. User memory is written only through
  the address space's table and the direct map (`src/kernel/user_memory.hsc`).
- **Timers** (`src/kernel/timers.hsc`): a heap of deadlines per CPU; each CPU's timer is set for its next
  tick or its earliest deadline.
- **Channels** (`src/kernel/channels.hsc`, `0053`): two end objects sharing a core with the rings' memory,
  which ends map; doorbells as signals on port bindings, handles moved in batches, kernel-copied reads and
  writes on the same rings. A mapping is on its address space's list of rings and holds the core until
  it's unmapped or the space is released. Objects that hold each other, like an end in a batch on
  another channel, are destroyed one after another (`destroy_later`, `src/kernel/objects.hsc`).
- **Memory budgets** (`src/kernel/memory_budgets.hsc`, `0011`, `0054`): every object is charged to the budget
  that paid for it, its slot and what it holds, and what it grows later (handle-table pages, page tables,
  bindings, handle batches) as it grows; its whole charge comes back once it's released. Budgets split
  into children, whose limit the parent is charged; closing a child moves its charges to the parent. The
  root budget, of the memory free at boot, is the kernel's. Taking an owning handle moves the object's
  charge to the taker's process's budget.
- **Memory objects** (`src/kernel/memory.hsc`, `0054`): anonymous memory, charged for its whole size when
  made and filled with zeroed frames as it's touched, through user page faults. A mapping is on its
  space's list and its memory's, and whoever claims it takes it down; a fault maps a page only while
  its mapping is on its space's list. A fault outside what's mapped, or one a mapping doesn't allow,
  destroys the thread. Device memory is physical addresses outside the kernel's RAM; a window shares
  another memory object's frames and is destroyed with it (`0055`).
- **IRQs and the platform capability** (`src/kernel/irqs.hsc`, `0039`, `0055`): the platform capability,
  made at boot for the root task, registers interrupt controllers and makes IRQs and device memory. An
  IRQ is a controller line routed to a CPU; each interrupt bumps its port binding's packet, and a
  level-triggered line stays masked until the driver acknowledges it.
- **Process control** (`src/kernel/control.hsc`, `src/kernel/intercepts.hsc`, `0017`, `0056`): rights on a
  process cover its subtree. A thread is held by a suspend or a stop, and parked once its whole state is
  its saved registers: at its next entry, off its run queue, or after its wait. Intercepts stop threads at
  system calls' entries and exits and at unresolved faults, report them through a port, and let them go
  on by making the call again from user mode (`arch.restart_syscall`), skipping it, or killing the thread.

## Interrupts and Time

- Every interrupt, fault and system call enters through the arch layer's entries on the CPU's kernel
  stack, and the kernel runs with interrupts disabled until it returns to user mode or goes idle.
  Critical events (NMI, double fault, machine check) have stacks of their own.
- **Interrupt controllers** (`src/kernel/interrupts.hsc`, `0039`, `0049`) are registered with the kernel:
  their registers mapped in the window, their lines routed to device interrupt IDs, which each CPU has
  its own of. A level-triggered line is masked when its interrupt arrives. The kernel parses no firmware
  tables; until the platform service exists, tests register the emulator's I/O APIC.
- **The clock** (`src/kernel/clock.hsc`): monotonic nanoseconds since the timer started, the same on every
  CPU, as every context's `clock`. No wall clock (`0009`).
- **Ticks**: every CPU's timer interrupts 100 times a second, for the scheduler.

## Threads and Scheduling

- **Threads** (`src/kernel/threads.hsc`, `0023`, `0050`) run in user mode. One kernel stack per CPU, so
  a thread is its saved registers, its address space, its budget and its place in the scheduler, under
  1 KiB, plus its vector state, about 1 KiB more, saved and restored at every switch between threads.
- **The dispatcher** (`src/kernel/scheduler.hsc`, `0037`): each CPU runs the highest-priority ready thread
  whose budget has time left, round robin within a priority, and threads without time or without a
  budget round robin in the background band below. Each CPU has its own run queue, and takes a thread
  from another's when it has nothing to run. A thread made ready above what its CPU runs gets a
  reschedule IPI there.
- **CPU budgets** (`src/kernel/budgets.hsc`): a priority, and CPU time per period, charged at ticks and
  switches and refilled by the sporadic-server rule. A spent budget's threads run in the background band
  until it's refilled (Demote).

## Not Built Yet

| What | Roadmap |
|---|---|
| The generated ABI package | M5 |
| I/O-port ranges, IOMMU domains, message-signaled interrupts | M7 |
| Destroying large subtrees with preemption points | M5 |
| Loading programs, the root task, user space | M6 |
| The platform service, PCIe, drivers | M7 |
| xAPIC (without x2APIC), tickless idle, CPU affinity for budgets | later |
