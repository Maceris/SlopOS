# Proposal: Kernel Entry and Return to User Mode

Status: **adopted for x86-64** 2026-10-13, with the names `.entry` and `.syscall_entry`. Hemera's
`docs/calling_convention.md` (*Entry Functions*) and `base/intrinsics/x86_64` are the reference.
Still open: AArch64 and RISC-V (after M3), and compile-time constant arguments (now
`compile-time-parameters.md`, through generics). The rest of this
document is the original draft. Raised by `../design/layers.md` (L1) and
`../../docs/specs/arch_interface.md` (*Entry Stubs*). Logged in `../hemera-feedback.md` as *Kernel
entry and return to user mode*. Needed from roadmap M4 (threads); M1–M3 only need what Hemera
already has.

## Problem

A kernel's entry and exit paths run before and after any normal function can: there's no usable
stack yet, or registers that belong to user code are still live. Hemera has no inline assembly,
by design, and `#naked` was left out because without it a naked body has nothing to contain. Its
one tool here is `#calling_convention(.interrupt)`, whose compiler-generated prologue saves what
the function changes and returns with `iretq`.

That isn't enough for the SlopOS kernel (`../decisions/0032`):

| Need | Why `.interrupt` doesn't cover it |
|---|---|
| **The full user register set** as data, so the kernel can save it in a thread, switch threads, change syscall results, and let debuggers read it | `.interrupt` saves registers only to restore them; the function never sees them |
| **Handlers that never return**, ending in a return to a possibly different thread | `.interrupt` always returns to what it interrupted |
| **One handler for many vectors**, knowing which vector arrived | `.interrupt` is one function per IDT entry, with no vector number |
| **`SYSCALL` entry**: no frame is pushed, the stack pointer is still the user's, so the first instructions must `swapgs` and switch stacks | Not an IDT entry at all |
| **Returning to user mode** with a full register set (`sysretq` or `iretq`) | No way to write it |
| `XSAVE`/`XSAVEC`/`XRSTOR`, `XSETBV`/`XGETBV`, `RDSEED`/`RDRAND`, reading the `gs` base | Not declared in `intrinsics.x86_64` yet |
| AArch64 and RISC-V entry (a 2 KiB-aligned table of 16 entries on AArch64; `stvec` with an `sscratch` stack swap on RISC-V) | `.interrupt` is x86-64 only |

## Proposal

Keep assembly out of the language. Everything here is a fixed, mechanical sequence tied to the
architecture and the calling convention, so the compiler generates it, the way it already
generates prologues, `morestack` calls and `.interrupt` functions. The compiler may use LLVM inline
assembly internally to do that; programs never see it.

Four pieces, shown for x86-64. AArch64 and RISC-V follow the same pattern (*Other
Architectures*).

### 1. A register frame type

`intrinsics.x86_64` declares the layout every generated entry path saves, and every return path
restores:

```
/*
 * The interrupted code's registers, saved by entry paths and restored by return_to_user.
 * Its layout is part of the calling convention version.
 */
RegisterFrame :: struct {
    r15 : u64,
    r14 : u64,
    r13 : u64,
    r12 : u64,
    r11 : u64,
    r10 : u64,
    r9 : u64,
    r8 : u64,
    rbp : u64,
    rdi : u64,
    rsi : u64,
    rdx : u64,
    rcx : u64,
    rbx : u64,
    rax : u64,
    // The vector that arrived, or SYSCALL_VECTOR for a SYSCALL.
    vector : u64,
    // The CPU's error code, or 0 for vectors without one.
    error_code : u64,
    // Pushed by the CPU, or filled in by the SYSCALL entry path.
    rip : u64,
    cs : u64,
    rflags : u64,
    rsp : u64,
    ss : u64,
}

SYSCALL_VECTOR :: 0xffff_ffff_ffff_ffff
```

### 2. `#calling_convention(.entry)`

An **entry function** takes the frame, and may or may not return:

```
user_entry #calling_convention(.entry) :: fn(frame: ptr[mut x86_64.RegisterFrame]) #never_returns {
    // No carrier or context yet: find them, like an interrupt function does
    cpu : ptr[ArchCpu] : cast[ptr[ArchCpu]](x86_64.read_gs_base())
    intrinsics.set_carrier(cpu.carrier)
    push_context cpu.context^ {
        kernel_entry.dispatch(frame)
    }
}
```

Its generated entry path:
1. pushes an error code of 0 if the CPU didn't, and the vector number (see 3);
2. `swapgs` if the interrupted code was in user mode. For the vectors that can arrive anywhere
   (NMI, machine check, double fault), it reads `IA32_GS_BASE` instead of trusting `cs`, the way
   Linux's "paranoid" entry does, since they can arrive between a `swapgs` and the `iretq` after
   it;
