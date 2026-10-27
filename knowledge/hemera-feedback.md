# Hemera Feedback Log

The stated goal of SlopOS is to test how Hemera's design scales in real-world use. This
file is where that evidence accumulates: what the language, compiler and `std` make easy, hard or
impossible, from building and running the code and from marker comments in the source
(`grep -rn "HEMERA(\|STD(" src/`, see `conventions.md`).

Designs still open live in `hemera-proposals/`; once one is in Hemera, Hemera's docs are the
reference and the proposal is removed (code insertion and cryptography were, 2026-10-23, relative pointers and endian-specific integers 2026-10-25, and builds as programs 2026-10-26). This file is
the index and status board.
Since `decisions/0030`, SlopOS changes Hemera's `base/`, `std/`, `examples/` and `docs/`
directly; those changes are logged here too, with the reason. The compiler (`apps/`) is built out
as SlopOS needs it (`decisions/0047`), and that's logged here too. An item is done once it's in
Hemera's `docs/` and works: implemented in the compiler, `base` or `std`, with tests.
Severity: **blocker** / **friction** / **nice**.

---

## 1. Open Items

### Language and library design

| Topic | State | Details |
|---|---|---|
| Kernel entry on RISC-V | x86-64 and AArch64 done (`decisions/0062`, `0063`); RISC-V waits for the third architecture, on the same pattern: a frame type, `.entry`, an entry-table intrinsic, `return_to_user` (`sret`), and system-register instructions | `hemera-proposals/kernel-entry.md` |

### Smaller gaps

Known limits, each an error rather than wrong code. Severity: nice.

- A generic function declared inside a function (E4024); a generic type declared there works.

### Targets and runtime

From the survey of Hemera's docs against its compiler (2026-10-24):

- **macOS / Mach-O** is in `compilation.md`'s linking table, but only ELF and PE/COFF can be linked (E7000), and a
  build package's target for Mac is refused. RISC-V, which `multitasking.md` gives a carrier register (`s11`),
  can't be built.
- **Signals**: `multitasking.md` describes per-carrier alternate signal stacks, but the runtime installs no signal
  handlers on Linux. This doesn't affect SlopOS (section 2, *Fibers*).

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

Resolved items are removed once they're done, and so are those decided against. Everything up to 2026-10-25 was:
the survey of Hemera's docs against its compiler and what came of it (complex numbers and quaternions, type values,
field defaults, variadic groups, `~` on untyped constants, pointers to `mut` views, several names in one declaration,
`#insert` in generic bodies, types declared in functions, the shortest float text, `find_packages` removed, parser
recovery dropped), relative pointers and endian-specific integers (whose proposal went with them), and the compiler's
one crash. They're in this file's history, up to commit `d8db719`, and in Hemera's own commits and `docs/`; older
references like "item 9" or "Resolved 2026-10-15" lead to commit `052f203`.
Since then: optional views as results (`-> ((mut u8[])?)`), `match f()? { ... }`, and an optional that starts zeroed
being `Some(0)`, now `None`, `None` being `Optional`'s first variant (decided with the owner, found in 8d3); the
intermittent E4012, a name called ambiguous between imports before the package's own `#insert`, which wins, was done;
and `#code` starting a statement in a block, found fixing it; and a `#run` seeing a type it
describes before it was laid out, once, as `syscall_table`'s `Result[ChannelPair, ChannelError]` with no variants (it
waits for what a description holds by value now).
Then the smaller gaps (2026-10-26): `is_ok` and `is_error` for results; `f()?.member`, the result unwrapped and then
its member, the error or `None` returned (decided with the owner); optionals and results of secrets (a public tag, a
secret value), secrets zeroed when freed, and `or_return` no longer making a public result secret; what a function
gives back pointers from, worked out from its body, so one returning `runtime.new`'s memory isn't taken to return the
caller's stack; `compute[T] { ... give x }`, a block with a value, for `or_else`'s fallback that does more (decided
with the owner: a block doesn't evaluate to its last expression); bounds proofs of `at + i` and through a pointer to a
fixed array (the `||` one was a misdiagnosis); `#insert` in generic types; generic types declared in functions;
constants of `#union` structs naming overlapping members; and `match` and `switch` on a `cstring`, decided against
(a string knows its length) and now a clear error, pointing to std's `c_string.to_string`, which now takes a limit and
gives `None` when there's no zero within it, rather than reading on (decided with the owner). Sharing parsed files between targets was dropped, since checking
changes the trees, and with it `hemera-proposals/build-programs.md`, which had nothing else open.

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
