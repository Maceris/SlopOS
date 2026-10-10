# Hemera Feedback Log

The stated goal of SlopOS is to test how Hemera's design scales in real-world use. This
file is where that evidence accumulates: what the language and `std` make easy, hard or
impossible. Entries are currently **design pressure** from planning; once code exists, most
come from marker comments in the source (`grep -rn "HEMERA(\|STD(" src/`, see `conventions.md`).

Detailed designs live in `hemera-proposals/`; this file is the index and status board.
Since `decisions/0030`, SlopOS changes Hemera's `base/`, `std/`, `examples/` and `docs/`
directly; those changes are logged here too, with the reason. Compiler work (`apps/`) is
never done from this project, so it stays an open item until the compiler does it.
Severity: **blocker** / **friction** / **nice**.

---

## 1. Open Items

### Needed to boot a kernel (roadmap M1)

The smallest kernel that proves the toolchain: Limine loads a Hemera ELF, it sets up a
GDT/IDT, prints to the serial port and framebuffer, handles a timer interrupt, and halts.

| # | Need | State | Severity |
|---|------|-------|----------|
| 1 | Freestanding build: no runtime, custom entry symbol | `OperatingSystem.None` and a per-target entry (`BuildOptions.entry`) exist; a no-runtime build is still needed | blocker |
| 2 | `std` usable without an OS | **Resolved** 2026-10-09: tiers in Hemera's `std` (`PACKAGE_TIER` in each package's `package_info.hsc`); `base/runtime/thread.hsc` has `.None`, `.SlopOS` and `.UEFI` branches | — |
| 3 | User-supplied panic handler | `context.assertion_handler` and `intrinsics.trap()` (works freestanding) now cover `assert`. Still unstated: whether runtime panics (divide by zero, bounds) go through the same handler | friction |
| 4 | ELF output + section placement / linker script | `target_options.linker_script` exists in `BuildOptions`; how the compiler links (which linker, ELF executable output for `.None`) is still unstated | blocker |
| 5 | Codegen flags: no red zone, no SIMD/float in kernel, target CPU `x86-64-v3` | **Resolved** 2026-10-05: `target_options.red_zone`, `cpu`, `cpu_features`, `code_model`, `relocation_model` | — |
| 6 | Privileged instructions (`lgdt`, `lidt`, `out`, `cli`, `hlt`, `rdmsr`, `mov cr3`...) | **Declared** 2026-10-09 in `base/intrinsics/x86_64`, imported by `base/intrinsics/platform.hsc` when `TARGET_ARCH == .x86_64`: interrupts, descriptor tables, `load_segments`, I/O ports, MSRs, control registers, `invlpg`, `cpuid`, `rdtsc`. The compiler still has to implement them | blocker |
| 7 | Interrupt entry stubs: naked functions / interrupt calling convention | Not in docs; `calling_convention.md` WIP | blocker (stopgap: link a hand-written `.S`) |
| 8 | Volatile MMIO reads/writes | **Declared** 2026-10-09: `intrinsics.volatile_load_u8`...`_u64` and `volatile_store_*` (`base/intrinsics/volatile.hsc`). The compiler still has to implement them | blocker for drivers |
| 9 | A context before any allocator exists | `Context` requires `allocator`, `logger`, `clock`, `random` and now `assertion_handler`. Early boot could use a panicking allocator and a serial logger, but `push_context` overrides can't point into the stack, so their state can't live on the boot stack: use memory reached through a pointer (a Limine-provided region) or constant data | friction |
| 10 | Carrier block in freestanding builds | Every prologue reads `stack_limit` at `[r14]`, and `assert` calls `intrinsics.carrier()`. The kernel needs: a way to provide a carrier block per CPU (loaded at every entry), a freestanding option for what a failed stack check does (no `morestack`: trap or assert), a way for IST/exception-stack entry stubs to swap `stack_limit`, and possibly a pointer slot in `CarrierBlock` for freestanding programs' own per-CPU data | blocker |

**Suggested approach for 6–8:** arch-specific intrinsic packages (e.g. `base/intrinsics/x86_64`),
imported only by the arch layer, plus a volatile access mechanism. LLVM already has naked
functions and `x86_intrcc`, so a `#naked` or `#calling_convention(...)` directive may be cheap.

### Language and library design

