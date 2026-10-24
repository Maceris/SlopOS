# Roadmap

Milestones of real subsystems (see `decisions/0005-scope-real-implementations.md`). Ordered
by dependency. Each lists what gets built, the specs it follows, and **what it stresses in
Hemera**, since that's the actual output of the project.

Layer references (L0–L6) are from `../docs/architecture/layers.md`.

---

## M0 — Foundations (no hardware needed)

Pure code that everything else depends on, and that can be tested on a host.

- **Build package** for the targets: kernel (`OS == .None`), user space (`OS == .SlopOS`),
  host (tests). Hemera has no build system, so this is a Hemera program registering targets
  through the compiler API in `base/compiler` (`hemera-proposals/build-programs.md`,
  `decisions/0028`).
- **Hemera `std`**: split into tiers (freestanding / allocating / os); add containers that
  work without an allocator (intrusive lists, fixed-capacity arrays, bitmaps, ring buffers)
  and formatting into a fixed buffer; fix `SharedPtr` to use atomics.
- **Boot protocol types**: the portable `BootInfo` type (`../docs/specs/boot_info.md`) and the
  Limine protocol structures.
- **Arch interface** (L1 ↔ L2): the `arch_interface` package of `---` declarations that
  `arch/x86_64` must implement (`../docs/specs/arch_interface.md`).
- **House-rule checks**: arch interface conformance and `std` tier
  enforcement, registered with `compiler.add_check` (`decisions/0007`, `0029`).

Specs: Limine boot protocol.
Stresses: generics, `distinct`, `#packed`/`#align`, compile-time layout asserts, build
system in Hemera, compile-time reflection over packages (house-rule checks), tests.

## M1 — Boot to Console (L0, L1)

Building it needs the compiler work in `compiler-plan.md` (Phases 0–6).


- Kernel entry from Limine; convert responses to `BootInfo`.
- `CPUID` check for x86-64-v3; refuse to boot otherwise, with a message.
- GDT + TSS (with interrupt stacks), IDT, exception handlers decoding faults into a
  portable `Fault` union.
- 16550 serial output and a framebuffer text console (PSF2 font parsing, scrolling).
- Kernel `Logger` implementation and an assertion handler (`context.assertion_handler`) that
  prints a stack trace (using `intrinsics.capture_stack_trace`, addresses relative to the
  image base, `decisions/0021`).
- The boot CPU's carrier block and carrier register, set up before any checked function runs,
  and loaded on every kernel entry (`design/kernel.md` §3).

Specs: Intel SDM Vol. 3A (ch. 3, 5, 6, 7), PSF2 font format, 16550 UART.
Stresses: privileged-instruction intrinsics, interrupt calling convention / naked functions,
early-boot context (no allocator yet), `Logger`, formatting without allocation, panics,
the carrier block and prologue stack check in a freestanding build.

## M2 — Memory (L1, L2)

- Physical frame allocator: buddy allocator over the boot memory map, SMP-safe.
- 4-level paging: map/unmap/protect, W^X enforced, NX, global pages, PCID.
- Kernel address-space layout (direct map, kernel image, per-CPU areas), KASLR-ready.
- Slab allocator for kernel objects; general kernel heap implementing Hemera's `Allocator`.

Specs: Intel SDM Vol. 3A ch. 4.
Stresses: the `Allocator` interface for real, bit-packed page table entries, atomics,
`Result` error handling, where state lives without globals.

## M3 — Interrupts, Time, SMP (L1, L2)

- Interrupt controllers registered with the kernel (the platform service reads the MADT, `decisions/0039`;
  the kernel parses no ACPI, `0031`), the I/O APIC, IRQ routing to (later) driver messages.
- Local APIC / x2APIC, TSC calibration, the kernel's monotonic clock. A mapped clock page only as
  `0024`'s opt-in; time goes through a syscall (`0009`).
- The kernel window for device registers (`0049`).
- Bringing up the other CPUs, per-CPU data via `GS`, spinlocks, TLB shootdown.

Specs: Intel SDM Vol. 3A ch. 10–11, Intel x2APIC spec, Intel 82093AA I/O APIC datasheet.
Stresses: atomics and fences, the per-CPU `context.user_data` approach, volatile MMIO.

## M4 — Threads and Scheduling (L2)

- Thread objects (≤ 1 KiB target), XSAVE state, context switch.
- One kernel stack per CPU ("run to completion or record a continuation").
- Per-CPU run queues, CPU budgets (`design/scheduling.md`), idle and preemption.

Spec: `design/threads.md`.
Stresses: tagged unions as continuation state, `defer`, calling convention vs. context
switching, IST stacks and the carrier block's `stack_limit`, how `std`'s thread entry stub
sets up the carrier register (`decisions/0026`).

## M5 — Capabilities and IPC (L2)

- Per-process handle tables, rights, revocation.
- Kernel objects: address space, thread, memory object, channel/endpoint, IRQ, I/O port
  range, MMIO range.
- IPC: shared-ring channels, ports, handle transfer (`design/ipc.md`); syscall
  interception (`design/kernel.md` §4).
