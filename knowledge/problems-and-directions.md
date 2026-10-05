# Problems With Modern Operating Systems, and What We Could Do Instead

A brainstorm, not a spec. Each section names what goes wrong today, why it went wrong
(usually: a decision that made sense in 1970 or 1995 and can no longer be undone), and
clean-slate directions SlopOS could take. Items marked **[decided]** link to their record;
decisions go in `decisions/`, unresolved questions in `open-questions.md`.

Status markers: **[decided]** = recorded in `decisions/`, **[leaning]** = seems right, **[explore]** = worth prototyping, **[unsure]** = real tension.

---

## 0. The Big Pattern

Most of what follows is one problem wearing different hats: **modern OSes are built on
ambient, global, mutable, untyped state.**

| Hemera bans...              | ...and the OS equivalent is                                            |
|-----------------------------|------------------------------------------------------------------------|
| Mutable global variables    | Env vars, cwd, umask, `/etc`, the registry, the global filesystem namespace |
| Exceptions (unchecked errors) | Signals, `errno`, `-1` return conventions, the OOM killer           |
| Hidden dependencies         | Ambient authority: any program can open any file the user can          |
| Untyped / stringly data     | Text pipes, argv parsing, config file formats                          |
| Implicit behavior           | Installers that mutate the system, `LD_PRELOAD`, shared `/usr/lib`     |

A useful framing for the whole project: **SlopOS is Hemera's philosophy applied to a
system.** Where Hemera says "inputs and outputs are apparent from the function signature",
SlopOS says "a program's authority is apparent from what it was handed at launch".
That gives us a consistent tiebreaker when design questions come up.

---

## 1. Security: Ambient Authority

**Problem.** A program runs with *all* of the user's authority. A PDF viewer can read
`~/.ssh/id_rsa`, a game can encrypt your documents, an npm post-install script can do
anything you can. Sandboxing (iOS, Android, Flatpak, macOS TCC) is bolted on after the
fact and is full of holes because the underlying APIs assume ambient access.

**Root cause.** Unix security was designed to protect *users from each other* on a
shared mainframe. Today a machine has one user and hundreds of mutually-untrusting
programs. The principal is wrong.

Related: the confused-deputy problem, `root`/Administrator as an all-or-nothing switch,
path-based access checks (TOCTOU races, symlink attacks).

**Directions.**
- **[leaning]** *Object capabilities.* No global namespace to reach into. A process can
  only touch what it holds a handle to. Handles are unforgeable, can be passed over IPC,
  and can be attenuated (e.g. read-only view of a directory). seL4, Fuchsia/Zircon,
  KeyKOS/EROS, Capsicum, WASI all do some version of this.
- **[leaning]** *The powerbox pattern.* When a program wants "a file", the trusted
  system file picker hands it a capability to exactly the file the user chose. The user's
  click *is* the permission grant, so there's no permission dialog to fatigue them.
- **[decided]** *No kernel principal.* Users are sessions in the ownership tree, with a
  limited administrator and per-user encryption (`decisions/0016`); servers authorize by
  connection only (`decisions/0014`).
- **[decided]** *Revocation.* Destroying an object revokes every handle to it, transitively;
  to revoke one recipient, destroy an owned child object or close its connection. No
  per-call cost (`decisions/0008`, `decisions/0010`).
- **[decided]** Command-line arguments are grants, globs become a `FileSet`, and programs
  can ask the powerbox for more at runtime, on the console or in a GUI (`decisions/0018`).
  Still **[unsure]**: how does a shell work in detail? Typing `grep foo ~/notes/*.md` implicitly grants
  grep read access to those files — that's actually a nice model (the shell is the
  powerbox), but scripts and globbing need thought.

**Hemera angle.** Capabilities map naturally onto Hemera's "no objects, no methods" style:
a capability is an opaque `distinct` handle type, operations are free functions that take it.

---

## 2. Kernel Architecture: The Trusted Computing Base Is Enormous

**Problem.** Linux is 30M+ lines running in ring 0; any bug in any driver can take over
the machine. Studies consistently find drivers are the majority of kernel code *and* the
majority of kernel bugs.

**Directions.**
- **[leaning]** *Microkernel*. Kernel does address spaces,
  threads/scheduling, IPC, capabilities, interrupts → messages. Everything else — drivers,
  filesystems, network stack — runs in user space. L4 proved IPC can be fast enough; Mach's
  reputation for slowness was Mach's fault, not the concept's.
