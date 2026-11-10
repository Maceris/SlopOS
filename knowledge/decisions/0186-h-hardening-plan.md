# 0186: H, Hardening, Planned

Status: accepted, chosen with the project's owner; built, Ha to He
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

## As Built: Ha
- **The test path** is the one found above. `boot.py --kvm user@address` boots x86-64 in QEMU with KVM there, with
  `-cpu host`: the image, and every local file a QEMU argument names, copied up, and disks and the serial output
  copied back; a boot that needs the console's sockets is refused. `boot_tests.py` runs `KVM_TESTS` through it when
  `SLOPOS_KVM_HOST` is set, and says it left them out otherwise. A kernel boots there in about two seconds.
- **The features**: `X86ShadowStack` (44) and `X86Ibt` (45) from CPUID leaf 7, `Aarch64Gcs` (85) from
  `ID_AA64PFR1_EL1`.
- **The boot log** (`arch_interface.log_hardening`, on the boot CPU after `init_cpu`): the control-flow integrity
  mechanisms, the transient-execution issues that apply and those that don't, and the mitigations on. On x86-64 the
  issues are `IA32_ARCH_CAPABILITIES`' (every one taken as applying without it, as under TCG); on AArch64, Spectre v2
  and Meltdown by `CSV2` and `CSV3`. Enhanced IBRS is set by `init_cpu` on each CPU where `IBRS_ALL` says it's there,
  recorded in `../design/arch-x86-64.md`.
- **What the three machines say**: TCG's x86-64 has no CET, and no `IA32_ARCH_CAPABILITIES`; QEMU's AArch64 `max` has
  BTI, PAC and GCS, and neither issue; KVM on the i9-12900K has shadow stacks and not IBT, is affected by speculative
  store bypass, TAA, MMIO stale data, BHI and PBRSB, not by Meltdown, MDS, GDS and RFDS, and runs with enhanced IBRS.
- **Tests:** "boots and halts" checks each architecture's control-flow line under TCG; "KVM: has CET's shadow stacks"
  checks a KVM guest's.
- **Found on the way:** "AArch64: catches a CPU that stops making progress" timed out once among the other tests and
  passed alone; it's timing-sensitive under TCG's load, and was kept as flaky. Hemera's `Hosted.DescribesWhileInserting`
  failed once while the boot tests loaded the machine, and passed alone and in a full run after.

## As Built: Hb
- **The option** is `TargetOptions.control_flow_integrity` (`--control-flow-integrity`), on ELF targets for x86-64
  and AArch64. SlopOS's build turns it on for the kernel, the programs and the libraries. It sets LLVM's module flags,
  which also write the ELF's `.note.gnu.property` (x86-64's `IBT` and `SHSTK`; AArch64's `BTI`, `PAC` and `GCS`),
  and on AArch64 each function's attributes: `branch-target-enforcement`, `sign-return-address=non-leaf` with the A
  key.
- **The resume loop's problem, solved in LLVM.** A re-entered frame returns through the loop, so on AArch64 the loop
  has to sign its own return address as the frame's prologue signed the one it replaces: with the stack pointer at the
  frame's entry. Outside Darwin, LLVM puts the frame record below the other callee-saved registers, so that stack pointer
  isn't at a fixed distance from the frame pointer. Hemera's LLVM patch 0004 (`"frame-record-at-top"`) gives Hemera
  functions Darwin's order, which puts it at the top: the entry stack pointer is always the frame pointer plus 16. The
  hand-written frames follow the same rule: morestack's now keeps its saved limit, segment, `x19` and `x20` below its
  frame record, and the stack check's small frame signs its return address too (patch 0006, on 0003). So
  `fiber_reenter` signs with `frame + 16` (`PACIA1716`), and the loop authenticates each continuation against the frame
  that returned (`AUTIA1716`); both are hints, which do nothing without pointer authentication.
- **Landing pads after calls**, where the loop's indirect branch lands, came from nowhere: Hemera's docs said the
  compiler put `endbr64` there, but nothing did. Patch 0005 (`"landing-pads-after-calls"`) puts `endbr64` or `bti j`
  after every call, and makes an address-taken block `bti jc`, since morestack calls a function's body with `blr`.
  The hand-written sequences have theirs: the fiber switches, morestack, the foreign shims, and on x86-64 each
  interrupt's stub and SYSCALL's entry.
