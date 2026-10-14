# Layered Architecture

Status: **accepted** 2026-10-13 (`decisions/0002-layered-architecture.md`). The official
description is `../../docs/architecture/layers.md`; this note is the history of how it was
reached, and is no longer updated. Revised 2026-10-13
against Hemera as of commit `bee69fe`: platform intrinsics, interrupt functions, freestanding
build options, `CarrierBlock.program_data`, `std` tiers, and house-rule checks registered by the
build.

Goal: run on x86-64 first, but keep everything above a thin bottom layer portable,
so a second architecture (AArch64, RISC-V) is a matter of writing new bottom-layer
packages rather than touching the kernel or anything above it.

## The Key Distinction: Two Kinds of Hardware

"Abstract the hardware behind a common interface" applies to two very different things,
and they belong in different places:

| | CPU & core platform | Peripheral devices |
|---|---|---|
| Examples | Privilege levels, page tables, interrupt controller, timer, context switching, syscall entry, SMP | Disks, NICs, GPUs, keyboards, USB, sound |
| How many | One per architecture | Thousands, per machine |
| Needs ring 0? | Yes, by definition | No (with an IOMMU) |
| Where it goes | **Arch layer, inside the kernel** | **Drivers in user space, behind device-class protocols** |

A classic monolithic HAL (Windows NT's `hal.dll`) mixes both. In a microkernel the CPU
part must stay privileged and tiny, and the device part should leave the kernel
entirely. So SlopOS gets *two* hardware boundaries: the **arch interface** (compile-time,
for the kernel) and **device-class protocols** (typed IPC, for everything above drivers).

## The Layers

```
 ┌─────────────────────────────────────────────────────────────────┐
 │ L6  Applications & shell                                        │  portable
 │     programs = packages exporting typed functions               │
 ├─────────────────────────────────────────────────────────────────┤
 │ L5  Runtime: Hemera std's OS == .SlopOS branches, program       │  portable
 │     loader, (later) POSIX personality                           │
 ├──────────────── service protocols (typed IPC) ──────────────────┤  versioned
 │ L4  System services (user space)                                │  portable
 │     process mgr · supervisor · powerbox · storage · network ·   │
 │     terminal · display · input · events/log · stores · sessions │
 ├──────────────── device-class protocols (typed IPC) ─────────────┤  hardware boundary 2
 │ L3  Platform & drivers (user space)                             │  per platform/
 │     platform service (ACPI / devicetree / PCIe enumeration)     │  per device
 │     drivers: virtio-blk, virtio-net, ps2, framebuffer, nvme ... │
 ├──────────────── system ABI (syscalls) ──────────────────────────┤  stable (0025)
 │ L2  Microkernel core                                            │  portable
 │     address spaces · threads · scheduler · IPC · capabilities · │
 │     IRQ → port packets · memory objects · root task start       │
 ├──────────────── arch interface (compile-time) ──────────────────┤  hardware boundary 1
 │ L1  Arch layer: arch/x86_64, arch/aarch64, arch/riscv64         │  per arch
 ├──────────────── BootInfo ───────────────────────────────────────┤  internal
 │ L0  Boot adapter: bootloader protocol → normalized BootInfo     │  per boot protocol
 └─────────────────────────────────────────────────────────────────┘
```

L0, L1 and L2 are compiled into one image, the kernel. Everything from L3 up is user space.
Only L1, the platform-specific parts of L3, and (if the bootloader changes) L0 change between
architectures.

## Interfaces Between Layers

Five interfaces, each with its own stability rules. Each one is a candidate for a
specification in `../../docs/specs/`.

| Interface | Between | Form | Stability | Checked by |
|---|---|---|---|---|
| `BootInfo` | L0 → L2 | A Hemera struct passed to the kernel's portable entry | Internal to the kernel image; changes freely | The type checker |
| Arch interface | L1 ↔ L2 | An `arch_interface` package of `---` declarations | Internal to the kernel image; changes freely | House-rule check (`../decisions/0029`) |
| System ABI | L2 ↔ L3+ | Syscalls, startup block, calling convention version | Stable once frozen (`../decisions/0025`, `0027`) | `system-abi.md` |
| Device-class protocols | L3 ↔ L4 | Hemera `union` types over channels | Versioned (open question) | Shared `protocols` package |
| Service protocols | L4 ↔ L5/L6 | Hemera `union` types over channels | Versioned (open question) | Shared `protocols` package |

The two that are internal to the kernel image can be changed in one commit with every
implementation, since all of them are compiled together. That's what keeps the arch interface
cheap to reshape while a second architecture is being added (`../decisions/0022`).

## Targets and `std` Tiers

The layers split into two build targets (`../decisions/0028`), and each target may only use
some of Hemera's `std` tiers (Hemera `docs/packages.md`, *Standard Library Tiers*). The tier
check (`../decisions/0029`) enforces it.

| Layers | Target | Build options | `std` tiers |
|---|---|---|---|
| L0–L2 | Kernel | `os = .None`, `startup_code = false`, `stack_check_failure = .AssertionHandler`, `red_zone = false`, SIMD off in `cpu_features`, ELF with a `linker_script` | `Freestanding`, `Allocating` (with the kernel's own allocators) |
| L3–L6 | User space | `os = .SlopOS`, startup code from `std` (`../decisions/0026`) | All, including `Os` |

Host tests are a third target, for portable packages that don't need either.

---

### L0 — Boot Adapter

Turns whatever the bootloader hands over into a **normalized `BootInfo`**: memory map,
framebuffer (if any), pointer to ACPI RSDP or devicetree blob, command line,
initial modules (the first user-space programs), the kernel's own load address, the other
CPUs and how to start them, and an entropy seed if the bootloader has one.

- The kernel never parses bootloader-specific structures itself; it consumes `BootInfo`.
  A different bootloader (Limine, our own UEFI loader, U-Boot) means a different L0 package,
  not a different kernel.
- **L0 is per boot protocol, not per architecture.** The Limine protocol is almost the same on
  x86-64, AArch64 and RISC-V, so one `boot/limine` package serves all three, with `#if
  TARGET_ARCH` only around the few arch-specific responses (SMP). L1 never sees Limine
  structures.
- **L0 owns the kernel's entry point.** The kernel is built without Hemera's startup code, so
  the entry function does what Hemera's `docs/compilation.md` (*Freestanding Programs*) says:
  1. Point a carrier block on the boot stack at the end of that stack, and load it with
     `intrinsics.set_carrier`.
  2. `push_context` a context built from constants (`runtime.FAILING_ALLOCATOR`, the early
     serial logger), since there is no heap yet.
  3. Build `BootInfo` without allocating (it points into bootloader-reclaimable memory, which
     the kernel keeps until it has copied what it needs).
  4. Call the portable `kernel.boot(boot_info)` (L2), which never returns.
- **First step** (`../decisions/0020`): use the [Limine](https://github.com/limine-bootloader/limine) boot
  protocol. It provides long mode, a higher-half mapping, the memory map, framebuffer,
  SMP startup and modules, so we can get to Hemera code without writing a loader.
- **Later, optional, as a language test:** our own UEFI loader in Hemera, a separate program
  with `os = .UEFI` (PE/COFF output, Hemera `docs/compilation.md`, *Linking*). It would hand
  over its own protocol, read by a second L0 package.

### L1 — Arch Layer

One package per architecture, all implementing the **same set of function signatures**, the
`arch_interface` package. The kernel imports exactly one, selected at compile time, always
under the name `arch`:

```
#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}
#if TARGET_ARCH == .riscv64 {
    import arch from "../arch/riscv64"
}
```

L1 is written in Hemera on top of the platform intrinsics in Hemera's `base`
(`intrinsics.x86_64`: `cli`, `lgdt`, `wrmsr`, `write_cr3`, `invlpg`, `cpuid`, ...) and
interrupt functions (`#calling_convention(.interrupt)`). Those intrinsics exist only when
compiling for their architecture, so nothing portable can use them by accident.

What the interface covers (draft):

| Area | Example functions |
|---|---|
| CPU setup | `init_boot_cpu`, `start_secondary_cpu`, `detect_features -> CpuFeatures` (`../decisions/0019`) |
| Kernel entry | Interrupt, exception and syscall entry stubs (see below), which call portable `kernel.handle_*` functions |
| Paging | `PageTable`, `map`, `unmap`, `protect` (taking `ptr[mut PageTable]` and a portable `Protection`), `activate`, `flush_tlb`, `flush_tlb_all` |
| Interrupts | `enable/disable_interrupts`, `mask/unmask_irq`, `end_of_interrupt`, `send_ipi(cpu, kind)` |
| Timer | `counter() -> u64`, `counter_frequency`, `set_deadline(counter)` |
| User state | `UserRegisters`, `VectorState`, `save/restore_vector_state`, `return_to_user(ptr[UserRegisters])` |
| Faults | Decoding exceptions into a portable `Fault` union |
| Misc | `halt`, `spin_hint`, `entropy_seed` (RDSEED / RNDR / Zkr `seed`) |

Design rules:
- **Types cross the boundary as portable types.** Page permissions are a portable
  `Protection` enum, not x86 PTE bits. Faults are a portable `Fault` union, not raw vectors.
- **No policy in L1.** It switches address spaces when told to; it never decides which.
- **Small.** If something could be written portably in L2, it goes in L2.
- **No raw instructions outside L1 and L0.** Only `arch/*` and `boot/*` import a platform
  package from `intrinsics`. Proposed as a house-rule check next to the arch-interface check,
  with per-architecture drivers in L3 as the only other exception (x86 port I/O).

What moved out of L1 in this revision, because Hemera now provides it portably:
- **Per-CPU state.** In the kernel, each CPU runs exactly one carrier (no fibers, no
  migration), so the carrier block *is* the per-CPU block. `PerCpu` embeds its
  `runtime.CarrierBlock`, whose `program_data` points back at the `PerCpu`, and portable L2 code
  reaches it as `intrinsics.carrier().program_data`, through the carrier register. L1 only has
  to find the carrier block at entry (below). The CPU's index is `carrier().index`.
- **Time units.** L1 exposes a raw counter and its frequency. L2 turns them into
  `runtime.Instant` and maintains the clock page, so the conversion is written once.
- **Thread switching.** With one kernel stack per CPU (`../decisions/0023`), there are no
  kernel threads to switch between, so the interface has no `switch_to`. A thread's state is
  its saved user registers and vector state, saved at entry and restored by `return_to_user`.

**Kernel entry.** Interrupt, exception and syscall stubs are the only kernel code that runs
without a carrier or a context. Each one:
1. finds this CPU's carrier block in the architecture's per-CPU register (x86-64: the `gs` base
   after `swapgs`; AArch64: `TPIDR_EL1`; RISC-V: `sscratch`), saving the interrupted code's
   carrier register if it came from user mode (`kernel.md` §3, `../decisions/0026` item 4);
2. loads it with `intrinsics.set_carrier`, switching `stack_limit` for IST and other separate
   exception stacks;
3. pushes the CPU's prebuilt context (`PerCpu.context`);
4. calls the portable handler, passing a portable `Fault`, IRQ number or syscall frame.

> **Gap: not every entry can be written in Hemera yet.** Interrupt functions cover x86-64 IDT
> entries. They don't cover x86-64 `SYSCALL` entry (no frame is pushed, and the stack pointer
> is still the user's), returning to user mode with a full register set (`sysretq`/`iretq`),
> `XSAVE`/`XRSTOR`, or AArch64 and RISC-V exception vectors. Hemera has no inline assembly.
> Needed from M4 (`../hemera-feedback.md`, *Kernel entry and return to user mode*).

> **Checked at compile time:** the signatures live in an `arch_interface` package as bodiless
> `---` declarations, and a house-rule check registered by the build with `compiler.add_check`
> verifies that any package imported as `arch` implements every one exactly
> (`../decisions/0007`, `0029`).

### L2 — Microkernel Core

Portable Hemera, written only against L1, the `BootInfo` type, and `std`'s `Freestanding` and
`Allocating` tiers. Responsibilities, and nothing else (detailed in `kernel.md` §2):

- **Address spaces and memory objects.** Kernel tracks physical memory ownership; user
  space decides what to map where (via capabilities to memory objects).
- **Threads and scheduling.** Dispatch and budget enforcement only; policy is set from user
  space (`scheduling.md`, proposed).
- **IPC.** Asynchronous channels over shared-memory rings, with ports as the single wait
  mechanism; blocking and RPC are library code on top (`ipc.md`, proposed).
- **Capabilities.** Per-process handle table; every kernel object is reached via a handle.
- **Interrupt routing.** An IRQ becomes a packet on the port of whichever driver holds the
  capability for it. The kernel never runs driver code.
- **Device access grants.** Device memory objects, I/O port ranges (x86), IRQs, and IOMMU
  domains. That's how drivers in L3 touch hardware without being in L2.
- **Starting user space.** The kernel starts exactly one process, the root task, and hands it
  everything (`../decisions/0012`).

### L3 — Platform & Drivers (user space)

This is the "standardize the hardware" layer for peripherals.

- **Platform service**: started by the root task. Parses ACPI (x86) or
  devicetree (ARM/RISC-V), enumerates PCIe, and launches drivers, handing each one only
  the capabilities for its own device. Architecture differences in *discovery* stop here.
- **Drivers** each implement one or more **device-class protocols**:

  | Protocol | Purpose |
  |---|---|
  | `block` | read/write numbered blocks, flush, geometry |
  | `net` | send/receive frames, MAC, link state |
  | `framebuffer` / `display` | modes, shared pixel buffer, vsync events |
  | `input` | key, pointer, touch events |
  | `clock` | wall clock time (RTC) |
  | `entropy` | random bytes |
  | `serial` | byte stream for debugging consoles |

  Everything above L3 talks to "a `block` capability", never to "an NVMe controller".

- **virtio first.** QEMU's virtio devices are simple, well-specified, and identical across
  x86-64, AArch64 and RISC-V, so one set of drivers works on every architecture we try.
  virtio's design (shared-memory rings plus notifications) is also very close to our IPC
  model, so our device-class protocols can be modeled on it.

- **A device-class protocol is just a Hemera type:** a tagged `union` of requests and a
  `union` of responses. No separate IDL; serializers/stubs generated at compile time. A union
  variant carries one type, so variants with several fields use a struct:

  ```
  BlockTransfer :: struct {
      lba : u64,
      count : u32,
      buffer : SharedBuffer,
  }

  BlockRequest :: union {
      Read(BlockTransfer),
      Write(BlockTransfer),
      Flush,
      Info,
  }
  ```

### L4 — System Services

Portable, user space, each holding only the capabilities it needs. The full list, with what
each holds and whether it's in the trusted computing base, is in `services.md`:

- **Root task** — the first process; splits budgets and device capabilities and starts the
  rest. Policy-free, never restarted (`../decisions/0012`).
- **Process manager** — loads programs and builds processes for a requester, who owns them.
- **Supervisor** — restarts crashed drivers and services (MINIX 3 reincarnation server).
- **Powerbox** — mediates grants (file picker, "allow network", `../decisions/0018`).
- **Storage** — filesystems on top of `block`; presents typed, capability-scoped namespaces.
- **Network** — TCP/IP on top of `net`.
- **Terminal, display, input** — consoles and the compositor on top of `serial`,
  `framebuffer`/`display` and `input`; they own the trusted path.
- **Accounts and sessions** — login, per-user volumes, session nodes (`../decisions/0016`).
- **Events / log** — structured, typed events.
- **Config store, bundle store** — typed system configuration; content-addressed programs and
  libraries.

### L5 — Runtime

Hemera's own `std` (`../decisions/0030`): SlopOS support is its `OS == .SlopOS` branches, the
same way `base/runtime/thread.hsc` and `std` already branch on the other operating systems.
`std/io`, `std/time`, `std/os`, threads and fibers are implemented over SlopOS syscalls and L4
protocols, and each thread starts in `std`'s entry stub, which sets up its carrier block
(`../decisions/0026`). Since much of `std` is still `TODO`, **SlopOS's native API and Hemera's
`std` can be designed together**, probably the most valuable feedback loop in the project.

### L6 — Applications

Programs as packages exporting typed functions; shell builds CLIs from signatures
(see `problems-and-directions.md` §4).

---

## What Is Portable, Concretely

| Artifact | Per-arch? | Notes |
|---|---|---|
| Bootloader | yes | Limine supports x86-64, AArch64, RISC-V, LoongArch |
| `boot/*` (L0) | no, per boot protocol | Small `#if TARGET_ARCH` sections for arch-specific responses |
| `arch/*` (L1) | yes | The only per-arch kernel code |
| Kernel core | no | |
| Platform service | partly | ACPI vs devicetree parser; PCIe is shared |
| virtio drivers | no | Identical across architectures |
| Real-hardware drivers | per device | Not per architecture |
| Services, runtime, apps | no | |
| On-disk / wire formats | no | Use explicit-endian types (`u32le`), never native ints |

## Build Shape (illustrative only)

Package structure and naming are deliberately undecided. They'll be drafted once the OS
design is more refined, informed by both this architecture and Hemera's style (see
`../open-questions.md`). The sketch below only shows how the layers might map to folders.

```
src/
  build/            build package: kernel, user-space and host-test targets (0028)
  checks/           house-rule checks, registered by the build (0029)
  boot/
    limine/         L0: Limine protocol → BootInfo, kernel entry point
  boot_info/        the BootInfo type, shared by L0 and L2
  arch_interface/   the --- declarations L1 implements
  arch/
    x86_64/         L1
  kernel/           L2
  platform/         L3 platform service
  drivers/          L3 drivers, one package each
  protocols/        device-class + service protocol types, shared by both sides
  services/         L4
  (runtime)         L5 lives in Hemera's std as its OS == .SlopOS branches
  apps/             L6
```

`protocols/` is its own package so drivers and their clients import the same types
and can never disagree about a message layout. `boot_info/` and `arch_interface/` are separate
for the same reason: two layers depend on each, and neither layer owns it.
