# 0049: Device Interrupts, TLB Shootdown and the Kernel Window

Status: accepted
Date: 2026-10-22
Related: `0009` (time through a syscall), `0021` (KASLR), `0024` (a mapped clock page only as an
opt-in), `0031` (no firmware tables in the kernel), `0032` (arch interface), `0039` (platform
discovery), `0048` (the kernel's address space), `../roadmap.md` M3

## Context
M3 brings interrupts from devices, mappings of the kernel's own beyond the direct map, and changing
mappings every CPU may have cached. The roadmap's first list for M3 had the kernel parse ACPI's
static tables and keep a clock page; `0031` and `0039` since put firmware tables in the platform
service, and `0009` and `0024` time behind a syscall, with a mapped page only as an opt-in.

## Decision
- **The kernel parses no ACPI.** Interrupt controllers are registered with the kernel by the platform
  service, which reads the MADT (`0039`); until it exists, tests register the emulator's I/O APIC from
  `arch_interface.test_device`. The HPET isn't needed: the counter is the TSC, measured against the
  PIT when nothing gives its frequency.
- **The kernel window**: 64 GiB of kernel addresses at a random 1 GiB boundary in the kernel half,
  away from the direct map and the image region, for device registers and other mappings of the
  kernel's own. Addresses are handed out first fit from a sorted list of free ranges. `no_kaslr` on
  the command line puts it at the lowest boundary instead, and `tools/boot.py --no-kaslr` passes it.
- **TLB shootdown, one at a time.** Its CPU publishes the batch, asks every other online CPU to flush
  with a TlbFlush IPI, flushes its own TLB, and waits until they all have. A CPU flushes when the IPI
  takes it from idle, and while it waits to start a shootdown of its own, so two starting at once don't
  wait on each other. The kernel runs with interrupts disabled, so a shootdown starts with no other
  lock held. Unmapping frees what it emptied (page tables, addresses) only after the shootdown.
- **Device interrupt IDs are per CPU.** Each CPU has `arch.device_interrupt_range()` of them, and its
  `PerCpu` records which controller line each is routed from. A level-triggered line is masked when its
  interrupt arrives, until it's acknowledged; every device interrupt is acknowledged to the local
  controller once taken.
- **Time is the kernel's clock in every CPU's context**: monotonic nanoseconds since the timer
  started, from the counter and its frequency. No wall clock in the kernel (`0009`), and no clock page:
  user space will read monotonic time through a syscall, and a mapped page may come back as `0024`'s
  opt-in.

## Alternatives considered
- **Mapping device registers in the direct map:** they're not RAM, and the direct map's large pages
  would have to be split around them with another cache mode.
- **One global vector space shared by every CPU:** wastes vectors on every CPU for interrupts only one
  takes, and caps the system at about 190 devices.
- **Shootdowns that queue a batch per CPU and don't wait:** cheaper for the initiator, but whatever
  was unmapped can't be freed until every CPU has flushed anyway, so the wait just moves.

## Consequences
- Registering a controller costs a page of the window; unregistering isn't needed until the platform
  service restarts (`0017`).
- Every code path that unmaps kernel memory goes through a shootdown, and none holds a lock across it.
- `arch_interface` gains `test_device` and `test_device_interrupts`, for tests like `test_nmi`.