- **[explore]** *Restartable services* (MINIX 3's reincarnation server). A crashed disk
  driver gets restarted; clients retry. Needs idempotent or resumable protocols.
- **[explore]** *Language-based isolation* (Singularity, Theseus): all code in one address
  space, isolation enforced by the compiler instead of the MMU. Tempting since everything is
  Hemera, but Hemera has `rawptr`, `bit_cast` and compile-time execution — isolation
  would only be as sound as a verifier we don't have. Probably: MMU isolation first,
  keep this as a later optimization for trusted-by-construction code.
- **[leaning]** How small is "micro": a responsibility list modelled on existing
  microkernels and their missteps, with scheduling policy in user space
  (`design/kernel.md`, `design/scheduling.md`).

---

## 3. IPC and Data Exchange: Text as the Universal Interface

**Problem.** Unix pipes carry unstructured bytes. Every program re-implements parsing and
formatting; output meant for humans gets scraped by machines (parsing `ls` is a meme for a
reason); whitespace in filenames breaks things; locale changes break parsers.
Text as the default data format is explicitly something we don't want.

**Directions.**
- **[leaning]** *Typed messages.* IPC carries values with a schema. The schema comes from
  Hemera types directly — no separate IDL — using compile-time execution to generate
  serializers/stubs.
- **[leaning]** *Shared-memory transport*. Small messages via kernel IPC;
  bulk data via shared-memory rings. **Hemera's relative pointers are ideal here** — a
  data structure built with `relptr32` is position-independent, so it means the same thing
  at different addresses in two processes, and on disk.
- **[explore]** *One canonical self-describing binary format* for when the reader doesn't
  know the type ahead of time (so generic tools — a pager, a table viewer, `jq`-like
  queries — work on anything). Hemera's `any` + type info is the in-memory analogue.
- **[explore]** *Streams of records, not bytes.* A pipeline is `Stream[T]`. PowerShell and
  Nushell show the UX; Hemera's `|>` operator is the same idea at the function level.
  SOA types could make streams of records columnar and fast.
- **[unsure]** *Text's real virtue is debuggability and universality.* We need a universal
  "render any value as text" and "parse text as any type" story, or people will hate it.
- **[unsure]** *Schema evolution.* Producer and consumer compiled against different versions
  of a type. Needs rules (append-only fields? tagged fields like protobuf?).

---

## 4. Program Interfaces: Every Program Parses argv

**Problem.** A program's interface is a `char**`. Every program hand-rolls argument parsing,
help text, validation and completion, inconsistently. Nothing is discoverable by machines.

**Directions.**
- **[leaning]** *Programs export typed functions, not `main(argc, argv)`.*
  ```
  search :: fn(pattern: Regex, files: File[], ignore_case := false, max := 0) -> Stream[Match]
  ```
  Hemera already has named parameters and defaults, which map 1:1 onto `--ignore-case --max 5`.
  The shell (not the program) generates parsing, help, tab completion and validation from
  the signature. A GUI launcher could generate a form from the same signature.
- **[leaning]** *This also answers an early question: can my program just call grep's search functions?*
  If `grep` is a package exporting `search`, then the CLI, other programs, and scripts are
  all just callers of the same function. The unit of reuse becomes the function, not the process.
- **[unsure]** In-process vs out-of-process call. Linking grep's `search` into my program
  means trusting grep's code with my authority. Calling it as a separate process via typed
  IPC keeps isolation but costs a context switch per call. Maybe both, chosen by the caller.
- **[explore]** Multiple entry points per program (subcommands become just more exported functions).

---

## 5. Libraries, Linking and Versioning

**Problem.** Dynamic linking → DLL hell, glibc symbol-version breakage, "works on my
machine". Static linking → bloat, and every app must be rebuilt for a security fix.
Containers "solved" this by shipping an entire OS per app.

**Root cause.** Libraries are identified by *name + a version number humans assign*, and
installed into a *single shared global location*. Both are lies about compatibility.

**Directions.**
- **[leaning]** *Content-addressed libraries.* A library is identified by the hash of its
  contents (Nix, Unison, Git). Two apps depending on the same hash share one copy on disk
  and in memory; different hashes coexist without conflict. You get static linking's
  determinism with dynamic linking's sharing.
- **[explore]** *Compiler-checked compatibility.* Since everything is Hemera, the toolchain
  can diff the exported type signatures of two library versions and *know* whether the
  change is compatible, rather than trusting a semver number.
- **[explore]** *Security-fix substitution.* The hole in content addressing: a CVE in
  `libfoo#abc123` means every app pins the vulnerable hash. Need a policy mechanism:
  "hash X is replaced by hash Y for anyone whose interface check passes", recorded and
  reversible.
- **[leaning]** The OS ABI is Hemera-native, with generated thunks for C, avoiding the
  C ABI's known flaws (`design/system-abi.md`).

---

## 6. Installation, Packaging and System State

**Problem.** Installing software mutates the system: files scattered across `/usr`,
`Program Files`, `AppData`, registry keys, services, PATH edits. Uninstalling leaves residue.
Two apps can clobber each other. The system drifts into a state nobody can reproduce.
Explicit goals: no Windows-style installers, no registry.

**Directions.**
- **[leaning]** *Apps are immutable, self-contained bundles.* "Installing" = adding a
  reference to a content-addressed bundle. Running it doesn't require installing it at all.
- **[leaning]** *All state an app creates is attributable to that app.* Each app gets its
  own private storage namespace (by capability, not by convention). Uninstall = drop the
  bundle reference + the namespace; nothing is left behind because nothing could be written
  anywhere else.
- **[leaning]** *System configuration is declarative and versioned* (NixOS, Fuchsia,
  ChromeOS A/B). The system is a function of a config; changes are atomic and roll back.
- **[unsure]** Sharing data between apps (a photo library used by two editors) — done by
  capabilities to a shared store, granted explicitly. Plugins (code that runs inside another
  app) are the hard case.

---

## 7. Configuration and Environment: The OS's Mutable Globals

**Problem.** Environment variables, current working directory, umask, locale, timezone,
`/etc/*`, dotfiles in `$HOME`, the Windows registry: a pile of global mutable state,
inherited implicitly, in dozens of formats, with no schema.

**Directions.**
- **[leaning]** *Spawn with an explicit, typed context.* A new process receives a typed
  struct: its capabilities, its config, locale, etc. — nothing is inherited implicitly.
  This is **Hemera's `context` / `push_context` model lifted to process level**, which is a
  nice symmetry to test the language against.
- **[leaning]** *Config is typed data owned by the app*, validated against the app's
  declared config type. No global config database.
- **[explore]** No "current working directory" string — a directory capability instead.

---

## 8. Filesystem and Namespace

**Problem.** A single global tree of path strings. TOCTOU races, symlink attacks,
case-sensitivity and Unicode normalization mismatches, `..` escapes. Crash consistency is
famously hard to get right (the write-temp/fsync/rename/fsync-dir dance). Metadata is barely
queryable ("find all photos from 2023" = walk the disk).

**Directions.**
- **[leaning]** *Per-process namespaces* (Plan 9): each process sees only what it was given,
  composed from capabilities. There is no `/` everyone shares.
- **[leaning]** *Handle-relative operations only* (`openat`-style everywhere), so there is
  no ambient path resolution.
- **[explore]** *Transactions / copy-on-write / snapshots* as the primitive, so "atomically
  replace this file" and "roll back" are single operations.
- **[explore]** *Typed, queryable metadata* (BeOS/BFS attributes and live queries).
  Files could carry their Hemera type.
- **[explore]** Objects vs files: is a "file" just a persisted typed value?
- **[unsure]** Interop with the outside world (FAT USB sticks, git repos, network shares)
  requires path-based trees somewhere. A compatibility view over the native model?

---

## 9. Concurrency, Async I/O and Process Creation

**Problem.**
- I/O was designed blocking; async was retrofitted repeatedly (`select` → `poll` →
  `epoll` → `io_uring`; Windows IOCP). Each layer co-exists forever.
- Signals are one of the worst designs in computing: asynchronous interruption at any
  instruction, "async-signal-safe" function lists, `EINTR` everywhere.
- `fork()` copies a whole process to then immediately throw it away with `exec()`; it is
  incompatible with threads and hard to make fast ("A fork() in the road", HotOS 2019).

**Directions.**
- **[leaning]** *Completion-based, async-first syscall interface.* A submission/completion
  queue per thread (io_uring-shaped) is *the* interface; blocking calls are a library
  convenience on top. Proposed shape: channel rings are the queues, ports the wait
  mechanism (`design/ipc.md` §3).
- **[leaning]** *No signals.* Everything (child exit, timer, "please terminate",
  hardware events) is a message on a channel the process chose to listen on.
- **[leaning]** *Spawn, not fork.* Create an empty process, hand it capabilities and a
  context, start it.
- **[explore]** Hemera's fibers (see Hemera's `multitasking.md`: about 1.4 KiB per idle
  fiber, frames never move) + completion queues = cheap structured concurrency in user space.

