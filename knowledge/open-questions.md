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
(`0024`), stable raw syscalls and the ABI package (`0025`), the carrier register and
stack-limit checks at thread start (`0026`), and when ABIs freeze (`0027`: not until the OS
design is thorough and development is under way). The rest have recommendations in
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
  `hemera-proposals/context-extensions.md`. Since 2026-10-04 Hemera says *where code runs*
  doesn't belong in the context but in the carrier block; the kernel's case holds because an
  entry never leaves its CPU. Alternative: find `PerCpu` as `kernel.cpus[carrier.index]`.
- **The carrier register in the kernel** (`design/kernel.md` §3, `0026`). Every Hemera
  prologue reads `[r14]`, so kernel entry must load a per-CPU `CarrierBlock` (save the user's
  `r14`, never trust it, restore it on exit). Open: does `PerCpu` embed the `CarrierBlock`;
  what the stack-limit check does in the kernel (there's no `morestack`: trap, or call the
  assertion handler); and how IST stacks (NMI, #DF, #MC) and nested interrupts swap
  `stack_limit`, since the check compares against the normal kernel stack's limit.
- **Kernel frame sizes.** Stack arrays can now be passed as views, so more code will put
  buffers on the stack. The kernel has one fixed stack per CPU: a house-rule check (`0007`)
  for a maximum kernel frame size?
- **A per-thread pointer for foreign callbacks** (`0026` item 3). Hemera reloads the carrier
  pointer from OS thread-local storage when foreign code calls back into Hemera. Add one
  kernel-saved per-thread register value (FS base / `TPIDR_EL0` / `tp`) only for that, or
  declare foreign callbacks unsupported until there's ported C code (no external C is linked
  into SlopOS today)?
- **Hardware control-flow integrity for SlopOS itself.** Hemera's fibers now work under CET
  shadow stacks, IBT, AArch64 GCS, PAC and BTI. Does SlopOS enable them, for user space and
  for the kernel? Shadow stacks are per thread and must be created by the kernel (special
  pages), which conflicts with "user space owns stacks" and the per-thread memory target
  (`0023`); CET isn't part of x86-64-v3 (`0003`), so it would need runtime detection like
  AES (`0019`); context switches would save the CET state. The threat model (`0013`) doesn't
  cover exploit mitigations yet. Likely its own decision.
- **Unwinding fibers from outside the process.** Debuggers, profilers and crash reporters
  using `0017`'s `inspect`/`read_memory` must understand Hemera's resume loop
  (`.loop_return`, `FiberResumeState`) and stack segments. That layout is private to the
  runtime, so these tools pin the runtime version they understand?
- **System ABI conventions** (`design/system-abi.md` §§2–8): Hemera-native calling
  convention, register convention for syscalls, startup block contents, C thunks. Confirm.
- **`#escaping` in syscall declarations.** Pointers the kernel keeps after a call returns
  (`thread_create`'s `entry`, `stack` and `start`) should be `#escaping` parameters in the ABI
  package, so `std` can't hand the kernel a pointer into its stack. Pointers the kernel only
  uses during the call (`port_wait`'s `out`) stay non-escaping. Write the rule down for the
  stub generator, and check it with a house rule?
- **Second architecture timing** (`decisions/0022`): start AArch64 right after M3, as
  proposed, or later?

## Hemera

- Bitfields: integers + masks (current plan) vs. explicit-position bitfields (`hemera-proposals/bitfields.md`).
- Racy plain memory accesses: UB, defined as relaxed, or a `shared[T]` type? (`hemera-proposals/atomics.md` §3)
- Do runtime panics (bounds checks, divide by zero) go through `context.assertion_handler`,
  like `assert`? The kernel's panic path depends on it (`hemera-feedback.md` item 3).
- Context extensions (`hemera-proposals/context-extensions.md`): threads and fibers created
  inside a scope copy the context, including the chain pointer, and can outlive the scope, so
  extension nodes can't be freed when it ends. Immortal, arena-owned, or reference-counted?
- Carrier register on RISC-V: Hemera defines `r14` (x86-64) and `x28` (AArch64) only, and
  SlopOS targets riscv64 (`0022`).

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
- Fiber stacks vs. message sizes. A fiber's first stack segment is 1 KiB, and further
  segments are sized to the frame that needs them. Copying a large message (up to 64 KiB,
  `design/ipc.md` §2) into a stack buffer on a fiber forces a large segment allocation.
  Hemera's memory budget assumes about 1 KiB of frames at a typical wait; measure `std`'s
  receive and decode path against that, and keep large receive buffers per connection on the
  heap?
- Per-carrier state in `std` (allocator caches, a `Random` per carrier, the scheduler's
  port). Hemera's pattern is a no-yield region indexed by `current_thread_index()`. Who
  assigns that index on SlopOS (`std`'s thread entry stub), and is it dense enough to index
  arrays? Is the per-thread page shared with the kernel (`design/scheduling.md` §3) separate
  from the carrier block, or reached from it?

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

Raised with Hemera's 2026-10-04 fiber redesign. Notes in *italics* are SlopOS's view.

* Should plain threads grow their stacks with segments too, instead of treating the limit as an error?
  *SlopOS leans yes: user space owns stacks (`0023`), and segmented thread stacks would let
  threads start as small as fibers instead of a 4 KiB page.*
* A `park` and/or waiter API that guarantees suspends where yield does not?
  *SlopOS's ports supply the waiter registration: `park` binds the fiber's key on the
  scheduler's port, and when it returns false the caller waits with `port_wait` on its
  thread's own port (`design/ipc.md` §4).*
* Windows: the stack bounds in the thread environment block are used by structured exception handling and some APIs.
  Either update them on every switch (as Windows' own fibers do), or rely only on vectored exception handlers
  (as Go does).
* Windows: whether the thread-local storage slot for the carrier pointer can be at a fixed offset.
* LLVM: reserving the carrier register, and emitting this prologue and this `morestack` protocol.
* Debuggers and profilers need to know that a return into the resume loop continues in the fiber's resume state.
* While a fiber is suspended, its return addresses are in ordinary memory and are trusted when it resumes.
  IBT/BTI limit where they can lead to, and the runtime could also check them against a table of call sites.
  A hardened mode with a shadow stack per fiber is possible, at a much higher memory cost.
