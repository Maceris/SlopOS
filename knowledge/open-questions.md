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
transactions and snapshots are in the filesystem (`decisions/0046`). Answered 2026-10-25 (`decisions/0085`): a
process per unlocked volume under a container service that never sees plaintext, ChaCha20-Poly1305 by default,
ordered crash semantics with durability through `Sync`, no writable file mappings ever, no intent log to begin with,
and 4 KiB blocks with 16 KiB B+tree nodes.

## Software

Nothing open. Answered 2026-10-27 (`decisions/0092`) and built in M9: one bundle store, the system configuration per
generation, `AppData` and `Config[T]`, and Hemera's typed linking and reproducible output (its `docs/compilation.md`).

## Console and sessions

- **A shared volume after a member leaves** (`decisions/0161`): a new key generation's key is wrapped by the volume key,
  which the share's secret unwraps and which doesn't change, so it doesn't protect new data from a member who kept the
  secret and gets the disk. Should taking a member out give the volume a new volume key, wrapped by a new secret sealed
  to those left, and is that a new SlopFS operation, or a clone?

Answered 2026-11-01 (`decisions/0136`): the typed terminal protocol, one powerbox per session, elevation by
re-authentication on the trusted path, and Ctrl+Alt+Delete or a serial BREAK as the secure attention key, which the
input service recognizes.

## Shell

Nothing open. Answered 2026-11-02 (`decisions/0162`): `shell.md`'s sketched syntax, named shell; a pipeline's input is
the `Stream[T]` parameter named `input`; `Stream[T]` as batches in shared memory in `std`; scripts as programs, with
functions local to them; and entries taking typed values from an `arguments` page.

## Observability

Open, from `design/observability.md` (2026-10-24):

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

## Lessons

From `design/lessons.md` (2026-10-29). Answered: R (`decisions/0096`); Perf, memory pressure, the boot items, the
trusted path's budgets and the lifecycle channel in 10a, names without invisible characters, and a log of the CPU's
transient-execution issues (`0097`). The smaller items are proposed in each milestone's design note. Still open:

- **Sealing the system volume's key to a measured boot set** (a TPM measuring the bootloader and the generation), an
  option off by default against an evil maid, not an administrator (`lessons.md` §10.1, `0013`). Decided when B is
  planned.
- **Forgetting a volume's key on suspend** (`lessons.md` §10.3, `0042`), once suspend exists after P.

## Hemera Threads

* Nothing open. Segmented stacks for plain threads were adopted
  (Hemera's `docs/multitasking.md`, *Stacks*). The Hemera-only questions from the fiber redesign (Windows' thread environment block and
  thread-local storage, LLVM support, return addresses of suspended fibers) moved to Hemera's
  `docs/multitasking.md`, *Open Questions*.