- System call ABI; typed message stubs generated at compile time from Hemera types.

Stresses: `distinct` handle types, compile-time code generation from `TypeInfo`/`FunctionInfo`,
relative pointers in shared memory, `Result` across the kernel boundary.

## A — AArch64 (L0, L1, Hemera)

The second architecture (`decisions/0022`, `0061`), started 2026-10-23 with M6 paused after 6b. Baseline
ARMv8.2-A with LSE atomics; QEMU `virt`, edk2 and Limine. In five stages: A1 Hemera on AArch64, hosted (code
generation, the carrier register, the prologue stack check, fibers, Linux in `base`, tested through user-mode
QEMU); A2 Hemera for an AArch64 kernel (entry functions, system-register intrinsics); A3 SlopOS boots (MMU,
exception vectors, PL011); A4 interrupts, time and SMP (GICv3, the generic timer); A5 threads and user mode, with
every boot test on both architectures. M6 then resumes for both.

Stresses: the arch interface's x86 assumptions, Hemera's backend beyond x86, compile-time arguments for system
registers, `TARGET_ARCH` branching.

## M6 — User Space (L2, L4, L5)

- ELF loader with relocations (PIE) and ASLR, shared by the kernel, the root task and the process
  manager.
- Root task / process manager; initial capabilities; the typed boot configuration (`system_config`).
- Syscall library, and the start of the `std` port (`OS == .SlopOS`).
- A debug-log capability, so programs can report before M7's console.

