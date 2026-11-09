# 0186: H, Hardening, Planned

Status: accepted, chosen with the project's owner
Date: 2026-11-09
Related: `0003` (the CPU baseline), `0013` (the threat model), `0019` (AES detected at boot), `0023` (cheap threads,
user space owns stacks), `0096` (robustness), `0097` (lessons adopted: the transient-execution boot log), `0088` and
`0182` (the filesystem and AML fuzzers), `../open-questions.md` (*Kernel*: hardware control-flow integrity),
`../hemera-proposals/kernel-entry.md`, Hemera's `docs/multitasking.md` and `docs/calling_convention.md`,
`../roadmap.md` H

## Context
The roadmap's H has three items: the decision on hardware control-flow integrity, fuzzers as test programs, and a boot
log of transient-execution issues. A survey found:
- **Hemera** designed its fibers to work under hardware control-flow integrity: every transition is a real call
  matched by a real return, fibers share their carrier thread's shadow stack, and the x86-64 switch already reads and
  unwinds it (`RDSSP`, `INCSSP`), which does nothing without shadow stacks. But nothing emits landing pads (`endbr64`,
  `bti`), signs return addresses, or uses AArch64's Guarded Control Stack; `calling_convention.md` lists the fiber
  resume path under pointer authentication and GCS as not done.
- **SlopOS** detects AArch64's PAC and BTI and enables neither; it doesn't detect x86-64's CET or AArch64's GCS. Its
  kernel logs nothing about transient execution.
- **Fuzzing:** Hemera has coverage-guided fuzzing of property tests on hosted targets (`hemera --fuzz`). SlopOS's FAT,
  slopfs and AML fuzzers are seeded mutation tests without coverage. Nothing fuzzes the system call table, the
  protocols' validators or the ELF loader.
- **Testing:** QEMU emulates AArch64's PAC, BTI and GCS (its ARM emulation list has `FEAT_PAuth`, `FEAT_BTI` and
  `FEAT_GCS`), so they can be boot-tested. Its TCG doesn't emulate CET ("TCG doesn't support requested feature" for
  `cet-ss` and `cet-ibt`). The build machine's i9-12900K has CET, and QEMU here has the WHPX accelerator, which isn't
  usable until Windows' Hypervisor Platform is turned on.

## Decision
Chosen with the project's owner:
- **Every mechanism the hardware has**: on AArch64, BTI, PAC and GCS; on x86-64, IBT and shadow stacks. For user space
  and for the kernel. Each is detected at boot, as AES is (`0019`), since none is in the baseline (`0003`), and turned
  on where it's there.
- **x86-64's are tested through WHPX first**: the owner turns on Windows' Hypervisor Platform, and H's first stage
  checks whether a guest sees CET and boot-tests through it if so. If not, the fallback is chosen then: real hardware,
  a nested hypervisor, or x86-64's left untested.
- **All four fuzzers, coverage-guided**: the protocols' validators, the filesystems' mount paths and the ELF loader as
  hosted property tests under `hemera --fuzz`; the system call table from a SlopOS test program, guided by the
  kernel's coverage. Short runs in the suites, longer ones on demand.

Decided here:
- **Shadow stacks and GCSs are the kernel's to make**, at `thread_create`, as special pages in the thread's address
  space charged to its memory budget, sized by the creator (0 for a default of 64 KiB, 8192 return addresses). It's
  the one exception to "user space owns stacks" (`0023`): user code can't write them, so it can't make them. Fibers
  have none of their own: they use their carrier's, as Hemera designed, so the default is per carrier, not per fiber.
- **A process runs with what all its code was built for**: the process builder reads each ELF's properties
  (`GNU_PROPERTY_X86_FEATURE_1_AND`, `GNU_PROPERTY_AARCH64_FEATURE_1_AND`), its libraries' too, and asks for the
  mechanisms all of them have; a program without them runs without, logged. Everything SlopOS builds has them.
