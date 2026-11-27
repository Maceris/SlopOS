# 0199: M19, RISC-V, Planned

Status: accepted
Date: 2026-11-24
Related: `0022` (RISC-V third), `0061` (A's plan, the pattern), `0135` (SlopOS's bootloader), `0026` (the carrier
register), `0081` (VT-d), `0197` (RISC-V chosen next), `../hemera-proposals/kernel-entry.md`, `../roadmap.md`
M19

## Context
`0022` made RISC-V the third architecture, and `0197` made it M19, planned with the owner on A's pattern once the
bounds checker was built. The system is much bigger than when A was planned. Back then the x86-64 layer was 2,300
lines with M6 half built. Now the AArch64 layer is about 4,700 lines, 53 files outside it name AArch64, and there are
user space, drivers, the IOMMU, shadow stacks, graphics and audio.

What's there:
- **QEMU 11.1** has RISC-V's `virt` machine, edk2's RISC-V firmware (over OpenSBI), the AIA (APLIC and IMSIC) as well
  as the PLIC, the RISC-V IOMMU (`riscv-iommu-pci`, and a platform one), virtio-gpu and virtio-sound. Its CPUs take
  Sv48, Sv57, Sstc, Svpbmt, Zkr, Zicfilp, and Zicfiss with Zimop.
- **Hemera's LLVM (24)** has the RISC-V backend, which lowers both CFI extensions. It isn't built: only X86, AArch64
  and ARM are.
- **The Linux machine** has `qemu-riscv64` user mode with binfmt already.
- **Limine** has `BOOTRISCV64.EFI`.

What isn't:
- **No Hemera code is generated for RISC-V yet.** Its `Architecture` enum names `riscv64` and nothing more.
- **The prologue stack check** is a Hemera patch to LLVM for X86 and AArch64 only.
- **`morestack`, fibers, and entry and interrupt functions** are assembly for the other two.
- **SlopOS's bootloader** (`0135`) is a UEFI program, a PE file, which Hemera links with lld. LLVM has no RISC-V COFF
  writer and lld no RISC-V PE, so it can't be built for RISC-V as it is for the others.

## Decision
Chosen with the owner (2026-11-24):
- **The baseline is RVA23** (RVA23U64 and RVA23S64), like x86-64-v3 and ARMv8.2-A with LSE: vectors, Zicond, Sstc's
  S-mode timer, Svpbmt and Zimop are assumed. Shadow stacks (Zicfiss) and landing pads (Zicfilp) are optional in it,
  so they're used where the CPU has them, found by feature checks, as PAC and BTI are.
- **Hemera writes the UEFI program's PE itself.** lld links a position-independent ELF whose only relocations are
  relative, and Hemera turns it into a PE32+ EFI application, its relocations as base relocations, as edk2's GenFw
  does. The bootloader is then the same on all three architectures, generations and randomization included.
- **Both interrupt controllers, the AIA and the PLIC.** The AIA takes interrupts as messages, as GICv3's ITS does, and
  the IOMMU remaps them. The PLIC is what most boards shipped so far have. Each is a configuration of QEMU's `virt`
  that's tested.
- **The IOMMU and CFI are M19's last stage**, so RISC-V matches the other two before M20.

In seven stages:
- **R1, Hemera on RISC-V, hosted.**
  - LLVM rebuilt with the RISC-V backend.
  - The carrier register, a callee-saved one reserved, chosen and documented in R1.
  - The prologue stack check, as an LLVM patch for RISC-V (a trap and `morestack`, as for AArch64).
  - `morestack`, fibers and stack traces in RISC-V assembly.
  - Linux on riscv64 in `base`: its startup, system calls and threads.
  - RVA23U64 as the default target features.
  - Hemera's Linux tests run as riscv64 programs through user-mode QEMU, a third architecture in `linux_tests.py`.
- **R2, Hemera for a RISC-V kernel.**
  - Trap entry functions: `stvec` direct, the trap frame, `sret` to U-mode.
  - CSR intrinsics, the CSR a compile-time argument (`csrr`, `csrw`, `csrrs`, `csrrc`).
  - Fences, `sfence.vma`, `wfi`, and `ecall` to SBI, in `base/intrinsics/riscv64`.
  - The ELF-to-PE writer, with UEFI on riscv64 in `base`.
  - A freestanding test, and a UEFI program built and run under edk2.