- **The Guarded Control Stack** in the fiber switches: `CHKFEAT` (a hint) says whether the thread has one; if so, its
  pointer is kept when the scheduler switches in, and the fiber's entries above it are popped with `GCSPOPM` when it
  switches out.
- **Stack walks** (`capture_stack_trace`) strip return addresses' authentication codes, for a 48-bit address space.
- **Tests:** Hemera's `Freestanding.BuildsKernelWithControlFlowIntegrity` (`endbr64` at the interrupt stubs, SYSCALL's
  entry and the fiber switches) and `Freestanding.NotesControlFlowIntegrity` (a SlopOS program's note). With nothing
  turned on until Hc, SlopOS's suites check the code still runs, the new AArch64 frame layout included.

## Found Before Hc: AArch64's Timeouts
After Ha and Hb, AArch64 tests timed out now and then among the others and passed alone. With the owner, they were
looked into with less load, and `boot.py` now asks QEMU where each CPU was when a boot times out (`info registers -a`
through its machine protocol), which caught one:
- **About one AArch64 boot in 512 had no console, and went nowhere.** The bootloader put the direct map a random number
  of GiB up, and when that was the last GiB of a 512 GiB region, QEMU's `virt` UART and GIC, below RAM, fell under an
  empty top-level page-table entry, which the kernel's `map_early_device` can't map through, so it went without its
  console, and the boot idled for good. Pinning the offset there failed every time. The bootloader now never puts the
  direct map within 4 GiB below a 512 GiB boundary (`direct_map_offset`). Some 125 AArch64 boots a suite made it show
  in about one run in five, as if it were load.
- **A stray IRQ in AArch64's kernel code was taken as if from idle**, which never returns, abandoning what it
  interrupted. Under 12h's priority mask, only the NMI is meant to reach the kernel, but a signal raised just before the
  mask, or withdrawn before it's taken, can come anyway, as Linux expects. The entry now looks at what's pending
  (`ICC_HPPIR1_EL1`) and takes only the NMI there, leaving anything else pending. Nothing was seen to fail this way.
- **`test_memory`'s large pages read their saving from the budget**, which memory freed by the test before can lower
  while it's read. It measures up to three times now, failing only if large pages never save anything.
- The earlier note that the lockup test is timing-sensitive is withdrawn: with these, the suites ran without a flaky test.

## Found in Hc: Code Mapped From the Bundle Store
The chaos test, at seed 6163708234096652301 (`test_chaos_seed`), killed `bundle_store` and then `clock`, and five
services crashed at once with execute faults in their own images. `0094` had the process builder map a program's
read-only segments straight from the memory its file is in, shared between processes; for a program from the bundle
store that's the store's paged memory, so once the store had ended, a page of code not touched yet couldn't be paged in.
It broke `0181`'s F6, that no service maps memory another process owns. Chosen with the owner: every segment is mapped
from the process's own image now. That costs nothing: the image held every segment already, as `elf_loader.load`
copies them all, and was charged for them; sharing only left those pages unmapped. Typed libraries are still mapped
from their grants, but those are the root task's boot modules, which the kernel owns. The same seed passes on both
architectures.

## As Built: Hc
- **Faults.** `FAULT_SHADOW_STACK`, `FAULT_LANDING_PAD` and `FAULT_AUTHENTICATION`, decoded from x86-64's control
  protection exception (its error code saying which) and AArch64's GCS, BTI and FPAC exceptions, named in crash reports.
- **Pointer authentication (AArch64).** Each process has a random key, loaded as its threads return to user mode; the
  kernel has its own, loaded as each CPU first goes idle. Both are loaded where no frame below returns: a key or
  `SCTLR_EL1.EnIA` changed under a signed frame fails it, which the first try did, in the helper that loaded them.
  The kernel ran with the user's key after an entry from user mode until Hd. Stack walks strip authentication codes:
  the kernel's samples and lockup reports, crash reports and the debugger.
- **Branch target identification (AArch64).** The ELF loader reads a program's property note (`PT_GNU_PROPERTY`), and
  maps its code with `PROTECTION_GUARDED`, AArch64's GP bit, when it has landing pads. Typed libraries' code isn't
  guarded: base's loader doesn't read their notes.
- **Shadow stacks.** `thread_create` starts a thread at once, and `thread_create_in` has no argument words left, so a
  shadow stack can't be given with either. Instead a process says what its code was built for and gives a region of its
  address space (`process_set_control_flow`, call 93), which the process manager and the root task's loader do from the
  note, from the top of the free range; each thread made in it from then on gets a shadow stack there before its first
  instruction, 64 KiB under a guard page, made and mapped by the kernel, given back when the thread ends. Its memory is
  found through its mapping, not kept in the thread, which keeps `Thread` under 1 KiB on AArch64. Its pointer is read
  as the thread enters the kernel and loaded as it leaves. A shadow stack's pages map on any absent read or write, as not
  every architecture says the access was the shadow stack's, and refuse ordinary writes once mapped.
  - x86-64: `CR4.CET` (with `CR0.WP`), `IA32_U_CET` and `IA32_PL3_SSP`, pages read-only and dirty. Under KVM, every
    program runs on shadow stacks and a tampered return is refused. Indirect branch tracking (`ENDBR_EN`) is set where
    the CPU has it, which no machine here has: built, not boot-tested.
  - AArch64: the Guarded Control Stack needs its pages marked through permission indirection (FEAT_S1PIE), so every
    mapping moved to it: `PIR_EL1` and `PIRE0_EL1` give each index `leaf_entry` makes its permissions, writable entries
    set DBM (an index bit), GCS pages are index 0xb, and `TCR2_EL1.PIE` goes on as a CPU first switches to the
    kernel's own tables. `GCSPR_EL0` and `GCSCRE0_EL1` (with `nTR`, as the fiber switches read the pointer) per thread.
    A GCS page needs AP[2] clear, which the first try left set. Every program runs on a GCS; a write to it is refused.
- **Budgets.** A shadow stack is charged to its thread's budget: 64 KiB, its memory object's bookkeeping (some 8.6 KB)
  and, for the first, up to three pages of page tables. So a program has what it was given for itself, its launcher
  adds `slop_os.shadow_stacks_budget` to the budget it splits off (`launch_given`, the root task's loader): for its
  first thread, and for the runtime's lifecycle thread where it's given a lifecycle channel, which every supervised
  service is. That second thread was missed at first, and on AArch64 `disk_check` ran out of budget partway through
  reading a clone back; threads a program makes itself are its own to pay for.
- **Tests.** `test_control`'s copies tamper with a return address, branch into a function's middle, and write to their
  shadow stack: refused on AArch64 by PAC, BTI and GCS, skipped under TCG's x86-64; under KVM, the tampered return is
  refused by the shadow stack. The chaos test found the bundle store's shared code (above).

## As Built: Hd
- **AArch64.**
  - *Signed returns with the kernel's own key*: `exception_entry` loads it on every entry from user mode, in its body,
    and puts the user's back, read from the registers as they were, before it returns on the one path that does (a
    pseudo-NMI from user mode): its own frame was signed with the user's key.
  - *Landing pads*: the kernel image's code is mapped guarded (GP) where the CPU has BTI, GP being reserved without it.
  - *A Guarded Control Stack for each CPU's kernel stack*, 16 KiB in the kernel window between guard pages,
    permission indirection's index 0xa (`PIR_EL1`'s GCS). The kernel never returns into frames it left, so as SP_EL1
    starts again from its top in idle and `return_to_user`, so does `GCSPR_EL1`, and `GCSCR_EL1.PCRSEL` goes on
    there; exceptions push nothing. The kernel's fibers share it, as Hb's switches pop their entries.