| Topic | State | Details |
|---|---|---|
| Compile-time reflection over packages | Adopted (2026-10-05); the rest declared 2026-10-09: `offset_of` and struct layout (R8), calls and used types (R9), `type_info_of` returning a pointer (N1), `PackageInfo.location` (N3), `has_body` (N5). Still open: the compiler filling them in, and bodies for `reflection.enum_member_name` (N2) and `reflection.equal` (N4) | `hemera-proposals/reflection-checks.md`; `decisions/0029` |
| Builds of many outputs | Adopted (2026-10-05) in `base/compiler/build.hsc`. Still open: `riscv64` (below), `root` vs canonical package paths, documenting parse-once/parallel builds (B10); `os.run_process` is declared in `std/os/process.hsc` with the `--allow-run` check, but doesn't start processes yet | `hemera-proposals/build-programs.md` §7; `decisions/0028` |
| Bitfields | Undecided; plan is integers + masks, logging how much it hurts | `hemera-proposals/bitfields.md` |
| Racy plain memory accesses | UB, defined as relaxed, or a `shared[T]` type? | `hemera-proposals/atomics.md` §3 |
| Generic atomics | Minor: collapsing the many per-type names into generic `atomic_add[T]` would test constrained generics. (No `ptr[T]` atomics by design: no pointer arithmetic on `ptr[T]`, so `rawptr` is the atomic pointer type.) | `hemera-proposals/atomics.md` §1 |
| Un-suffixed atomic ordering | **Resolved** 2026-10-09: stated as sequentially consistent at the top of `base/intrinsics/atomics.hsc` | — |
| Clock/time follow-ups | `Context.clock`/`random` adopted; `runtime.duration_between(start, end: MonotonicTime) -> Duration` added 2026-10-09. Still open: `std/time`'s `now()` is a stub | `hemera-proposals/context-clock-random.md`, "Still open" |
| Context extensions | `user_data: rawptr` is one slot shared by every user-space library; proposal: a typed, scoped `pNext`-style chain. Since every fiber embeds a copy of `Context`, keeping it small matters more now; nodes need a lifetime that outlives fibers created in their scope | `hemera-proposals/context-extensions.md` |
| Calling-convention version | SlopOS names and pins the calling-convention version it builds against (`hemera-abi-v1`), but freezes nothing until its own design is thorough (`decisions/0027`). The 2026-10-04 redesign is the kind of change that pinning makes visible | `design/system-abi.md` §7 |
| Fibers in freestanding builds | Fibers no longer copy frames, but they need an allocator for segments and a scheduler on the carrier. The kernel runs to completion (`decisions/0023`), so fiber machinery stays out of freestanding builds anyway (ties to `std` tiers) | §2 below |
| Carrier pointer without TLS | Hemera loads the carrier pointer from OS thread-local storage when a thread starts and when foreign code calls back. SlopOS has no TLS: thread start uses an entry stub (`decisions/0026`); foreign callbacks would need one per-thread pointer | `open-questions.md`, *Kernel* |
| Unwinding suspended fibers out of process | Debuggers and profilers need the resume-loop protocol (`.loop_return`, `FiberResumeState`) and segment chaining; in-process there's `capture_fiber_stack_trace`. Is the layout documented as something tools may rely on per runtime version? | `open-questions.md`, *Kernel* |
| Target enums | `OperatingSystem.SlopOS`, `.UEFI` and `OutputType.FlatBinary` added 2026-10-09 (the compiler still has to support them). `Architecture` still lacks `riscv64`, which needs a carrier register in the calling convention first | — |
| Compile-time side effects and trust | Gate adopted: `--allow-run` grants running processes and writing outside the output folder, read with `build_permissions()`. Open: the grant reaches `#run` code in every imported package, not only the build package's; SlopOS would prefer it scoped or passed explicitly | `hemera-proposals/build-programs.md` §5, §7 |

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
  hardware even if no Hemera code treats it so. This is sound because a kernel entry never
  leaves its CPU (`decisions/0023`). Each `PerCpu` holds a prebuilt `Context`, so entry stubs
  pass a pointer to it and the "context at `gs:[0]`" idea isn't needed (`design/kernel.md` §3).
  The kernel is `user_data`'s only user. The shared-`rawptr` friction shows up in user space:
  `hemera-proposals/context-extensions.md`. Since 2026-10-04 the kernel also needs a carrier
  block per CPU for the prologue stack check (item 10); see `design/kernel.md` §3.
- **Fibers.** Since 2026-10-04 a fiber has its own small segmented stack (about 1.4 KiB per
  idle fiber, Hemera `docs/multitasking.md`), frames never move, and suspending saves
  registers on the fiber's own stack. Resuming re-enters frames with real calls, so it works
  with hardware control-flow integrity. SlopOS has no signals and delivers faults as port
  packets, so nothing ever runs on a fiber's small segment without warning (Hemera's
  alternate-signal-stack caveat doesn't apply). Paired with ports it's the native async I/O
  model: submit, `park`, the completion packet resumes the fiber (`design/ipc.md` §4).
