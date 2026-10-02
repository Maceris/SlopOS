# Hemera Feedback Log

The stated goal of SlopOS is to test how Hemera's design scales in real-world use. This
file is where that evidence accumulates: what the language and `std` make easy, hard or
impossible. Entries are currently **design pressure** from planning; once code exists, most
come from marker comments in the source (`grep -rn "HEMERA(\|STD(" src/`, see `conventions.md`).

Detailed designs live in `hemera-proposals/`; this file is the index and status board.
Severity: **blocker** / **friction** / **nice**.

---

## 1. Open Items

### Needed to boot a kernel (roadmap M1)

The smallest kernel that proves the toolchain: Limine loads a Hemera ELF, it sets up a
GDT/IDT, prints to the serial port and framebuffer, handles a timer interrupt, and halts.

| # | Need | State | Severity |
|---|------|-------|----------|
| 1 | Freestanding build: no runtime, custom entry symbol | `OperatingSystem.None` exists; no-runtime build and entry selection still needed (entry per target: `hemera-proposals/build-programs.md`) | blocker |
| 2 | `std` usable without an OS | Tiers in `std_proposal/`; upstream `base/runtime/thread.hsc` still hits `#else //TODO error, unsupported` on an unknown OS | blocker |
| 3 | User-supplied panic handler | Docs mention runtime panics (divide by zero, bounds) but not who handles them | blocker |
| 4 | ELF output + section placement / linker script | Backend has ELF object format; linking story unclear | blocker |
| 5 | Codegen flags: no red zone, no SIMD/float in kernel, target CPU `x86-64-v3` | `cpu_features` option exists and could disable SSE/AVX; red zone needs a flag | blocker |
| 6 | Privileged instructions (`lgdt`, `lidt`, `out`, `cli`, `hlt`, `rdmsr`, `mov cr3`...) | None in `base/intrinsics` | blocker |
| 7 | Interrupt entry stubs: naked functions / interrupt calling convention | Not in docs; `calling_convention.md` WIP | blocker (stopgap: link a hand-written `.S`) |
| 8 | Volatile MMIO reads/writes | Not present | blocker for drivers |
| 9 | A context before any allocator exists | `Context` requires `allocator` and `logger`; early boot could use a panicking allocator and a serial logger | friction |

**Suggested approach for 6–8:** arch-specific intrinsic packages (e.g. `base/intrinsics/x86_64`),
imported only by the arch layer, plus a volatile access mechanism. LLVM already has naked
functions and `x86_intrcc`, so a `#naked` or `#calling_convention(...)` directive may be cheap.

### Language and library design

| Topic | State | Details |
|---|---|---|
| Compile-time reflection over packages | API in progress on the Hemera side; needed for all house-rule checks (`decisions/0007`) and `std` tier enforcement | `hemera-proposals/reflection-checks.md` (R1–R9) |
| Builds of many outputs | Proposal: build package registering targets via a compiler API | `hemera-proposals/build-programs.md` (B1–B10) |
| Bitfields | Undecided; plan is integers + masks, logging how much it hurts | `hemera-proposals/bitfields.md` |
| Racy plain memory accesses | UB, defined as relaxed, or a `shared[T]` type? | `hemera-proposals/atomics.md` §3 |
| Typed `ptr[T]` atomics / generic atomics | Minor: `rawptr` + casts works. Collapsing the many per-type names into generic `atomic_add[T]` would test constrained generics | `hemera-proposals/atomics.md` §4 |
| Un-suffixed atomic ordering | Assumed sequentially consistent; worth stating in the intrinsics docs | — |
| Context in a register | Could a target say "context lives at `gs:[0]`" in the kernel instead of passing it on every call? | §2 below |
| Fibers in freestanding builds | Stack-copying fibers can't run in the kernel; keep fiber machinery out of freestanding builds (ties to `std` tiers) | §2 below |
| Target enums | `OperatingSystem` still lacks `UEFI` (for a Hemera bootloader) and eventually `SlopOS`; `Architecture` lacks `riscv64`; no raw/flat binary output type | — |
| Compile-time side effects and trust | `docs/compilation.md`: compiling untrusted code is unsafe. Process spawning at compile time makes it worse; gate it explicitly | `hemera-proposals/build-programs.md` §5 |

## 2. Design Notes

Context for the open items, and choices SlopOS relies on.

- **No mutable globals vs. kernel state.** Page tables, run queues, the IDT and the physical
  memory allocator are threaded through `context`: `context.user_data` points at the CPU's
  `PerCpu` block, reached via one typed accessor so the cast lives in one place:
  ```
  per_cpu :: fn() -> ptr[mut PerCpu] {
      return cast[ptr[mut PerCpu]](context.user_data)
  }
  ```
  The IDT and GDT still live at fixed addresses the CPU knows, which is "global" to the
  hardware even if no Hemera code treats it so. Friction to watch: every subsystem shares one
  `rawptr` extension point.
- **Fibers.** `std/fiber` copies stack frames out and back in, relying on the frame layout in
  `calling_convention.md`. With no signals in SlopOS, user stacks are never interrupted
  asynchronously, so this is safer than on Unix. Paired with async completion queues it could
  be the native async I/O model (submit, yield, completion resumes the fiber).
- **No thread-local storage.** `design/threads.md` relies on Hemera having no thread-local
  globals: starting a thread only sets the instruction pointer, stack pointer and context
  register. A future thread-local feature would add a per-thread cost to every SlopOS thread.
- **Sandboxed compilation.** A SlopOS that compiles software on-device could run `#run` code
  with no capabilities at all, which answers the untrusted-compilation problem.

## 3. Resolved

Changes made to Hemera in response to SlopOS (newest first):

- 2026-10-01 — Declaration directives after the name (`main #export :: fn() {}`); `#export` documented.
- 2026-10-01 — `--package=<name>:<path>` to remap `base`/`std`/`user`/`vendor` (e.g. to `std_proposal`); path parsing bugs fixed.
- 2026-10-01 — `rawptr` atomics; atomic load/store for `int`/`uint`/`uintptr`; `compiler_fence_acquire_release`.
- 2026-10-01 — `_` to ignore return values (`docs/functions.md`).
- 2026-10-01 — Arch interfaces and house rules: compile-time reflection checks rather than an `implements` feature (`decisions/0007`).
- 2026-09-30 — Atomic loads/stores, hardware and compiler fences, `_acquire_release`, compare-exchange returning `(old, success)`, increment/decrement returning the old value (`hemera-proposals/atomics.md`).
- 2026-09-30 — `and`/`or`/`xor` intrinsics take an operand; unsigned fixed-width atomic variants.
- 2026-09-30 — `Context.user_data: rawptr` as the extension point (programs can't add fields).
- 2026-09-30 — `OperatingSystem.None` for freestanding targets.

## 4. Features That Look Like a Strong Fit

- **Relative pointers** (`relptr*`) → position-independent shared-memory IPC and on-disk structures.
- **Endian-specific integers, `#packed`, `#align`** → descriptors, network and disk formats.
- **`Result` / tagged unions, no exceptions** → typed syscall errors; device protocols as unions.
- **Context + allocators** → process spawn context and per-process memory budgets.
- **Named parameters + defaults** → automatic CLI generation from function signatures.
- **Compile-time execution + `FunctionInfo`/`TypeInfo`** → syscall tables, IPC stubs, serializers, house-rule checks.
- **`distinct` types** → capability handles that can't be confused with each other or with integers.
- **`|>` pipe operator** → a model for typed process pipelines.
- **`#if OS == ...` branching in `std`** → SlopOS slots in as a new branch.
