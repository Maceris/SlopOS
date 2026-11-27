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

### Smaller gaps

Known limits, each an error rather than wrong code. Severity: nice.

- A generic function declared inside a function (E4024); a generic type declared there works.
- No checked arithmetic: integer overflow wraps, and nothing in `base` or `std` says when it would have. The shell's
  language (11d, `src/shell_language/arithmetic.hsc`) checks its own with the sign tricks (`added`, `subtracted`,
  `multiplied`); intrinsics over LLVM's `llvm.sadd.with.overflow` and its kin would be one instruction and a branch.
  Marked `//STD(missing)`. Done 2026-11-23 (Before M19's N4, `decisions/0197`): `intrinsics.add_overflows`,
  `subtract_overflows` and `multiply_overflows`, and `std:math`'s `checked_add`, `checked_subtract` and
  `checked_multiply` giving optionals (`docs/operators.md`, *Integer overflow*); the shell's language uses them.
- `is_ok` and `is_error` bind as loosely as `if`, so `a is_error || b is_error` doesn't parse: each needs parentheses
  or a variable of its own, as M16's greeter and powerbox kept needing. Chosen with the project's owner (2026-11-21):
  they bind tighter than `&&` and `||`, as a comparison does. Severity: friction. Done 2026-11-21 (Hemera 0454b7c):
  a level of their own between `&&` and the comparisons, in the parser and the formatter (`docs/operators.md`).
- An escape a string doesn't know is the character after the backslash (`docs/types.md`), so `"\x00"` is `x00`, not a
  zero byte, with nothing said: std/audio's test wrote a WAV file's bytes that way and read three characters. A warning
  for an escape that isn't one of the table's (`\n`, `\t`, `\r`, `\0`, `\u{...}`, `\\`, `\"`) would catch it.
  Severity: friction (2026-11-22). Done 2026-11-23 (N4): W2003, for any but `\\`, `\"` and `\'` past the table's,
  in strings and characters. Its first build found the bootloader's backspace, `"\x08 \x08"`, showing `x08 x08`.
- One undeclared name can hide behind its consequences: in M18's 18b, a name a shell file never declared gave about 64
  E4030 errors ("escapes into the stack") in code that used it, and the error naming it was lost among them. Errors
  that follow from a name that couldn't be resolved would be better left out. Severity: friction (2026-11-23). Done
  2026-11-23 (N4): the cause was a function whose body had the error, left out of the stack-pointer check, so its
  callers took it to give back pointers from everything they passed it; it's taken to give back nothing now.
- The bounds proof loses a counter kept at most a constant count through a loop: `if n < buffer.count { buffer[n] =
  byte; n += 1 }` over elements, then `buffer[0..<n]`, is E4031 when `buffer` is a fixed array, as its count is the
  constant, and the bound against it loosens by one each time around until it's dropped (widening without
  thresholds). `docs/types.md` says one "kept below a count keeps that". Found in Before M19's N2, where the powerbox
  needed an `if` it can't reach. Severity: friction (2026-11-23).

### Targets and runtime

From the survey of Hemera's docs against its compiler (2026-10-24):

