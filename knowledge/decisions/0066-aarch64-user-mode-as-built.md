# 0066: User Mode on AArch64, as Built

Status: accepted
Date: 2026-10-24
Related: `0061` (the plan for AArch64), `0065` (A4), `0023` (eager vector state), `0026` (process start), `0058`
and `0059` (programs), `0047` (fixes found on the way), `../design/system-abi.md`,
`../../docs/specs/arch_interface.md` (AArch64), `../roadmap.md` A

## Context
AArch64's last stage (A5, `0061`): EL0 threads, system calls, floating-point and SIMD state, and everything M5
built on them, so every boot test that applies runs on both architectures, before M6 resumes for both. The
system ABI said AArch64 gets x86-64's rules "with its own registers", which needed choosing, as did how a
thread's FP and SIMD registers are switched.

## Decision
Chosen with the project's owner:
- **System calls**: `svc #0` with the number in `x8`, up to six arguments in `x0` to `x5`, and results in `x0`
  (0 or the error variant's tag), `x1` and `x2`, every other register kept, as x86-64's `rax`, `rdx` and `r8`.
- **FP and SIMD state, eagerly**: `v0` to `v31`, `FPCR` and `FPSR` saved at every switch away from a user thread
  and restored on the way back, as `0023` does with XSAVE on x86-64. Floating point stays enabled
  (`CPACR_EL1.FPEN`), and the kernel, built without it, never touches those registers.

As built:
- **In Hemera**: `aarch64.system_call`, answering in `x0` to `x2`, and `save_fp_simd` and `restore_fp_simd`, which
  write the `q` registers' loads and stores as encodings, since the kernel's target has no floating point for the
  assembler to accept them; `base`'s SlopOS runtime and `std/os/slop_os`'s stubs make their calls per
  architecture; `slop_os.THREAD_REGISTERS` is 34 on AArch64 (`x0` to `x30`, `sp`, `pc`, `pstate`).
- **In the arch layer** (`user.hsc`, `vector.hsc`): user registers in the `RegisterFrame`, `return_to_user` with the
  kernel stack's top, the debugger's view of the registers (user mode may only change `pstate`'s condition flags),
  and 528 bytes of vector state. SVE's larger state isn't kept yet.
- **Programs for AArch64**: the build package's `arch` setting builds the programs too, at the baseline, and the
  ELF loader takes this architecture's machine and relative relocation (`R_AARCH64_RELATIVE`). The root task
  starts, maps `hello.elf`, and ends as on x86-64.
- **Boot tests**: every one runs on both architectures but BIOS, x86-64's baseline and the NMI (`0065`), with
  AArch64's own baseline check: 52 in all.
- **Found on the way, fixed (`0047`):**
  - The kernel copied a thread's registers for a debugger through a 32-entry buffer, enough for x86-64's 18;
    AArch64's 34 ran past it and corrupted the debugger's page. It's 64 now.
  - `test_devices` told the driver its controller was an I/O APIC whatever the test device was, and read QEMU's
    HPET, which only x86-64 machines have; it passes the test device's kind and reads a device each architecture's
    emulator has (the PL011's peripheral ID on AArch64). `test_threads` and `test_control` read x86-64's vector
    state and registers by their places; those are per architecture now.
  - A5's test device, re-raised the moment it was acknowledged, stormed: the driver never ran. It's driven by the
    generic timer's physical timer now, about a thousand a second, as x86-64's PIT is.

## Alternatives considered
- **The number in the `svc` immediate**, or in `x16` as Apple's kernel has it: the first needs every stub's number
  to be a compile-time constant and the kernel to read it from ESR; the second leaves `x8`, the indirect-result
  register, alone, which no system call uses.
- **Lazy FP switching**, trapping first use: less copying for threads that never use FP, at a trap per first use
  and per-CPU tracking of who owns the registers.

## Consequences
- AArch64 is done (`0061`); M6 resumes, for both architectures: 6c (the process manager) and 6d.
- SVE and SME state, pointer authentication, BTI and the Guarded Control Stack, MSIs through the ITS, NMIs, ACPI
  for ACPI-only machines, and EL2 with VHE are still to come, each when something needs it.
