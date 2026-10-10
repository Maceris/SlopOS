# Layered Architecture

Status: **proposed** (see `decisions/0002-layered-architecture.md`)

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
entirely. So SlopOS gets *two* abstraction boundaries: the **arch interface** (compile-time,
for the kernel) and **device-class protocols** (typed IPC, for everything above drivers).

## The Layers

```
 ┌─────────────────────────────────────────────────────────────────┐
 │ L6  Applications & shell                                        │  portable
 │     programs = packages exporting typed functions               │
 ├─────────────────────────────────────────────────────────────────┤
 │ L5  Runtime: Hemera std for OS == .SlopOS, program loader,      │  portable
 │     (later) POSIX personality                                   │
 ├─────────────────────────────────────────────────────────────────┤
 │ L4  System services (user space)                                │  portable
 │     process mgr · capability broker/powerbox · supervisor ·     │
 │     storage · network · display · input · events/log · store    │
 ├──────────────── device-class protocols (typed IPC) ─────────────┤  ← boundary 2
 │ L3  Platform & drivers (user space)                             │  per platform/
 │     platform service (ACPI / devicetree / PCIe enumeration)     │  per device
 │     drivers: virtio-blk, virtio-net, ps2, framebuffer, nvme ... │
 ├──────────────── syscalls (the only kernel API) ─────────────────┤
 │ L2  Microkernel core                                            │  portable
 │     address spaces · threads · scheduler · IPC · capabilities · │
 │     IRQ → message routing · memory objects                      │
 ├──────────────── arch interface (compile-time) ──────────────────┤  ← boundary 1
 │ L1  Arch layer: arch/x86_64, (later) arch/aarch64, arch/riscv64 │  per arch
 ├─────────────────────────────────────────────────────────────────┤
 │ L0  Boot: bootloader → normalized BootInfo                      │  per firmware
 └─────────────────────────────────────────────────────────────────┘
```

Only L0, L1 and the platform-specific parts of L3 change between architectures.

---

### L0 — Boot

Gets the CPU into a known state and hands the kernel a **normalized `BootInfo`**:
memory map, framebuffer (if any), pointer to ACPI RSDP or devicetree blob, command line,
initial modules (the first user-space programs), and the kernel's own load address.

- The kernel never parses firmware-specific structures itself; it consumes `BootInfo`.
  Different firmware (UEFI, BIOS, U-Boot) means a different loader, not a different kernel.
