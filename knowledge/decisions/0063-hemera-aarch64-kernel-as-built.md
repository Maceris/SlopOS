# 0063: Hemera for an AArch64 Kernel, as Built

Status: accepted
Date: 2026-10-24
Related: `0061` (the plan for AArch64), `0062` (A1), `0047` (compiler fixes), `../hemera-proposals/kernel-entry.md`,
`../roadmap.md` A

## Context
AArch64's second stage (A2, `0061`): what an AArch64 kernel needs from Hemera, before SlopOS boots on it in A3.
`../hemera-proposals/kernel-entry.md` outlined it: a frame type, `.entry`, a vector-table intrinsic, a return to
user mode, and system-register instructions with the register as a compile-time argument. How those look, and
how the stage is tested, were left to choose.

## Decision
Chosen with the project's owner:
- **System registers by name, as a compile-time enum argument**: `aarch64.read_system_register(.VBAR_EL1)` and
  `write_system_register(.TTBR0_EL1, value)`, with `SystemRegister`'s values the registers' encodings, and
  `read_system_register_encoded(op0, op1, crn, crm, op2)` and its write for registers it doesn't name.
- **One entry function for all 16 vectors**: `aarch64.vector_table(handler)` gives the 2 KiB-aligned table for
  `VBAR_EL1`, and the frame records which entry it came through. `svc` arrives there as a synchronous exception
  from EL0, so AArch64 has no `.syscall_entry`.
- **Tested by booting**: a freestanding program runs in `qemu-system-aarch64` and takes real exceptions.

As built, in Hemera:
- **`aarch64.RegisterFrame`**: `x0` to `x30`, `sp_el0`, `elr`, `spsr`, `esr`, `far` and the entry's index, 304
  bytes. Each table entry makes the frame's room on `SP_EL1`, saves `x0` and `x1`, and branches to the entry
  function's code, which saves the rest, clears the frame pointer and calls the body. A body that returns gets
  the frame restored and `eret`.
- **`aarch64.return_to_user(frame, kernel_stack)`**: restores a frame and `eret`s, with the stack pointer put at
  `kernel_stack` first. AArch64 has no TSS, so the stack pointer at `eret` is where the next exception's frame
  goes, which is why it takes one; x86-64's takes only the frame.
- **The rest of `base/intrinsics/aarch64`**: `daif_set` and `daif_clear`; `dsb` and `dmb` with a `BarrierDomain`,
  and `isb`; `tlbi_*` (by VA, last level, all ASIDs, by ASID, all, local and inner shareable); `dc_*`, `ic_*` and
  `at_*`; `wfi`, `wfe`, `sev`, `sevl`; `rndr` and `rndrrs`; `brk`; and `semihosting`, which ends QEMU with an exit
  code as x86-64's tests do through `isa-debug-exit`.
- **The test** (`apps/compiler/test/freestanding_tests.py`): on QEMU `virt`, at EL1, it turns the MMU on with an
  identity map and maps its own image again for EL0, then takes a breakpoint it returns from, three system calls
  from EL0 (answered by the entry function returning and through `return_to_user`), and a stack check that traps.
  It also generates every function in `base` and `std` for that target. The kernel target is
  `-fp-armv8,-neon,+strict-align`: no floating point or SIMD, which trap until `CPACR_EL1` enables them, and
  aligned accesses, since memory is Device memory until the MMU is on.
- **Found on the way, fixed (`0047`):** AArch64's baseline features were put after a target's own, so `+v8.2a`
  turned floating point back on for a target that had turned it off; the baseline comes first now. QEMU starts an
  ELF at its entry, and the compiler makes that the entry function, but a kernel on QEMU needs a stack first: the
  test's linker script writes four instructions that set one, and QEMU's generic loader starts there.

## Alternatives considered
- **A function per system register** (like x86-64's `read_cr3`): dozens of functions, and nothing for the ones
  left out. **The raw encoding only**: covers everything and reads worst.
- **A handler per exception kind**: four functions to write and pass, to save the kernel one branch on the kind.
- **Building and inspecting only**, like x86-64's freestanding test: faster, but the entry code wouldn't run until
  A3.

## Consequences
- A3's `arch_aarch64` uses these as they are: `UserRegisters` is `aarch64.RegisterFrame`, interrupt and fault entry
  one `.entry` function decoding `vector` and ESR, and `return_to_user` takes the thread's kernel stack top.
- SlopOS's kernel target on AArch64 is no FP/SIMD, as on x86-64; `+strict-align` matters only for code before the
  MMU is on, which Limine has already turned on.
- `../hemera-proposals/kernel-entry.md`'s AArch64 half is done; RISC-V's waits for the third architecture.