- **R3, SlopOS boots on RISC-V.**
  - `arch_riscv64` behind the arch interface.
  - SlopOS's bootloader on QEMU `virt` through edk2 and OpenSBI.
  - The 16550 UART, found in the device tree, as the early console.
  - Traps, and Sv48 paging with Svpbmt's memory types.
  - The build package and `boot.py` taking `riscv64`, and the first boot tests.
- **R4, interrupts, time and SMP.**
  - The AIA (APLIC and IMSIC) and the PLIC, each found in the device tree, each boot-tested.
  - Sstc's `stimecmp` as the timer.
  - The other harts started through SBI's HSM.
  - IPIs through the IMSIC, or SBI's on a PLIC machine.
  - TLB shootdown by IPI and `sfence.vma`, since RISC-V has no broadcast invalidation.
  - Device interrupts and the kernel window.
- **R5, threads and user mode.**
  - U-mode threads and `ecall` system calls.
  - FP and vector state, saved as the other two save theirs.
  - The scheduler and M5's objects.
  - virtio over PCI (ECAM, from the device tree).
  - Every boot test that applies, on all three architectures.
- **R6, the IOMMU and CFI.**
  - The RISC-V IOMMU's DMA and MSI remapping, as `0081` did for VT-d and D did for SMMUv3.
  - Zicfiss shadow stacks for user and kernel, enabled through SBI.
  - Zicfilp landing pads in Hemera's code.
  - Boot tests that each catches what it should, testable under TCG.
- **R7, a review**, as M16 to M18 had.

## Alternatives considered
- **RVA22**: reaches more of the boards sold so far. Without assured vectors or Sstc, the kernel needs SBI's timer
  as a fallback, and CFI can't count on Zimop.
- **Limine on RISC-V**: works already, but RISC-V would boot differently from the others, without generations or
  randomization until the bootloader was ported.
