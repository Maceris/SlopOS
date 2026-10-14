# Open Questions

Running list of unresolved questions only. When one is answered, record the answer in
`decisions/` (or the relevant design note) and delete the question here.

## Executables, libraries and program reuse

- What does a *service* look like: how does it declare the protocols it offers?
  (Executables and libraries are settled: a target names its entry function, `main` by
  default, libraries have none and `#export` their interface; `decisions/0028`.)
- Is a program's exported entry-point signature its manifest (static authority)? E.g.
  `search :: fn(pattern: Regex, files: FileSet)` would declare exactly what it receives at
  launch, and the shell would derive launch grants from the parameter types
  (`design/security.md` §6). Runtime grants go through the powerbox (`decisions/0018`).
- Is the system configuration that wires services together a Hemera value computed at
  compile time, so the compiler type-checks the wiring? (`hemera-proposals/build-programs.md`)
- How do libraries work? How are they shared and versioned? How do we avoid DLL hell
  and bloated static binaries? → see `problems-and-directions.md` §5 (content addressing)
- Can we avoid libc-style version breakage from limited forwards/backwards compatibility?
  → §5 (compiler-checked interface compatibility)
- Can a program call another program's functions (e.g. grep's search) directly, and is that
  linked in-process or called out-of-process over IPC? → §4. Linked code gets all of the
  caller's authority (`decisions/0013`).

## Security and capabilities

The security design is summarized in `design/security.md`; decisions `0008`–`0018` cover
handles and lifetime, the ambient floor and replay, revocation and rights, budgets, the root
task, the threat model, server authorization, handle types, users and encryption, restart
and process control, and granting authority. Services are listed in `design/services.md`.

Answered 2026-10-13: unlocking without a password, sharing and member removal, and the account
database (`decisions/0042`); genuine prompts and the remote login protocol (`0043`). Nothing open.

## Kernel

Answered: AES (`decisions/0019`), bootloader (`0020`), KASLR (`0021`), target architectures
(`0022`: x86-64, AArch64, RISC-V, 64-bit only), threads (`0023`), replay vs. direct IPC
(`0024`), stable raw syscalls and the ABI package (`0025`), the carrier register and
stack-limit checks at thread start (`0026`), when ABIs freeze (`0027`: not until the OS
design is thorough and development is under way), `BootInfo` (`0031`) and the arch interface
(`0032`). Per-CPU state goes through the carrier block (`intrinsics.carrier().program_data`), which
`PerCpu` embeds; a failed stack check in the kernel calls the assertion handler; entry stubs set
`stack_limit` for IST stacks (`../docs/architecture/layers.md`, `../docs/specs/arch_interface.md`).
Out-of-process fiber unwinding relies on the calling convention version (Hemera's
`docs/calling_convention.md`, *Version*).
Confirmed 2026-10-13: kernel scope and objects (`0034`), IPC and ports (`0035`), syscall
interception (`0036`), scheduling and lending (`0037`), system ABI conventions with `#escaping` and
no C callbacks for now (`0038`), and AArch64 right after M3 (`0022`).

- **Hardware control-flow integrity for SlopOS itself.** Hemera's fibers now work under CET
  shadow stacks, IBT, AArch64 GCS, PAC and BTI. Does SlopOS enable them, for user space and
  for the kernel? Shadow stacks are per thread and must be created by the kernel (special
  pages), which conflicts with "user space owns stacks" and the per-thread memory target
  (`0023`); CET isn't part of x86-64-v3 (`0003`), so it would need runtime detection like
  AES (`0019`); context switches would save the CET state. The threat model (`0013`) doesn't
  cover exploit mitigations yet. Likely its own decision. Deferred (2026-10-13): nothing before
  M4 needs it, and kernel shadow stacks would also need the entry paths to switch them
  (`hemera-proposals/kernel-entry.md`, *Open Questions*).

## Layering (`../docs/architecture/layers.md`)

Nothing open. Answered: the arch interface's contents (`../docs/specs/arch_interface.md`); kernel
entry on x86-64 (Hemera entry functions; AArch64 and RISC-V are tracked in `hemera-feedback.md`);
the kernel parses no firmware tables (`0031`); platform discovery, wired interrupt controllers and
IOMMUs (`0039`). Protocol versioning moved to *IPC and data*.

## IPC and data

Nothing open. Answered: wire format, schema evolution and protocol versioning, protocol tags,
idempotence and lending metadata, and values without a compiled type (`decisions/0040`,
`design/protocols.md`); receive buffers and per-carrier state in `std` (`0041`).

## Storage

- Files as byte streams, typed values, or both?
- How much of a path-based tree do we need for interop (FAT, git, network shares)?
- Transactions / snapshots in the filesystem layer or a layer above?

## Hemera Threads

Raised with Hemera's 2026-10-04 fiber redesign. Notes in *italics* are SlopOS's view.

* Should plain threads grow their stacks with segments too, instead of treating the limit as an error?
  *SlopOS leans yes: user space owns stacks (`0023`), and segmented thread stacks would let
  threads start as small as fibers instead of a 4 KiB page.*
* Windows: the stack bounds in the thread environment block are used by structured exception handling and some APIs.
  Either update them on every switch (as Windows' own fibers do), or rely only on vectored exception handlers
  (as Go does).
* Windows: whether the thread-local storage slot for the carrier pointer can be at a fixed offset.
* LLVM: reserving the carrier register, and emitting this prologue and this `morestack` protocol.
* While a fiber is suspended, its return addresses are in ordinary memory and are trusted when it resumes.
  IBT/BTI limit where they can lead to, and the runtime could also check them against a table of call sites.
  A hardened mode with a shadow stack per fiber is possible, at a much higher memory cost.