3. pushes every general register, completing the `RegisterFrame` on the stack the CPU switched to
   (the TSS's `rsp0` or an IST stack);
4. calls the function with a pointer to the frame. Like an interrupt function, the body has no
   stack check in its prologue, and no carrier or context until it sets them up.

If the function returns (allowed only without `#never_returns`, for NMIs), the generated code
restores the frame and returns with `iretq`, doing the matching `swapgs`.

The SYSCALL entry uses the same convention through a second convention name,
`#calling_convention(.syscall_entry)`, because its first instructions differ: `swapgs`, save the
user `rsp` and load the kernel stack from fixed offsets of the `gs` base, then build a
`RegisterFrame` from the registers (`rip` from `rcx`, `rflags` from `r11`, `vector` =
`SYSCALL_VECTOR`). The fixed offsets are a struct in `intrinsics.x86_64` that the `gs` base must
point at:

```
// What the gs base points at in the kernel, for SYSCALL entry. Must be first in the per-CPU block.
SyscallScratch :: struct {
    kernel_stack : u64,
    user_stack : u64,
}
```

### 3. One handler for every vector

An intrinsic the compiler expands, once per handler, into 256 tiny stubs (push the vector, push a
zero error code where the CPU doesn't, jump to the handler's entry path), and returns their
addresses for the IDT:

```
EntryPoints :: struct {
    addresses : u64[256],
}

// handler must be a constant: the compiler generates its stubs at compile time.
entry_points : fn(handler: (fn(frame: ptr[mut RegisterFrame]) #never_returns)) -> ptr[EntryPoints] : ---
```

The compiler knows which vectors push an error code (8, 10–14, 17, 21, 29, 30), so the frame is
always the same shape. The critical vectors' stubs use the paranoid `swapgs` check.

### 4. Returning, and the remaining instructions

```
/*
 * Restore frame and return to user mode: swapgs, then sysretq when the SYSRET conditions hold
 * (rcx == rip, r11 == rflags, rip canonical), otherwise iretq.
 */
return_to_user #never_returns : fn(frame: ptr[RegisterFrame]) : ---

// The current gs base (rdgsbase with FSGSBASE, otherwise IA32_GS_BASE).
read_gs_base : fn() -> rawptr : ---

// Vector state. mask selects state components (XCR0 bits); area is 64-byte aligned.
xsave : fn(area: rawptr, mask: u64) : ---
xsavec : fn(area: rawptr, mask: u64) : ---
xsaveopt : fn(area: rawptr, mask: u64) : ---
xrstor : fn(area: rawptr, mask: u64) : ---
xgetbv : fn(register: u32) -> u64 : ---
xsetbv : fn(register: u32, value: u64) : ---

// A random value, or null when the CPU had none ready (carry flag clear).
rdseed : fn() -> u64? : ---
rdrand : fn() -> u64? : ---
```

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

`mrs`, `msr` and the CSR instructions encode the register as part of the instruction. That needs
either one intrinsic per register, or a way to require a compile-time constant argument (see
*Open Questions*). They're needed when AArch64 starts, after M3 (`../decisions/0022`).

## Alternatives Considered

- **Inline assembly and `#naked`** (C, Rust, Zig): the most general, and how every other kernel
  does it. But it adds a sub-language with constraint syntax and per-architecture assemblers to
  Hemera, and every block is code that type checking and compile-time checks can't see. The set of
  sequences a kernel needs is small and fixed, so generating them costs less.
- **Assembly files linked through the build** (`TargetOptions` accepting `.S` files, assembled by
  LLVM's integrated assembler): keeps the language unchanged and works for anything. But the
  SlopOS arch layer would no longer be Hemera, which is what the project exists to test, and the
  frame layout would be duplicated between assembly and Hemera. Worth keeping in mind as an escape
  hatch for something nobody anticipated, like a 16-bit CPU startup trampoline.
- **Syscalls through an interrupt gate (`int 0x80`) as a stopgap:** works with today's `.interrupt`
  convention, but `.interrupt` still can't hand over the register frame or switch threads, so it
  doesn't remove the need for entry functions.
- **Extending `.interrupt` instead of adding `.entry`:** `.interrupt` saves only what the function
  changes, which is cheaper for simple handlers in programs that never switch threads. Changing it
  to always build a full frame would make those slower, so the two stay separate.

## Open Questions

- **Constant arguments:** `entry_points` needs a handler known at compile time, and AArch64's
  `mrs`/`msr` need a register known at compile time. A general way to mark a parameter as
  compile-time constant (a `#compile_time` parameter directive?) would cover both, and other
  immediates.
- **Names:** `.entry` and `.syscall_entry`, or names tied to the hardware mechanism (`.trap`,
  `.exception`).
- **CET shadow stacks in the kernel:** the entry and return paths would need to switch shadow
  stacks too, if the kernel ever enables them.
- **Where `SyscallScratch` lives:** this draft requires it at offset 0 of whatever the `gs` base
  points at. An alternative is a `TargetOptions` setting for its offset.
