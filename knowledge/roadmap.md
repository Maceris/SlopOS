# Roadmap

Milestones of real subsystems (see `decisions/0005-scope-real-implementations.md`). Ordered
by dependency. Each lists what gets built, the specs it follows, and **what it stresses in
Hemera**, since that's the actual output of the project.

Layer references (L0–L6) are from `../docs/architecture/layers.md`.

---

## M0 — Foundations (no hardware needed)

Done 2026-10-17. Pure code that everything else depends on, and that can be tested on a host.

- **Build package** for the targets: kernel (`OS == .None`), user space (`OS == .SlopOS`),
  host (tests). Hemera has no build system, so this is a Hemera program registering targets
  through the compiler API in `base/compiler` (Hemera's `docs/compilation.md`, *Build Packages*;
  `decisions/0028`).
- **Hemera `std`**: split into tiers (freestanding / allocating / os); add containers that
  work without an allocator (intrusive lists, fixed-capacity arrays, bitmaps, ring buffers)
  and formatting into a fixed buffer; fix `SharedPtr` to use atomics.
- **Boot protocol types**: the portable `BootInfo` type (`../docs/specs/boot_info.md`) and the
  Limine protocol structures (Limine since replaced by SlopOS's own bootloader, B).
- **Arch interface** (L1 ↔ L2): the `arch_interface` package of `---` declarations that
  `arch/x86_64` must implement (`../docs/specs/arch_interface.md`).
- **House-rule checks**: arch interface conformance and `std` tier
  enforcement, registered with `compiler.add_check` (`decisions/0007`, `0029`).

Specs: Limine boot protocol.
Stresses: generics, `distinct`, `#packed`/`#align`, compile-time layout asserts, build
system in Hemera, compile-time reflection over packages (house-rule checks), tests.

## M1 — Boot to Console (L0, L1)

Done 2026-10-15 (`compiler-plan.md` Phase 6). Building it needed the compiler work in `compiler-plan.md` (Phases 0–6).
Limine, which it booted through, was replaced by SlopOS's own bootloader in B.

- Kernel entry from Limine; convert responses to `BootInfo`.
- `CPUID` check for x86-64-v3; refuse to boot otherwise, with a message.
- GDT + TSS (with interrupt stacks), IDT, exception handlers decoding faults into a
  portable `Fault` union.
- 16550 serial output and a framebuffer text console (PSF2 font parsing, scrolling).
- Kernel `Logger` implementation and an assertion handler (`context.assertion_handler`) that
  prints a stack trace (using `intrinsics.capture_stack_trace`, addresses relative to the
  image base, `decisions/0021`).
- The boot CPU's carrier block and carrier register, set up before any checked function runs,
  and loaded on every kernel entry (`design/kernel.md` §3).

Specs: Intel SDM Vol. 3A (ch. 3, 5, 6, 7), PSF2 font format, 16550 UART.
Stresses: privileged-instruction intrinsics, interrupt calling convention / naked functions,
early-boot context (no allocator yet), `Logger`, formatting without allocation, panics,
the carrier block and prologue stack check in a freestanding build.

## M2 — Memory (L1, L2)

Done 2026-10-22 (`decisions/0048`).

- Physical frame allocator: buddy allocator over the boot memory map, SMP-safe.
- 4-level paging: map/unmap/protect, W^X enforced, NX, global pages, PCID.
- Kernel address-space layout (direct map, kernel image, per-CPU areas), KASLR-ready.
- Slab allocator for kernel objects; general kernel heap implementing Hemera's `Allocator`.

Specs: Intel SDM Vol. 3A ch. 4.
Stresses: the `Allocator` interface for real, bit-packed page table entries, atomics,
`Result` error handling, where state lives without globals.

## M3 — Interrupts, Time, SMP (L1, L2)

Done 2026-10-22 (`decisions/0049`).

- Interrupt controllers registered with the kernel (the platform service reads the MADT, `decisions/0039`;
  the kernel parses no ACPI, `0031`), the I/O APIC, IRQ routing to (later) driver messages.
- Local APIC / x2APIC, TSC calibration, the kernel's monotonic clock. A mapped clock page only as
  `0024`'s opt-in; time goes through a syscall (`0009`).
- The kernel window for device registers (`0049`).
- Bringing up the other CPUs, per-CPU data via `GS`, spinlocks, TLB shootdown.

Specs: Intel SDM Vol. 3A ch. 10–11, Intel x2APIC spec, Intel 82093AA I/O APIC datasheet.
Stresses: atomics and fences, the per-CPU `context.user_data` approach, volatile MMIO.

## M4 — Threads and Scheduling (L2)

Done 2026-10-22 (`decisions/0050`).

- Thread objects (≤ 1 KiB target), XSAVE state, context switch.
- One kernel stack per CPU ("run to completion or record a continuation").
- Per-CPU run queues, CPU budgets (`design/scheduling.md`), idle and preemption.

Spec: `design/threads.md`.
Stresses: tagged unions as continuation state, `defer`, calling convention vs. context
switching, IST stacks and the carrier block's `stack_limit`, how `std`'s thread entry stub
sets up the carrier register (`decisions/0026`).

## M5 — Capabilities and IPC (L2)

Done 2026-10-23 (`decisions/0051` to `0057`), in four stages: the system call path, objects, handles and reclamation;
ports; channels; then memory budgets and memory objects, the platform capability, process control and intercepts, and
the syscall table generated from the ABI package.

- Per-process handle tables, rights, revocation.
- Kernel objects: address space, thread, memory object, channel/endpoint, IRQ, I/O port
  range, MMIO range.
- IPC: shared-ring channels, ports, handle transfer (`design/ipc.md`); syscall
  interception (`design/kernel.md` §4).
- System call ABI; typed message stubs generated at compile time from Hemera types.

Stresses: `distinct` handle types, compile-time code generation from `TypeInfo`/`FunctionInfo`,
relative pointers in shared memory, `Result` across the kernel boundary.

## A — AArch64 (L0, L1, Hemera)

The second architecture (`decisions/0022`, `0061`), started 2026-10-23 with M6 paused after 6b, and done 2026-10-24 (`0062` to `0066`). Baseline
ARMv8.2-A with LSE atomics; QEMU `virt`, edk2 and Limine. In five stages: A1 Hemera on AArch64, hosted (code
generation, the carrier register, the prologue stack check, fibers, Linux in `base`, tested through user-mode
QEMU); A2 Hemera for an AArch64 kernel (entry functions, system-register intrinsics); A3 SlopOS boots (MMU,
exception vectors, PL011); A4 interrupts, time and SMP (GICv3, the generic timer); A5 threads and user mode, with
every boot test on both architectures. M6 then resumes for both.

Stresses: the arch interface's x86 assumptions, Hemera's backend beyond x86, compile-time arguments for system
registers, `TARGET_ARCH` branching.

## M6 — User Space (L2, L4, L5)

- ELF loader with relocations (PIE) and ASLR, shared by the kernel, the root task and the process
  manager.
- Root task / process manager; initial capabilities; the typed boot configuration (`system_config`).
- Syscall library, and the start of the `std` port (`OS == .SlopOS`).
- A debug-log capability, so programs can report before M7's console.

Done 2026-10-24 (`decisions/0058` to `0060`, `0067` to `0069`), in five stages (`0058`, with 6d split in `0068`): 6a
user programs as executables (`base`'s SlopOS runtime, the build package's user targets, the startup block); 6b the
kernel starts the root task; 6c the root task and the process manager, with the early entropy source; 6d the start of
`std`'s SlopOS port, with typed entry points; 6e the user-mode boot tests as programs of their own.

Specs: ELF-64, System V x86-64 relocations.
Stresses: `std` design, the system ABI, the context register at process start.

## M7 — Platform and Drivers (L3)

Done 2026-10-25 (`decisions/0070`, `0071`, `0073` to `0077`): the platform service (ACPI's static tables, PCIe through ECAM, the
virtio-pci transport); virtio-rng, virtio-console, virtio-blk and virtio-input behind the `entropy`, `serial`, `block`
and `input` device-class protocols, generated from Hemera types (`0040`); and the supervisor restarting crashed
drivers, which their clients reach again through connectors (`0077`). In six stages: 7a generated protocols, 7b the
kernel for drivers (MSI-X, DMA memory, firmware tables), 7c the platform service and virtio-rng, 7d virtio-console, 7e
virtio-blk, 7f virtio-input and restarts.

Specs: PCIe base spec, virtio 1.2.
Stresses: volatile MMIO, fences, protocol unions, driver isolation.

---

## After M7

Planned 2026-10-24. **The order is decided** (`decisions/0072`): storage first, with D, the IOMMUs, before it. Each
milestone's stages are decided when it starts. Each milestone's design is in a note in `design/`, which says what
existing systems got wrong and what SlopOS does instead; the choices that need deciding are in `open-questions.md`.
`design/lessons.md` (2026-10-29) adds what those notes missed, and three tracks to run alongside them, decided in
`decisions/0096` (R) and `0097` (Perf, memory pressure, and items placed in the milestones below); its smaller items are
proposed in each milestone's design note. Each stage gets an "as built" record and runs on both architectures.

```
 M7 drivers ─► D IOMMU ─► M8 storage ─► M9 system services ─► M10 console, accounts ─► M11 shell
                                          and software           and sessions             and tools
                                              │                                              │
                                     B bootloader (boot counting)       P power ◄────────────┤
                                                                                             ▼
                                   M16 audio ◄─ M15 GUI ◄─ M14 remote ◄─ M13 network ◄─ M12 debugging
                                                                                         H hardening
```

**What "done" looks like at the end of M11, the first usable system:** SlopOS boots from a disk image, on either
architecture, into a login prompt on the console; a user logs in with a password, which unlocks their encrypted home
volume; a shell runs installed programs, whose typed parameters it turns into command lines, completion and grants;
files survive a reboot, and a crash at any moment leaves every volume consistent; an update to the system is a new
generation, which can be rolled back.

The kernel's work still to come, by milestone, so it isn't a surprise inside a user-space stage (D's IOMMUs, M9's
pager-backed and shared read-only memory objects and pressure signal, R's fault injection, Perf's tickless idle and
large pages, and B's panic record are built):

| Kernel feature | For | Milestone |
|---|---|---|
| Power: system off and reset, through a capability (PSCI on AArch64, ACPI's reset register and `\_S5` from the AML service on x86-64) | Shutting down | P |
| Single-stepping and hardware breakpoints and watchpoints, under `write_state` (built, `thread_set_debug`) | The debugger | M12 |
| A sampling capability over a process subtree (user PC and frame-pointer walk at ticks), a trace ring of scheduler and IPC events (built: an intercept's sampling, and a ring of switches and wakes) | Profiling and tracing | M12 |
| `RDTSC` trapping per process (`0009`) (built, `process_set_traps`); one thread at a time, by the recorder, rather than pinning | Record and replay | M12 |
| The CPU's transient-execution issues logged (`0097`) | The trade `0013` made, made visible | H |
| Shadow stacks and IBT, PAC, BTI and GCS state in threads, if `H` decides for them | Hardening | H |

## D — Device Isolation (L2, L3)

Done 2026-10-25 (`decisions/0079` to `0084`): Intel VT-d and Arm SMMUv3 behind `iommu_interface` (`0039`), registered
by the platform service from DMAR and `iommu-map`; a DMA domain per driver with its own I/O virtual addresses, only DMA
memory mapped; every MSI remapped, taken only from its device; and drivers out of the TCB: one that isn't trusted gets
no DMA memory without an IOMMU, and one whose DMA is blocked is killed and started again. In five stages: Da the
interface and registration, Db VT-d DMA remapping, Dc VT-d interrupt remapping, Dd SMMUv3, De drivers out of the TCB.

Specs: Intel VT-d (rev. 4.x), Arm SMMUv3 (IHI 0070).
Stresses: a second compile-time interface checked like `arch_interface`, bit-packed descriptor formats, invalidation
queues and their fences.

## M8 — Storage (L4)

Design: `design/storage.md`. Done 2026-10-27 (`decisions/0085` to `0091`): every filesystem in user space, in a process
per volume. The storage manager holds the disks; a partition server per disk hands out narrowed `block` connections; a
FAT server serves the ESP; slopfs, the native filesystem (pooled volumes, copy-on-write B+trees, every block checked
through its parent, ordered crash semantics, atomic replacement and transactions, change cursors), runs as a container
service per partition and a volume server per unlocked volume, which alone holds its key (ChaCha20-Poly1305, key
generations). Snapshots, clones, quotas and the reserve; stored links listed and revoked by the volume that issued them.
`std`'s files over the `Dir`, `File` and `FileSet` protocols. slopfs is tested hosted, with a crash-state tester and a
fuzzer, and the hosted image builder makes the disk SlopOS boots from. In six stages: 8a partitions, 8b FAT32 and the
file protocols, 8c slopfs hosted, 8d slopfs as services, 8e encryption and snapshots, 8f stored links.

Specs: UEFI 2.10 (GPT), Microsoft's FAT32 specification v1.03, RFC 8439, NIST SP 800-38D, BLAKE3.
Stresses: explicit-endian on-disk structs, bounds proofs over block buffers, generic B+trees, `Result` on every path,
hosted tests of code written for SlopOS, cryptography's speed in Hemera.

## M9 — System Services and Software (L4)

Design: `design/software.md`; the events service in `design/observability.md`. Done 2026-10-31 (`decisions/0092` to
`0126`):
- **9a** the scheduler, clock and events services, and every service the supervisor starts restarted (`0093`).
- **9b** the bundle store, pager-backed memory objects, and programs outside the boot set loaded from the system volume,
  their code shared (`0094`).
- **9c** typed files and names, the config service and `Config[T]`, the system configuration as checked data in the boot
  set, memory pressure and eviction, the Perf baselines under `-icount`, and R4's storage faults (`0107` to `0112`).
- **9d** generations on the ESP, degraded boots and the supervisor's report of healthy, the update service (staged,
  tentative, permanent, rolled back, collected), installations with `AppData` and `Config[T]`, and the recovery
  generation (`0113` to `0118`).
- **9e** shared libraries bound by the runtime from grants, `service_kit` as one, and substitution by the config store's
  policy, checked against interface records (`0119` to `0122`).
- **9f** follow-ups: boot modules' code shared, the substitution policy in generations, and generations that change only
  services applied live (`0123` to `0126`).

Specs: ELF-64 dynamic linking as far as typed linking needs it; the MC146818 and PL031 datasheets.
Stresses: reproducible compiler output, code run both by `#run` and at run time, schemas serialized from `TypeInfo`,
separately compiled libraries.

## Catch-up — What Earlier Decisions Planned and Weren't Built

Done 2026-10-30 (`decisions/0095`, `0098` to `0101`), in four parts: M5 to M8's (the kernel's own memory held back,
tests for missing grants and ABI mismatches, services reconnecting to a restarted system volume); M9's (`test_budgets`
as a program, CPU affinity for IRQs and budgets, services logging through `base`'s logger); house-rule checks
(hardware structs' size asserts, discarded `Result`s in the kernel, with Hemera's `FunctionInfo.discards`); and deferred
items done or placed: in M10, the root task's services restarted and logging to the events service (`0093`), and
interrupt controllers unregistered when the platform service restarts (`0049`); in M12, debuggers reading untouched
pages (`0056`) and the per-thread page shared with the kernel (`0041`); in P, ACPI's `_CRS` for x86-64's PCI windows
(`0074`).

## R — Robustness Testing (all layers)

Planned 2026-10-29 (`decisions/0096`): error paths run, by machinery compiled in only under `robustness=on`. Done: **R1**
fault injection swept by `boot_tests.py` (`0104`), **R2** counters started near their wrap (`0105`), **R3** lock ranks
(`0106`), **R4** storage faults, with 9c (`0112`), **R5** chaos, random services killed and budgets checked (`0181`'s F6),
and **R6** schedule exploration of lock-free code on Hemera's model checker, in Before M13's C2 and C3 (`0187`): the
handle entry's tag and the shootdown's handshake, in packages of their own with model-checked tests.

Specs: none; prior art in Linux's `failslab`, `INITIAL_JIFFIES` and `lockdep`, `loom` and CHESS.
Stresses: compile-time settings read by target code, `Allocator` wrappers, per-CPU state checked on every lock.

## Perf — Numbers Kept, Not Assumed (all layers)

Planned 2026-10-30 (`decisions/0097`): benchmarks as boot tests held to baselines, by instruction counts under
`-icount` (built in 9c, `0112`). Then, before M10 (`0127`), done 2026-10-31: **Pa** tickless idle (`0128`); **Pb** 2 MiB
pages for anonymous memory of 2 MiB or more (`0129`); **Pc** per-connection CPU loans, the storage servers serving by
the loans' priorities (`0130`).

Stresses: timing and counting inside boot tests, results compared across builds.

## B — Boot (L0)

Done 2026-10-31 (`decisions/0131` to `0135`): SlopOS's own UEFI bootloader, in Hemera, replacing Limine on both
architectures. **B1** Hemera's `OS == .UEFI` target, PE32+ EFI applications, and function types with a calling
convention; **B2** the bootloader booting disks, the kernel given SlopOS's own handoff, every CPU started by it;
**B3** tries left in the generation record and automatic fallback, the recovery generation by the key r or when nothing
else is left, the seed file, and the panic record kept across a warm reset; **B4** ISOs through it from an El Torito EFI
image, and Limine and BIOS boot removed. TPM sealing goes to H.

Specs: UEFI 2.10, PE/COFF.
Stresses: a third kind of output (PE32+), the Microsoft x64 and AArch64 calling conventions at the firmware boundary.

## M10 — Console, Accounts and Sessions (L4)

Design: `design/console-and-sessions.md`.

- **The terminal service** with a typed terminal protocol (styled text, cursor and region operations, key events,
  paste as its own event): no escape sequences in the stream, so printing a file can't reprogram the terminal. A VT
  adapter translates for byte streams (the serial line now, SSH in M14). The reserved status line and the secure
  attention key (`0043`).
- **The input service** owns the keyboards and the seat, and sees the secure attention key before anyone else.
- **Accounts**: the account service and its unencrypted volume, Argon2id (RFC 9106), wrapped volume keys
  (`0042`); first-boot setup creating the administrator.
- **Login and sessions**: console login, the session manager unlocking the home volume and starting the session's
  first program with its starting capabilities (`0016`).
- **The powerbox**, one per session (`0018`), with its console front end, persistent grants as stored links (8f),
  and the user's view of what they've granted, to revoke it. Elevation is the powerbox asking for re-authentication
  on the trusted path and granting one capability, never a `sudo`.

Done 2026-11-02 (`decisions/0136` to `0161`), planned with the owner (`0136`): the typed terminal protocol;
Ctrl+Alt+Delete and a serial BREAK as the secure attention key; Ctrl-C an `Interrupt` to the terminal's owner; and
everything `design/lessons.md` §3 proposed. In four stages:
- **10a** the terminal and input services and the trusted path (`0137` to `0140`): the terminal protocol and service,
  the VT adapter, Unicode widths and visible substitutes; the input service, keymaps and new keyboards accepted by a
  code; the status line, the secure attention key's screen and the framebuffer; the lifecycle channel; and the root
  task's services started again when they end.
- **10b** accounts (`0141` to `0148`): `#secret`, volumes made at run time, the account service with Argon2id, wrapped
  keys, the password rules and rate limits, and first-boot setup with the recovery code.
- **10c** login and sessions (`0149` to `0155`): console login, several sessions, `Locale`, installations run in each
  session, and idle ones stopped under memory pressure.
- **10d** the powerbox and sharing (`0156` to `0161`): requests answered through the chooser, grants kept as stored
  links and revoked, elevation, and volumes shared between users.

Specs: RFC 9106 (Argon2), RFC 3394 or the AEAD for key wrapping, ECMA-48 (for the VT adapter only), the Unicode
standard's East Asian Width and UAX #29 for terminal widths.
Stresses: Unicode handled without a runtime library, memory-hard hashing inside a budget, many sessions on fibers.

## M11 — The Shell and Tools (L5, L6)

Design: `design/shell.md`.

- **The shell language** (`0018`: not Hemera): typed values instead of strings, so no word splitting, no option
  injection and no quoting rules to get wrong; command lines parsed from manifests (`0044`); arguments become grants
  of the parameter's type; pipelines connect `Stream[T]`s and are type-checked before anything starts; errors stop a
  script unless it handles them; results rendered by the shell from their schemas.
- **Scripts are programs**: a script declares typed parameters, so it has a manifest and runs with only what it's
  given.
- **Interactive use**: completion, help from documentation comments, history, jobs (Ctrl-C a message, never a signal).
- **The `std` port filled out**: `Stream[T]`, the terminal client and a line editor, time zones (TZif, RFC 8536),
  a linear-time regex engine (RE2's design, so no pattern can take exponential time).
- **Tools**: listing, copying, moving and removing files; search; a viewer and pager for any typed value; the process
  tree; snapshots; grants; installing; a text editor.

Done 2026-11-06 (`decisions/0162` to `0180`), planned 2026-11-02 (`0162`, `0164`), in five stages; with it, the
first usable system (above):
- **11a** the `std` port (`0163`, `0165` to `0168`): entries taking typed values, `Stream[T]` and `Sink[T]`, the
  terminal client and line editor, time zones from TZif, and linear-time regular expressions.
- **11b** the language and calls through manifests (`0169` to `0171`): typed values, arguments read by type and grants
  made from types, shell functions, errors handled with `or`, `try` and `?`, and `cd`.
- **11c** pipelines over typed streams, records decoded by manifests, the built-in stages and tables (`0172`).
- **11d** interactive use (`0174` to `0178`): documentation comments kept and checked by the compiler, `help`,
  completion, history, jobs, Ctrl-C and `Progress`, and the shell as every session's first program; and a message that
  breaks its protocol ending its connection, and memory that says when no one else holds it.
- **11e** the tools and scripts (`0179`, `0180`): what a program's entry gives back; listing, copying, moving,
  removing and recovering files, with snapshots; search, `view` and a pager; the session's processes, kept grants and a
  user's own installations; the editor; scripts with `param` lines, each in a shell of its own; and shutting down from
  the secure attention key's screen.

Stresses: an interpreter in Hemera (tagged unions, arenas), reflection-driven parsing and rendering, Unicode and
regex tables generated at compile time, the typed-entry machinery from the caller's side.

## Before P — What M10 and M11 Left

Planned 2026-11-07 (`decisions/0181`), with the owner: what M10, M11, R and B left for later that comes before P, in
seven parts: **F1** the shell's background jobs read as they write and said to end, values rendered by their types,
and tables cut to the terminal's width; **F2** Unicode normalization and case folding in `std`, for "did you mean";
**F3** installing any program, given what any installation gets, its other parameters optional, and installations
stopped under pressure started again when their session's shown; **F4** kept grants listed and revoked from the shell,
end to end; **F5** a shared volume given a new volume key when a member's taken out, and its old blocks sealed again; **F6** R5's chaos tests; **F7**
a development generation's command line edited before it boots.

Done 2026-11-07, each part's As Built in `0181`. The chaos tests found more than they were planned to: a thread's
fault now ends its process, and no service maps memory another process owns (`memory_read` reads every kind but
device memory, paged memory waited for from its pager), so a client or driver that ends is an error to its server,
not a fault. A shared volume's snapshots from before a member's taken out are let expire rather than sealed again,
keeping the old generations until they go.

## P — Power (L3)

- The ACPI service (`0039`, `services.md`): an AML interpreter, scoped to what the platform needs: the namespace,
  `\_S5`, `_PRT` for later hardware, the power button's event.
- Shutting down and rebooting through a kernel power capability (PSCI on AArch64, ACPI on x86-64), with services
  told first so volumes are committed.
- Proposed (`design/lessons.md` §5), decided when P is planned: `Stop` sent in reverse dependency order with a short
  deadline each, volumes committed, what's left killed and named in the log; the hardware watchdog's driver (§6.2).
- From the catch-up (`decisions/0101`), with the AML interpreter: x86-64's PCI windows from the host bridge's `_CRS`
  (`0074`), rather than from what the firmware left programmed.

Planned 2026-11-07 (`decisions/0182`), with the project's owner: an AML interpreter that runs methods, bounded; the
power button shutting down cleanly; the console, or an administrator's shell through elevation, shutting down or
restarting. In five parts: **P1** the kernel's `PowerControl`; **P2** the AML interpreter, hosted; **P3** the ACPI
service, `\_S5`, `_CRS`'s windows and the power button (a PL061 `gpio-keys` driver on AArch64); **P4** a graceful
shutdown, `Stop` in reverse start order with deadlines, and restarting; **P5** the `i6300esb` watchdog.

Specs: ACPI 6.5 (AML), Arm PSCI (DEN 0022).
Stresses: an interpreter of an untrusted bytecode, kept in its own process.
Meant to come before M11 ended, so the first usable system shuts down properly; until it does, the secure attention
key's screen commits the volumes and ends the root task (`decisions/0180`). Next after what M10 and M11 left (above, `decisions/0181`).

## M12 — Observability and Debugging (L4, L6)

Design: `design/observability.md`.

- **Crash reports**: a fatal fault goes to the process's creator through its exception port (`0056`); the supervisor
  records registers, a frame-pointer stack trace, and the hashes of the images loaded, symbolized from the bundle
  store's DWARF; no memory is dumped unless asked for.
- **A debugger** on process control (`0017`, `0056`): breakpoints, stepping, watchpoints, Hemera values shown through
  their `TypeInfo`, fibers listed as well as threads.
- **Record and replay** (`0009`, `0024`): a recorder on intercepts, a replayer answering a program's system calls
  from its recording; exact for a process on one carrier, best effort for several.
- **Tracing and profiling**: IPC traced through intercepts, a system trace ring, a sampling profiler.

In four stages: **12a** crash reports and symbols; **12b** the debugger; **12c** record and replay; **12d** tracing
and profiling. From the catch-up (`decisions/0101`): in 12b, a debugger reading pages nothing has touched yet
(`0056`); in 12d, the per-thread page shared with the kernel (`0041`).

Planned 2026-11-08 (`decisions/0183`), with the project's owner: DWARF and Hemera's schemas beside it; replay exact
for several carriers too, through a deterministic mode in Hemera's `std`; the events service keeping a budget per
source. 12a takes lockup detection and the budgets too; 12d the boot timeline and what was lent to each process.

Built 2026-11-08 (`decisions/0183`'s as-built records): crash reports from the shell, the supervisor and the session
manager, named by function through a `symbols` decoder; lockup detection; a budget per events source; the shell's
`debug`, on hardware breakpoints, watchpoints and stepping; `record` and `replay`, exact for several threads, with
Hemera's deterministic mode; the kernel's trace, the boot timeline, and the shell's `profile`. Left for later: lines
from DWARF and values through schemas, fibers listed, attaching through the powerbox, a recording kept as a file, an
administrator's `trace` tool, what was lent to each process, and the per-thread page.

What it left, planned 2026-11-08 (`decisions/0185`), with the project's owner, in four more stages: **12e** debug
information (full DWARF variables and types, linked to schemas, in a debug file in the bundle store; lines and values
in the debugger and crash reports); **12f** the debugger's reach (process-wide breakpoints, fibers listed, attaching
through the powerbox); **12g** recordings as files, received handles replayed, the administrator's `trace`, system
reports read back, budgets from the configuration; **12h** the per-thread page, what services spent on each
process's behalf, and a lockup's registers, with pseudo-NMIs on AArch64. Built: 12e, every program's debug file in the bundle store when the system is built with them,
and the debugger's lines and values; 12f, process-wide breakpoints, fibers listed, and attaching through the powerbox;
12g, recordings as files, received handles replayed, `trace` and `crashes system` through elevation, and budgets from
the configuration; 12h, the per-thread page, attribution in `processes`, and a lockup's registers and stack, with
pseudo-NMIs on AArch64 (`decisions/0185`'s as-built records). M12 is done, but a child CPU budget for each shell job,
which waits for session programs to get CPU budgets (Before M13's C1).

Specs: DWARF 5.
Stresses: the compiler's debug information, reflection over arbitrary values, fibers seen from outside.

## H — Hardening (L1, L2, L5)

- The decision on hardware control-flow integrity (`open-questions.md`, *Kernel*): CET shadow stacks and IBT, PAC,
  BTI and GCS, for user space and the kernel, each detected at boot like AES (`0019`).
- Fuzzers as test programs: the system call table (generated from the ABI package), every protocol's validators,
  the filesystems' mount paths, the ELF loader.

- A boot log of which transient-execution issues apply to the CPU and which cheap mitigations are on (`0097`), from
  `IA32_ARCH_CAPABILITIES` and AArch64's ID registers; `0013`'s scope unchanged.

Stresses: the compiler emitting `endbr64`/`bti` and shadow-stack-aware fiber switches in freestanding code.
Any time after M11.

Planned 2026-11-09 (`decisions/0186`), with the owner: every mechanism the hardware has, for user space and the kernel
(AArch64's BTI, PAC and GCS; x86-64's IBT and shadow stacks), each detected at boot; x86-64's tested through WHPX if a
guest sees CET there; all four fuzzers coverage-guided. In five stages: **Ha** the x86-64 test path, the features
detected, and the transient-execution log; **Hb** Hemera's landing pads, signed returns, property notes, and fiber and
entry sequences to match; **Hc** user space, with kernel-made shadow stacks and GCSs at `thread_create`; **Hd** the
kernel; **He** the fuzzers, the system call table's on a kernel with coverage counters.

## Before M13 — What Was Promised and Not Built

A catch-up stage, in three parts: what earlier plans promised and nothing yet schedules.

**C1, sessions' CPU budgets.** What `design/services.md`, `design/scheduling.md` and `0011` promised and M9 built only
for services. The scheduler service splits the root CPU budget for services and drivers, but not for sessions: every
session program runs on the session manager's budget, so no user's work is bounded or scheduled apart from another's,
and the shell has no budget to split for its jobs (`decisions/0185`'s 12h).

- **The scheduler gives the session manager a budget it can split**: a share for sessions in `system_config`, with
  the right to make children, rather than a bind-only copy.
- **Each session gets a child of it**, and its programs run on that session's budget, or on children of it: the
  session's share configurable, as its events budget is (`SessionSettings`), with a default.
- **The shell gets its session's budget, or a child of it, to split**, and each job runs on a child of the shell's,
  as 12h planned; `processes` shows what each job and each session ran.
- **Tests:** two sessions' programs, each spinning, get their shares; a job's time shows on its own budget.

**C2, Hemera's atomics intercepted** (planned in Hemera, with its owner). R6 needs a test build in which every
atomic operation is a point where a test can choose which thread runs next, which `0096` left to propose to Hemera.
To plan:
- A compile-time setting under which each atomic intrinsic (loads, stores, exchanges, compare-exchanges, read-modify-
  writes and fences), `spin_hint`, and `wait_on_value` and the wakes call a scheduling hook first, with the
  operation, its address and its memory order; compiled out entirely otherwise, so other builds are unchanged.
- A model checker in `std/testing` on that hook: a test's threads run as fibers on one carrier, switched only at
  those points, the interleavings chosen systematically with a bound on preemptions (CHESS), or at random with a
  seed for longer runs, a failing one replayed from its schedule. What the memory orders allow beyond interleavings
  (weak memory, as `loom` models) is decided in the plan, not assumed.
- Hosted tests of `std`'s own lock-free code first (`SpinLock`, the fiber pool's queues, `SharedPtr`), which find
  what the checker misses before SlopOS relies on it.

**C3, R6: schedule exploration** (`0096`), on C2's checker. Hosted tests of the kernel's lock-free code: the frame
caches, the slab magazines and the shootdown's handshake, each built hosted with the setting on, with what they find
fixed and kept as regular tests, as R1 to R5's findings were. Then the rest of the kernel's atomics-only protocols
worth the time (run-queue stealing, quiescent states, the events and trace rings), chosen in C3's plan.

## M13 — Networking (L3, L4)

Design: `design/networking.md`.

- **virtio-net** and the `net` protocol: frames through shared rings.
- **The network service**: a user-space IPv4 and IPv6 stack, with TCP (RFC 9293, SACK, window scaling, CUBIC) and
  UDP.
- **Network authority as capabilities**: no process can reach the network without a connection to it, narrowed to
  the destinations and ports it may use; listening on a port is a grant, so there are no privileged ports.
- **Names**: a resolver in the network service, so a capability can be scoped to `example.com:443`; Happy Eyeballs
  (RFC 8305).
- **Time**: NTP with NTS (RFC 5905, 8915) in the clock service.
- **TLS 1.3** (RFC 8446) in `std`, with hostname verification by default and the trust store a capability.

Planned 2026-11-10 (`decisions/0188`), in seven stages, and an eighth since: **13a** virtio-net and `net`; **13b** IP, ARP, NDP, ICMP,
DHCPv4, SLAAC; **13c** TCP, UDP, the `Network` protocol and its policies; **13d** the crypto TLS needs, in Hemera's
`std` (P-256, RSA, SHA-384, AES-128-GCM, AES-SIV, X.509); **13e** names and the clock's floor; **13f** TLS 1.3 in `std`;
**13g** NTP with NTS; **13h**, added 2026-11-12, a security review of M13's code, with fuzz targets for what comes from outside. TLS interoperates with the Internet's servers; the resolver is in the network service; more
authority than a session's default is asked of the powerbox.

Specs: the RFCs above, RFC 791, 792, 826, 2131, 4443, 4861, 4862, 8200, 7323, 2018, 9438, 1035, 3596.
Stresses: packet processing speed, wrapping arithmetic (sequence numbers), thousands of timers and connections on
fibers.

## Linear Algebra — Between 13c and 13e

Scheduled 2026-11-11 by the project's owner, and built that day: Hemera's float math and linear algebra (`decisions/0189`,
whose As Built says what was made), for M15's canvas, fonts and graphics programs, built after M13's 13c and before
its 13e, which then goes on. In 0189's order:

- **L1, float math:** the float intrinsics in the compiler (`floor`, `ceil`, `trunc`, `round_even`,
  `fused_multiply_add`, `minimum`, `maximum`, `copy_sign`, `square_root` on vectors), then `std/math`, freestanding,
  from musl and fdlibm, and correctly rounded float parsing, with their tests.
- **L2, arrays as vectors:** element-wise `+ - * / %` on fixed arrays of any length, swizzles on arrays of 1 to 4
  elements, assignable when no letter repeats; `docs/types.md`. Alongside L1.
- **L3, matrices:** a built-in `matrix[T, rows, columns]`, column-major, `m[row, column]`, the products, `transpose`
  and `identity`; `docs/operators.md` made true.
- **L4, `std/linear_algebra`:** vectors' and quaternions' functions, determinants and inverses, and Vulkan's and
  OpenGL's transforms.
- **L5, f32's own, vector and fast float math** (`decisions/0190`, whose As Built says what was made), added
  2026-11-11 by the project's owner, before 13e, and built that day: `std/math`'s f32 functions with kernels of their
  own, within 0.51 ulp on every f32; every function lane by lane on `vector[T, n]`, f64's lanes giving the scalar's
  bits; and `std/math/fast`, within 3.5 ulp, for shading and sampling; each tier measured in `perf_tests`.

## M14 — Remote Login (L4)

- **SSH** (RFC 4251–4254; curve25519-sha256, RFC 8731; Ed25519 host keys, RFC 8709; ChaCha20-Poly1305), with key and
  password authentication through the account service, sessions attaching to the terminal service through the VT
  adapter, and SSH's limits as `0043` states them (no interactive powerbox, a key login's volume locked until a
  password).
- **The native remote protocol** later: typed values, capabilities, prompts outside the stream, unlocking from the
  client (`0042`, `0043`).

Planned 2026-11-13 (`decisions/0191`), with the project's owner: an SSH server and a client, `mlkem768x25519-sha256`
beside `curve25519-sha256`, each session's terminal served by the SSH service rather than the console's terminal
service, and SFTP with scp over it; no port or agent forwarding; the native protocol after M15 and M16. In seven
stages: **14a** crypto for SSH in Hemera's `std` (ML-KEM-768, OpenSSH's ChaCha20-Poly1305, OpenSSH's key formats);
**14b** `std/ssh`, both roles, tested in memory and against OpenSSH; **14c** accounts' public keys and the host key;
**14d** the SSH service: login, sessions, terminals, commands, locked homes; **14e** SFTP and scp; **14f** the `ssh`
client on SlopOS; **14g** a security review of M14's code, then its full suites.

## M15 — Display and Input (L3, L4, L6)

Design: `design/display.md`.

- **virtio-gpu** (2D) and the `display` protocol.
- **The compositor**: clients draw into their own buffers and never see each other's pixels or input; screen
  capture, global shortcuts, input injection and clipboard history are capabilities from the powerbox, designed in
  rather than added later (Wayland's portals); paste only on the user's gesture.
- **A trusted path in the GUI**: a band on every window, drawn by the compositor, naming the program, and a layer no
  client can draw over, for the powerbox's dialogs and login.
- **Text and a small UI library**: a TrueType rasterizer, simple shaping, layout; forms generated from manifests,
  as the shell's command lines are.
- **Programs**: a terminal emulator speaking the terminal protocol, the typed-data viewer, a launcher.

Stresses: SIMD in composition and rasterization, floating point in user space, a large generic UI library.

## M16 — Audio (L3, L4)

- virtio-sound and an audio service mixing clients' streams, with a high-priority budget of short periods (`0037`).
- The soft real-time goal (`design/scheduling.md`) measured: no underruns with the CPUs saturated by other budgets.
- The microphone as a powerbox capability, with an indicator on the trusted path.

## Later

- **RISC-V**, the third architecture (`decisions/0022`), after LLVM is rebuilt with its backend.
- **Real hardware**: NVMe, xHCI (HID, mass storage, where a stick's FAT is untrusted input), AHCI.
- **Indexing and live queries** over typed files' attributes (`0046`, BeOS).
- **A POSIX personality**, a library over the native protocols for porting tools; optional, never in the core
  (`problems-and-directions.md` §16).
- **ABI v1** (`0025`, `0027`), once the system above runs on two architectures and the release tooling compares the
  ABI package with its previous release.
- **Not planned**: the Hemera compiler on SlopOS, while it depends on LLVM, which rule 6 keeps out.

---

## Status

| Milestone | State |
|---|---|
| M0 | done 2026-10-17: `BootInfo`, `arch_interface`, `CpuFeatures`; the build package (`src/build`) with the house-rule checks for `std` tiers and the arch interface (`src/checks`); freestanding `std` for views, fixed-buffer text and formatting, and `std/containers` (`FixedArray`, `RingBuffer`, `Bitmap`, intrusive `List`); `SharedPtr` on atomics |
| M1 | done 2026-10-15 (`compiler-plan.md` Phase 6); `tools/boot_tests.py` boots it seven ways. Entry from user mode is generated (entry functions, 2026-10-16) and waits for user mode itself (M4–M6) |
| M2 | done 2026-10-22 (`decisions/0048`): the buddy frame allocator (`src/kernel/frames`); x86-64 paging behind the arch interface (map, unmap, protect, translate, W^X, NX, global pages, PCIDs; `src/arch/x86_64/paging.hsc`); the kernel's own address space, a direct map and the image with each segment's protection, on every CPU, after which boot memory is reclaimed (`src/kernel/address_space.hsc`); the slab allocator with per-CPU magazines (`src/kernel/slab`) and the kernel heap on it, every CPU's `Allocator` (`src/kernel/heap.hsc`). Per-CPU caches of single frames; KASLR for the image and the direct map, which holds every region of the kernel's own (`0021`, amended). Frames, slabs and paging are unit-tested over a buffer standing in for memory |
| M3 | done 2026-10-22 (`decisions/0049`): the other CPUs start, go idle and stop with the kernel; TLB shootdown across CPUs (`src/kernel/shootdown.hsc`); the kernel window for device registers, at a random address (`src/kernel/window.hsc`); I/O APICs behind the arch interface, registered controllers, per-CPU device interrupt IDs and routing (`src/arch/x86_64/io_apic.hsc`, `src/kernel/interrupts.hsc`); the kernel's monotonic clock in every CPU's context (`src/kernel/clock.hsc`). Boot tests: a shootdown on 4 CPUs, the PIT's interrupts through QEMU's I/O APIC, the clock against the counter. Registration through a syscall waits for M5, the platform service for M7 |
| M4 | done 2026-10-22 (`decisions/0050`): threads in user mode (`src/kernel/threads.hsc`), with eager XSAVE vector state (`src/arch/x86_64/vector.hsc`) and user address spaces with PCIDs (`src/kernel/spaces.hsc`); per-CPU run queues with stealing, CPU budgets with sporadic-server refills and Demote, ticks on every CPU, idle and preemption (`src/kernel/scheduler.hsc`, `src/kernel/budgets.hsc`). The arch interface is complete on x86-64. Boot tests: 4 threads on 2 CPUs, each preempted and resumed with its own vector state; a budgeted thread against a background one. Blocking, exiting and creating threads by system call come with M5 |
| M5 | done 2026-10-23, in four stages. Stage 1 done (`decisions/0051`): the system call path, kernel objects in type-stable pools, per-process handle tables with generations and rights, quiescent-state reclamation, Process nodes and the ownership tree, threads that exit and are destroyed, address spaces destroyed with their threads; seven calls in the ABI package (`docs/specs/system_calls.md`). Stage 2 done (`decisions/0052`): ports with wake and timer bindings, per-CPU timer heaps with precise deadlines, threads that block on ports and finish their waits when they next run, the monotonic clock as a call. Stage 3 done (`decisions/0053`): channels with shared rings mapped by both ends, doorbells as signals on port bindings (Once and Persistent), handles moved in batches, kernel-copied reads and writes for recorded processes, notify-and-wait with a handoff to the caller's CPU. Stage 4 in four parts: 4a done (`decisions/0054`): memory budgets that every object is charged to, split and closed into their parents, with charges moving when owning handles are taken; anonymous memory objects charged in full and filled lazily through page faults, mapped and shared between spaces, a bad fault destroying the thread. 4b done (`decisions/0055`): the platform capability, which registers interrupt controllers and makes IRQs and device memory; IRQs delivered as port packets and acknowledged; windows onto memory objects, destroyed with them. 4c done (`decisions/0056`): process control over a subtree with the five rights, threads held by suspends and stops and parked where their state is their registers, intercepts that stop threads at calls' entries and exits and at faults (the exception port), with Continue, Skip and Kill, register and memory access, kill, and termination signals. 4d done (`decisions/0057`): the syscall table as a struct of typed function types in the ABI package, from which `#insert` generates the stubs, the call numbers and the kernel's dispatch into typed handlers; the kernel's per-kind code generated from a table of object kinds; the boot tests call through the stubs |
| M6 | done 2026-10-24, planned 2026-10-23 (`decisions/0058`), in four stages. 6a done (`decisions/0059`): programs build as position-independent executables for `os = .SlopOS` (`src/apps`, `src/services`, `src/drivers`), with Hemera's `base` runtime for SlopOS (a page heap on memory objects, the clock, `process_exit`), the startup block in the ABI package, the shared ELF loader (`src/elf_loader`, unit-tested on the built programs), and the programs carried as boot modules (`docs/specs/programs.md`). 6b done (`decisions/0060`): the kernel loads the root task from the first boot module with the shared loader, at random places, with a labeled grant table (the platform, a debug log, each other module as a read-only memory object over its frames), the boot's random seed and its stack in the startup block; the root task's end stops the kernel; programs write lines through the debug log (`debug_log`). 6c done (`decisions/0067`): the root task splits its budget and starts the services `system_config` lists: the entropy service (a ChaCha20 stream from the boot seed) and the process manager with its own loader (`src/process_builder`), then the supervisor through the manager; the stub supervisor starts `hello` through it. Programs are loaded into processes their requester made, which own their image, stack and startup block, through `thread_create_in`, `process_give_handles` and `memory_size`; a boot test kills the manager and `hello` keeps running. The root task is long-lived; only its end stops the kernel. 6d done (`decisions/0068`): a program's `main` takes its grants as typed parameters, which Hemera's compiler fills from the startup block through base's runtime (`log: DebugLog?`, `manager: os.Channel[ProcessManager]`); `std/os` has `Channel[P]` and `Listener[P]` with protocol tags, the channel helpers, and `launch`, typed by the program's entry; `system_config` names each service's entry and checks the wiring when it's compiled; every startup block has a seed, which `context.random` comes from; the startup code checks the ABI version (1). 6e done (`decisions/0069`): the kernel's user-mode tests are programs in `src/tests`, which the root task runs with `test_program=<name>`, launching copies of themselves where they need other processes; leaks are checked through budgets, and by the kernel, which logs what's left once the root task ends; `test_budgets` stays in the kernel. M6 is done |
| A (AArch64) | done 2026-10-24 (`decisions/0061`, planned 2026-10-23 in five stages, with M6 paused after 6b meanwhile). A1 done (`decisions/0062`): Hemera generates AArch64 code for Linux, with the carrier register `x28`, the prologue stack check (LLVM patch 0003), `morestack`, fibers, threads, linking C, and Linux in `base` and `std/os`; Hemera's Linux tests all pass as AArch64 programs under user-mode QEMU. A2 done (`decisions/0063`): entry functions through `aarch64.vector_table`, `return_to_user`, system registers by name as compile-time arguments, barriers, TLB and cache maintenance, `rndr` and semihosting in `base/intrinsics/aarch64`; a freestanding test boots in `qemu-system-aarch64`, turns the MMU on and takes exceptions from EL1 and system calls from EL0. A3 done (`decisions/0064`): SlopOS's kernel boots on QEMU `virt` through UEFI and Limine (`--setting=arch=aarch64`, `boot.py --arch aarch64`), with `src/arch/aarch64` for CPU setup, exception entry, `TTBR1`/`TTBR0` paging with ASIDs and the PL011, and stops after memory until A4 (`TAKES_INTERRUPTS`); 8 boot tests on AArch64. A4 done (`decisions/0065`): the GICv3, the generic timer, the other CPUs and TLB shootdown, with the GIC, the timer's interrupt and the PL011 found in the device tree (`src/devicetree`); the kernel boots to its timer ticks on every CPU; 14 boot tests on AArch64. A5 done (`decisions/0066`): user mode on AArch64, with SlopOS's system calls in `x8`, `x0` to `x5` and `x0` to `x2`, eagerly switched FP and SIMD state, and the programs and the root task built and loaded for AArch64; every boot test that applies runs on both architectures (52). A is done; M6 resumes, for both |
| M7 | done 2026-10-25 (`decisions/0070`, `0071`, `0073` to `0077`): generated protocols, the kernel for drivers, the platform service, virtio-rng, -console, -blk and -input, connectors and driver restarts |
| D | done 2026-10-25 (`decisions/0079` to `0084`): VT-d and SMMUv3 behind `iommu_interface`, DMA and interrupt remapping, drivers out of the TCB |
| M8 | done 2026-10-27 (`decisions/0085` to `0091`): GPT and partition servers, FAT32 and the file protocols, slopfs hosted and as services, encryption and snapshots, stored links |
| M9 | done 2026-10-31 (`decisions/0092` to `0126`): the scheduler, clock and events services, the bundle store and paged memory, the config store, generations and updates, installations, shared libraries and substitution, and 9f's follow-ups |
| Catch-up | done 2026-10-30, in four parts (`decisions/0098` to `0101`): what M5 to M9 planned and hadn't built, the house-rule checks, and deferred items done or placed in M10, M12 and P |
| Perf | done 2026-10-31 (`decisions/0097`, `0112`, `0127` to `0130`): benchmarks held to baselines, tickless idle, large pages, CPU loans in the storage servers |
| R | planned 2026-10-29 (`decisions/0096`): R1 to R4 done 2026-10-30 (`0104` to `0106`, `0112`); R5 done 2026-11-07 (`0181`'s F6); R6 done 2026-11-10, Before M13's C2 and C3 (`0187`) |
| B | done 2026-10-31 (`decisions/0131` to `0135`): Hemera's UEFI target, SlopOS's bootloader, boot counting and recovery, ISOs through it, Limine and BIOS boot removed |
| M10 | done 2026-11-02 (`decisions/0136` to `0161`): the terminal and input services and the trusted path, accounts, login and sessions, the powerbox and sharing |
| M11 | done 2026-11-06 (`decisions/0162` to `0180`): the shell, its language, calls through manifests, pipelines, interactive use, and the tools and scripts |
| Before P | done 2026-11-07 (`decisions/0181`), in seven parts, F1 to F7: what M10, M11, R and B left, with what the chaos tests found fixed |
| P | done 2026-11-07 (`decisions/0182`), in five parts, P1 to P5: turning off and restarting, AML, the ACPI service and the power button, a graceful shutdown, the hardware watchdog |
| M12 | done 2026-11-09: 12a to 12d (`decisions/0183`), and 12e to 12h, what they left (`decisions/0185`); a child CPU budget for each shell job waits for session programs to get CPU budgets (Before M13's C1) |
| H | done 2026-11-09 (`decisions/0186`), in five stages, Ha to He: the x86-64 test path and the boot log, Hemera, user space, the kernel, the fuzzers. Ha built: boots through KVM in the Linux VM for CET's shadow stacks, the features detected, and the transient-execution log; Hb, Hemera's landing pads, signed returns and notes; Hc, user space's PAC, BTI and GCS on AArch64 and shadow stacks and IBT on x86-64; Hd, the kernel's PAC, BTI and GCS on AArch64 and IBT on x86-64, supervisor shadow stacks waiting for FRED; He, coverage-guided fuzzing: FAT, slopfs, the ELF loader, AML and every protocol's validators under `hemera --fuzz` (`tools/fuzz.py`), and the system calls guided by the kernel's coverage counters |
| Before M13 | planned 2026-11-09 (`decisions/0187`), in three parts: C1 sessions' CPU budgets, split from the scheduler's for each session and the shell's for each job; C2 Hemera's atomics intercepted in a test build, with a model checker in `std/testing`; C3 R6's schedule exploration of the kernel's lock-free code on it. Done 2026-11-10: each session and each program the shell starts on a CPU budget of its own (C1); Hemera's atomics routed to a model checker with weak memory, in `std/testing` (C2); the handle entry's tag and the shootdown's handshake in packages of their own, checked, a lookup's torn read found and fixed (C3) |
| M13 | planned 2026-11-10 (`decisions/0188`): 13a to 13g, and 13h, a security review, added 2026-11-12; 13a built, virtio-net and the `net` protocol; 13b built, the network layer: DHCPv4, SLAAC, ARP, neighbour discovery and pings; 13c built, TCP, UDP, the `Network` protocol and its policies, about 20 MiB/s to the development machine; 13d built, the crypto TLS needs in Hemera's `std`; 13e built, names (a resolver in the stack, Happy Eyeballs, policies by name and the rebinding rule) and the clock's floor; 13f built, TLS 1.3 in `std/tls`, `std/net`'s TLS streams and the trust store as a capability, and the network service copying streams' memory rather than mapping it; 13g built, NTP with NTS in the clock service, from the command line's `nts=`, with ALPN and the exporter in `std/tls` and `std/ntp`; 13h built, the security review: no memory-safety bug, the service no longer waits on programs nor takes paged memory, shares per channel, the stack's randomness and ISNs keyed, chain building budgeted, the clock's steps bounded, and fuzz targets for frames, TCP, DNS, TLS, NTS-KE, DER, X.509, PEM and policies |
| Linear Algebra | decided 2026-11-10 (`decisions/0189`), scheduled 2026-11-11 between M13's 13c and 13e: L1 to L4; done 2026-11-11: float intrinsics, std/math and correctly rounded parsing (L1), arrays as vectors with swizzles (L2), matrices (L3), std/linear_algebra (L4); L5, f32's own, vector and fast float math (`decisions/0190`), 2026-11-11 |
| M14 | planned 2026-11-13 (`decisions/0191`): 14a to 14g, SSH server and client, ML-KEM hybrid, SFTP; 14a built, SHA-3, ML-KEM-768 and OpenSSH's ChaCha20-Poly1305 in `std/crypto` |
| M15–M16 | planned 2026-10-24 (*After M7*, above): the order decided (`decisions/0072`), each milestone's stages proposed until it starts; not started |
