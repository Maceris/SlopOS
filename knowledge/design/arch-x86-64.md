# Arch Notes: x86-64

What L0 and L1 (see `layers.md`) need to deal with on x86-64. Doubles as a template
for what any later architecture note needs to cover.

## Target Environment

- **Development target:** QEMU `q35` machine, UEFI firmware (OVMF), virtio devices.
  Real hardware later.
- **CPU baseline:** x86-64-v3 (`../decisions/0003-cpu-baseline-x86-64-v3.md`): AVX,
  AVX2, BMI1/2, FMA, F16C, LZCNT, MOVBE, XSAVE on top of v2. Anything newer is detected
  at runtime with `CPUID`; older CPUs are rejected at boot with a clear message.
- **Required features:** NX (for W^X), SYSCALL/SYSRET, APIC, invariant TSC (or fall
  back to HPET/LAPIC timer calibration).
- **XCR0:** enable only x87/SSE/AVX state by default to keep per-thread save areas small;
  AVX-512/AMX are a per-process opt-in (`../decisions/0023`).
- **Use if present:** PCID (cheaper address-space switches), SMEP/SMAP (kernel can't
  execute or casually read user memory), FSGSBASE, x2APIC, RDRAND, AES-NI + PCLMULQDQ + VAES (reported in
  `CpuFeatures`, `../decisions/0019`), 5-level paging (later),
  IOMMU (Intel VT-d / AMD-Vi) — required before untrusted drivers get DMA.

## Boot Path

1. OVMF (UEFI) → Limine.
2. Limine loads the kernel ELF into the higher half at a randomized base (KASLR,
   `../decisions/0021`), sets up long mode, a basic page table,
   and passes the memory map, framebuffer, RSDP, SMP info and modules.
3. Kernel entry (`arch/x86_64`) converts Limine's structures into the portable `BootInfo`
   and calls the portable kernel entry point.

## What `arch/x86_64` Has To Implement

| Piece | x86-64 mechanism | Notes |
|---|---|---|
| Segmentation | GDT with kernel/user code+data, TSS | TSS holds the interrupt stacks (IST) |
| Interrupts | IDT, 256 vectors | Entry stubs must save registers; needs asm or an interrupt calling convention |
| Interrupt controller | Local APIC + I/O APIC (or x2APIC) | Legacy 8259 PIC masked and ignored |
| Timer | LAPIC timer, TSC-deadline if available | Calibrate against HPET or PIT at boot |
| Paging | 4-level page tables, 4 KiB / 2 MiB / 1 GiB pages | NX bit for W^X; PCID for TLB tagging |
| Syscalls | `SYSCALL`/`SYSRET`, MSRs `STAR`/`LSTAR`/`FMASK` | `SWAPGS` to reach per-CPU data |
| Per-CPU data | `GS` base → `PerCpu` struct | Holds the CPU's prebuilt kernel `Context` (`kernel.md` §3). `r14` (the carrier register) is loaded from it on every entry from user mode (`kernel.md` §3) |
| SMP | Limine MP feature now; INIT-SIPI-SIPI later | |
| FPU/SIMD state | `XSAVE`/`XRSTOR`, lazy or eager | Kernel itself should avoid SIMD (see below) |
| Platform discovery | ACPI: RSDP → XSDT → MADT, MCFG, HPET | Parsed in user space (L3), except the bits the kernel needs to start CPUs |

## Compiler Requirements Specific to x86-64 Kernels

- **No red zone** in kernel code (interrupts would clobber it).
- **No SSE/AVX in the kernel** (or save/restore it on every entry), so the kernel is built
  with SIMD features disabled and no floating point. User space targets full v3.
- **Position-independent:** the kernel is a PIE that Limine relocates (and can randomize);
  see `../decisions/0004-position-independent-code.md`. Matches the backend's current PIC default.
- **ELF output + linker script** for section placement and the entry symbol.
- **Instruction access:** `cpuid`, `rdmsr`/`wrmsr`, `in`/`out`, `mov cr0/cr2/cr3/cr4`,
  `invlpg`, `lgdt`/`lidt`/`ltr`, `swapgs`, `rdtsc`, `hlt`, `pause`, `cli`/`sti`,
  `xsave`/`xrstor`, `iretq`, `sysretq`.

All of these are tracked in `../hemera-feedback.md`.