- **Booting through OpenSBI alone** (QEMU's `-kernel`, no UEFI): the simplest start, but nothing like how the other
  two boot, nor real RVA23 boards with UEFI.
- **The AIA only**: one interrupt driver and one QEMU configuration, but most boards shipped so far couldn't run it.
- **The IOMMU and CFI later**: M19 ends sooner, and RISC-V trails the other two in what they guard against.

## Consequences
- Each stage gets an "as built"; `design/arch-riscv64.md` is written with R3.
- LLVM's build grows by its RISC-V backend. The next LLVM build takes longer, and so does every one after.
- The arch interface may change again where it still assumes x86 or ARM: interrupts that are messages only, a
  broadcast TLB invalidation.
- The device tree package reads RISC-V's nodes: harts, the AIA, the PLIC, the 16550.
- `../hemera-proposals/kernel-entry.md`'s RISC-V half is R2.
- The boot tests run three times over. A full run is about half as long again.

## As Built: R1 (2026-11-25)
- **LLVM** builds its RISC-V backend. Three patches of Hemera's: the prologue stack check (0007, a trap or `morestack`),
  quoted symbols in RISC-V assembly's `call` and `la` (0008), and a fix for instruction selection looping forever on
  an AND mask with Zba or Zbs (0009), found compiling `std/ntp`.
- **The carrier register is `s11`.** RVA23U64's features are the default, with the LP64D ABI.
- **`morestack`, fibers and stack traces** are RISC-V assembly. A suspended fiber keeps 112 bytes, or 224 with
  floating point. Assembly in the module that uses D or V turns them on itself, since LLVM reads module assembly with
  no features.
- **Linux on riscv64 in `base` and `std/os`:** startup, the generic system call table, threads through `clone`, and
  linking C (LP64D's foreign calls, `ld-linux-riscv64-lp64d.so.1`). The thread carrier is local-exec thread-local
  storage in an executable, since RISC-V's linker doesn't relax general-dynamic as the others' do.
- **Tests:** Hemera's Linux tests run as riscv64 programs through user-mode QEMU on the Linux VM, 83 of 83, `libc`
  against a sysroot from Debian's `libc6-riscv64-cross`.

## As Built: R2 (2026-11-25)
- **Trap entry:** `#calling_convention(.entry)` on RISC-V is what `stvec` points at, in direct mode. `sscratch` is the
  hart's `riscv64.TrapScratch` in U-mode and 0 in S-mode; the entry swaps it with `tp`, so a trap from U-mode runs on
  `TrapScratch.kernel_stack` with `tp` pointing at the `TrapScratch`. A trap from S-mode builds its frame on the stack
  it was on. `riscv64.RegisterFrame` is `x0`–`x31`, `sepc`, `sstatus`, `scause` and `stval`, 288 bytes. The entry
  clears `SUM`. `return_to_user(frame, scratch)` sets `sscratch` and returns with `sret`. So SlopOS's per-hart data
  can start with its `TrapScratch`, and `tp` finds it.
- **`base/intrinsics/riscv64`:**
  - `csrr`, `csrw`, `csrrw`, `csrrs` and `csrrc`, the CSR a compile-time `riscv64.Csr`;
  - `fence` with its access kinds as compile-time arguments, `fence_i`, and `sfence_vma` in four forms;
  - `wfi`, `pause`, `ebreak` and `seed`;
  - `read_tp` and `write_tp`;
  - `sbi_call`, `enter` for the bootloader, `semihosting`, and `system_call` answering in a0–a2;
  - `sstatus`'s bits and `scause`'s codes as constants.
- **The ELF-to-PE writer:** a RISC-V UEFI application is linked by `ld.lld` as a position-independent ELF, each
  segment on pages of its own from 0x1000. Hemera makes the PE32+ image from it: a section per segment, with the
  segment's protection; base 0; relative relocations as DIR64 base relocations. edk2 applies each section's
  protection. Debug info isn't kept, so a bootloader's stack traces can't be symbolized yet.
- **A kernel's features** are `-f,-d,-zve32x,-zvl32b`, which takes out every vector extension RVA23 implies. Without
  D or F the ABI is LP64. A kernel above 2 GiB needs `--code-model=medium` (`medany`).
- **Tests:**
  - Hemera's `freestanding_tests.py` boots a RISC-V kernel under OpenSBI on QEMU's `virt` (`rva23s64`). It turns on
    Sv39, takes an S-mode breakpoint, runs three U-mode `ecall`s (returned by `sret` and through `return_to_user`),
    reads a U page with `SUM` set, calls the SBI, and ends at the stack check's trap.
  - Every function in `base` and `std` generates for that target.
  - A UEFI application runs under edk2 (`edk2-riscv-code.fd`), finds its image base, and turns the machine off.
  - HemeraTest reads the image back as a PE.

## As Built: R3 (2026-11-25)
- **`src/arch/riscv64`** (`../design/arch-riscv64.md`; the arch interface spec has its table): features from the
  device tree and RVA23's baseline, `init_system` and `init_cpu`, one `.entry` function in `stvec`, Sv48 paging with
  Svpbmt's memory types, the device tree's 16550 as the early console, the SBI's system reset, semihosting for
  `test_exit`, and Zkr's `seed` for entropy. What R4 to R6 bring is listed in `NOT_YET_IMPLEMENTED`, 47 stubs that stop
  the hart, and `TAKES_INTERRUPTS` is back, as A3 had it: false on RISC-V, so the kernel stops once its own address
  space, heap and console are up, after the tests that need only those. `src/iommu/riscv` drives no IOMMU kind until
  R6, so the platform service's registration of one fails.
- **The arch interface's one change: `detect_features` takes the firmware's tables.** Supervisor mode can't read
  `misa` or probe an extension, so a hart's features are the device tree's (`riscv,isa-extensions` or `riscv,isa`, and
  `mmu-type`). x86-64 and AArch64 ignore them. RISC-V's `CpuFeature`s are 128 to 191 in `std/os/slop_os`.
- **Exceptions in the kernel run on the DoubleFault critical stack.** A trap's frame goes on the stack it came from, so
  the stack check's `ebreak` on a full stack would trap again in the handler. The entry instead rewrites the frame and
  returns, its `sret` landing in `kernel_trap` on the critical stack; the interrupted `s0` and `ra` stay, so the stack
  trace goes through the faulting code. Each stack's limit leaves room below it for the 288-byte frame as well as the
  guard. The kernel never faults on purpose, as it reaches user memory through the direct map.
- **Paging:** one root for both halves, the kernel half shared by copying its 256 top-level entries, as on x86-64. A
  non-leaf entry has no spare bits, so `unmap` looks for a second valid entry rather than keeping a count. A and D are
  always set (Svade); `take_accessed` is false. `map` fences each new entry on the calling hart.
- **The bootloader on RISC-V:** `BOOTRISCV64.EFI`, built without vector extensions, which edk2 leaves off; Sv48 tables
  for the identity map and the direct map; `riscv64.enter`; the boot hart alone, by `RISCV_EFI_BOOT_PROTOCOL`'s ID (in
  `std/os/uefi`), until R4 starts the others; and it refuses a device tree whose `mmu-type` has no Sv48.
- **Found on the way:** edk2 installs the device tree's configuration table in its pool, whose memory its own
  allocations reuse while the bootloader reads files, so the tree was zeros by the time it was read. The bootloader
  now copies the tree into its own pages before anything else, on every architecture.
- **Sv48 isn't in RVA23S64**, which mandates only Sv39, and QEMU's `rva23s64` has only Sv39. The baseline keeps Sv48,
  decided with this plan; the tests run `rva23s64,sv48=on,zkr=on`, Zkr being optional in RVA23 too, and needed for the
  kernel window's randomness.
- **`boot.py --arch riscv64`** boots on `virt` through edk2 (`edk2-riscv-code.fd`, a copy of the variables), the
  kernel alone, as RISC-V has no user space yet; `boot_tests.py` builds the RISC-V kernel and bootloader and runs 8
  tests: boots and stops before interrupts; a kernel fault; a failed assertion; read-only code; the heap; a CPU without
  V refused by the kernel's check; and KASLR on and off. The bootloader's refusal of a CPU without Sv48 was checked by
  hand: the firmware then goes on to its next boot option, so a test could only wait out its timeout.
- **Left for R4:** another hart may fault on a kernel mapping just made, before Svvptc's bounded time; R4 retries such
  a fault rather than stopping.

## As Built: R4 (2026-11-25)
- **Both controllers, found in the device tree:** the AIA where there's an IMSIC with supervisor files (`riscv,imsics`
  taking external interrupt 9) and the APLIC whose `msi-parent` it is; else a PLIC. Each hart is found by its interrupt
  controller's cpu node (the device tree package's new `parent_reg_of`).
  - **With the AIA every interrupt is a message**, as on x86-64: the kernel's device interrupt IDs are each hart's IMSIC
    identities (16 up), claimed through `stopei`; MSIs are the hart's file and the ID, with nothing kept per device; the
    APLIC delivers its lines by message, its target the hart's IMSIC index and the ID; and IPIs are identities 1 to 3
    written to the target's file.
  - **With the PLIC** the IDs are the kernel's own (32 to 255), routed from lines as AArch64 routes SPIs; the claimed
    line is completed at `end_of_interrupt`; there are no MSIs; and IPIs are the SBI's `sbi_send_ipi`, their kinds kept
    in the target's `ArchCpu`, each taken as an interrupt of its own.
