# 0065: Interrupts, Time and SMP on AArch64, as Built

Status: accepted
Date: 2026-10-24
Related: `0061` (the plan for AArch64), `0064` (A3), `0032` (the arch interface), `0039` (wired interrupts and
the platform), `0047` (fixes found on the way), `../../docs/specs/arch_interface.md` (AArch64), `../roadmap.md` A

## Context
AArch64's fourth stage (A4, `0061`): the GICv3, the generic timer, starting the other CPUs and TLB shootdown,
so the kernel goes on past its own address space as it does on x86-64. Unlike x86-64's local APIC, the GIC's
registers are wherever the platform puts them, and QEMU `virt` has no device that raises a steady wired
interrupt by itself for the device test. MSIs (the GICv3 ITS) and NMIs have no direct counterpart yet.

## Decision
Chosen with the project's owner:
- **Devices from the device tree**: `init_system` takes the firmware's tables (an interface change, along with
  `early_console_init`), and the arch layer finds the GICv3's distributor and redistributors, the virtual
  timer's interrupt, and the PL011 in the device tree. A small reader of the flattened format is its own
  package (`src/devicetree`), for L2 and the platform service later. edk2 on QEMU `virt` gives a device tree
  only with ACPI off, so `boot.py` boots it that way; ACPI's MADT and SPCR come later, for ACPI-only machines.
- **The test device is an SPI pended in software** (`GICD_ISPENDR`): a line nothing on `virt` uses, raised again
  each time it's acknowledged and at every timer interrupt until it's stopped. It tests routing, masking,
  acknowledgement and delivery to a chosen CPU, though no device raises it.
- **MSIs and NMIs stay listed** in `NOT_YET_IMPLEMENTED`: the ITS matters once PCIe devices do, and an NMI needs
  pseudo-NMIs through GIC priorities or FEAT_NMI. Their tests stay x86-64's.

As built:
- **The GICv3** (`src/arch/aarch64/gic.hsc`): every interrupt in group 1 at one priority, with EOImode 0. Each CPU
  wakes its redistributor (found by MPIDR affinity) and enables its SGIs and the timer's PPI there, then its CPU
  interface through the ICC system registers. IPIs are SGIs 1 to 3 through `ICC_SGI1R_EL1`. An SPI's interrupt
  ID is its line's and can't be chosen, so the kernel's per-CPU device interrupt IDs (32 to 255) are translated
  through a table of routes in `ArchSystem`.
- **The timer** (`timer.hsc`): the virtual counter and timer at `CNTFRQ_EL0`. Its interrupt is a level, so the
  entry stops the timer before acknowledging it, until the next deadline.
- **`idle`** returns with `eret` to a wait loop at EL1 with `SP_EL1` at the kernel stack's top and interrupts
  unmasked, so an interrupt from idle starts there, as x86-64's IST slot does.
- **Device registers through the direct map**: the GIC's 2 MiB blocks, like the console's, are mapped in Limine's
  tables at `init_system` and in the kernel's own by `init_kernel_page_table`, two table frames a block. QEMU's
  redistributor region has room for 123 CPUs, 8 blocks.
- **`TAKES_INTERRUPTS` is gone**: both architectures take interrupts, so the kernel no longer stops after memory.
- **TLB shootdown** stays L2's, with IPIs and local `tlbi`, as on x86-64; AArch64's broadcast invalidation (the
  `is` forms) is there for L2 to use later.
- **Boot tests on AArch64** (14): besides A3's, the default boot to its third timer interrupt, every CPU started,
  the clock against the counter, TLB shootdown on 4 CPUs, a device's interrupts through the GIC, fibers, fiber
  pools on 6 CPUs, and a fiber's stack growing onto segments in a kernel built with morestack.
- **Found on the way, fixed (`0047`):**
  - `test_pool`'s carriers unmasked interrupts once their pools were done, then counted themselves done. On the
    slower emulated AArch64 CPUs a timer tick had come by then, and taking it went to idle, since an interrupt
    never returns into kernel code, so they never counted. They count first now, and idle unmasks interrupts.
  - Hemera's `c_string.length` counted a byte before checking it, so an empty C string came out one long.
  - L2's controller mapping (`CONTROLLER_REGISTERS_SIZE`) was 4 KiB, an I/O APIC's; it's 64 KiB, a GICv3
    distributor's, now.

## Alternatives considered
- **QEMU `virt`'s fixed addresses**: quicker, but the kernel would only boot there until the device tree was read.
- **ACPI's MADT first**: what servers use, but QEMU `virt`'s firmware gives either, and the device tree is what
  most Arm boards have.
- **The PL011's own interrupt** as the test device: a real device, but it shares the console, and its rate depends
  on what's written.
- **Pseudo-NMIs or the ITS now**: masking by priority everywhere, or device and collection tables, before anything
  needs them.

## Consequences
- A5 brings user mode on AArch64: EL0 threads, `svc` system calls, FP and SIMD state, and the tests that need them;
  then M6 resumes for both architectures.
- The PL011's and the GIC's addresses come from the device tree, so the kernel isn't tied to QEMU `virt`; it still
  needs a device tree, until ACPI is read too.
- Limine starting a kernel at EL2 with VHE (base revision 6) is still untested.
