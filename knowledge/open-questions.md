# Open Questions

Running list of unresolved questions only. When one is answered, record the answer in
`decisions/` (or the relevant design note) and delete the question here.

## Libraries and program reuse

- How do libraries work? How are they shared and versioned? How do we avoid DLL hell
  and bloated static binaries? → see `problems-and-directions.md` §5 (content addressing)
- Can we avoid libc-style version breakage from limited forwards/backwards compatibility?
  → §5 (compiler-checked interface compatibility)
- Can a program call another program's functions (e.g. grep's search) directly, and is that
  linked in-process or called out-of-process over IPC? → §4

## Security and capabilities

"Capability" here means *object* capability (an unforgeable reference that both designates
an object and confers rights to it), not POSIX `CAP_*` privileges, which are still ambient.
→ `problems-and-directions.md` §1, Candidate Core Principle 1.

- Kernel handle tables (Zircon) or capability address spaces (seL4 CNodes)?
- Which object types does the kernel know about? Likely memory (untyped/frames), address
  spaces, threads, scheduling budget, IPC endpoints, notifications, IRQs, I/O ports, MMIO,
  IOMMU domains. Everything else (files, directories, sockets, display, clipboard) is an
  endpoint capability to a server, tagged so the server knows which object and which
  rights. Is that split right?
- What is the *ambient floor*, the authority every process has without holding a
  capability? Computation and allocation within its own budget, surely. Monotonic time?
  Wall-clock time and randomness? (Making those capabilities is what makes §14 record/replay
  possible; monotonic time is also a covert/timing channel.) Logging?
- How is revocation implemented, and what does it cost per call? Options: kernel-tracked
  derivation tree (seL4 `Revoke`), caretaker/forwarder proxies (+ membranes for
  transitive revocation), or server-side only (server stops honoring a badge; Zircon-style,
  revoke by closing the channel). Most interesting capabilities are server capabilities,
  so is server-side revocation enough?
- Rights model: fixed rights bits on every handle (Zircon: read/write/duplicate/transfer…)
  plus richer server-defined rights (read-only, append-only, subtree-only, expiry)? How is
  attenuation exposed: a kernel `mint`/`replace` with fewer rights, servers issuing derived
  capabilities, or both?
- Should rights live in Hemera types (`Dir[ReadOnly]`, `restrict :: fn(Dir[RW]) -> Dir[RO]`)?
  Types give early errors and ergonomics, but across a process boundary they're only the
  other side's promise; the kernel/server must still enforce. How do typed handles map
  onto the untyped runtime enforcement?
- Static or dynamic authority? Fuchsia-style declarations (component manifests with
  `use`/`offer`/`expose`, routed by a framework) make authority readable before running.
  Could a program's exported typed entry points (§4) *be* its manifest: its parameters are
  its capabilities?
- How do servers avoid reintroducing ambient authority? Rule candidate: a server authorizes
  a request only by the capability it arrived on, never by caller identity checked against
  an ACL (otherwise the confused deputy returns). Is that enforceable, or only a convention?
- How does a shell grant capabilities? Is "arguments on the command line = grants" enough?
  (Shell as powerbox; scripts and globbing are the hard part.)
- What does the powerbox look like before there's a GUI: shell only, or a trusted
  text-mode picker on a trusted path (§15)?
- What is a principal: user, program, or (user, program)? Do we need multiple users at all?
- How does the very first process get its capabilities (the boot-time root of authority)?
  seL4-style root task that receives all memory and devices and builds everything else?
- How are capabilities re-established after a reboot or a service restart (§2 restartable
  drivers)? Rebuilt from declarative system config (fits §6/§13), persisted (KeyKOS/EROS
  orthogonal persistence), or a mix? Clients holding a capability to a restarted server
  need a reconnection story.
- How do debuggers, profilers and a process monitor get authority over other processes
  without becoming an all-powerful root? (A capability to a process subtree, handed out
  by whoever spawned it?)
- Wire capabilities: can a capability be sent across the network? Kernel-table handles
  can't leave the machine; sparse/password capabilities (unguessable tokens, macaroons) can
  but leak by copying. Needed early, or out of scope?

## Kernel

- How minimal? Does the scheduler policy live in the kernel?
- IPC: synchronous, asynchronous, or both? Message size limits?
- Per-CPU kernel state with no mutable globals: where does it live? (See `hemera-feedback.md`.)
- Bootloader: Limine to start (proposed in `design/layers.md`); a Hemera UEFI loader later?
- Second architecture: which, and when? (x86-64 first: `decisions/0001`)
- When to turn on KASLR? (PIC everywhere: `decisions/0004`)
- Is the system ABI Hemera-native, with a C-ABI shim only for ported code?
- Threads: one kernel stack per CPU? AVX-512 opt-in? (see `design/threads.md`)

## Hemera

- Bitfields: integers + masks (current plan) vs. explicit-position bitfields (`hemera-proposals/bitfields.md`).
- Racy plain memory accesses: UB, defined as relaxed, or a `shared[T]` type? (`hemera-proposals/atomics.md` §3)

## Layering (`design/layers.md`)

- Exact contents of the arch interface: what's in L1 vs. portable L2?
- Does the kernel parse any ACPI itself (needed to start CPUs and find the APIC), or does
  the bootloader provide enough?
- Platform service: one process for ACPI + PCIe, or separate?
- Device-class protocol versioning: what happens when `block` gains a new request?

## IPC and data

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
  lives (`hemera-proposals/build-programs.md`).
- Per-target build settings: typed values or strings? (`hemera-proposals/build-programs.md` §3)

