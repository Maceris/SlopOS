# Kernel Entry on AArch64 and RISC-V

Status: **open**, needed after M3 (`../decisions/0022`). x86-64 was adopted 2026-10-13 as
`#calling_convention(.entry)` and `.syscall_entry`, with `x86_64.RegisterFrame`, `entry_points`
and `return_to_user`; Hemera's `docs/calling_convention.md` (*Entry Functions*) and
`base/intrinsics/x86_64` are the reference. This keeps how the SlopOS kernel uses it, and the
same pattern for the other architectures. Raised by `../design/layers.md` (L1) and
`../../docs/specs/arch_interface.md` (*Entry Stubs*).

## How the SlopOS Kernel Uses It

| Arch interface | x86-64 implementation |
|---|---|
| `UserRegisters` | `x86_64.RegisterFrame` |
| Interrupt, exception and fault entry | One `.entry` function, installed for all 256 vectors through `entry_points`. It decodes `frame.vector` into `kernel_entry.interrupt`, `user_fault` or `kernel_fault` |
| NMI, machine check, double fault | Separate `.entry` functions on IST stacks; the NMI one returns |
| `SYSCALL` | A `.syscall_entry` function calling `kernel_entry.syscall` |
| `return_to_user` | `x86_64.return_to_user` |
| Vector state | `xsavec`/`xsaveopt` and `xrstor` with the thread's mask; `xsetbv` when the mask changes (`0023`) |
| `hardware_entropy` | `rdseed` |

The arch layer is then written entirely in Hemera, with no assembly file.

## Other Architectures

The same four pieces, with the frame and instructions each architecture has:

| | AArch64 | RISC-V |
|---|---|---|
| Frame | `x0`–`x30`, `sp_el0`, `elr_el1`, `spsr_el1`, `esr_el1`, `far_el1` | `x1`–`x31`, `sepc`, `sstatus`, `scause`, `stval` |
| Entry table | An intrinsic generating the 2 KiB-aligned `VBAR_EL1` table (16 entries) from a handler | `stvec` in direct mode: one entry path, swapping the stack through `sscratch` |
| Return | `eret` | `sret` |
| Instructions | `mrs`/`msr`, `tlbi`, `dsb`/`isb`, `wfi`, `rndr` | `csrr`/`csrw`, `sfence.vma`, `wfi`, `seed` |

`mrs`, `msr` and the CSR instructions encode the register as part of the instruction, so the register
is a compile-time argument, passed through generics like `x86_64.entry_points`' handler (Hemera's
`docs/types.md`, *Compile-Time Parameters*). They're needed when AArch64 starts, after M3 (`../decisions/0022`).

## Open Questions

- **CET shadow stacks in the kernel:** the entry and return paths would need to switch shadow
  stacks too, if the kernel ever enables them (`../open-questions.md`, deferred until M4).
