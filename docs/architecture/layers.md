# Layer Model

SlopOS is a microkernel system built in seven layers, from the boot adapter (L0) to
applications (L6). Two of the boundaries between them abstract hardware: the **arch interface**
inside the kernel, for the CPU and core platform, and **device-class protocols** above user-space
drivers, for peripheral devices.

Implementation status: **specified, not implemented.** No layer has code yet.

Decided in `../../knowledge/decisions/0002-layered-architecture.md`. The design history is in
`../../knowledge/design/layers.md`. Four-digit numbers like `0023` refer to decision records in
`../../knowledge/decisions/`.

## Layers

```
 ┌─────────────────────────────────────────────────────────────────┐
 │ L6  Applications & shell                                        │  portable
 ├─────────────────────────────────────────────────────────────────┤
 │ L5  Runtime: Hemera std's OS == .SlopOS branches                │  portable
 ├──────────────── service protocols (typed IPC) ──────────────────┤
 │ L4  System services (user space)                                │  portable
 ├──────────────── device-class protocols (typed IPC) ─────────────┤  hardware boundary 2
 │ L3  Platform service & drivers (user space)                     │  per platform / device
 ├──────────────── system ABI (syscalls) ──────────────────────────┤
 │ L2  Microkernel core                                            │  portable
 ├──────────────── arch interface (compile-time) ──────────────────┤  hardware boundary 1
 │ L1  Arch layer: arch/x86_64, arch/aarch64, arch/riscv64         │  per architecture
 ├──────────────── BootInfo ───────────────────────────────────────┤
 │ L0  Boot adapter: bootloader protocol → BootInfo                │  per boot protocol
 └─────────────────────────────────────────────────────────────────┘
```

L0, L1 and L2 are compiled together into one image, the kernel. L3 and everything above it run
in user space.

| Layer | Contents | Varies by |
|---|---|---|
| L0 | Boot adapter: the kernel's entry point; turns the bootloader's handoff into `BootInfo` | Boot protocol |
| L1 | Arch layer: CPU setup, paging, interrupts, timer, kernel entry, user state | Architecture |
| L2 | Microkernel core: memory, address spaces, threads, scheduling, IPC, capabilities | Nothing |
| L3 | Platform service (hardware discovery) and drivers | Platform and device |
| L4 | System services: root task, process manager, supervisor, storage, network, sessions, ... | Nothing |
| L5 | Runtime: Hemera's `std`, implemented for `OS == .SlopOS` | Nothing |
| L6 | Applications and the shell | Nothing |

## Interfaces

| Interface | Between | Form | Stability |
|---|---|---|---|
| `BootInfo` | L0 → L2 | A Hemera struct passed to the kernel's portable entry point | Internal to the kernel image |
| Arch interface | L1 ↔ L2 | The `arch_interface` package: bodiless `---` function declarations | Internal to the kernel image |
| System ABI | L2 ↔ L3 and above | Syscalls, the startup block, the Hemera calling convention version | Stable once frozen (`0025`, `0027`) |
| Device-class protocols | L3 ↔ L4 | Hemera `union` types of requests and responses, over channels | Versioned |
| Service protocols | L4 ↔ L5, L6 | Hemera `union` types of requests and responses, over channels | Versioned |

- **Internal interfaces** change together with every implementation of them, in one change,
  since the kernel image is compiled as a whole.
- **Protocol types live in a shared `protocols` package**, imported by both sides, so the two
  ends of a channel always agree on the layout of a message.
- How protocols are versioned is not yet specified.

Each interface gets its own specification in `../specs/`. None is written yet.

## Build Targets

| Layers | Target | Required build options | Hemera `std` tiers allowed |
|---|---|---|---|
| L0–L2 | Kernel | `os = .None`, `startup_code = false`, `stack_check_failure = .AssertionHandler`, `red_zone = false`, SIMD disabled in `cpu_features`, ELF output with a `linker_script` | `Freestanding`, `Allocating` |
| L3–L6 | User space | `os = .SlopOS` | All |

Build options are Hemera's `TargetOptions` (`base/compiler/build.hsc`). The build package
(`0028`) defines both targets, plus a host target for tests of portable packages.

## Checked Rules

The build registers house-rule checks (`0007`, `0029`) that enforce:

- **Arch interface conformance:** a package imported as `arch` defines every function in
  `arch_interface` with an identical signature.
- **`std` tiers:** a package imports no package of a higher tier than its own, and the kernel
  target uses only the tiers listed above.
- **Platform intrinsics:** only L0, L1 and per-architecture drivers in L3 import a platform
  package from Hemera's `intrinsics` (such as `intrinsics.x86_64`).

---

## L0 — Boot Adapter

The boot adapter is one package per boot protocol, linked into the kernel. It contains the
kernel's entry point, which:

1. points a carrier block on the boot stack at the end of that stack and loads it with
   `intrinsics.set_carrier`;
2. pushes a context built from constants (`runtime.FAILING_ALLOCATOR`, an early serial logger);
3. builds a `BootInfo` without an allocator (`../specs/boot_info.md`);
4. calls the portable `kernel.boot(boot_info)`, which never returns.

`BootInfo` holds the memory map, the kernel image's location, the CPUs and how to start them,
the boot modules, framebuffers, firmware tables, and the command line. It's specified in
`../specs/boot_info.md`.

The kernel parses no bootloader structures outside L0.