---

## 10. Errors Across the Kernel Boundary

**Problem.** `errno` is a (thread-local) global; `-1` means error except when it doesn't;
error codes lose all context ("No such file or directory" — *which* file?).

**Directions.**
- **[leaning]** Every system call returns a Hemera `Result[T, E]` where `E` is a tagged
  union specific to that call, carrying context. No global error state. This is a free win
  given the language.

---

## 11. Resource Accounting and Cleanup

**Problem.** Memory overcommit plus the OOM killer means allocation "succeeds" then a random
process dies later. It's hard to answer "how much is this app *really* using?" Crashed
processes leak resources held on their behalf by other services.

**Directions.**
- **[leaning]** *Every resource is owned by something in a tree* (process → job → user
  session). Killing a node reclaims everything beneath it, including state held in servers
  on its behalf (servers attribute allocations to the requesting capability).
- **[explore]** *Budgets rather than best-effort.* Memory/CPU/IO quotas per node; allocation
  fails explicitly (a `Result`) instead of overcommit. Hemera's per-context allocators are a
  natural way for a program to sub-divide its own budget.
- **[unsure]** No overcommit makes `fork`-style tricks and huge sparse mappings harder. We
  don't have fork, so maybe fine.

---

## 12. Drivers and Hardware

**Problem.** Drivers run with full kernel privilege; a buggy Wi-Fi driver can read all
memory. DMA-capable devices can bypass the MMU entirely.