- **The arch interface's one change: `init_cpu` takes the CPU's hardware ID.** Supervisor mode can't read its hart's
  ID, which the PLIC's contexts and the IMSIC's files are by. x86-64 and AArch64 read theirs and ignore it.
- **Timer:** Sstc's `stimecmp`, at `/cpus`' `timebase-frequency`.
- **Idle:** `sstatus.SIE` and `wfi`. An interrupt in supervisor mode only comes while idle, and its entry, like an
  exception's, rewrites the frame and returns, its `sret` landing in `idle_interrupt` on the kernel stack's top, as an
  entry from idle starts on x86-64's IST.
- **The other harts:** the bootloader starts every cpu node's hart by the SBI's HSM at a trampoline, which loads
  `satp`, takes its stack, clears `tp` and waits on its mailbox, as the other two park their CPUs.
- **Stale page faults** (R3's leftover): a kernel page fault on an address the tables now allow is fenced and retried,
  as another hart may have made the mapping after this one walked it. The check runs in the entry, before there's a
  context.
- **The test device:** with the AIA, the APLIC's last source, pended through `setipnum`; with the PLIC, which can't pend
  a line in software, the UART's transmitter interrupt, armed at each tick and taken back at `end_of_interrupt`.
- **Tests:** `boot.py --aia` boots `virt,aia=aplic-imsic`. `boot_tests.py` runs 21 RISC-V tests: on the PLIC and again
  on the AIA, booting and halting with boot memory reclaimed, every hart started (4), the clock, idle harts' ticks
  stopping, TLB shootdown, a binding slot read while it's remade, an object's ownership raced, and the test device's
  interrupts routed through the wired controller; and R3's five (a kernel fault, a failed assertion, read-only code, the
  heap, a CPU without V) once.