- **x86-64: indirect branch tracking only**, `IA32_S_CET.ENDBR_EN` where the CPU has IBT, built and not tested, as no
  machine here has it. Supervisor shadow stacks were left for FRED, chosen with the owner: SYSCALL's entry and
  `return_to_user`, Hemera's assembly, would need `SETSSBSY`, unwinding to the token and `CLRSSBSY`; every entry goes
  through the interrupt stack table, whose token is busy while the kernel runs, so a fault in kernel code would become
  a double fault, losing its name; and KVM here doesn't set `CET_SSS`, which says they're safe in a virtual machine.
- **Tests**, on the command line at the boot CPU's second tick, after it's gone idle: `test_tamper` (a tampered
  return), `test_branch` (a branch into a function's middle) and `test_shadow_write` (an ordinary write to the kernel's
  shadow stack) each stop the kernel with the fault named on AArch64 (`--expect-line-start`, new in `boot.py`), and
  say they're skipped on x86-64 under TCG and KVM.
- **Found on the way: the kernel window could overlap the direct map.** It kept clear of the direct map's offset plus
  how many bytes of RAM it maps, but QEMU's AArch64 virt has RAM from 1 GiB, so the direct map reaches further. Without
  KASLR the window always overlapped it; with KASLR now and then. Nothing was mapped in the window early enough to
  show it until the kernel's shadow stacks were. It now keeps clear of the highest physical address mapped.

