# 0064: SlopOS Boots on AArch64, as Built

Status: accepted
Date: 2026-10-24
Related: `0061` (the plan for AArch64), `0062` and `0063` (Hemera on AArch64), `0032` (the arch interface),
`0005` (missing parts are listed), `0029` (house rules), `0021` (KASLR), `0047` (compiler fixes),
`../../docs/specs/arch_interface.md` (AArch64), `../roadmap.md` A

## Context
AArch64's third stage (A3, `0061`): SlopOS's kernel built for AArch64, booted by Limine through UEFI on QEMU's
`virt` machine, with an arch package behind the arch interface: the PL011 as the early console, exception
vectors and the MMU. Interrupts, the timer and the other CPUs are A4, and user mode A5, but the kernel's boot
path uses them as soon as its own address space is up, and Hemera checks every function in the kernel's
packages, so the code that calls them has to compile on AArch64 even where it won't run.

## Decision
Chosen with the project's owner:
- **Stop after memory**: each arch package says how far it goes with `TAKES_INTERRUPTS`, and where it's false
  the kernel stops once its own address space, heap and console are up, after running the tests that need only
  those (`kernel.stop_before_interrupts`). What A4 and A5 bring is listed in `NOT_YET_IMPLEMENTED`, as stubs
  that stop the CPU.
- **The architecture is a setting**: the build package's `arch` (x86_64 by default, or aarch64), `boot.py
  --arch`, and `boot_tests.py` builds both kernels and runs the AArch64 subset too.

As built:
- **`src/arch/aarch64`**: features from the ID registers and the baseline check (ARMv8.2-A with LSE: floating
  point, Advanced SIMD, the LSE atomics, RDM and PAN); `init_system` and `init_cpu` (the vector table, PAN, FP
  trapping, `MAIR_EL1`, 16-bit ASIDs); one `.entry` function decoding ESR into the portable faults, `svc` and
  SError; paging with `TTBR1` for the kernel and `TTBR0` with an ASID for each address space; the PL011; and
  `rndrrs`, the virtual counter, and semihosting for `test_exit`. The arch interface spec has its table.
- **The house rule on `NOT_YET_IMPLEMENTED`** (`0005`, `0029`): a listed function may also be a stub in the
  package's `not_yet_implemented.hsc`. One defined anywhere else is "there now", and a stub there that isn't
  listed is an error, so the list stays true either way.
- **`early_console_init(direct_map_offset)`**: the arch interface's one change. Limine's direct map covers memory
  only, so the PL011's registers are mapped there, at the direct map's address for them, in Limine's tables as a
  Device block in the first gap, and again in the kernel's own by `init_kernel_page_table`, with two frames from
  `kernel_half_frames`. L2's window already stays clear of the direct map, so nothing can collide with it. With
  no global state in L1, the console's address is in `TPIDR_EL1` until `init_cpu`, then in the `ArchCpu`.
- **The kernel stack**: Limine's base revision 6 starts the kernel with all of PSTATE clear, `PSTATE.SP` included,
  so it runs on `SP_EL0`, and every exception taken to EL1 switches to `SP_EL1`, which Limine leaves pointing
  anywhere. `init_cpu` sets `SP_EL1` to the kernel stack's top (Hemera's new `aarch64.write_sp_el1`), so the boot
  stack and the kernel stack are what they are on x86-64.
- **The Limine adapter**: AArch64's MP structures (the MPIDR as each CPU's hardware ID), no x2APIC flag, and its
  own linker script. The kernel target is `-fp-armv8,-neon`.
- **`boot.py --arch aarch64`**: `qemu-system-aarch64 -M virt -cpu max` with edk2's AArch64 firmware, the ISO on a
  SCSI CD, Limine's `BOOTAA64.EFI`, and semihosting. `test_exit` ends QEMU with `(code << 1) | 1`, as the debug
  exit device does on x86-64, so a code still reads apart from QEMU's own exit.
- **Boot tests on AArch64** (8): boots, sets up memory and halts; a kernel fault, a failed assertion, read-only
  code and the heap; a CPU below the baseline (`cortex-a57`); and KASLR on and off. Every x86-64 test still runs.
- **Found on the way, fixed (`0047`):** Hemera compiled compile-time code reaching AArch64's instructions, through a
  constant holding the early logger, for the machine compiling it, which the assembler refused; another
  architecture's instructions are traps in compile-time code now, and an error elsewhere. That error then found
  Hemera's own `libc` test calling `x86_64.syscall` on AArch64, which now makes the call per architecture.
  `std/os/slop_os`'s `system_call` had nothing for other architectures, which only matters once user mode does.

## Alternatives considered
- **Stubs on the boot path** (every interface function present, the A4/A5 ones stopping when reached): the boot
  would end at the first one, the timer, before anything worth testing, unless the boot path changed anyway.
- **Building both architectures every time**: the house rules would check both each build, at about twice the
  kernel's build time.
- **A fixed kernel address for the console** instead of its direct-map address: it would need an address L2's
  window and the image could never take, which L2 doesn't know about.
- **Leaving the kernel on `SP_EL1`**, switching to it at entry: there's no way to move a running function's stack,
  and Limine's `SP_EL1` isn't known to be valid.

## Consequences
- A4 drives the GICv3, the generic timer's interrupts and the other CPUs, takes their names off
  `NOT_YET_IMPLEMENTED`, and makes `TAKES_INTERRUPTS` true; `idle` will `eret` to a wait loop on the kernel stack,
  so an interrupt from idle starts at its top.
- The PL011's address is QEMU `virt`'s; real hardware's comes from the device tree or ACPI's SPCR, later.
- Limine may start a kernel at EL2 with VHE where the firmware runs there (base revision 6); QEMU without
  virtualization starts it at EL1, which is all that's tested.
- Seen once each while testing, not reproduced: the compiler crashing (0xC0000005) on one x86-64 kernel build, and
  x86-64's `test_memory` boot test failing once and passing on four reruns. The compiler crash is being hunted with
  the Debug build (`hemera-feedback.md`).
