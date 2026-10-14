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
- **Account database at rest** (`design/services.md`): what key protects the account
  service's own volume, given it must be readable before anyone logs in?

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
  Decide together with device-class protocol versioning: what happens when `block` gains a new
  request? Leaning: variants are append-only, a server answers an unknown variant with
  `.Unsupported`, and clients ask with a `Features` request.
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