## As Built: He
- **Fixtures for property tests** (Hemera's `testing.fixture`): a volume's image costs far more to make than a case
  takes to run, and Hemera has no mutable globals, so a property test can ask its runner to keep something from its
  first case to its last, made once and released after, in `hemera --test`'s runs, its shrinking, and `hemera --fuzz`.
  Each case puts it back as it found it.
- **Hosted fuzz targets**, each a property test `hemera --fuzz` guides by coverage, and runs 100 random cases of in
  the unit tests:
  - FAT's and slopfs's (plain and encrypted) mount paths: up to 16 byte changes where the structure is, or slopfs's
    three ways of damage, drawn, on a volume set up once; the seeded fuzzers stay.
  - The ELF loader: hello.elf with up to 16 bytes changed, most in its headers, read, and loaded and relocated if it
    reads (`SLOPOS_PROGRAMS` says where it is, as `hemera --fuzz` gives no argument).
  - Every protocol's validators (`src/protocols/test`): any bytes, as any protocol's request or response with any
    number of handles, judged without reading outside them and the same way twice. For that, Hemera's channel,
    message and protocol code builds on every OS now, std's protocol packages too; launching stays SlopOS's. That a
    message accepted encodes back the same, which the plan asked, isn't checked: it needs code generated per protocol.
  - AML's three property tests, as they were.
  - `tools/fuzz.py` builds and runs each for `SLOPOS_FUZZ_SECONDS` (60 by default), keeping each target's corpus and
    findings under `SLOPOS_FUZZ_FOLDER`. Ten seconds each found nothing; the validators run some 35,000 cases a second,
    the encrypted volume 10, its key derived at each mount.
- **The system call fuzzer** (`src/tests/test_fuzz_syscalls`):
  - *Coverage*: Hemera's `TargetOptions.coverage` instruments a build as `--fuzz` does; the build's `coverage=on`
    turns it on for the kernel, and `coverage_take` (call 94; ABI 13, with Hc's call 93) copies its counters to the
    caller and zeroes them. A call rather than a mapping: a take a few hundred thousand times a run is cheap, and the
    counters needn't be page-aligned or shared.
  - *Calls*: from the ABI table, each argument word drawn by its parameter's type, which a compile-time table gives:
    a handle mostly of the kind its parameter takes, from objects the fuzzer made under a budget of its own; scratch
    memory between unmapped ranges, or addresses no user mapping has; numbers at and past limits; a wait's deadline
    milliseconds off. Calls that would end it, start code in it, change its own thread or what it measures aren't made.
  - *Guidance*: inputs that reach a new bucket of a kernel counter's hits are kept and changed. In 20 seconds it makes
    some 450,000 calls and reaches some 3,000 of the x86-64 kernel's 12,851 counters; without coverage counters every
    input is drawn afresh.
  - *Checks*: the kernel survives, and the root task finds the fuzzer's budget back to nothing and only the kernel's
    objects left. Boot tests run it on both kernels, with and without counters, on both architectures;
    `SLOPOS_FUZZ_SECONDS` lengthens it, and `fuzz_seed` replays a run's draws (its timing aside). A run under
    `robustness=on`, which the plan asked, isn't in the suites yet.
  - *Open*: while it was being built, two runs of some fifty ended early: once killed (`EXIT_KILLED`, a fault or a
    kill of its own process) and once on a failed assertion (134), without the logs that would say where. Forty runs
    since, the same seeds among them, passed; a boot test that fails prints the whole log, so the next will show it.