In four stages (`decisions/0058`): 6a user programs as executables (`base`'s SlopOS runtime, the
build package's user targets, the startup block); 6b the kernel starts the root task; 6c the root task
and the process manager, with the early entropy source; 6d the start of `std`'s SlopOS port, with typed
entry points, and the user-mode boot tests as programs of their own.

Specs: ELF-64, System V x86-64 relocations.
Stresses: `std` design, the system ABI, the context register at process start.

## M7 — Platform and Drivers (L3)

- Platform service: ACPI static tables, PCIe enumeration (ECAM via MCFG).
- virtio over PCI (modern transport), then virtio-blk, virtio-console, virtio-rng, virtio-input.
- Device-class protocols: `block`, `serial`, `entropy`, `input`.
- Supervisor restarts crashed drivers.

Specs: PCIe base spec (config space), virtio 1.2.
Stresses: volatile MMIO, fences (Hemera's `base/intrinsics/atomics.hsc`), protocol unions, driver isolation.

## M8 — Storage (L4)

- Storage service on top of `block`.
- FAT32 (an existing spec; interop, and a good test of packed/endian structs), then a native
  copy-on-write filesystem designed for SlopOS (typed metadata, snapshots).
- Capability-scoped namespaces.

## M9 — Userland (L5, L6)

- Fill out the `std` port.
- Shell that builds CLIs from exported function signatures.
- A handful of real programs (file search, viewer for typed data, etc.).

## Later

- Networking: virtio-net + a TCP/IP stack.
- Display: virtio-gpu (2D), compositor, trusted input path.
- A Hemera UEFI bootloader (replacing Limine).
- RISC-V, the third architecture (`decisions/0022`), after LLVM is rebuilt with its backend.

---

## Status

| Milestone | State |
|---|---|
| M0 | done 2026-10-17: `BootInfo`, `arch_interface`, `CpuFeatures`; the build package (`src/build`) with the house-rule checks for `std` tiers and the arch interface (`src/checks`); freestanding `std` for views, fixed-buffer text and formatting, and `std/containers` (`FixedArray`, `RingBuffer`, `Bitmap`, intrusive `List`); `SharedPtr` on atomics |
| M1 | done 2026-10-15 (`compiler-plan.md` Phase 6); `tools/boot_tests.py` boots it seven ways. Entry from user mode is generated (entry functions, 2026-10-16) and waits for user mode itself (M4–M6) |
| M2 | done 2026-10-22 (`decisions/0048`): the buddy frame allocator (`src/kernel/frames`); x86-64 paging behind the arch interface (map, unmap, protect, translate, W^X, NX, global pages, PCIDs; `src/arch/x86_64/paging.hsc`); the kernel's own address space, a direct map and the image with each segment's protection, on every CPU, after which boot memory is reclaimed (`src/kernel/address_space.hsc`); the slab allocator with per-CPU magazines (`src/kernel/slab`) and the kernel heap on it, every CPU's `Allocator` (`src/kernel/heap.hsc`). Per-CPU caches of single frames; KASLR for the image and the direct map, which holds every region of the kernel's own (`0021`, amended). Frames, slabs and paging are unit-tested over a buffer standing in for memory |
| M3 | done 2026-10-22 (`decisions/0049`): the other CPUs start, go idle and stop with the kernel; TLB shootdown across CPUs (`src/kernel/shootdown.hsc`); the kernel window for device registers, at a random address (`src/kernel/window.hsc`); I/O APICs behind the arch interface, registered controllers, per-CPU device interrupt IDs and routing (`src/arch/x86_64/io_apic.hsc`, `src/kernel/interrupts.hsc`); the kernel's monotonic clock in every CPU's context (`src/kernel/clock.hsc`). Boot tests: a shootdown on 4 CPUs, the PIT's interrupts through QEMU's I/O APIC, the clock against the counter. Registration through a syscall waits for M5, the platform service for M7 |
| M4 | done 2026-10-22 (`decisions/0050`): threads in user mode (`src/kernel/threads.hsc`), with eager XSAVE vector state (`src/arch/x86_64/vector.hsc`) and user address spaces with PCIDs (`src/kernel/spaces.hsc`); per-CPU run queues with stealing, CPU budgets with sporadic-server refills and Demote, ticks on every CPU, idle and preemption (`src/kernel/scheduler.hsc`, `src/kernel/budgets.hsc`). The arch interface is complete on x86-64. Boot tests: 4 threads on 2 CPUs, each preempted and resumed with its own vector state; a budgeted thread against a background one. Blocking, exiting and creating threads by system call come with M5 |
| M5 | done 2026-10-23, in four stages. Stage 1 done (`decisions/0051`): the system call path, kernel objects in type-stable pools, per-process handle tables with generations and rights, quiescent-state reclamation, Process nodes and the ownership tree, threads that exit and are destroyed, address spaces destroyed with their threads; seven calls in the ABI package (`docs/specs/system_calls.md`). Stage 2 done (`decisions/0052`): ports with wake and timer bindings, per-CPU timer heaps with precise deadlines, threads that block on ports and finish their waits when they next run, the monotonic clock as a call. Stage 3 done (`decisions/0053`): channels with shared rings mapped by both ends, doorbells as signals on port bindings (Once and Persistent), handles moved in batches, kernel-copied reads and writes for recorded processes, notify-and-wait with a handoff to the caller's CPU. Stage 4 in four parts: 4a done (`decisions/0054`): memory budgets that every object is charged to, split and closed into their parents, with charges moving when owning handles are taken; anonymous memory objects charged in full and filled lazily through page faults, mapped and shared between spaces, a bad fault destroying the thread. 4b done (`decisions/0055`): the platform capability, which registers interrupt controllers and makes IRQs and device memory; IRQs delivered as port packets and acknowledged; windows onto memory objects, destroyed with them. 4c done (`decisions/0056`): process control over a subtree with the five rights, threads held by suspends and stops and parked where their state is their registers, intercepts that stop threads at calls' entries and exits and at faults (the exception port), with Continue, Skip and Kill, register and memory access, kill, and termination signals. 4d done (`decisions/0057`): the syscall table as a struct of typed function types in the ABI package, from which `#insert` generates the stubs, the call numbers and the kernel's dispatch into typed handlers; the kernel's per-kind code generated from a table of object kinds; the boot tests call through the stubs |
| M6 | planned 2026-10-23 (`decisions/0058`), in four stages. 6a done (`decisions/0059`): programs build as position-independent executables for `os = .SlopOS` (`src/apps`, `src/services`, `src/drivers`), with Hemera's `base` runtime for SlopOS (a page heap on memory objects, the clock, `process_exit`), the startup block in the ABI package, the shared ELF loader (`src/elf_loader`, unit-tested on the built programs), and the programs carried as boot modules (`docs/specs/programs.md`). 6b done (`decisions/0060`): the kernel loads the root task from the first boot module with the shared loader, at random places, with a labeled grant table (the platform, a debug log, each other module as a read-only memory object over its frames), the boot's random seed and its stack in the startup block; the root task's end stops the kernel; programs write lines through the debug log (`debug_log`) |
| A (AArch64) | planned 2026-10-23 (`decisions/0061`), in five stages; M6 paused after 6b meanwhile. A1 done (`decisions/0062`): Hemera generates AArch64 code for Linux, with the carrier register `x28`, the prologue stack check (LLVM patch 0003), `morestack`, fibers, threads, linking C, and Linux in `base` and `std/os`; Hemera's Linux tests all pass as AArch64 programs under user-mode QEMU. A2 done (`decisions/0063`): entry functions through `aarch64.vector_table`, `return_to_user`, system registers by name as compile-time arguments, barriers, TLB and cache maintenance, `rndr` and semihosting in `base/intrinsics/aarch64`; a freestanding test boots in `qemu-system-aarch64`, turns the MMU on and takes exceptions from EL1 and system calls from EL0. A3 done (`decisions/0064`): SlopOS's kernel boots on QEMU `virt` through UEFI and Limine (`--setting=arch=aarch64`, `boot.py --arch aarch64`), with `src/arch/aarch64` for CPU setup, exception entry, `TTBR1`/`TTBR0` paging with ASIDs and the PL011, and stops after memory until A4 (`TAKES_INTERRUPTS`); 8 boot tests on AArch64. A4 done (`decisions/0065`): the GICv3, the generic timer, the other CPUs and TLB shootdown, with the GIC, the timer's interrupt and the PL011 found in the device tree (`src/devicetree`); the kernel boots to its timer ticks on every CPU; 14 boot tests on AArch64 |
| M7–M9 | not started |