- **First step** (`../decisions/0020`): use the [Limine](https://github.com/limine-bootloader/limine) boot
  protocol. It provides long mode, a higher-half mapping, the memory map, framebuffer,
  SMP startup and modules, so we can get to Hemera code without writing a loader.
- **Later, optional, as a language test:** our own UEFI loader in Hemera. The compiler already maps
  an `UEFI` OS type and COFF output in its LLVM backend, so this is a realistic second
  target that exercises the compiler without the kernel's extra demands.

### L1 — Arch Layer

One package per architecture, all implementing the **same set of function signatures**.
The kernel imports exactly one, selected at compile time:

```
#if TARGET_ARCH == .x86_64 {
    import x86_64 as arch from "../arch"
}
#else_if TARGET_ARCH == .arm64 {
    import aarch64 as arch from "../arch"
}
```

What the interface covers (draft):

| Area | Example functions |
|---|---|
| CPU setup | `init_boot_cpu`, `init_secondary_cpu`, `cpu_count`, `current_cpu` |
| Per-CPU state | `per_cpu() -> ptr[PerCpu]` (x86: via `GS` base) |
| Paging | `AddressSpace` type, `map`, `unmap`, `protect`, `activate`, `flush_tlb` |
| Interrupts | `enable/disable_interrupts`, `register_vector`, `mask/unmask_irq`, `end_of_interrupt` |
| Timer | `timer_frequency`, `set_oneshot`, `monotonic_now` |
| Threads | `ThreadState` (saved registers), `init_thread_state`, `switch_to` |
| User boundary | `enter_user_mode`, syscall entry → calls a portable `kernel.handle_syscall` |
| Faults | Page fault / exception decoding into a portable `Fault` tagged union |
| Misc | `halt`, `pause`, `random_seed` (RDRAND / RNDR) |

Design rules:
- **Types cross the boundary as portable types.** Page permissions are a portable
  `Protection` enum, not x86 PTE bits. Faults are a portable `Fault` union, not raw vectors.
- **No policy in L1.** It switches address spaces when told to; it never decides which.
- **Small.** If something could be written portably in L2, it goes in L2.

> **Checked at compile time:** the signatures live in an `arch_interface` package as bodiless
> `---` declarations, and a `#run` check verifies the selected `arch/*` package implements every
> one exactly (`../decisions/0007-house-rules-compile-time-checks.md`).

### L2 — Microkernel Core

Portable Hemera, written only against L1. Responsibilities, and nothing else:

- **Address spaces and memory objects.** Kernel tracks physical memory ownership; user
  space decides what to map where (via capabilities to memory objects).
- **Threads and scheduling.** Dispatch and budget enforcement only; policy is set from user
  space (`scheduling.md`, proposed).
- **IPC.** Asynchronous channels over shared-memory rings, with ports as the single wait
  mechanism; blocking and RPC are library code on top (`ipc.md`, proposed).
- **Capabilities.** Per-process handle table; every kernel object is reached via a handle.
- **Interrupt routing.** An IRQ becomes a message to whichever driver holds the capability
  for it. The kernel never runs driver code.
- **Device access grants.** Capabilities to MMIO ranges, I/O port ranges (x86), IRQs, and
  IOMMU-confined DMA buffers. That's how drivers in L3 touch hardware without being in L2.

### L3 — Platform & Drivers (user space)

This is the "standardize the hardware" layer for peripherals.

- **Platform service**: the first privileged user-space process. Parses ACPI (x86) or
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
  `union` of responses. No separate IDL; serializers/stubs generated with `#run`.

  ```
  BlockRequest :: union {
      Read(lba: u64, count: u32, buffer: SharedBuffer),
      Write(lba: u64, count: u32, buffer: SharedBuffer),
      Flush,
      Info,
  }
  ```

### L4 — System Services

Portable, user space, each holding only the capabilities it needs:

- **Process manager** — creates address spaces, loads programs, hands out initial capabilities.
- **Capability broker / powerbox** — mediates grants (file picker, "allow network").
- **Supervisor** — restarts crashed drivers and services (MINIX 3 reincarnation server).
- **Storage** — filesystems on top of `block`; presents typed, capability-scoped namespaces.
- **Network** — TCP/IP on top of `net`.
- **Display / input** — compositor on top of `framebuffer`/`display` + `input`; owns the trusted path.
- **Events / log** — structured, typed events.
- **Bundle store** — content-addressed program and library storage.

### L5 — Runtime

The Hemera `std` port: `std` already branches on `OS` (see `base/runtime/thread.hsc`), so
SlopOS becomes a new `OS == .SlopOS` branch. `std/io`, `std/time`, `std/os`, threads and
fibers get implemented over SlopOS syscalls and L4 protocols. Since most of `std` is
still `TODO`, **SlopOS's native API and Hemera's `std` can be designed together** —
probably the most valuable feedback loop in the project.

### L6 — Applications

Programs as packages exporting typed functions; shell builds CLIs from signatures
(see `problems-and-directions.md` §4).

---

## What Is Portable, Concretely

| Artifact | Per-arch? | Notes |
|---|---|---|
| Bootloader | yes | Limine supports x86-64, AArch64, RISC-V, LoongArch |
| `arch/*` | yes | The only per-arch kernel code |
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
  boot/         L0: Limine config now; Hemera UEFI loader later
  arch/
    x86_64/     L1
  kernel/       L2
  platform/     L3 platform service
  drivers/      L3 drivers, one package each
  protocols/    device-class + service protocol types, shared by both sides
  services/     L4
  (runtime)     L5 lives in Hemera's std as its OS == .SlopOS branches
  apps/         L6
```

`protocols/` is its own package so drivers and their clients import the same types
and can never disagree about a message layout.
