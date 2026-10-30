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
  through the compiler API in `base/compiler` (Hemera's `docs/compilation.md`, *Build Packages*;
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

The second architecture (`decisions/0022`, `0061`), started 2026-10-23 with M6 paused after 6b, and done 2026-10-24 (`0062` to `0066`). Baseline
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

In five stages (`decisions/0058`, with 6d split in `0068`): 6a user programs as executables (`base`'s SlopOS
runtime, the build package's user targets, the startup block); 6b the kernel starts the root task; 6c the
root task and the process manager, with the early entropy source; 6d the start of `std`'s SlopOS port, with
typed entry points; 6e the user-mode boot tests as programs of their own.

Specs: ELF-64, System V x86-64 relocations.
Stresses: `std` design, the system ABI, the context register at process start.

## M7 — Platform and Drivers (L3)

- Platform service: ACPI static tables, PCIe enumeration (ECAM via MCFG).
- virtio over PCI (modern transport), then virtio-blk, virtio-console, virtio-rng, virtio-input.
- Device-class protocols: `block`, `serial`, `entropy`, `input`.
- Supervisor restarts crashed drivers.

In six stages (`decisions/0070`): 7a generated protocols (`0040`), with channel tags in the kernel and the first
services' protocols moved to them; 7b the kernel for drivers (MSI-X, DMA memory, the firmware tables for the root
task); 7c the platform service, PCIe through ECAM, the virtio-pci transport and virtio-rng; 7d virtio-console; 7e
virtio-blk; 7f virtio-input and supervisor restarts. Drivers stay trusted until an IOMMU stage after M7.

Specs: PCIe base spec (config space), virtio 1.2.
Stresses: volatile MMIO, fences (Hemera's `base/intrinsics/atomics.hsc`), protocol unions, driver isolation.

---

## After M7

Planned 2026-10-24. **The order is decided** (`decisions/0072`): storage first, with D, the IOMMUs, before it. The
stages below are still a draft, decided milestone by milestone when each starts, as `0058` and `0070` were. Each milestone's design is in a note in `design/`, which says what
existing systems got wrong and what SlopOS does instead; the choices that need deciding are in `open-questions.md`.
`design/lessons.md` (2026-10-29) adds what those notes missed, milestone by milestone, and three tracks to run alongside
them; decided in `decisions/0096` (R) and `0097` (Perf, memory pressure, and items placed in 9c, 9d, B, 10a, 10c and H
below); its smaller items are proposed in each milestone's design note.
Stages keep the pattern so far: each gets an "as built" record and runs on both architectures.

```
 M7 drivers ─► D IOMMU ─► M8 storage ─► M9 system services ─► M10 console, accounts ─► M11 shell
                                          and software           and sessions             and tools
                                              │                                              │
                                     B bootloader (boot counting)       P power ◄────────────┤
                                                                                             ▼
                                   M16 audio ◄─ M15 GUI ◄─ M14 remote ◄─ M13 network ◄─ M12 debugging
                                                                                         H hardening
```

**What "done" looks like at the end of M11, the first usable system:** SlopOS boots from a disk image, on either
architecture, into a login prompt on the console; a user logs in with a password, which unlocks their encrypted home
volume; a shell runs installed programs, whose typed parameters it turns into command lines, completion and grants;
files survive a reboot, and a crash at any moment leaves every volume consistent; an update to the system is a new
generation, which can be rolled back.

The kernel's work after M7, by milestone, so it isn't a surprise inside a user-space stage:

| Kernel feature | For | Milestone |
|---|---|---|
| IOMMU domains, interrupt remapping (`0039`'s `iommu_interface`) | Drivers out of the TCB | D |
| Pager-backed memory objects: faults on a memory object become packets to a pager, which supplies the pages | Programs and libraries mapped from storage without reading them whole | M9 |
| Read-only memory objects shared between processes, mapped at different addresses | Shared library text | M9 |
| Power: system off and reset, through a capability (PSCI on AArch64, ACPI's reset register and `\_S5` from the AML service on x86-64) | Shutting down | P |
| Single-stepping and hardware breakpoints and watchpoints, under `write_state` | The debugger | M12 |
| A sampling capability over a process subtree (user PC and frame-pointer walk at ticks), a trace ring of scheduler and IPC events | Profiling and tracing | M12 |
| Pinning a process's threads to one CPU, `RDTSC` trapping per process (`0009`) | Record and replay | M12 |
| A pressure signal on memory budgets; clean pages of pager-backed objects given back under pressure (`0097`) | Services' caches before allocations fail | M9 (9c) |
| Fault injection points, counters started near their wrap, lock ranks, under `robustness=on` (`0096`) | Running every error path | R |
| Tickless idle, large pages (`0097`) | Performance | Perf |
| A panic record kept across the reset; the CPU's transient-execution issues logged (`0097`) | Lost panics; the trade `0013` made, made visible | B, H |
| Shadow stacks and IBT, PAC, BTI and GCS state in threads, if `H` decides for them | Hardening | H |

## D — Device Isolation (L2, L3)

Planned 2026-10-25 (`decisions/0079`), in five stages: Da the interface and registration, Db VT-d DMA remapping, Dc
VT-d interrupt remapping, Dd SMMUv3, De drivers out of the TCB. IOVAs are allocated per domain, only DMA memory is
mapped, and a DMA fault is reported on the Device for the supervisor to restart its driver. Da done 2026-10-25
(`decisions/0080`): `iommu_interface` with VT-d and SMMUv3 identified, `iommu_register`, and the platform service
registering them from DMAR and `iommu-map`. Db done 2026-10-25 (`decisions/0081`): VT-d translates each domain, with
the invalidation queue, domains' own I/O virtual addresses, and faults logged. Dc done 2026-10-25 (`decisions/0082`):
VT-d remaps every device's MSIs, each taken only from its device. Dd done 2026-10-25 (`decisions/0083`): SMMUv3
translates each domain through stage 2, the ITS's doorbell mapped into each. De done 2026-10-25 (`decisions/0084`), so
D is done: a driver that isn't trusted gets no DMA memory without an IOMMU, and one whose DMA is blocked is killed and
started again.

- Intel VT-d and Arm SMMUv3 behind `iommu_interface` (`0039`), registered by the platform service: a DMA domain per
  driver, DMA memory mapped into its device's domain only, interrupt remapping so a device can't forge MSIs.
- Drivers leave the TCB: a driver without a domain gets no DMA memory (`0039`, "only drivers the boot configuration
  marks as trusted get DMA").
- Right after M7 and before M8, with VT-d and SMMUv3 themselves rather than `virtio-iommu` first (`0072`).
- A test driver that tries to DMA outside its domain, and is stopped.

Specs: Intel VT-d (rev. 4.x), Arm SMMUv3 (IHI 0070). QEMU: `-device intel-iommu,intremap=on` on q35,
`-machine virt,iommu=smmuv3`.
Stresses: a second compile-time interface (`iommu_interface`) checked like `arch_interface`, bit-packed descriptor
formats (`hemera-proposals/bitfields.md`), invalidation queues and their fences.

## M8 — Storage (L4)

Design: `design/storage.md`. Planned 2026-10-25 (`decisions/0085`): the six stages below, a process per unlocked
volume, ChaCha20-Poly1305 by default, ordered crash semantics, no writable mappings, no intent log to begin with,
4 KiB blocks and 16 KiB nodes, and SlopOS booting from the disk image the image builder makes, the ISO kept. 8a done
2026-10-25 (`decisions/0086`): the storage manager, GPT, partition servers and narrowed `block` connections. 8b done
2026-10-25 (`decisions/0087`): FAT32 read and write, the file protocols in `std`, the FAT server, and `std`'s files
on SlopOS beneath a working directory, with a directory-relative API on every OS. 8c done 2026-10-25
(`decisions/0088`): slopfs hosted, its crash-state tester and fuzzer, and the image builder, whose disk SlopOS boots.
8d done 2026-10-25 (`decisions/0089`): the container service and volume servers, Replace, transactions, change
cursors, and programs loaded from the system volume, Limine's modules only the boot set. 8e done 2026-10-26
(`decisions/0090`): encrypted volumes unlocked by a passphrase, their keys only in their volume servers, key
generations, snapshots and clones by birth times and dead lists, and quotas and the reserve. 8f done 2026-10-27
(`decisions/0091`), so M8 is done: stored links, made from a grant a connection gives, followed anywhere in a path
through the storage manager, listed and revoked by the volume that issued them, and never shared on.

- **Every filesystem in user space, in a process per volume.** The storage manager holds the disks' `block`
  capabilities; a partition server per disk hands out connections narrowed to a range of blocks; a container service
  per SlopOS partition manages free space and never sees plaintext; a volume server per unlocked volume holds that
  volume's key. Foreign filesystems run as unprivileged servers holding only their partition.
- **FAT32**, for the EFI system partition (which the update service writes boot generations to, M9) and later USB
  sticks; atomic replacement is best effort (`0046`).
- **The native filesystem**: pooled like APFS (many volumes share a container's space), copy-on-write B+trees
  (Rodeh), every block checked through its parent's pointer, snapshots and clones by birth time and dead lists (ZFS),
  authenticated encryption per volume with key generations (`0042`), crash states that are always a prefix of the
  operations committed, atomic replacement and transactions under a `Dir` (`0046`), change cursors instead of
  watches that overflow.
- **The `Dir`, `File` and `FileSet` protocols** (`0015`, `0018`, `0046`), bulk data through a buffer each connection
  shares, and `std`'s files over them.
- **Hosted first**: the filesystems are portable packages, unit-tested over a buffer standing in for a disk, tested
  for crash consistency by replaying every prefix of recorded writes (as CrashMonkey does), fuzzed with mutated
  images, and used by a hosted image builder that makes the disk image SlopOS boots from.

In six stages:
- **8a, partitions:** the storage manager, GPT, the partition server and narrowed `block` connections.
- **8b, FAT32 and the file protocols:** the FAT server, `Dir`, `ReadOnlyDir`, `File`, `ReadOnlyFile` and `FileSet`,
  informational names, and `std`'s files for SlopOS; the ESP readable from a boot test.
- **8c, the native filesystem, hosted:** the on-disk format, the container's space map and checkpoints, the B+tree,
  volume trees, checksums; the crash-state tester, the fuzzer and the image builder.
- **8d, the native filesystem as services:** the container service and volume servers, atomic replacement,
  transactions, `Sync`, change cursors.
- **8e, encryption and snapshots:** sealed volumes, key generations, snapshots and clones, quotas and the reserve
  that keeps deleting possible on a full disk.
- **8f, stored links:** links in a recipient's namespace to an object in another volume, listed and revoked by the
  granter (`design/security.md` §8), for M10's sharing.

Specs: UEFI 2.10 (GPT, the system partition's FAT), Microsoft's FAT32 specification v1.03 with long names,
RFC 8439 (ChaCha20-Poly1305), NIST SP 800-38D (AES-GCM), BLAKE3.
Stresses: explicit-endian on-disk structs with layout asserts, bounds proofs over block buffers (E4031), generic
B+trees, `Result` on every path, hosted tests of code written for SlopOS, cryptography's speed in Hemera.

## M9 — System Services and Software (L4)

Design: `design/software.md`; the events service in `design/observability.md`. Planned 2026-10-27 (`decisions/0092`):
the five stages below, one bundle store on the system volume, log records as format strings and typed arguments,
the system configuration serialized into each generation, `AppData` and `Config[T]` entry parameters, a scheduler
service that splits budgets as configured, and B after M9; Hemera's side proposed in `hemera-proposals/`
(`reproducible-builds.md`, `typed-linking.md`, `typed-log-records.md`).

- **The services every later milestone assumes**: the scheduler service (`0037`), the clock service (the RTC: the
  MC146818 on x86-64, the PL031 on AArch64 `virt`), the events service for typed logs, which replaces the debug log
  for everything but the root task, and restarts for the services the supervisor starts other than drivers, which
  7f's connectors (`0077`) already reach.
- **The bundle store**: content-addressed programs, libraries and schemas (`0045`), installed by adding a reference
  and never by running code, collected from roots (generations and installations); the process manager loads from it,
  mapping programs through pager-backed memory objects.
- **The config store**: typed configuration values validated by their schemas, defaults from the bundle and
  overrides kept apart (so an update never has to merge files), versioned, with rollback. The system configuration
  becomes a value that the root task validates with the same code the build runs today (`0044`).
- **Generations and updates**: a system generation is the kernel, the boot set and the configuration's version; an
  update writes a new one beside the old and switches to it at boot; rollback chooses the previous one.
- **Installations**: an app is installed into a session as an entry naming a bundle; its private data directory and
  typed configuration belong to the entry, so uninstalling leaves nothing behind (`problems-and-directions.md` §6).
- **Shared libraries**: separately compiled Hemera libraries linked by the loader by hash and by each function's
  type (so a mismatch is a load error, never a crash), with security-fix substitution by policy (`0045`).

In five stages: **9a** the scheduler, clock and events services; **9b** the bundle store, pager-backed memory objects
and loading from storage (the system boots from its disk image: the boot set from the ESP, everything else from the
system volume); **9c** the config store and the system configuration at run time; **9d** generations, updates and
installations; **9e** shared libraries and substitution. 9a done 2026-10-29 (`decisions/0093`): the scheduler, clock and
events services, with every service the supervisor starts restarted. 9b done 2026-10-29 (`decisions/0094`): the bundle store, paged memory, and
programs outside the boot set booted from the store, their code shared.

Added by `decisions/0097`: in **9c**, the benchmarks with baselines (*Perf*, below), the memory pressure signal and
evictable pager pages, and slopfs refusing names with control, bidirectional or invisible characters; in **9d**,
dependency kinds in `system_config` (required with a deadline, optional, late) with degraded boots instead of hangs,
the pinned recovery generation, and the ESP budgeted, boot-set files shared by hash.

Specs: ELF-64 dynamic linking, as far as typed linking needs it; the MC146818 and PL031 datasheets.
Stresses: deterministic, reproducible compiler output (content addressing depends on it); code run both by `#run`
and at run time (the wiring check); schemas serialized from `TypeInfo`; separately compiled libraries in the compiler.

## Catch-up — What Earlier Decisions Planned and Weren't Built

Planned 2026-10-29, after reading every decision's consequences back (`decisions/0095` did the first two: the storage
manager restarting its servers, and manifests). In four parts, before 9c, each committed as it passes:

1. **M5 to M8's**: the kernel's own share of memory held back from the root budget (`0054`); test programs for a
   missing required grant (exit 126) and an ABI version mismatch (125, `0068`); a test of a partition server's
   dependents killed and served again (`0095`); the supervisor, the events service and the bundle store reconnecting to
   the system volume when its server is started again (`0095`). Typed files in `Dir` (`0046`) go to 9c, with the
   config store's typed values.
2. **M9's**: `test_budgets` moved from the kernel to a program (`0069`); CPU affinity for IRQs and CPU budgets, with
   the scheduler service applying it from `system_config` and AArch64's ITS moving an LPI (`0055`, `0073`); every service
   the supervisor starts logging through `base`'s logger (`0093`). The process manager loading by bundle hash stays with
   9e (`0094`).
3. **House-rule checks** (`0007`, `0021`, `0029`), as far as Hemera's reflection reaches: no floating point in the
   kernel, programs don't import programs, no `rawptr` outside allowed packages, no pointers in system call results,
   interrupt handlers don't allocate, hardware structs have layout asserts (by a convention to settle); `Result`s
   discarded in the kernel need the compiler to report them, proposed to Hemera.
4. **Deferred items** placed: done now, FAT timestamps and FSInfo's free count (`0087`), and the entropy service for
   programs the supervisor starts (`0067`); in M10, the root task's services restarted and logging to the events
   service (`0093`), and interrupt controllers unregistered when the platform service restarts (`0049`); in M12,
   debuggers reading pages nothing has touched (`0056`); in P, with the AML service, ACPI's `_CRS` for x86-64's PCI
   windows (`0074`); the per-thread page shared with the kernel (`0041`) placed with the owner.

## R — Robustness Testing (all layers)

Planned 2026-10-29 (`decisions/0096`, from `design/lessons.md` §9.5): running the error paths `0005` asks for, which
mostly never run. Test machinery is compiled in only by the build setting `robustness=on`, never into other builds. In
six stages: **R1** fault injection (named failure points in the kernel, `fail=<point>:<n>` swept by `boot_tests.py`, a
failing allocator in `std` for hosted tests and programs); **R2** counters started near their wrap (the clock,
generations, PCIDs and ASIDs, IOVAs, ring indices); **R3** lock ranks checked at every acquisition, with a ranked spin
lock in `std`; **R4** storage faults, with 9c (failed and torn writes, every `Sync` after a failed write told); **R5**
chaos, after 10a (random services killed, budgets checked); **R6** schedule exploration for lock-free code, when
Hemera's atomics can be intercepted. R1 to R3 run after the catch-up, before 9c.

Specs: none; prior art in Linux's `failslab`, `INITIAL_JIFFIES` and `lockdep`, `loom` and CHESS.
Stresses: compile-time settings read by target code, code left out when a setting is off, `Allocator` wrappers,
per-CPU state checked on every lock.

## Perf — Numbers Kept, Not Assumed (all layers)

Planned 2026-10-30 (`decisions/0097`, `design/lessons.md` §9.1). Benchmarks as boot tests with recorded baselines,
failing on a regression beyond a margin: IPC round trip, page fault, thread and process creation, a program's start
from the bundle store, file create and `Sync`, boot to healthy; instruction counts (`-icount`) beside wall time, since
QEMU's timing is noisy. They land in 9c. Then, as stages between milestones, each planned when it starts: tickless idle
(`0050`), large pages for the direct map and large memory objects, and storage bandwidth scheduled by the lent budget
in the volume and container services (Linux's bug 12309).

Stresses: timing and counting inside boot tests, results compared across builds.

## B — Boot (L0)

- A Hemera UEFI bootloader, replacing Limine (`0020`), on both architectures: reads the ESP's generations, counts
  boot attempts (as the Boot Loader Specification's automatic boot assessment does) and falls back to the previous
  generation when a new one doesn't report healthy. Until it exists, falling back is choosing from Limine's menu.
- From `decisions/0097`: the recovery generation, reached by a key or after every normal generation's counter runs out;
  the command line a field of the generation, editable only for development generations, with no `test_*` options in
  release kernels; a panic record kept across the reset and copied to the ESP; a seed file on the ESP mixed into the
  boot seed and rewritten before the kernel runs; the bootloader reading nothing but FAT, generation records (checked by
  generated validators) and ELF, each boot-set file checked against its generation's hash. Sealing the system volume's
  key to a measured boot set is decided when B is planned (`open-questions.md`, *Lessons*).
- Hemera's UEFI target: PE32+ output, the UEFI calling convention, `base` for `OS == .UEFI` or a freestanding
  equivalent.

Specs: UEFI 2.10, PE/COFF.
Stresses: a third kind of output (PE32+), the Microsoft x64 and AArch64 calling conventions at the firmware boundary.
Alongside M9; required before automatic rollback.

## M10 — Console, Accounts and Sessions (L4)

Design: `design/console-and-sessions.md`.

- **The terminal service** with a typed terminal protocol (styled text, cursor and region operations, key events,
  paste as its own event): no escape sequences in the stream, so printing a file can't reprogram the terminal. A VT
  adapter translates for byte streams (the serial line now, SSH in M14). The reserved status line and the secure
  attention key (`0043`).
- **The input service** owns the keyboards and the seat, and sees the secure attention key before anyone else.
- **Accounts**: the account service and its unencrypted volume, Argon2id (RFC 9106), wrapped volume keys
  (`0042`); first-boot setup creating the administrator.
- **Login and sessions**: console login, the session manager unlocking the home volume and starting the session's
  first program with its starting capabilities (`0016`).
- **The powerbox**, one per session (`0018`), with its console front end, persistent grants as stored links (8f),
  and the user's view of what they've granted, to revoke it. Elevation is the powerbox asking for re-authentication
  on the trusted path and granting one capability, never a `sudo`.

In four stages: **10a** the terminal and input services, the status line and the secure attention key; **10b**
accounts and first-boot setup; **10c** login and sessions; **10d** the powerbox and sharing. From `decisions/0097`:
in 10a, the trusted path's services on a reserved budget, the secure attention key's menu listing and ending the
session's programs, the lifecycle channel (moved from 11a) with `Ping`, and the last boot's panic record shown; in 10c,
the session manager asking idle installations to save and stop under memory pressure.

Specs: RFC 9106 (Argon2), RFC 3394 or the AEAD for key wrapping, ECMA-48 (for the VT adapter only), the Unicode
standard's East Asian Width and UAX #29 for terminal widths.
Stresses: Unicode handled without a runtime library, memory-hard hashing inside a budget, many sessions on fibers.

## M11 — The Shell and Tools (L5, L6)

Design: `design/shell.md`.

- **The shell language** (`0018`: not Hemera): typed values instead of strings, so no word splitting, no option
  injection and no quoting rules to get wrong; command lines parsed from manifests (`0044`); arguments become grants
  of the parameter's type; pipelines connect `Stream[T]`s and are type-checked before anything starts; errors stop a
  script unless it handles them; results rendered by the shell from their schemas.
- **Scripts are programs**: a script declares typed parameters, so it has a manifest and runs with only what it's
  given.
- **Interactive use**: completion, help from documentation comments, history, jobs (Ctrl-C a message, never a signal).
- **The `std` port filled out**: `Stream[T]`, the terminal client and a line editor, time zones (TZif, RFC 8536),
  a linear-time regex engine (RE2's design, so no pattern can take exponential time).
- **Tools**: listing, copying, moving and removing files; search; a viewer and pager for any typed value; the process
  tree; snapshots; grants; installing; a text editor.

In five stages: **11a** the `std` port (`Stream[T]`, terminal client, line editor); **11b** the language and calls
through manifests; **11c** pipelines and rendering; **11d** interactive use; **11e** the tools and scripts as
programs. This is the first usable system (above).

Stresses: an interpreter in Hemera (tagged unions, arenas), reflection-driven parsing and rendering, Unicode and
regex tables generated at compile time, the typed-entry machinery from the caller's side.

## P — Power (L3)

- The ACPI service (`0039`, `services.md`): an AML interpreter, scoped to what the platform needs: the namespace,
  `\_S5`, `_PRT` for later hardware, the power button's event.
- Shutting down and rebooting through a kernel power capability (PSCI on AArch64, ACPI on x86-64), with services
  told first so volumes are committed.
- Proposed (`design/lessons.md` §5), decided when P is planned: `Stop` sent in reverse dependency order with a short
  deadline each, volumes committed, what's left killed and named in the log; the hardware watchdog's driver (§6.2).

Specs: ACPI 6.5 (AML), Arm PSCI (DEN 0022).
Stresses: an interpreter of an untrusted bytecode, kept in its own process.
Before M11 ends, so the first usable system shuts down properly.

## M12 — Observability and Debugging (L4, L6)

Design: `design/observability.md`.

- **Crash reports**: a fatal fault goes to the process's creator through its exception port (`0056`); the supervisor
  records registers, a frame-pointer stack trace, and the hashes of the images loaded, symbolized from the bundle
  store's DWARF; no memory is dumped unless asked for.
- **A debugger** on process control (`0017`, `0056`): breakpoints, stepping, watchpoints, Hemera values shown through
  their `TypeInfo`, fibers listed as well as threads.
- **Record and replay** (`0009`, `0024`): a recorder on intercepts, a replayer answering a program's system calls
  from its recording; exact for a process on one carrier, best effort for several.
- **Tracing and profiling**: IPC traced through intercepts, a system trace ring, a sampling profiler.

In four stages: **12a** crash reports and symbols; **12b** the debugger; **12c** record and replay; **12d** tracing
and profiling.

Specs: DWARF 5.
Stresses: the compiler's debug information, reflection over arbitrary values, fibers seen from outside.

## H — Hardening (L1, L2, L5)

- The decision on hardware control-flow integrity (`open-questions.md`, *Kernel*): CET shadow stacks and IBT, PAC,
  BTI and GCS, for user space and the kernel, each detected at boot like AES (`0019`).
- Fuzzers as test programs: the system call table (generated from the ABI package), every protocol's validators,
  the filesystems' mount paths, the ELF loader.

- A boot log of which transient-execution issues apply to the CPU and which cheap mitigations are on (`0097`), from
  `IA32_ARCH_CAPABILITIES` and AArch64's ID registers; `0013`'s scope unchanged.

Stresses: the compiler emitting `endbr64`/`bti` and shadow-stack-aware fiber switches in freestanding code.
Any time after M11.

## M13 — Networking (L3, L4)

Design: `design/networking.md`.

- **virtio-net** and the `net` protocol: frames through shared rings.
- **The network service**: a user-space IPv4 and IPv6 stack, with TCP (RFC 9293, SACK, window scaling, CUBIC) and
  UDP.
- **Network authority as capabilities**: no process can reach the network without a connection to it, narrowed to
  the destinations and ports it may use; listening on a port is a grant, so there are no privileged ports.
- **Names**: a resolver in the network service, so a capability can be scoped to `example.com:443`; Happy Eyeballs
  (RFC 8305).
- **Time**: NTP with NTS (RFC 5905, 8915) in the clock service.
- **TLS 1.3** (RFC 8446) in `std`, with hostname verification by default and the trust store a capability.

In five stages: **13a** virtio-net and `net`; **13b** IP, ARP, NDP, ICMP, DHCPv4, SLAAC; **13c** TCP, UDP and the
network service's protocol; **13d** DNS and NTP; **13e** TLS.

Specs: the RFCs above, RFC 791, 792, 826, 2131, 4443, 4861, 4862, 8200, 7323, 2018, 9438, 1035, 3596.
Stresses: packet processing speed, wrapping arithmetic (sequence numbers), thousands of timers and connections on
fibers.

## M14 — Remote Login (L4)

- **SSH** (RFC 4251–4254; curve25519-sha256, RFC 8731; Ed25519 host keys, RFC 8709; ChaCha20-Poly1305), with key and
  password authentication through the account service, sessions attaching to the terminal service through the VT
  adapter, and SSH's limits as `0043` states them (no interactive powerbox, a key login's volume locked until a
  password).
- **The native remote protocol** later: typed values, capabilities, prompts outside the stream, unlocking from the
  client (`0042`, `0043`).

## M15 — Display and Input (L3, L4, L6)

Design: `design/display.md`.

- **virtio-gpu** (2D) and the `display` protocol.
- **The compositor**: clients draw into their own buffers and never see each other's pixels or input; screen
  capture, global shortcuts, input injection and clipboard history are capabilities from the powerbox, designed in
  rather than added later (Wayland's portals); paste only on the user's gesture.
- **A trusted path in the GUI**: a band on every window, drawn by the compositor, naming the program, and a layer no
  client can draw over, for the powerbox's dialogs and login.
- **Text and a small UI library**: a TrueType rasterizer, simple shaping, layout; forms generated from manifests,
  as the shell's command lines are.
- **Programs**: a terminal emulator speaking the terminal protocol, the typed-data viewer, a launcher.

Stresses: SIMD in composition and rasterization, floating point in user space, a large generic UI library.

## M16 — Audio (L3, L4)

- virtio-sound and an audio service mixing clients' streams, with a high-priority budget of short periods (`0037`).
- The soft real-time goal (`design/scheduling.md`) measured: no underruns with the CPUs saturated by other budgets.
- The microphone as a powerbox capability, with an indicator on the trusted path.

## Later

- **RISC-V**, the third architecture (`decisions/0022`), after LLVM is rebuilt with its backend.
- **Real hardware**: NVMe, xHCI (HID, mass storage, where a stick's FAT is untrusted input), AHCI.
- **Indexing and live queries** over typed files' attributes (`0046`, BeOS).
- **A POSIX personality**, a library over the native protocols for porting tools; optional, never in the core
  (`problems-and-directions.md` §16).
- **ABI v1** (`0025`, `0027`), once the system above runs on two architectures and the release tooling compares the
  ABI package with its previous release.
- **Not planned**: the Hemera compiler on SlopOS, while it depends on LLVM, which rule 6 keeps out.

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
| M6 | done 2026-10-24, planned 2026-10-23 (`decisions/0058`), in four stages. 6a done (`decisions/0059`): programs build as position-independent executables for `os = .SlopOS` (`src/apps`, `src/services`, `src/drivers`), with Hemera's `base` runtime for SlopOS (a page heap on memory objects, the clock, `process_exit`), the startup block in the ABI package, the shared ELF loader (`src/elf_loader`, unit-tested on the built programs), and the programs carried as boot modules (`docs/specs/programs.md`). 6b done (`decisions/0060`): the kernel loads the root task from the first boot module with the shared loader, at random places, with a labeled grant table (the platform, a debug log, each other module as a read-only memory object over its frames), the boot's random seed and its stack in the startup block; the root task's end stops the kernel; programs write lines through the debug log (`debug_log`). 6c done (`decisions/0067`): the root task splits its budget and starts the services `system_config` lists: the entropy service (a ChaCha20 stream from the boot seed) and the process manager with its own loader (`src/process_builder`), then the supervisor through the manager; the stub supervisor starts `hello` through it. Programs are loaded into processes their requester made, which own their image, stack and startup block, through `thread_create_in`, `process_give_handles` and `memory_size`; a boot test kills the manager and `hello` keeps running. The root task is long-lived; only its end stops the kernel. 6d done (`decisions/0068`): a program's `main` takes its grants as typed parameters, which Hemera's compiler fills from the startup block through base's runtime (`log: DebugLog?`, `manager: os.Channel[ProcessManager]`); `std/os` has `Channel[P]` and `Listener[P]` with protocol tags, the channel helpers, and `launch`, typed by the program's entry; `system_config` names each service's entry and checks the wiring when it's compiled; every startup block has a seed, which `context.random` comes from; the startup code checks the ABI version (1). 6e done (`decisions/0069`): the kernel's user-mode tests are programs in `src/tests`, which the root task runs with `test_program=<name>`, launching copies of themselves where they need other processes; leaks are checked through budgets, and by the kernel, which logs what's left once the root task ends; `test_budgets` stays in the kernel. M6 is done |
| A (AArch64) | done 2026-10-24 (`decisions/0061`, planned 2026-10-23 in five stages, with M6 paused after 6b meanwhile). A1 done (`decisions/0062`): Hemera generates AArch64 code for Linux, with the carrier register `x28`, the prologue stack check (LLVM patch 0003), `morestack`, fibers, threads, linking C, and Linux in `base` and `std/os`; Hemera's Linux tests all pass as AArch64 programs under user-mode QEMU. A2 done (`decisions/0063`): entry functions through `aarch64.vector_table`, `return_to_user`, system registers by name as compile-time arguments, barriers, TLB and cache maintenance, `rndr` and semihosting in `base/intrinsics/aarch64`; a freestanding test boots in `qemu-system-aarch64`, turns the MMU on and takes exceptions from EL1 and system calls from EL0. A3 done (`decisions/0064`): SlopOS's kernel boots on QEMU `virt` through UEFI and Limine (`--setting=arch=aarch64`, `boot.py --arch aarch64`), with `src/arch/aarch64` for CPU setup, exception entry, `TTBR1`/`TTBR0` paging with ASIDs and the PL011, and stops after memory until A4 (`TAKES_INTERRUPTS`); 8 boot tests on AArch64. A4 done (`decisions/0065`): the GICv3, the generic timer, the other CPUs and TLB shootdown, with the GIC, the timer's interrupt and the PL011 found in the device tree (`src/devicetree`); the kernel boots to its timer ticks on every CPU; 14 boot tests on AArch64. A5 done (`decisions/0066`): user mode on AArch64, with SlopOS's system calls in `x8`, `x0` to `x5` and `x0` to `x2`, eagerly switched FP and SIMD state, and the programs and the root task built and loaded for AArch64; every boot test that applies runs on both architectures (52). A is done; M6 resumes, for both |
| M7 | planned 2026-10-24 (`decisions/0070`), in six stages. 7a done (`decisions/0071`): protocols are generated from their unions (`os.protocol_code`), with variable-size data as `slop_os.Relative[T]`, handles moved with their messages, validators checking every message before it's read, and protocol tags on channels (`channel_create`'s, read with `channel_tag`, checked for each `Channel[P]` in a message or an entry's parameters); the process manager's, the entropy service's and the supervisor's protocols are generated; `test_protocols` checks them. 7b done (`decisions/0073`): Devices for PCIe functions, their message-signaled IRQs through the local APICs or the GICv3's ITS (`src/kernel/devices.hsc`, `src/arch/aarch64/its.hsc`), DMA domains and pinned, contiguous DMA memory below a limit (`frames.allocate_below`), and the firmware tables copied for the root task's `firmware` grant (`src/kernel/firmware.hsc`); `test_msi_dma` drives QEMU's `edu` through its MSI and DMA on both architectures. 7c done (`decisions/0074`): the platform service (`src/services/platform`) finds the host bridge through `src/pci`, numbers buses and places BARs where firmware didn't, and gives each device once to the supervisor, which starts its driver with the device's bundle (the `platform` protocol); `src/virtio`, the modern virtio-pci transport with MSI-X and split virtqueues in little-endian types; `virtio_rng`, offering itself to the entropy service on the new `rng` protocol, which reseeds from it. 7d done (`decisions/0075`): the `serial` protocol (a Write, and a Read the driver holds until bytes arrive); `virtio_console`, a driver with a listener the supervisor connects its clients through; the console service, showing its clients' lines and echoing what's typed, with hello as its first client; `tools/boot.py` types into a virtio console over a loopback socket. 7e done (`decisions/0076`): the `block` protocol (blocks through a per-connection DMA buffer the client reaches through a window, several tagged requests in flight, `Flush`, `Describe`); `virtio_blk`, with up to 16 requests in flight and descriptor chains freed as the device gives them back; the disk check, which reads a mark boot.py wrote and writes one boot.py finds afterwards. 7f done 2026-10-25 (`decisions/0077`), so M7 is done: the `input` protocol (typed events, keys as HID usages, a held Read); `virtio_input`; the console types from the first keyboard with a US keymap; connectors (`src/protocols/connector`), which the supervisor serves and clients redial; the supervisor restarts a driver that crashes or is killed, up to 3 times a minute, with its device reissued by the platform service; boot.py types on a virtio keyboard through QMP, and `test_restart` kills the console's driver and sees the console dial it again |
| D | done 2026-10-25, planned the same day (`decisions/0079`), in five stages. Da done (`decisions/0080`): `iommu_interface` (`docs/specs/iommu_interface.md`), checked by the build like the arch interface for each package imported as `iommu_*`, with VT-d (`src/iommu/vtd`) and SMMUv3 (`src/iommu/smmuv3`) identifying their IOMMUs; the kernel's IOMMUs and the requester IDs each covers (`src/kernel/iommus.hsc`), registered with `iommu_register` (ABI 5); a domain bound to its first device's IOMMU, refusing a device behind another; the platform service registering VT-d units from DMAR's device scopes and SMMUv3s from the device tree's `iommu-map`; virtio drivers taking `VIRTIO_F_ACCESS_PLATFORM`; the boot tests run with QEMU's IOMMUs, and one without. Db done (`decisions/0081`): VT-d in legacy mode translates each DMA domain through second-level tables (`src/iommu/vtd`, `src/kernel/translation.hsc`), with the invalidation queue, I/O virtual addresses from 1 MiB per domain, tables charged to the domain, teardown that unmaps before frames go, and faults through an MSI to CPU 0, logged; Hemera's `clflush` and `mfence` for a unit that doesn't snoop. Dc done (`decisions/0082`): VT-d's interrupt remapping, a remapped entry per MSI checked against its device's requester ID, compatibility-format interrupts blocked, and wired lines refused while it's on. Dd done (`decisions/0083`): SMMUv3 with stage 2 only (`src/iommu/smmuv3`): a two-level stream table, the command and event queues, VMIDs per domain, the ITS's doorbell mapped into each domain at its own address (`arch_interface.msi_doorbell`), and faults read from the event queue at CPU 0's ticks, as QEMU's SMMU has only wired interrupts. De done (`decisions/0084`), so D is done: `system_config` trusts SlopOS's own drivers with DMA where no IOMMU confines them, and the platform service makes their domains trusted (`DMA_DOMAIN_TRUSTED`, ABI 6), any other domain getting no DMA memory there (`Untrusted`); a blocked DMA raises `SIGNAL_DMA_FAULT` on its Device, which the supervisor watches, killing the driver, which it then starts again as one that crashed; `edu_dma`, a driver of QEMU's edu device that isn't trusted, DMAs outside its domain and is stopped and started again until it's ended too often, on both architectures, and is refused DMA memory without an IOMMU |
| M8 | done 2026-10-27, planned 2026-10-25 (`decisions/0085`), in six stages. 8a done (`decisions/0086`): GPT (`src/gpt`, read primary or backup, and written, unit-tested hosted); the storage manager (`src/services/storage_manager`), given connectors to every disk, starting a partition server for each (`src/services/partition_server`), which holds only its disk and serves its partitions and `block` connections narrowed to one, zero-copy through the driver's own buffer, refusing blocks outside it; the `partitions` and `storage` protocols; the disk check opening its partition through the storage manager; boot.py's test disk a GPT disk; 8b done (`decisions/0087`): FAT32 read and write (`src/fat`, unit-tested hosted), served by a FAT server the storage manager starts per FAT partition, holding only that partition; the file protocols `dir`, `read_only_dir`, `file`, `read_only_file` and `file_set` in `std/os/slop_os`, data through a buffer each file connection gives its server; `std`'s files on SlopOS beneath a `working_directory` grant, and `os.Directory` with `_in` path functions on every OS; the disk check reading and writing the ESP boot.py writes; 8c done (`decisions/0088`): slopfs (`src/slopfs`), copy-on-write B+trees sealed with BLAKE3 down from a checkpoint ring, the container's space map, owners and volumes written twice, volumes of objects, keyed name hashes and 64 KiB chunks, checked whole by `verify`; a crash-state tester replaying every prefix, subset between flushes and torn write of a workload's writes; a fuzzer for slopfs (resealing what it damages) and FAT; and the image builder (`src/tools/image_builder`), whose GPT disk SlopOS boots from on both architectures, BIOS and UEFI; 8d done (`decisions/0089`): a container service per container, holding only its partition and checking every block a volume server reads or writes against that volume's extents, and a volume server per volume, serving the file protocols; Replace, transactions logged in client memory and checked for conflicts, change cursors over a volume's history; and every program outside the boot set read from the system volume; 8e done (`decisions/0090`): volumes sealed with ChaCha20-Poly1305 or AES-256-GCM, their keys wrapped by a passphrase through Argon2id and held only by their volume servers, key generations, snapshots and clones by birth times and dead lists, and quotas with a reserve that keeps deleting possible; 8f done (`decisions/0091`): stored links (`src/slopfs/links.hsc`), made from a `grant` a `dir` connection gives and kept by a directory in another volume, followed anywhere in a path through the storage manager's `links` protocol, which the volume they lead into checks against what it issued; listed and revoked by that volume, and never shared on from what a link reached |
| M9 | planned 2026-10-27 (`decisions/0092`), in five stages: one bundle store on the system volume, log records as format strings and typed arguments, the system configuration serialized per generation, `AppData` and `Config[T]`, B after M9; Hemera's reproducible output, typed linking and typed log records proposed (`hemera-proposals/`). Not started |
| Perf | planned 2026-10-30 (`decisions/0097`): benchmarks with baselines in 9c, then stages between milestones; not started |
| R | planned 2026-10-29 (`decisions/0096`), in six stages, R1 to R3 before 9c; not started |
| M10–M16, B, P, H | planned 2026-10-24 (*After M7*, above): the order decided (`decisions/0072`), each milestone's stages proposed until it starts; not started |