- **No thread-local storage.** `design/threads.md` relies on Hemera having no thread-local
  globals. Per-thread execution state is the carrier block in a reserved register, set up by
  `std`'s thread entry stub (`decisions/0026`). Hemera only needs OS thread-local storage
  for foreign callbacks, which SlopOS doesn't have yet. A future thread-local feature would
  add a per-thread cost to every SlopOS thread.
- **Sandboxed compilation.** A SlopOS that compiles software on-device could run `#run` code
  with no capabilities at all, which answers the untrusted-compilation problem.

## 3. Resolved

Changes made to Hemera in response to SlopOS (newest first):

- 2026-10-09 — Made from SlopOS under `decisions/0030`. Items marked "the compiler still has to" are declarations only:
  - `std` tiers: a `tiers` package, and every `std` package declares `PACKAGE_TIER` in its `package_info.hsc` (a new convention for package docs and constants, `docs/packages.md`). Was item 2.
  - `std/time` uses `runtime.Instant`; `runtime.duration_between` turns two `MonotonicTime` readings into a `Duration`.
  - Reflection: `offset_of`, struct layout in `TypeInfoStruct`/`StructMember`, `type_info_of` returns a pointer, `PackageInfo.location`, `FunctionInfo.has_body`, `calls`, `used_types`; `reflection.enum_member_name` and `reflection.equal` (bodies still to write).
  - `base/intrinsics/x86_64` privileged instructions, imported per architecture by `base/intrinsics/platform.hsc` (item 6) and `intrinsics.volatile_*` (item 8).
  - `OperatingSystem.SlopOS`, `.UEFI`, `OutputType.FlatBinary`; `thread.hsc` branches for them.
  - `os.run_process` (`ProcessResult`, `ProcessError`), which reports a compile error without `--allow-run`.
  - Un-suffixed atomics documented as sequentially consistent.

- 2026-10-05 — Builds and compile-time reflection (`base/compiler/build.hsc`, `package.hsc`, `function.hsc`, `types.hsc`; `hemera-proposals/build-programs.md`, `reflection-checks.md`):
  - Build packages register targets, steps and checks (`add_target`, `add_step`, `add_check`) with command-line options as defaults; per-target string settings (`target_setting`); entry per target (was part of item 1).
  - `BuildOptions` gained name, root, output path, entry, package paths, CPU and features, code and relocation models, red zone and linker script (was item 5, and part of item 4).
  - `--allow-run` and `build_permissions()` gate processes and writes outside the output folder at compile time.
  - `PackageInfo`, `ImportInfo`, `ConstantInfo`, `TypeDeclaration`, `ProgramInfo`, `find_packages`, `package_info`, `find_constant`, `find_function`; `report_error`/`report_warning` that keep going.
  - Type info: `FunctionInfo.is_exported`, `is_escaping` on parameters and function types, `TypeInfoStruct.is_scoped`.
- 2026-10-04 — Fiber, stack and calling-convention redesign (Hemera `docs/multitasking.md`, `docs/calling_convention.md`, `docs/memory.md`):
  - Fibers no longer copy frames; resuming re-enters frames with real calls, so fibers work with CET shadow stacks, IBT, GCS, PAC and BTI (was *Fibers vs. hardware CFI*).
  - A stack-limit check in every prologue replaces guard pages and stack probes for Hemera code (was *Stack probes*).
  - Foreign calls go through shims that switch to the carrier's own stack; callbacks reload the carrier from TLS and use the context the outgoing shim saved (was *Callbacks from C*).
  - `context.assertion_handler` and `intrinsics.trap()` (most of item 3); `intrinsics.capture_stack_trace` replaces `Context.stack_trace`.
  - The context is read-only; `push_context name (field = value)` replaces assigning fields. `thread_index` and the fiber fields left `Context` for the runtime's `CarrierBlock`.
  - Pointers to the stack are allowed again, checked at compile time with `#escaping` parameters and `#scoped` structs.
- 2026-10-03 — `_weak` compare-exchange (`hemera-proposals/atomics.md`).
- 2026-10-03 — `Context.clock: ptr[Clock]` and `Context.random: ptr[Random]`; `Instant` (wall clock), `MonotonicTime`, `Duration`, `ClockError` in `base/runtime` (`hemera-proposals/context-clock-random.md`).
- 2026-10-01 — Declaration directives after the name (`main #export :: fn() {}`); `#export` documented.
- 2026-10-01 — `--package=<name>:<path>` to remap `base`/`std`/`user`/`vendor`; path parsing bugs fixed.
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
