# Hemera Feedback Log

The stated goal of SlopOS is to test how Hemera's design scales in real-world use. This
file is where that evidence accumulates: what the language, compiler and `std` make easy, hard or
impossible, from building and running the code and from marker comments in the source
(`grep -rn "HEMERA(\|STD(" src/`, see `conventions.md`).

Designs still open live in `hemera-proposals/`; once one is in Hemera, Hemera's docs are the
reference and the proposal is removed (code insertion and cryptography were, 2026-10-23). This file is
the index and status board.
Since `decisions/0030`, SlopOS changes Hemera's `base/`, `std/`, `examples/` and `docs/`
directly; those changes are logged here too, with the reason. The compiler (`apps/`) is built out
as SlopOS needs it (`decisions/0047`), and that's logged here too. An item is done once it's in
Hemera's `docs/` and works: implemented in the compiler, `base` or `std`, with tests.
Severity: **blocker** / **friction** / **nice**.

---

## 1. Open Items

### Needed to boot a kernel (roadmap M1)

The smallest kernel that proves the toolchain: Limine loads a Hemera ELF, it sets up a
GDT/IDT, prints to the serial port and framebuffer, handles a timer interrupt, and halts.

That kernel builds and boots now (2026-10-15, `compiler-plan.md` Phase 6). Its items 1–10, referred to by
number in older records, are in this file's history (see Resolved). Still watched:

| Issue | Severity | Where |
|---|---|---|
| Once (2026-10-16), building the kernel through the build package in `boot_tests.py` failed, and the output was lost. Two races in the checker that could explain it were found and fixed since (2026-10-20, 2026-10-22), and no build has failed that way in the many since. Watching a while longer; `build/failed_kernel_build.log` keeps the output if one does | unknown | `tools/boot_tests.py` |

### Language and library design

| Topic | State | Details |
|---|---|---|
| Builds of many outputs | Adopted (2026-10-05) in `base/compiler/build.hsc`; `os.run_process` runs processes since 2026-10-19 (Windows and Linux). Still open: sharing parsed files between targets and building them in parallel, documented as planned in Hemera's `docs/compilation.md` (2026-10-19); `find_packages` is unimplemented and may be removed | `hemera-proposals/build-programs.md`; `decisions/0028` |
| Kernel entry on AArch64 and RISC-V (needed after M3, `0022`) | x86-64 done 2026-10-13. The same pattern is outlined for the others: a frame type, `.entry`, an entry-table intrinsic (AArch64's `VBAR_EL1` table), `return_to_user` (`eret`, `sret`), and system-register instructions | `hemera-proposals/kernel-entry.md` |

### Smaller gaps

- Comparing two optionals (`a != b` with both `u64?`) checks, then fails to generate ("comparing
  Optional[u64] values can't be generated yet", E5002); unwrapping them first works. Found in
  `src/elf_loader/test` (M6, 2026-10-23). Severity: nice.
- `x & ~MASK` with `x` unsigned and `MASK` an untyped constant is refused: `~0xff` is the untyped -256, out of
  `u64`'s range, so `MASK` needs a cast (`~cast[u64](MASK)`). Found writing `std/crypto` (2026-10-19), still so.
  Severity: friction.
- A function declared inside a function can't be generic yet, nor have several names (E4024, E4018); hoisting
  it to the package works. Left out when nested functions became declarations (2026-10-23). Severity: nice.
- A pointer to a `mut` view can't be written: in `ptr[mut u8[]]`, the `mut` is the pointer's, so the view it
  points to only reads. Nothing has needed one yet (2026-10-23, read-only unless `mut`). Severity: nice.

## 2. Design Notes

Context for the open items, and choices SlopOS relies on.

- **No mutable globals vs. kernel state.** Page tables, run queues, the IDT and the physical
  memory allocator are reached through the CPU's `PerCpu` block. Since 2026-10-13 (proposed,
  `design/layers.md` L1) that's through the carrier block, which in the kernel is one per CPU,
  reached via one typed accessor so the cast lives in one place:
  ```
  per_cpu :: fn() -> ptr[mut PerCpu] {
      return cast[ptr[mut PerCpu]](intrinsics.carrier().program_data)
  }
  ```
  Before, it was `context.user_data`, which is sound only while a kernel entry never leaves its
  CPU; the carrier is right by definition, and leaves `user_data` free.
  The IDT and GDT still live at fixed addresses the CPU knows, which is "global" to the
  hardware even if no Hemera code treats it so. This is sound because a kernel entry never
  leaves its CPU (`decisions/0023`). Each `PerCpu` holds a prebuilt `Context`, so entry stubs
  pass a pointer to it and the "context at `gs:[0]`" idea isn't needed (`design/kernel.md` §3).
  The kernel is `user_data`'s only user. The shared-`rawptr` friction shows up in user space:
  Hemera's context extensions (`docs/multitasking.md`). Since 2026-10-04 the kernel also needs a carrier
  block per CPU for the prologue stack check (item 10); see `design/kernel.md` §3.
- **Fibers.** Since 2026-10-04 a fiber has its own small segmented stack (about 1.4 KiB per
  idle fiber, Hemera `docs/multitasking.md`), frames never move, and suspending saves
  registers on the fiber's own stack. Resuming re-enters frames with real calls, so it works
  with hardware control-flow integrity. SlopOS has no signals and delivers faults as port
  packets, so nothing ever runs on a fiber's small segment without warning (Hemera's
  alternate-signal-stack caveat doesn't apply). Paired with ports it's the native async I/O
  model: submit, `park`, the completion packet resumes the fiber (`design/ipc.md` §4).
  Fibers stay out of freestanding builds: they need an allocator for segments and a scheduler
  on the carrier, and the kernel runs to completion anyway (`decisions/0023`, ties to the
  `std` tiers).
- **No thread-local storage.** `design/threads.md` relies on Hemera having no thread-local
  globals. Per-thread execution state is the carrier block in a reserved register, set up by
  `std`'s thread entry stub (`decisions/0026`). Hemera only needs OS thread-local storage
  for foreign callbacks, which SlopOS doesn't have yet. A future thread-local feature would
  add a per-thread cost to every SlopOS thread.
- **Atomics, watching.** No compare-exchange takes a separate failure ordering; revisit if LL/SC
  targets show a measurable cost. A spinlock still needs a `with` block to hold `acquired` across
  the loop condition; fine, but worth watching as more lock-free code gets written.
- **Segmented stacks, watching.** Threads pay `morestack` at segment boundaries where a fixed stack
  wouldn't; measure against the spare-segment cache once SlopOS has threads.
- **Sandboxed compilation.** A SlopOS that compiles software on-device could run `#run` code
  with no capabilities at all, which answers the untrusted-compilation problem.
- **Code insertion, later if needed** (its proposal, done 2026-10-23, is in Hemera's `docs/compilation.md` now):
  parsing text into code (`compiler.parse`), and typed expression quotes (`Code[T]`). Nothing needs either yet.
- **Cryptography** (its proposal, done 2026-10-21, is in Hemera's `docs/memory.md`, *Secrets*, and `std/crypto`):
  value barriers beyond `intrinsics.select`'s own mask weren't added; the machine code is checked under
  Valgrind (`--valgrind-secrets`) instead.

## 3. Resolved

Resolved items are removed once they're done, as everything up to 2026-10-23 was; they're in this file's
history up to commit `052f203`, where references like "item 9" or "Resolved 2026-10-15" from older records
lead.

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