- **Left for R5:** device interrupts reach drivers through user space, so MSIs and wired lines from real devices are
  first used there; and the stale-fault retry for user pages, which return through `return_to_user`.

## As Built: R5 (2026-11-26)
- **User mode** (`src/arch/riscv64/user.hsc`): threads in U-mode, `ecall` system calls (the number in `a7`, arguments
  in `a0` to `a5`, results in `a0` to `a2`), the entry moving `sepc` past the `ecall` and `restart_syscall` back;
  `return_to_user` through `riscv64.return_to_user`, `sscratch` the hart's `TrapScratch`, `sstatus` made a user one
  each time. A debugger sees `x0` to `x31` by number, then `pc`: 33 registers (`slop_os.THREAD_REGISTERS`).
- **Floating-point and vector state**, switched eagerly as on the other two: `f0` to `f31` and `fcsr`, then the vector
  registers and `vstart`, `vtype`, `vl` and `vcsr`, by Hemera's new `riscv64.save_floating`, `restore_floating`,
  `save_vector` and `restore_vector`, which turn D and V on for their own instructions, as a kernel is built without
  them. `sstatus.FS` and `VS` are off in the kernel and on, Initial, in user mode.
- **Accessed bits kept by software** (`take_accessed`): under Svade an access through a leaf whose A bit is clear
  faults, and the trap entry sets it and makes the access again, as it does for a stale entry; so the pager's working
  sets work as on the others.
- **A trapped read of the time CSR** (`set_counter_trap`, scounteren's TM) is decoded as a Protection fault, as x86-64's
  and AArch64's are, so the kernel emulates it (`emulate_counter_read`, `rdtime`'s `rd`) and recording works.
- **No hardware debugging yet:** `set_debug` takes nothing but no slots and no stepping. RISC-V's triggers are the SBI's
  debug triggers extension's (Sdtrig), which isn't driven yet, so the debugger's breakpoints, steps and watchpoints
  don't run on RISC-V.
- **User space on RISC-V:** every program, library and test builds for RVA23U64. In Hemera's `base`, SlopOS's runtime
  takes riscv64 (its system calls through `riscv64.system_call`, and typed libraries as `EM_RISCV` with
  `R_RISCV_RELATIVE`), and `std/os/slop_os`'s system call stubs and `THREAD_REGISTERS` do too. In SlopOS: crash
  reports, the kernel's samples and the debugger's fiber walk read RISC-V's frame records 16 bytes below `s0`
  (`crash_reports.FRAME_RECORD_BELOW`), and a suspended fiber's continuation at 104; recording names RISC-V's call
  registers; `library_interface` takes a library's relative relocation type by its machine; the platform service finds
  the Goldfish RTC, which the clock service drives (its new `rtc_goldfish` grant).
- **Devices** are virtio over PCI, the host bridge's ECAM from the device tree, as on AArch64. Their MSIs need the AIA,
  so the RISC-V boot tests with programs run on `virt,aia=aplic-imsic`; the PLIC's are the kernel's own tests.
