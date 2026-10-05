# Open Questions

Running list of unresolved questions only. When one is answered, record the answer in
`decisions/` (or the relevant design note) and delete the question here.

## Executables, libraries and program reuse

- What does an executable look like? Current idea: the compiler is pointed at a package
  and looks for `main`; a library `#export`s the functions it exposes. What does a
  *service* look like: how does it declare the protocols it offers?
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

- **Unlocking encrypted volumes without a password** (`decisions/0016`). Key-based remote
  login and a user's background work can't unwrap a volume key, because verifying a
  signature yields no secret. Options: require the volume to be unlocked already by another
  session; credentials that can decrypt (the client unwraps the volume key); ask for the
  password once per boot; or keep a machine-held key for selected background work (weaker
  against disk theft and the administrator). Possibly different answers for remote login
  and background work.
- **Persistent grants and sharing** (`design/security.md` §8, proposed): stored links kept
  by the storage service in the recipient's namespace, and shared volumes whose key is
  wrapped for each member. Make it a decision? When a member is removed from a shared
  volume, is deleting their link and wrapped key enough, or must the volume be re-keyed
  (expensive: re-encrypt everything, or encrypt only new data with a new key)?
- **Genuine prompts on the console** (`decisions/0018`). How does the terminal service show
  that a prompt is the powerbox's and not a program's output: a reserved status line, a
  secure attention key, a per-user secret phrase shown with each prompt? What does that
  look like over remote login, where everything shares one byte stream?
- **Remote login protocol.** Implement SSH (RFC 4251–4254) for interoperability with
  existing clients, or a native protocol that carries typed values and capabilities to the
  remote side? Either way it plugs into the account service and session manager.
- **Which kernel object types exist?** Proposed list in `design/kernel.md` §2. Proposed
  there: no separate notification objects (channel signals and `port_wake` cover them),
  and timers are deadlines bound to ports (`design/ipc.md` §3). Awaiting confirmation.
- **Account database at rest** (`design/services.md`): what key protects the account
  service's own volume, given it must be readable before anyone logs in?

## Kernel

Answered: AES (`decisions/0019`), bootloader (`0020`), KASLR (`0021`), target architectures
(`0022`: x86-64, AArch64, RISC-V, 64-bit only), threads (`0023`), replay vs. direct IPC
(`0024`), stable raw syscalls and the ABI package (`0025`). The rest have recommendations in
`design/kernel.md`, `design/ipc.md`, `design/scheduling.md` and `design/system-abi.md`. Each
needs confirming before it becomes a decision.

- **Kernel scope** (`design/kernel.md` §2): confirm the responsibility table and the
  proposed object list. Is `Process` one type for process, job and session?
- **IPC primitive** (`design/ipc.md`): asynchronous shared-ring channels, kernel doorbells and
  handle transfer, messages up to half the ring (cap 64 KiB). Confirm, including the default
  ring size.
- **Ports** (`design/ipc.md` §3): one port object; readiness packets for channels, completion
  packets for kernel events; the channel rings serve as submission/completion queues. Confirm.
- **Syscall interception** (`design/kernel.md` §4): stops only at syscall entry and exit,
  `Continue`/`Skip`, no cancellation of blocked waits. Confirm.
- **Scheduling** (`design/scheduling.md`): a fixed kernel dispatcher whose parameters are set
  by a user-space scheduler service; priority on the budget; `Demote` only at first; soft
  real-time (glitch-free audio) as the latency goal. Confirm.
- **Budget lending** (`design/scheduling.md` §4): per-connection loans by default, per-request
  loans and priced requests as options. Confirm the default.
- **Per-CPU state** (`design/kernel.md` §3): `context.user_data` → `PerCpu` with a prebuilt
  `Context`, and global state in one boot-allocated `Kernel`. Confirm. User-space friction:
  `hemera-proposals/context-extensions.md`.