- **PAC keys are per process**, made at random by the kernel and switched with the address space, so a fiber resumed
  on another carrier authenticates; the kernel has its own, made each boot. The modifier is the stack pointer. Stack
  walkers (the kernel's samples, crash reports, the debugger, `capture_stack_trace`) strip the authentication code.
- **Code pages are guarded** for BTI where the ELF says so: `memory_map` gains a protection bit for it.
- **New faults** for a control-flow violation (x86-64's `#CP`, a BTI exception, a failed authentication, a GCS
  fault), decoded as their own `Fault` kinds, so crash reports name them.
- **The transient-execution log** is `0097`'s: which issues apply to the CPU (`IA32_ARCH_CAPABILITIES`, the speculation
  CPUID bits, AArch64's `CSV2`, `CSV3` and `SSBS`) and which mitigations are on. Only those that cost close to nothing
  are turned on (enhanced IBRS, set once, where `IBRS_ALL` says it's there), as `0013` allows; its scope is unchanged,
  and each is recorded in `../design/arch-x86-64.md`, or for AArch64 in `../../docs/specs/arch_interface.md`.

In five stages, each with an as-built record here:
- **Ha, the x86-64 test path and the boot log.**
  - `boot.py` boots through WHPX when asked, and a boot test checks the guest's CPUID for CET. Whether SlopOS boots
    under WHPX at all is part of finding out. If CET isn't seen, the fallback is chosen with the owner before Hc.
  - CpuFeatures gains `X86ShadowStack`, `X86Ibt` and `Aarch64Gcs`; the kernel logs which mechanisms the CPU has.
  - The transient-execution log and enhanced IBRS.
- **Hb, Hemera.** Landing pads (`endbr64`, `bti c`) at every function's entry and indirect target; return addresses
  signed (`PACIASP`, `AUTIASP`); the ELF property notes; and the hand-written sequences made to match: the fiber
  switch and resume (`fiber_reenter` signing what it stores with the frame's modifier, the fiber's GCS entries popped
  with `GCSPOPM`), `morestack`, the C function value shim, and the `.entry` and `.syscall_entry` stubs. Each behind a
  setting, on for SlopOS, the GCS and shadow-stack instructions run only when the carrier has one (as `RDSSP`
  reading 0 does now). Tested by the compiler's own tests on what it emits, then through Hc.
- **Hc, user space.** Detection and enabling per CPU; per-process enabling from the ELF properties; kernel-made shadow
  stacks and GCSs at `thread_create`; the CET user state (XSAVES' `CET_U`) and the GCS pointer and PAC keys switched
  with threads and processes; guarded code pages; the new faults; stack walkers stripping PAC. Tested by a program
  that overwrites its return address, and one that calls through a pointer to a function's middle: each ends in its
  fault, named in its crash report; and by the suites passing with everything on.
- **Hd, the kernel.** The kernel built with landing pads and signed returns, with its own keys; shadow stacks or GCSs
  for each CPU's kernel stack and its critical-event stacks (x86-64's supervisor shadow stacks, with their tokens and
  `IA32_INTERRUPT_SSP_TABLE` for the IST), switched by the entry paths, which `kernel-entry.md`'s open questions
  left for this. Tested by a kernel test, on the command line, that calls through a corrupted pointer and stops with
  the fault named.
- **He, the fuzzers.**
  - The protocol generator makes a property test for each protocol's validator: any bytes in, never a read outside
    the message, and what it accepts encodes back the same. Fuzzed under `hemera --fuzz`.
  - The slopfs and FAT fuzzers, the ELF loader and the AML interpreter as property tests, fuzzed the same way; their
    seeded runs stay in the suites.
  - The system call fuzzer: a SlopOS test program making calls from the ABI table with arguments drawn by type (its
    own handles, its own memory, sizes near limits), on a kernel built with coverage counters (a setting, as
    `robustness=on` is) that the program reads through a memory object to keep inputs that reached new code. It
    checks the kernel survives and every budget is back at the end, under `robustness=on` too.
  - Short runs in `unit_tests.py` and the boot tests; `SLOPOS_FUZZ_SECONDS` for longer ones. What they find is fixed
    and kept as a regular test, as R's findings were.

## Alternatives considered
- **User space only:** the kernel is the most valuable target, and its entries are Hemera's own code to change.
- **A shadow stack per fiber:** Hemera's design shares the carrier's, at no memory cost per fiber; a hardened mode
  with one per fiber stays possible later (`multitasking.md`).
- **Software control-flow integrity in Hemera** (checked indirect calls): costs on every call where the hardware
  costs next to nothing, and doesn't protect returns.
- **Building x86-64's untested, or deferring it:** WHPX may make it testable on this machine; decided after trying.
- **Random fuzzing only:** the validators and mount paths have deep checks a random input rarely gets past, which is
  what coverage finds.

## Consequences
- `thread_create` and `thread_create_in` gain a shadow-stack size; `memory_map` a guarded bit; `Fault` new kinds;
  CpuFeatures three features; the system call table and spec change.
- Hemera emits landing pads and signed returns for SlopOS, and its fiber and entry sequences change for every target
  that enables them.
- A Hemera program that's suspended stores signed return addresses; debuggers and crash reports strip them.
- The open question on hardware control-flow integrity (`../open-questions.md`) is answered here.
- AArch64's kernel tests run with BTI, PAC and GCS on, as QEMU's `max` CPU has them; x86-64's depend on Ha's finding.

## The x86-64 Test Path, Found (2026-11-09)
Ha's first step, done with the owner before the rest of Ha:
- **WHPX doesn't give CET.** With Windows' Hypervisor Platform on, QEMU's WHPX guest is refused `cet-ss` and `cet-ibt`
  ("host doesn't support requested feature"): Hyper-V on Windows 10 gives guests no CET. It also put VMware on Hyper-V,
  where VMware's guests lose CET too, so it was turned off again.
- **VMware gives its guests shadow stacks, not IBT.** The i9-12900K has both (VMware's log: the host's CPUID leaf 7
  with both bits), but VMware clears IBT from every guest's CPUID, even with a `featMask` asking for it.
- **Nested KVM gives a guest shadow stacks.** The Linux test VM, with VMware's nested virtualization on
  (`vhv.enable`), a backports kernel (7.2: KVM offers guests `cet_ss` and the CET state; Debian's 6.12 doesn't), and
  QEMU 11.1 from backports (10.0 has no CET), runs a guest with `-cpu host,+cet-ss,enforce`; SlopOS boots there to a
  healthy system.

So, chosen with the owner:
- **x86-64's shadow stacks are boot-tested through QEMU with KVM in the Linux VM**: `boot.py` gains a remote mode, as
  `linux_tests.py` has, which copies the image there and boots it with `-accel kvm -cpu host`. The CET boot tests run
  there; the rest of the suites stay on TCG.
- **x86-64's IBT is built, and not boot-tested**: Hemera emits `endbr64` (a no-op without IBT), and SlopOS detects IBT
  and enables it where it's there, sharing BTI's design, which is boot-tested on AArch64. A bare-metal check on a
  machine with IBT is left for later, recorded in the as-built record.