- **Found on the way:**
  - A fiber's first stack segment was 1 KiB, too little on RISC-V, whose frames save twelve callee-saved registers
    and `ra`, for a kernel fiber that allocates (a kernel's fibers can't grow). Hemera's `FIBER_INITIAL_STACK_SIZE` is
    1536 on RISC-V.
  - edk2's console on RISC-V's virt, with no display device, was only its serial terminal, which wraps lines at 80
    columns, and a program's first line short, from where the firmware's own messages left the cursor. `boot.py` gives
    virt QEMU's `ramfb`, as x86-64's q35 has its VGA, which makes the console 100 columns; Hemera's UEFI runtime starts
    a program's first output on a line of its own when the console's cursor isn't at column 0; and the bootloader's
    longest line, about a kept panic record, is shorter.
  - The bootloader's command line editor let go of held keys for a fixed half second; on a slow machine more came
    after. It now waits until half a second passes with none.
  - RISC-V's debug files are about twice the others' (198 MiB for every program), so a boot disk with them gets 256 MiB
    more for them on RISC-V.
  - R4's test device was pended at each of the kernel's timer interrupts on the hart that started it; but the kernel's
    tickless, and with that hart idle, under a loaded host, a driver saw 1 interrupt in two seconds. It has a deadline
    of its own now, as AArch64's has a timer of its own, the hart's compare the earlier of the two.
  - `boot_tests.py` said how many tests there were, not how many `SLOPOS_BOOT_TESTS` chose, and always ran the address
    tests; it counts what runs and chooses those too.
- **Tests:** 149 RISC-V boot tests pass: the PLIC's 8, every test of `TESTS` that applies on the AIA, the address
  tests, and a CPU without V. Left out, with why, in `boot_tests.py`'s `RISCV_LEFT_OUT`: x86-64's baseline; the NMI and the two
  lockup tests, as RISC-V's supervisor has no NMI to send; the power button, which virt hasn't; DMA outside a domain,
  the IOMMU's (R6); and the four that need hardware breakpoints, steps or watchpoints. Without a power button,
  `--end-when-done` can't end a run early, so a test waits for the root task's settle, with 90 s more.
- **Left for R7:** in the whole RISC-V suite, two tests stalled among the others and passed alone: the GUI login,
  its input stopping after the terminal started, just after `device interrupt 16 arrived, routed from nothing`, and
  SSH, whose scp never connected after sftp. Both look like a device's interrupt lost under load; x86-64's KVM audio
  test logged the same warning once when it was flaky. R7 looks for why an MSI comes to a hart with no route.

## As Built: R6 (2026-11-26)
- **The RISC-V IOMMU** (`src/iommu/riscv`), as SMMUv3's is: first-stage Sv48 tables for each domain, iohgatp Bare,
  the domain ID its PSCID; 47-bit I/O addresses, Sv48's lower half, as a device's addresses aren't sign-extended; a
  two-level device directory, its leaves made as devices are attached; the command queue (`IOTINVAL.VMA`,
  `IODIR.INVAL_DDT`, `IOFENCE.C`) and the fault queue, which L2 reads at CPU 0's ticks. It remaps no interrupts:
  MSIs are translated as other DMA (msiptp Off), and L2 maps the harts' supervisor interrupt files into each domain.
- **`arch_interface.msi_doorbell` gives pages** (`MsiDoorbell`, an address and a count): RISC-V's are the IMSIC's
  files, from the lowest hart's to the highest's, where AArch64's ITS has one page. A device behind the IOMMU can
  still raise any identity on any hart, as the IMSIC keeps nothing per device; only the IOMMU's MRIF mode would, which
  isn't driven.
- **The platform service** takes a RISC-V IOMMU from the host bridge's `iommu-map` as it takes an SMMUv3, a platform
  device (`riscv,iommu`) by its reg or a PCI function (`riscv,pci-iommu`) by its BAR 0, which it makes the function
  decode and master, and gives no client.