| Package | Boot protocol | Architectures |
|---|---|---|
| `boot/limine` | [Limine](https://github.com/limine-bootloader/limine) (`0020`) | x86-64, AArch64, RISC-V |

## L1 — Arch Layer

One package per architecture, each implementing `arch_interface`. The kernel imports exactly
one, always named `arch`:

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

The arch layer covers:

| Area | Responsibility |
|---|---|
| CPU setup | Initialize the boot CPU, start the others, report `CpuFeatures` (`0019`) |
| Kernel entry | Interrupt, exception and syscall entry stubs |
| Paging | Page tables: map, unmap, protect, activate, TLB flushes |
| Interrupts | Enable and disable, mask and unmask IRQs, end of interrupt, inter-processor interrupts |
| Timer | A raw counter, its frequency, and a one-shot deadline |
| User state | Saved user registers and vector state, and returning to user mode |
| Faults | Decoding exceptions into the portable `Fault` union |
| Miscellaneous | Halting, spin-wait hints, a hardware entropy seed |

Rules:
- **Only portable types cross the interface.** Page permissions are the portable `Protection`
  enum; faults are the portable `Fault` union.
- **The arch layer holds no policy.** It performs what L2 asks for.
- **What can be portable is in L2.** In particular:
  - **Per-CPU state** is reached portably. Each CPU has one carrier block, embedded in its
    `PerCpu` block, with `program_data` pointing back at the `PerCpu`. Kernel code reaches it
    as `intrinsics.carrier().program_data`, and the CPU's index as `intrinsics.carrier().index`.
  - **Time** is converted from the raw counter to `runtime.Instant` by L2.
  - **Threads** have no kernel stacks to switch between: there is one kernel stack per CPU
    (`0023`). A thread's state is its saved user registers and vector state.

The function signatures are specified in the arch-interface specification (`../specs/`, not
yet written).

### Kernel Entry

Interrupt, exception and syscall entry stubs are the only kernel code that runs without a
carrier block or a context. Each stub:

1. finds this CPU's carrier block through the architecture's per-CPU register (x86-64: the `gs`
   base after `swapgs`; AArch64: `TPIDR_EL1`; RISC-V: `sscratch`), and saves the user's carrier
   register when entered from user mode;
2. loads the carrier block with `intrinsics.set_carrier`, setting `stack_limit` for the stack
   in use (including IST and other separate exception stacks);
3. pushes the CPU's prebuilt context, `PerCpu.context`;
4. calls the portable L2 handler.

The user's carrier register is restored on return and its value is never trusted (`0026`).

**Not yet expressible in Hemera:** x86-64 IDT entries are interrupt functions
(`#calling_convention(.interrupt)`). `SYSCALL` entry, returning to user mode, vector state
saving and AArch64 and RISC-V exception vectors have no Hemera mechanism yet
(`../../knowledge/hemera-feedback.md`).

## L2 — Microkernel Core

Portable Hemera, using only L1, `BootInfo`, and `std`'s `Freestanding` and `Allocating` tiers.
It provides mechanism only; policy lives in user space.

- **Physical memory and memory objects**, including device memory and memory budgets (`0011`).
- **Address spaces**: mapping, unmapping and protecting memory objects.
- **Threads and scheduling**: dispatch and budget enforcement (`0023`).
- **Time**: the monotonic clock and deadlines.
- **IPC**: channels over shared-memory rings, and ports as the single wait mechanism.
- **Capabilities**: per-process handle tables, rights and revocation (`0008`, `0010`).
- **Interrupt routing**: an IRQ becomes a packet on the port of the driver holding its
  capability. The kernel runs no driver code.
- **Device access**: device memory objects, I/O port ranges (x86-64), IRQs and IOMMU domains.
- **Process control**: inspection, interception and termination (`0017`).
- **Starting user space**: the kernel starts one process, the root task, and gives it every
  resource (`0012`).

## L3 — Platform Service and Drivers

User-space processes.

- **The platform service** discovers hardware (ACPI on x86-64, devicetree on AArch64 and
  RISC-V, PCIe enumeration) and starts drivers, giving each one the capabilities for its own
  device only.
- **Drivers** implement device-class protocols. Nothing above L3 depends on which device or
  architecture is underneath.

| Protocol | Purpose |
|---|---|
| `block` | Read and write numbered blocks, flush, geometry |
| `net` | Send and receive frames, MAC address, link state |
| `framebuffer` / `display` | Modes, a shared pixel buffer, vsync events |
| `input` | Key, pointer and touch events |
| `clock` | Wall-clock time |
| `entropy` | Random bytes |
| `serial` | A byte stream, for consoles |

A protocol is a Hemera `union` of requests and a `union` of responses. Variants with several
fields carry a struct:

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

The first drivers are virtio devices, which are the same on every supported architecture.

## L4 — System Services

User-space processes, each holding only the capabilities it needs: the root task, process
manager, supervisor, powerbox, storage, network, terminal, display and input, accounts and
sessions, events and log, and the config and bundle stores. The list of services is not yet
final; the current design is in `../../knowledge/design/services.md`.

## L5 — Runtime

Hemera's `std` (`0030`), with `OS == .SlopOS` branches implemented over SlopOS syscalls and L4
protocols. Every thread starts in `std`'s entry stub, which sets up its carrier block (`0026`).

## L6 — Applications

Programs are packages that export typed functions. The shell builds command lines from their
signatures.

## Portability

| Component | Varies by |
|---|---|
| `boot/*` | Boot protocol (small per-architecture sections) |
| `arch/*` | Architecture |
| Kernel core | Nothing |
| Platform service | Platform (ACPI or devicetree); PCIe enumeration is shared |
| virtio drivers | Nothing |
| Other drivers | Device |
| Services, runtime, applications | Nothing |
| On-disk and wire formats | Nothing: explicit-endian types (`u32le`), never native integers |

Supported architectures, in order: x86-64, AArch64, RISC-V, all 64-bit (`0022`).
