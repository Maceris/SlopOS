# The Kernel Core as Built

What the kernel core (L2, `layers.md`) does so far, roadmap M1 to M4, and where its code is. What's not
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
| System calls, capabilities, kernel objects (memory objects, channels, ports, IRQs for drivers), IPC | M5 |
| Blocking, exiting and destroying threads; destroying address spaces | M5 |
| Loading programs, the root task, user space | M6 |
| The platform service, PCIe, drivers | M7 |
| xAPIC (without x2APIC), tickless idle, CPU affinity for budgets | later |