- **macOS / Mach-O** is in `compilation.md`'s linking table, but only ELF and PE/COFF can be linked (E7000), and a
  build package's target for Mac is refused.
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
- **Typed linking, reproducible output and typed log records** (their proposals, done 2026-10-27 to 2026-10-29, are
  in Hemera's `docs/compilation.md`, *Typed Libraries* and *Deterministic Output*, and `docs/types.md`, *Schemas*).
- **Cryptography** (its proposal, done 2026-10-21, is in Hemera's `docs/memory.md`, *Secrets*, and `std/crypto`):
  value barriers beyond `intrinsics.select`'s own mask weren't added; the machine code is checked under
  Valgrind (`--valgrind-secrets`) instead.
- **Zeroing memory others read without a lock** (2026-11-06, `decisions/0052`). `mem_zero`, and an assignment like
  `x^ = T.{}` that becomes one, write a byte at a time in the freestanding kernel, whose `memset` is a byte loop; the
  docs promise nothing wider. A field another CPU reads without a lock then goes through values it never held: a
  binding's port, read as half an address, faulted the kernel. Code that remakes such memory stores those fields with
  atomics and zeroes around them. Not a bug in Hemera, but easy to miss; a word-wide `memset` would also be faster.

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
gives `None` when there's no zero within it, rather than reading on (decided with the owner), as base's
`runtime.cstring_view` does too, for arguments, the environment and directory entries. Sharing parsed files between targets was dropped, since checking
changes the trees, and with it `hemera-proposals/build-programs.md`, which had nothing else open.
Then from the `rawptr` review and R1 (2026-10-30): `string_bytes(text)`, a string's bytes without reading its `data` as
a `rawptr` (`0103`); casts between an address and a float, `bool` or `char` refused, and an untyped constant cast to an
address checked as its own type (`cast[ptr[u8]](1.5)` had compiled); `--output=name.exe` no longer making
`name.exe.exe`; `-o value` taken as well as `-o=value`; and `std`'s `memory.FailingAllocator`, which fails the nth
allocation for fault injection's hosted sweeps (`0096`, `0104`); base's `array_try_reserve`, `array_try_add` and
`array_try_copy` (`0104`); and `std`'s ranked spin locks, `lock_ranked`, `lock_ranked_after` and `unlock_ranked` over a
`HeldRanks` (`0106`).
Then from 9e and 9f (2026-10-31): typed libraries on SlopOS, `base`'s loader binding them from grants (`0120`), and a
library's `base` sharing the program's process state, found when `service_kit` couldn't reserve addresses (`0121`,
`0124`).
Then from 11d (2026-11-05, `0176`), all in `std` and `base`: `schema.read_value[T]`, a value read back as another
program's is, checked, so code outside the RAW_POINTERS packages needn't cast; `terminal.set_completer[D]`, a
completer over data of the program's own type, and completions with descriptions, listed beside them, and a space
after a lone one; the terminal client giving back packets under keys not its own (`Other`), `read_line` going on with
a line it returned in the middle of, and `interrupted`, Ctrl-C without waiting; the stream reader's
`next_bytes_before`, a record or nothing by a deadline; and a lifecycle message from the program, Progress
(`lifecycle.report_progress`, base's `SLOP_OS_LIFECYCLE_PROGRESS`). One thing was easy to get wrong: in
`os.begin(&out)^ = .Variant(os.append(&out, ...))` the right side runs first, so the append lands before the message
and its relative is off, and the server drops the request as invalid; binding begin's pointer first is right, as the
rest of the code does.
Then after 11d (2026-11-05, `0177`): the generated `receive_request` and `receive_response` log a message that isn't
the protocol (`os.report_broken`, naming the package's `PROTOCOL`), which ends its connection, and a response of an
unknown variant is one; the stream's `answer` and `take_request` give null for one rather than skipping it; and the
terminal client keeps its events and text in growing arrays, each Input added after what's still to be read, so
`interrupted` sees Ctrl-C behind type-ahead.
Then for `0178` (2026-11-06), in `std/os/slop_os`'s system ABI: `SIGNAL_UNHELD` and the `memory_holders` call. And
`terminal.write_line` writes a line and its break together, as another client's text could land between them, which
a boot test of the shell caught as a program's line joined to the shell's table.
Then for 11e1 (2026-11-06, `0179`): what a SlopOS program's entry gives back, when it isn't an exit code, written for
its launcher (Hemera's `docs/compilation.md`, Entry Results): the generated entry hands it to base's
`runtime.os_entry_result`, which writes `SlopOsResultHeader` and the value in the grant `"result"` and makes the exit
code 1 for a `Result`'s `Error`; `std/os` gained `LaunchOptions.result`, `entry_result` to read it back, and
`ParameterName`, which an error holds to name the parameter it came from. The first build of a `main` giving back a
`Result` stopped at E5002, "a constant's value needs memory": the entry made the slot a large result comes back
through with the helper ordinary functions use, which needs a function state the entry doesn't have. It makes the
slot itself now, and a freestanding test builds such a program.
Then for 11e2 (2026-11-06, `0179`): `std`'s `dir` gained `Snapshot`, `Snapshots` and `OpenSnapshot`, and `files`
a `Snapshot`. The `os.begin(&out)^ = .Variant(os.append(&out, ...))` mistake of 11d was made four more times in the
file tools, each a request the server couldn't read; the compiler now warns of it (W4003): an assignment whose right
side calls something given `&x`, as a call on its left is, since the right side runs first (Hemera's
`docs/operators.md`). Once, too, the compiler crashed with an illegal instruction building every program for a boot
run, and didn't again when built alone or run again; not chased further.
Then for 11e3 (2026-11-06, `0179`): nothing new in Hemera. What cost time was what has before: `x is_some || y`
needing its parentheses, and an index guarded by `n == 0 || ...` in an `if` before it not proven in bounds, where a
separate `if n == 0 { return }` is.
Then for `0184` (2026-11-08), in `std/os/slop_os`'s system ABI: `PortError.BufferTooSmall` (16), which `port_wait`
gives for empty packets rather than returning 0 at once, and `channel_notify_and_wait` too, as `ChannelError`'s;
`port_wait`'s doc says so and how to pause instead. An empty wait reading as a pause cost a 12c test a stall that
looked like a hung `port_wait`.
Then for 12e (2026-11-08, `0185`), in the compiler: `--debug` describes locals and parameters with DWARF variables and
full types, each local in a stack slot of its own; a SlopOS program's debug info goes in `<name>.debug`, the program
linked with its DWARF and a table naming each local's type as a schema, written by a C++ port of base's schema writer
(`middle_end/schema_writer.cpp`), as compile-time code calling `runtime.schema_try_write` can't be relied on there; and
such a program has no table of functions' names, which kept every function alive after inlining and made programs
twice their size. MLIR's debug attributes have no enumerators and no vendor attributes, so enums are their backing
integers by name and the table is keyed by linkage name, local name and line. Optimized code puts locals in pieces
(`DW_OP_piece`) unless all of a value is read through memory, so the test reads each value through volatile loads.
Then for 12f (2026-11-08, `0185`): `std/os/slop_os`'s `process_set_debug` (89); base's `Fiber` gained `all_next` and
`all_previous`, and `std`'s `FiberPool` a list of every live fiber through them, for a debugger; the debug table names the
runtime's types after its functions. Two bugs found: base's `slop_os_start_thread` gave x86-64 threads a 16-byte aligned
stack pointer at their entry, 8 off what a called function expects, so an aligned store in a thread's frame faulted
(nothing had made one before a fiber pool on a second thread did); and `std`'s launch kept the address space rightless,
so it couldn't be passed on; it has `RIGHT_TRANSFER` now.
Then for 12g (2026-11-08, `0185`): base's `slop_os_adopt_events_ring`, for a process given its log ring after it
started. A protocol message's 4 KiB limit and a typed file's plain-data lists shaped the recording file: it's laid out
by hand on the heap, its events as a plain struct. A build once stopped in the compiler's JIT (`RuntimeDyld`'s
`resolveRelocation`, COFF x86-64, a fatal error), and didn't again; not chased further.
Then for 12h (2026-11-09, `0185`): base's `CarrierBlock.thread_page`, `Fiber.cpu_budget`, `runtime.note_running_fiber`
and `runtime.bind_cpu_budget`, no-ops but on SlopOS, where they write the per-thread page; std's fiber scheduler calls
the first around each turn. `HemeraTest` embeds base as `hemera` does, so both are rebuilt after a base change.
Imports changed (2026-11-14, decided with the owner, Hemera's `docs/packages.md`): a built-in location is a prefix
with a colon and the package's whole folder, `import uefi from "std:os/uefi"`, and a location without one is always
relative. The name after `import` must be the package's own, from its package statement (E4043), so a different name
is an alias. Every import in `src` was rewritten by script, 1,588 lines in 370 files; 133 took an alias, mostly
`import arch_x86_64 as arch`, `import shell_language as language` and the protocols' `import powerbox as
powerbox_protocol`. The house rules' `is_std` (`src/checks`) tells std's imports by a `std:` location or none. The
specs and the protocols design note use the new form; decisions and `compiler-plan.md` keep the old, as written.
M19, RISC-V (2026-11-25, `decisions/0199`). R1: LLVM's RISC-V backend, three patches of Hemera's (the prologue
stack check, quoted symbols in `call` and `la`, and instruction selection looping on an AND mask with Zba or Zbs,
found compiling `std/ntp`); the carrier `s11`; `morestack`, fibers and stack traces in RISC-V assembly; Linux on
riscv64 in `base` and `std/os`; the thread carrier local-exec in an executable, as RISC-V's linker doesn't relax
general-dynamic. R2: `#calling_convention(.entry)` for `stvec`, `riscv64.RegisterFrame` and `TrapScratch`, CSRs as
compile-time arguments, fences, `sfence.vma`, `sbi_call`, `enter` and `semihosting` in `base/intrinsics/riscv64`,
and UEFI on riscv64 as an ELF Hemera turns into a PE. R3, in `std` only: RISC-V's `CpuFeature`s (128 on) in
`std/os/slop_os`, and `RISCV_EFI_BOOT_PROTOCOL` (`uefi.RiscvBoot`) in `std/os/uefi`, for the boot hart's ID.
R5 (2026-11-26): `riscv64.save_floating`, `restore_floating`, `save_vector` and `restore_vector`, which turn D and V
on for their own instructions in a kernel built without them; SlopOS's runtime in `base` on riscv64 (system calls by
`ecall`, typed libraries as `EM_RISCV` with `R_RISCV_RELATIVE`) and `std/os/slop_os`'s system calls and 33
`THREAD_REGISTERS`; a fiber's first segment 1536 bytes on RISC-V, whose frames are bigger, as 1 KiB overflowed in a
kernel fiber that can't grow; and the UEFI runtime starting a program's first output on a line of its own when the
firmware left the console's cursor mid-line. R6 (2026-11-26): control-flow integrity on RISC-V, Zicfilp's `lpad 0` at
entries and after every call (LLVM patch 0010, the call aligned so its landing pad is) and Zicfiss's `sspush` and
`sspopchk` (LLVM's `hw-shadow-stack`), with the fiber switches keeping `ssp` and the module assembly's landing pads;
`riscv64.TrapScratch`'s `kernel_shadow_stack` and `user_shadow_stack`, for the one `ssp` a hart has for every mode;
LLVM patch 0011's `branch-to-sspopchk`, a branch to each epilogue's `sspopchk` for QEMU 11.1, which loses the pc
after one that passes; `slop_os.shadow_stacks_budget` counting Zicfiss's shadow stacks, as it did CET's and the
GCS's; and the build cache keyed by the linker it finds on the PATH, as an lld that drops RISC-V's property note had
linked a program the cache then gave back. R7 (2026-11-27), from its review: `vstart` zeroed around the
whole-register vector saves and restores, which would otherwise leave a thread another's bytes; morestack, the fiber
switches and the small frame that calls morestack (LLVM patch 0012) pushing and checking their own returns, as
RISC-V's shadow stack checks only the returns that say so, and without which a resumed fiber left it an entry off;
patch 0011's branch made inline assembly, as LLVM took the `BEQ` for the block's terminator; the trap entry clearing
`sstatus.SDT` with `SUM`; and the UEFI runtime noting its first console write with a plain store, as the atomic was
an LSE instruction the bootloader ran on ARMv8.0 before it could say it refuses the CPU. Left as they are: unlabeled
landing pads (`lpad 0`, as IBT and BTI are), the fiber switches' `ssp` from the carrier block's ordinary memory (as
the GCS's is), and the resume loop's indirect jump, which any landing pad passes. Before ABI v1 (2026-11-27): the
linker found beside the compiler before the PATH, Hemera's build putting its own lld there with the DLLs it and the
compiler load, so its `bin` folder is the whole toolchain (`decisions/0200`). M20 (2026-11-27, `decisions/0201`): 20g's
`RiscvSdtrig` CPU feature; 20k's callbacks from C on SlopOS, the runtime pointing each thread's thread pointer (fs
base through the new `thread_set_pointer`, `TPIDR_EL0`, `tp`) at a word holding its carrier block, which the callback
shim reads, as it reads its thread-local slot on Windows and Linux. 20i and 20j's indexes and queries in std's
SlopOS packages: dir's `DeclareIndex`, `DropIndex`, `Indexes`, `Query` and `LiveQuery`, files' `IndexOf`, `Index`,
`IndexedKind` and `Features.indexes`, a `query` protocol package (a live query's channel, and a predicate's terms),
and os's typed API over them (`declare_index[T]`, `where_number[T]`, `where_text[T]`, `both`, `either`, `negate`,
`query_in`, `open_live_query`, `next_live_event`). A predicate's `Term` holds its kind and comparison as `u32`s, as a
Relative's items are plain data, no enums (friction: the server checks each one by hand that the validator would).

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