- **System ABI conventions** (`design/system-abi.md` §§2–8): Hemera-native calling
  convention, register convention for syscalls, startup block contents, C thunks. Confirm.
- **Second architecture timing** (`decisions/0022`): start AArch64 right after M3, as
  proposed, or later?

## Hemera

- **Fiber runtime vs. hardware control-flow integrity.** Thawing frozen frames patches return
  addresses (`calling_convention.md`), which x86 CET shadow stacks and AArch64 pointer
  authentication reject. Consumer OSes increasingly enable these, so the fiber runtime may
  need reworking to run on them at all. Needs a separate discussion of the fiber design
  (`design/system-abi.md` §9, `hemera-feedback.md`).

- Bitfields: integers + masks (current plan) vs. explicit-position bitfields (`hemera-proposals/bitfields.md`).
- Racy plain memory accesses: UB, defined as relaxed, or a `shared[T]` type? (`hemera-proposals/atomics.md` §3)

## Layering (`design/layers.md`)

- Exact contents of the arch interface: what's in L1 vs. portable L2?
- Does the kernel parse any ACPI itself (needed to start CPUs and find the APIC), or does
  the bootloader provide enough?
- Platform service: one process for ACPI + PCIe, or separate?
- Device-class protocol versioning: what happens when `block` gains a new request?

## IPC and data

- Should channels carry a protocol identifier? A message involves three layers: kernel
  transport (bytes + handles, never inspected), the *connection protocol* (which request and
  response unions a connection speaks, e.g. `Dir` vs `ReadOnlyDir`, which is also how
  server-side rights are expressed, `decisions/0015`), and the *data encoding* (how values
  are laid out). An identifier would name the connection protocol only. Leaning: an opaque
  64-bit tag set at channel creation, never interpreted by the kernel, checked by `std` when
  a handle arrives as `Channel[P]`. It catches wiring mistakes early without a handshake, but
  isn't security (the creator picks it). What the tag *means* (exact type hash, or name +
  major version) depends on schema evolution, so decide them together.
- How does a protocol type declare that it's idempotent, so `std` can reconnect and retry
  automatically (`decisions/0017`)?
- Canonical wire format: raw Hemera layout with relative pointers, or a separate encoding?
- Schema evolution rules when producer and consumer disagree on a type's version.
- How do generic tools (pagers, viewers, queries) display values they have no compiled type for?

## Storage

- Files as byte streams, typed values, or both?
- How much of a path-based tree do we need for interop (FAT, git, network shares)?
- Transactions / snapshots in the filesystem layer or a layer above?

## Scope

- Package structure and naming for `src/`: to be drafted after the OS design is more
  refined, informed by the architecture and Hemera's style. Includes where the build package
  lives (`hemera-proposals/build-programs.md`) and where the ABI package lives
  (`decisions/0025`: in `std_proposal`'s SlopOS OS layer, or in `src/` next to `protocols/`).
- Per-target build settings: typed values or strings? (`hemera-proposals/build-programs.md` §3)

## Hemera Threads

* Should plain threads grow their stacks with segments too, instead of treating the limit as an error?
* A `park` and/or waiter API that guarantees suspends where yield does not?
* Windows: the stack bounds in the thread environment block are used by structured exception handling and some APIs.
  Either update them on every switch (as Windows' own fibers do), or rely only on vectored exception handlers
  (as Go does).
* Windows: whether the thread-local storage slot for the carrier pointer can be at a fixed offset.
* LLVM: reserving the carrier register, and emitting this prologue and this `morestack` protocol.
* Debuggers and profilers need to know that a return into the resume loop continues in the fiber's resume state.
* While a fiber is suspended, its return addresses are in ordinary memory and are trusted when it resumes.
  IBT/BTI limit where they can lead to, and the runtime could also check them against a table of call sites.
  A hardened mode with a shadow stack per fiber is possible, at a much higher memory cost.
