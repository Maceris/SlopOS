# Open Questions

Running list of unresolved questions only. When one is answered, record the answer in
`decisions/` (or the relevant design note) and delete the question here.

## Executables, libraries and program reuse

Nothing open. Answered 2026-10-13: typed entry points as manifests, services, the system
configuration as a compile-time value, and calling other programs (`decisions/0044`); content-addressed
libraries, compatibility checks and fix substitution (`0045`). Executables and libraries themselves
were settled in `0028`.

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
  Planned as roadmap track H, after M11 (2026-10-24).
  Related on the Hemera side: return addresses of suspended fibers (Hemera
  `docs/multitasking.md`, *Open Questions*).

## Layering (`../docs/architecture/layers.md`)

Nothing open. Answered: the arch interface's contents (`../docs/specs/arch_interface.md`); kernel
entry on x86-64 (Hemera entry functions; AArch64 and RISC-V are tracked in `hemera-feedback.md`);
the kernel parses no firmware tables (`0031`); platform discovery, wired interrupt controllers and
IOMMUs (`0039`). Protocol versioning moved to *IPC and data*.

## IPC and data

Nothing open. Answered: wire format, schema evolution and protocol versioning, protocol tags,
idempotence and lending metadata, and values without a compiled type (`decisions/0040`,
`design/protocols.md`); receive buffers and per-carrier state in `std` (`0041`).

## The roadmap after M7

Drafted 2026-10-24 (`roadmap.md`, *After M7*), with a design note per milestone. Answered 2026-10-24: the order,
storage first, and D (VT-d and SMMUv3, with interrupt remapping) right after M7, before M8 (`decisions/0072`). Each
milestone's stages and design choices are decided when it's planned; those are listed below.

## Storage

Answered 2026-10-13: files are bytes with an optional schema hash, trees exist only beneath directory handles, and
transactions and snapshots are in the filesystem (`decisions/0046`). Open, from `design/storage.md` (2026-10-24):

- **A process per unlocked volume**, under a container service that never sees plaintext (`storage.md` §2), or one
  storage service holding every volume, as `design/services.md` first had it. Proposed: the split, so a bug exploited
  through one user's files reaches only that user's volume, and the administrator's volume management goes to a
  process that can't read anything.
- **The default cipher**: ChaCha20-Poly1305 everywhere, or AES-256-GCM where the CPU has AES (`0019`). Proposed:
  ChaCha20-Poly1305 by default, chosen per volume at creation.
- **Ordered crash semantics** (a crash leaves a prefix of the acknowledged operations) as a promise of the native
  filesystem, and durability only through `Sync` (`storage.md` §4). Proposed: yes.
- **No writable file mappings**, ever, or later (`storage.md` §7). Proposed: never; read-only mappings of immutable
  content through pager-backed memory objects in M9.

## Software

Open, from `design/software.md` (2026-10-24):

- **The system configuration at run time** (`0044`'s "later, through the config store"): proposed as a value the
  build serializes into each generation and the root task validates with the same validator and wiring check the
  build runs (`software.md` §4).
- **One bundle store for every user**, or one per user's volume (privacy of which apps a user installed against
  sharing code between users).
- **App data keyed by installation**, not by bundle hash, given as `AppData` and `Config[T]` entry parameters
  (`software.md` §6). Proposed: yes; two new parameter kinds in the manifest.
- **Typed linking**: imports naming each function's type hash, so a mismatch fails the load (`software.md` §7).
  Proposed: yes; it's a Hemera compiler feature, to be proposed in `hemera-proposals/` when M9e starts.
- **Reproducible builds** as a requirement on Hemera's compiler, since content addressing depends on it.

## Console and sessions

Open, from `design/console-and-sessions.md` (2026-10-24):

- **A typed terminal protocol**, with escape sequences only in a VT adapter for byte streams (`console-and-sessions.md`
  §2), instead of VT100 compatibility in the terminal service. Proposed: typed.
- **One powerbox per session** (answers `design/services.md`'s open item). Proposed: per session.
- **Elevation without `sudo`**: re-authentication on the trusted path granting one capability to one program
  (`console-and-sessions.md` §5).
- **The secure attention key**'s combination, and the input service as the place it's recognized.
- **A lifecycle channel for every launched program** (`Stop`, as a `std` protocol), since the kernel has no request
  to end (`shell.md` §6).

## Shell

Open, from `design/shell.md` (2026-10-24):

- **The language's syntax and name**: the sketch in `shell.md` §2, or closer to an existing shell for familiarity.
- **`Stream[T]` as `std`'s typed stream protocol** between programs, with byte streams as `Stream[u8]`, and how a
  pipeline stage marks its input parameter.
- **Scripts as programs**: a script's declared parameters as its manifest, run in a process with only its grants.

## Observability

Open, from `design/observability.md` (2026-10-24):

- **Logs as format strings and typed arguments**, rendered when read, which changes what Hemera's logger interface
  hands over (`observability.md` §2).
- **Replay's promise**: exact for a process on one carrier, best effort for several (`observability.md` §5).
- **Debug information**: DWARF alone, or Hemera's schemas beside it for the debugger's view of values.

## Networking

Open, from `design/networking.md` (2026-10-24):

- **Network authority as narrowed connections** (destinations and listening ports in a policy), with or without a
  first-use prompt through the powerbox.
- **TLS in `std`**, or a service that holds keys and terminates connections.

## Display and audio

Open, from `design/display.md` (2026-10-24):

- **Scope**: software composition only, Latin text and simple shaping first, a small UI library for the first
  programs.
- **Where fonts and rasterizing live**: Hemera's `std` (general-purpose) or SlopOS.

## Hemera Threads

* Nothing open. Segmented stacks for plain threads were adopted
  (Hemera's `docs/multitasking.md`, *Stacks*). The Hemera-only questions from the fiber redesign (Windows' thread environment block and
  thread-local storage, LLVM support, return addresses of suspended fibers) moved to Hemera's
  `docs/multitasking.md`, *Open Questions*.