- **QEMU's IOMMU**, three things found:
  - `virt`'s `iommu-sys` is turned off whenever there's a dynamic sysbus device, as `ramfb` is, after the device was
    made, so it's there but left out of the device tree. `boot.py` gives `virt` the PCI one (`riscv-iommu-pci`, at slot
    0x1f, so no other device moves), on in bare mode at reset (`off=false`), as edk2 doesn't drive it.
  - Its walk (11.1) checks U on every entry, a table's too, as a request without a process ID is user mode's; so the
    tables' entries have U set, which the privileged spec reserves, and later QEMUs ignore. It also takes a page's PPN
    with its PBMT bits, so the pages have no PBMT, the PMAs making the interrupt files device memory.
  - Its translation cache keeps a page with the permission of the access that first used it, so a device that read a
    page first had its writes to it dropped: `boot.py` turns the cache off (`ioatc-limit=0`).
- **Zicfilp's landing pads**, in Hemera: `lpad 0` at every function's entry that can be reached indirectly and after
  every call, the call aligned so its landing pad is at a 4-byte boundary (Hemera's LLVM patch 0010, from LLVM's own
  `returns_twice` call), and in the generated assembly: the switches' entries, the foreign shims', morestack's, and
  where the resume loop re-enters. In the kernel from `init_cpu`, the SBI's FWFT `LANDING_PAD`; in user mode for each
  thread whose program has them (`senvcfg.LPE`).
- **Zicfiss's shadow stacks**, in Hemera: `sspush ra` and `sspopchk ra` in every function that saves its return
  address (LLVM's `hw-shadow-stack`); the fiber switches keep `ssp`, as AArch64's keep the GCS, and `fiber_reenter`
  pushes the loop's return. In the kernel, a shadow stack for each hart from L2, turned on (FWFT `SHADOW_STACK`) at its
  first idle or return to user mode, in those functions' own bodies, since a function that returned across it would
  check a return that was never pushed; user mode's for each thread (`senvcfg.SSE`). A hart has one `ssp` for every
  mode, so the trap entry keeps user mode's in the `TrapScratch` and starts the kernel's from its top, and returning
  puts it back (Hemera's `TrapScratch.kernel_shadow_stack` and `user_shadow_stack`).
- **QEMU's `sspopchk`** (11.1) is run wrongly: its translation updates the pc it tracks only where the check fails,
  so after one that passes the rest of the translation block takes its pc from the wrong instruction, a pc-relative
  branch's or `auipc`'s, or the block's own end where it doesn't end in a jump. The supervisor's `start_terminal`,
  whose epilogue ended at a page boundary, was found running that epilogue a second time, reading its caller's frame,
  and stopped by its shadow stack; the services crashed so in most boots. QEMU has since updated the pc where the check
  passes too. Every RISC-V target with shadow stacks is built with Hemera's LLVM's `branch-to-sspopchk`
  (`build.hsc`'s `RISCV_FEATURES`; LLVM patch 0011), a `beq zero, zero, .+4` to each epilogue's `sspopchk`, which ends
  QEMU's block so the `sspopchk` begins the next. An earlier reading blamed `c.sspush` and built without Zcmop, which
  only moved code until the bug hid; that's undone.
- **Budgets:** std's `slop_os.shadow_stacks_budget`, which a launcher adds to the budget it was asked for, counted
  CET's and the GCS's shadow stacks but not Zicfiss's, so on RISC-V every program had 76 KiB a thread less than it
  was given: the disk check's clone test ran out growing a file's bytes past 128 KiB. It counts Zicfiss now.
- **The linker:** RISC-V's property note (`CFI_LP_UNLABELED`, `CFI_SS`), which the ELF loader reads to give a process
  its landing pads and shadow stacks, is kept by lld only where it knows it: lld 19, Visual Studio's, drops it, and the
  program then runs without either. The lld Hemera's own LLVM builds (its `lld` target) keeps it; it has to be the
  `ld.lld` on the PATH for RISC-V builds. Hemera's build cache now keys a program by the linker it finds too, as one
  built with the other lld was taken from the cache.
- **Not yet:** the IOMMU's interrupt remapping (MRIF), and hardware debugging (the SBI's debug triggers).
- **Tests:** the DMA test runs on RISC-V; the kernel's three control-flow tests (a tampered return refused by the
  shadow stack, a branch to no landing pad, a write to its shadow stack, an access fault on RISC-V) and a boot on a CPU
  without either; and `test_control`'s three in user mode, its hardware debugger test skipped on RISC-V.
