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

- Static ACPI tables the kernel needs: RSDP/XSDT, MADT, HPET.
- Local APIC / x2APIC, I/O APIC, IRQ routing to (later) driver messages.
- TSC calibration, monotonic clock, the clock page (a seqlock, on Hemera's `base/intrinsics/atomics.hsc`).
- Bringing up the other CPUs, per-CPU data via `GS`, spinlocks, TLB shootdown.

Specs: ACPI 6.5 (static tables), Intel SDM Vol. 3A ch. 10–11, Intel x2APIC spec.
Stresses: atomics and fences, the per-CPU `context.user_data` approach, endian-specific table parsing.

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

## M6 — User Space (L2, L4, L5)

- ELF loader with relocations (PIE) and ASLR.
- Root task / process manager; initial capabilities.
- Syscall library, and the start of the `std` port (`OS == .SlopOS`).

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
- A second architecture (AArch64), proving the layering. Proposed to start right after M3
  instead (`decisions/0022`).

---

## Status

| Milestone | State |
|---|---|
| M0 | done 2026-10-17: `BootInfo`, `arch_interface`, `CpuFeatures`; the build package (`src/build`) with the house-rule checks for `std` tiers and the arch interface (`src/checks`); freestanding `std` for views, fixed-buffer text and formatting, and `std/containers` (`FixedArray`, `RingBuffer`, `Bitmap`, intrusive `List`); `SharedPtr` on atomics |
| M1 | done 2026-10-15 (`compiler-plan.md` Phase 6); `tools/boot_tests.py` boots it seven ways. Entry from user mode is generated (entry functions, 2026-10-16) and waits for user mode itself (M4–M6) |
| M2 | done 2026-10-22 (`decisions/0048`): the buddy frame allocator (`src/kernel/frames`); x86-64 paging behind the arch interface (map, unmap, protect, translate, W^X, NX, global pages, PCIDs; `src/arch/x86_64/paging.hsc`); the kernel's own address space, a direct map and the image with each segment's protection, on every CPU, after which boot memory is reclaimed (`src/kernel/address_space.hsc`); the slab allocator with per-CPU magazines (`src/kernel/slab`) and the kernel heap on it, every CPU's `Allocator` (`src/kernel/heap.hsc`). Per-CPU caches of single frames; KASLR for the image and the direct map, which holds every region of the kernel's own (`0021`, amended). Frames, slabs and paging are unit-tested over a buffer standing in for memory |
| M3 | started 2026-10-16: the other CPUs start, go idle and stop with the kernel (the `starts every CPU` boot test, 4 CPUs). ACPI, the I/O APIC, the clock page and TLB shootdown are to come |
| M4–M9 | not started |
