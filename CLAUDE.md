# CLAUDE.md

Guidance for working on SlopOS. Details live in `knowledge/`; this is the summary.

## What This Project Is

SlopOS is a capability-based microkernel operating system written in **Hemera**, a new
language whose compiler and standard library are still being built. **The real artifact is
the source code**: a realistic, large-scale stress test of Hemera's design, compiler and
`std`. Being able to build and run it eventually is a bonus, not the goal.

Hemera can't compile meaningful programs yet, so code is written against the language as
documented and proposed, and every gap or friction found is recorded as feedback.

## Repository Layout

- `knowledge/` — planning and project memory: roadmap, conventions, decisions, design notes,
  open questions, Hemera feedback and proposals. **Read the relevant parts before designing
  anything.** Start with `knowledge/README.md`.
- `docs/` — official user/developer documentation of the system as specified or built.
- `src/` — SlopOS source code.
- `std_proposal/` — working copy of Hemera's `std`. **It is `std` for this project.**

The Hemera repository (language docs in `docs/`, `base/`, compiler in `apps/compiler`) is
a separate repository, used as reference. Ask for the path to the Hemera repository folder
when relevant.

## Hard Rules

1. **Never modify the Hemera repository.** Needed language, `base`, compiler or doc changes
   go in `knowledge/hemera-feedback.md` or as a proposal in `knowledge/hemera-proposals/`.
   The Hemera side makes them in parallel.
2. **Real implementations, narrow scope, full depth** (`knowledge/decisions/0005`). Cut
   features, never quality: follow the real specs and cite them (`//SPEC:`), use the
   algorithms a production system would, handle every error path, be SMP-safe from the start.
   No toy versions, no fake stubs. Unimplemented paths return an explicit `NotSupported` error.
3. **General-purpose library code goes in `std_proposal/`**, written as real `std` code and
   tagged with its tier (freestanding / allocating / os).
4. **Mark language issues in the code** (`knowledge/conventions.md`):
   `//HEMERA(gap)`, `//HEMERA(guess)`, `//HEMERA(friction)`, `//STD(missing)`, `//SPEC:`.
   Write code the way it *should* look when the language falls short, and mark it.
5. **Record decisions** as numbered files in `knowledge/decisions/`; never rewrite an accepted
   one's meaning, supersede it. Move answered items out of `knowledge/open-questions.md`.
6. No external C code linked into SlopOS. Limine (bootloader) is treated like firmware.
7. **House rules are enforced by compile-time checks** (`knowledge/decisions/0007`): `#run`
   code reflecting over packages, kept together in one checks package. This replaces language features
   like `implements` (e.g. the arch interface) and enforces `std` tiers (each `std_proposal`
   package declares `PACKAGE_TIER`). The reflection API is still being designed; write checks
   against the expected API, mark guesses, and add needs to
   `knowledge/hemera-proposals/reflection-checks.md`.

## Guidelines

1. Work that has not yet been implemented can be signaled with `//TODO(name)` where name is the
   developer leaving the comment or was expecting to do the work. You can leave your own
   like `//TODO(claude)`, but you are not limited in completing any TODO, regardless of the name.

## Key Decisions So Far

- Microkernel; drivers, filesystems and services in user space.
- Object capabilities, no ambient authority; nothing global and mutable (the OS-level mirror
  of Hemera banning mutable globals).
- Typed everything at boundaries: syscalls return `Result`, IPC carries Hemera types,
  programs export typed functions instead of parsing `argv`.
- Layers L0 (boot) → L6 (apps), with two hardware boundaries: a compile-time arch interface
  in the kernel, and typed device-class protocols above user-space drivers (`knowledge/design/layers.md`).
- x86-64 first, kept portable; minimum CPU **x86-64-v3**; QEMU + virtio + Limine for development.
- Position-independent code everywhere (ASLR; kernel as relocatable PIE).
- Cheap threads: one kernel stack per CPU, small thread objects, no TLS, AVX-512 opt-in
  (`knowledge/decisions/0023`).
- Limine to boot (`0020`); KASLR on by default (`0021`); targets x86-64, then AArch64 and
  RISC-V, 64-bit only (`0022`); AES instructions detected at boot, never required (`0019`).
- Performance over determinism: direct shared-memory IPC by default, replay is opt-in
  (`0024`). Raw syscalls are the stable interface; every stable surface lives in one
  generated ABI package, unstable until a declared ABI v1 (`0025`, `knowledge/design/system-abi.md`).
- Proposed, not yet decided: kernel scope, async shared-ring IPC with ports, user-space
  scheduling policy (`knowledge/design/kernel.md`, `ipc.md`, `scheduling.md`).

## Writing Hemera: Things That Are Easy to Get Wrong

- Definitions: `name :: fn(...) -> T { }`; constants `x :: value`, variables `x : T = value` or `x := value`.
- Generics and pointers use square brackets: `fn[T]`, `ptr[T]`, `ptr[mut T]`, `cast[T](x)`. Dereference is `p^`.
- Loops: `loop { ... } while cond` — the condition comes after the body but is checked
  **before every iteration**, including the first; use `#at_least_once` for do-while.
  Loop-scoped variables go in a `with { }` block before `loop`.
- No methods, objects, exceptions, operator overloading, `++`/`--`, preprocessor, or mutable
  globals at runtime. A global must resolve to a constant at compile time, but computing it
  can run arbitrary code (including reading the compiler-provided compilation context, e.g.
  `OS`, `TARGET_ARCH`); anything depending on it waits until it's computed.
- Per-call state goes through the implicit `context` (allocator, logger, ...). Programs can't
  add fields; use `context.user_data: rawptr` (kernel: points at the per-CPU block).
- Ignore return values with `_`: `_, ok = f()`.
- Declaration directives go right after the name: `main #export :: fn() { }`.
- `&x` can't be taken on stack variables.
- Integer overflow wraps (two's complement) and does not panic.
- Atomics are intrinsics in `base`: `atomic_load_*`/`atomic_store_*`, `interlocked_*`, with
  suffixes `_acquire`, `_release`, `_acquire_release`, `_no_fence` (none = sequentially
  consistent). Fences: `fence_*` and `compiler_fence_*`. Compare-exchange returns
  `(old, success)`; increment/decrement return the old value.
- Use explicit-endian types (`u32le`) for externally defined layouts, and add a compile-time
  size check (`#run assert(size_of(T) == N)`) next to every hardware/binary struct.
- Follow Hemera's `docs/coding_guidelines.md`: a function does exactly one thing.

When unsure about syntax or semantics, check the Hemera docs, then guess and mark it
`//HEMERA(guess)`.

## Building

Not possible yet. When it is, point the compiler at `std_proposal` with
`--package=std:<path to std_proposal>`.
The latest debug build of the Hemera compiler should already be on the
system path, runnable with `hemera`. While it is not expected to work
properly for the majority of this project's lifecycle, the help text
may be more convenient than searching through the compiler source code,
though you may also do that.