**Directions.**
- **[leaning]** *User-space drivers*, each holding capabilities only to its device's MMIO
  range, I/O ports and IRQ. **IOMMU** confines what memory the device can DMA into.
- **[leaning]** Restartable drivers (see §2).
- **[explore]** Hemera's endian-specific ints, `#packed`, `#align` fit register maps and
  descriptor tables well. (Gaps — bitfields, volatile, atomics — tracked in `hemera-feedback.md`.)
- **[leaning]** Scope: we will not be writing a GPU driver. QEMU + virtio first; drivers
  implement device-class protocols (`design/layers.md`, L3).

---

## 13. Updates and Reliability

**Problem.** Updates require reboots, sometimes fail halfway, sometimes break things with no
clean way back.

**Directions.**
- **[leaning]** Atomic system updates (A/B images or content-addressed system generations);
  boot into the previous generation if the new one fails.
- **[explore]** Because services are user-space and restartable, most updates are "restart
  that one service", not "reboot".

---

## 14. Observability and Debugging

**Problem.** Logs are unstructured text to be grepped. Tracing (DTrace, eBPF, ETW) was
bolted on. Reproducing a bug often means guessing at the state.

**Directions.**
- **[leaning]** Structured events as a first-class system service (typed, per §3).
- **[explore]** Every IPC message is traceable, so "what did this app talk to?" is a query.
- **[explore]** *Record/replay.* If all nondeterminism (time, randomness, I/O) enters a
  process through capabilities and messages, a process's execution can be recorded and
  replayed deterministically. Hemera's no-mutable-globals rule makes this unusually
  plausible. Ambitious, but a genuinely differentiating feature.
  Direction set in `decisions/0009`: all nondeterminism arrives as syscall results, and a
  debugger-style syscall interception facility records and replays them.
  Replay is opt-in: performance wins over determinism, so IPC is direct shared memory by
  default and goes through syscalls only for recorded processes (`decisions/0024`).

---

## 15. User-Facing Security Holes

**Problem.** Classic X11 lets any client keylog any other. Clipboards are world-readable.
Password prompts can be spoofed by any app drawing a lookalike window.

**Directions.**
- **[leaning]** A *trusted path*: a UI element / key combo no app can draw or intercept, used
  for credential prompts and permission grants.
- **[leaning]** Input, clipboard and screen capture are capabilities like anything else.
- **[unsure]** GUI is far off; note it now so the capability model doesn't paint us into a corner.

---

## 16. Legacy Compatibility: POSIX

**Problem / choice.** Every OS that tried to be "better Unix" and also stay POSIX-compatible
ended up mostly Unix. But without POSIX there is no existing software.

**Directions.**
- **[leaning]** No POSIX in the core. The project's purpose is testing Hemera at scale,
  so writing native software *is* the point, not a cost.
- **[explore]** Maybe later: a POSIX "personality" as a user-space library over native
  capabilities (like Fuchsia's fdio, or Genode's libc), for porting a few tools.

---

## Candidate Core Principles

Drafted from the above. Not decided; promote to `decisions/` when agreed. Underlying all of
them, from the original goals: a **stable, performant, maintainable and extensible**
architecture, with **least privilege by default**.

1. **No ambient authority.** A process can do only what its capabilities allow.
2. **Nothing global and mutable.** No shared namespace, no environment, no registry.
3. **Typed at every boundary.** Syscalls, IPC, program interfaces, config, storage.
4. **Everything is owned.** Every resource has an owner in a tree; kill the owner, reclaim it all.
5. **Immutable software, attributable state.** Code is content-addressed and read-only; all
   mutable state belongs to someone identifiable.
6. **Messages, not interruptions.** Async completion queues and channels; no signals.
7. **Errors are values.** `Result` everywhere, with context.
8. **Small, restartable pieces.** Microkernel; drivers and services in user space.

## Tensions To Settle Early

The questions that shape the kernel (capability model, IPC primitive, system ABI) are tracked
in `open-questions.md` under *Security and capabilities* and *Kernel*.
