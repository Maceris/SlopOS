# Hemera Feedback Log

The stated goal of SlopOS is to test how Hemera's design scales in real-world use. This
file is where that evidence accumulates: what the language, compiler and `std` make easy, hard or
impossible, from building and running the code and from marker comments in the source
(`grep -rn "HEMERA(\|STD(" src/`, see `conventions.md`).

Designs still open live in `hemera-proposals/`; once one is in Hemera, Hemera's docs are the
reference and the proposal is removed. This file is the index and status board.
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

That kernel builds and boots now (2026-10-15, `compiler-plan.md` Phase 6). Items 1–10 (Resolved,
2026-10-12) are referred to by number there and elsewhere; data written by the bootloader was found
and resolved on 2026-10-13.

Found while writing it, each marked in `src/` (`grep -rn "HEMERA(\|STD(" src/`). The plan for
them is `compiler-plan.md`, Phase 7:

| Issue | Severity | Where |
|---|---|---|
| Once (2026-10-16), building the kernel through the build package in `boot_tests.py` failed, and the output was lost. Likely found 2026-10-20: the compiler crashed (an access violation, no output) when indexing through a pointer to an alias another thread hadn't resolved yet, about one build in four of std/crypto's tests; fixed, the checker now waits for it. Another race found 2026-10-22, about one kernel build in thirty (see Resolved). Watching whether the kernel build fails again; `build/failed_kernel_build.log` keeps its output if so | unknown | `tools/boot_tests.py` |

### Language and library design

| Topic | State | Details |
|---|---|---|
| Builds of many outputs | Adopted (2026-10-05) in `base/compiler/build.hsc`; `os.run_process` runs processes since 2026-10-19 (Windows and Linux). Still open: sharing parsed files between targets and building them in parallel, documented as planned in Hemera's `docs/compilation.md` (2026-10-19); `find_packages` is unimplemented and may be removed | `hemera-proposals/build-programs.md`; `decisions/0028` |
| Kernel entry on AArch64 and RISC-V (needed after M3, `0022`) | x86-64 resolved 2026-10-13 (see Resolved). The same pattern is outlined for the others: a frame type, `.entry`, an entry-table intrinsic (AArch64's `VBAR_EL1` table), `return_to_user` (`eret`, `sret`), and system-register instructions | `hemera-proposals/kernel-entry.md` |
| Cryptography in `std` (needed with networking and remote login) | Planned 2026-10-19, directions chosen with the Hemera author: SHA-256/512, BLAKE2b, BLAKE3, HMAC, HKDF, ChaCha20-Poly1305, AES-256-GCM (hardware from the start, through `vector[T, n]`, `v128` and per-function `#target_features`), X25519, Ed25519 and Argon2id, in one freestanding `std/crypto`; `#constant_time` checked by the compiler, with secrets marked on types (`#secret`). All six phases done (2026-10-19 to 20), plus Project Wycheproof's vectors and the machine code checked under Valgrind (`--valgrind-secrets`) | `hemera-proposals/cryptography.md`; `decisions/0042`, `0043`, `0019` |

### Found building programs (roadmap M6, stage 6a, 2026-10-23)

- Comparing two optionals (`a != b` with both `u64?`) checks, then fails to generate ("comparing
  Optional[u64] values can't be generated yet", E5002); unwrapping them first works. Found in
  `src/elf_loader/test`. Severity: nice.

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

## 3. Resolved

- 2026-10-23 — M6 stage 6a (`decisions/0059`): Hemera targets SlopOS. The compiler has `OSType::SlopOS`
  (`--os=slopos`, `os = .SlopOS` in a build package), whose startup code is the entry, given the startup
  block's address, ending the process with `main`'s result through `runtime.os_exit_process`, and linked as a
  static PIE. `base/runtime/slop_os.hsc` is the runtime's SlopOS layer (memory, clock, exit), with the page
  heap now shared with Linux (`page_heap.hsc`); `std/os/slop_os/startup.hsc` checks base's copy of the call
  numbers and the startup block at compile time. Two compiler fixes on the way (`0047`): `#assert` evaluates
  `cast` between integer types, the bitwise operators and shifts (documented in Hemera's
  `docs/directives.md`); and the ABI generator's stubs for calls that never return take their parameters.
- 2026-10-23 — Read-only unless given `mut`, decided with the Hemera author and documented in Hemera's
  `docs/types.md` (*Mutability*, *Array Views*). `mut` on `packets: mut Packet[]` meant nothing: a view's elements
  could always be changed, as could a dynamic array parameter's, and through a view inside a read-only struct. Now
  `T[]` only reads and `mut T[]` writes (reflected as `ArrayDimensions.is_mutable`); static and dynamic arrays
  follow what holds them; an array becomes a `mut T[]` only where it can be changed, implicitly at a call;
  `rawptr` only reads and `mut rawptr` writes; and `mut` that changes nothing (`n: mut int`) is an error.
  Allocators return `mut u8[]`, `view_of` from a `ptr[mut T]` gives a `mut T[]`, and the memory intrinsics take
  a `mut rawptr` destination. SlopOS needed `mut` on the views it writes: boot-info conversion, the memory map,
  the frame allocator's states, the timer heap, the slab's batches, `Kernel.per_cpus`, and the tests' packet and
  byte buffers.
- 2026-10-23 — The Hemera gaps found writing the generated ABI, and two older frictions, fixed in the compiler
  (`0047`) and documented in Hemera's docs, with tests (`expression_forms`, `inserted_member_names`):
  - `(expr).field`, `(expr)[i]` and `(expr)^` parse: a parenthesized expression takes a chain like a name.
  - `Result[T, E].Error(e)`: a variant named with the type's arguments.
  - An enum shorthand (or `.{...}`) as a generic function's argument waits until the other arguments or the
    result decide its type.
  - Enum and union shorthand looks through an optional (`return .ObjectGone` for a `PortError?`), decided with
    the Hemera author.
  - A function declared inside a function is a declaration of its own, generated like any; one with several
    names or generic parameters is refused with an error.
  - `#insert` names members in a quote, as chosen with the Hemera author: `#insert name = value` and
    `#insert name,` among an enum's members, `#insert name : T` among fields, and `value.#insert name` and
    `.#insert name` to reach one. A list of `#code members { ... }` quotes (and fields, variants, patterns,
    cases) puts each one's items in place, so an enum can be generated a member at a time from a table.
  - Printing made `fields`, `variants`, `members`, `patterns` or `cases` code (`compiler.code_text`) printed
    only the word; it prints the items now.
- 2026-10-23 — M5 stage 4d (`decisions/0057`): `std/os/slop_os` generates its stubs, call numbers and the
  kernel's dispatch from `Syscalls`, a struct of typed function types (`syscall_table.hsc`), with typed
  handles, slices and `Result`s. Two compiler fixes on the way: in a quote, `#insert` of patterns, cases,
  fields, variants or members spreads their items among the quoted match's, switch's or type's, as
  statements and lists already did; and printing a quote maps each `#insert` placeholder to its operand in
  the parser's order, so the printer's own order (string concatenation's, which the MS ABI evaluates right to
  left) no longer swaps them.

- 2026-10-23 — `std/os/slop_os`, for M5 stage 4c (`decisions/0056`): the `Intercept` kind, the five process
  rights, calls 34 to 44 (threads, memory, suspend and resume, registers, intercepts, kill), `StopPoint`,
  `StopInfo`, `InterceptAction`, `THREAD_REGISTERS`, `SIGNAL_TERMINATED`, the `Stop` packet kind and
  `ControlError`. No compiler change was needed.

- 2026-10-23 — `std/os/slop_os`, for M5 stage 4b (`decisions/0055`): the `Platform` object kind,
  `ControllerRegister`, `IrqCreate`, `IrqAck`, `MemoryCreatePhysical` and `MemoryCreateWindow`,
  `ControllerKind`, `IRQ_LEVEL` and `IRQ_ACTIVE_LOW`, `CacheMode`, `RIGHT_IRQ_ACK`, the `Irq` packet kind and
  `DeviceError`. No compiler change was needed.

- 2026-10-23 — `std/os/slop_os` (the ABI package), for M5 stage 4a (`decisions/0054`): the memory calls
  (`MemoryBudgetCreate`, `MemoryBudgetInfo`, `MemoryCreate`, `MemoryMap`, `MemoryUnmap`), a budget argument
  first on every creation call, `RIGHT_BUDGET_CHARGE` and the memory rights, `Protection`, `MemoryError`,
  `MAX_MEMORY_SIZE`, and `BudgetExceeded` (tag 25) in every error enum. No compiler change was needed.

- 2026-10-23 — Code insertion, phase 6 (first users), the Hemera part: `base/intrinsics/atomics.hsc`'s 714
  declarations are made at compile time from a list of 14 types, the orderings each kind of operation takes,
  and the operations' signatures, identical to what was written by hand (checked declaration by declaration).
  It costs about 17 ms a build. Needed on the way: `compiler.name` joins its parts (`name("atomic_load_", type,
  ordering)`, chosen 2026-10-23); `#insert` result types, named or not; a name looked up in an imported package
  whose top-level `#insert` may declare it is used provisionally, like the file's own, rather than waiting
  (runtime imports intrinsics, whose `#insert` needs runtime to run); `--generate-all` skips functions that only
  run at compile time; and `--show-inserted` prints a list of declarations a line each.

- 2026-10-23 — Code insertion, phase 5 of 6: `#macro` functions called as `name!(...)`, their `compiler.Code`
  arguments quoted as written, expanded hygienically: locals a macro's code declares are invisible to the caller
  (and the caller's to it), its other names resolve from the macro's own file and imports, and argument code stays
  the caller's. Expansion stops 64 insertions deep. Also fixed on the way: a statement may start with an
  assignment to an insertion (`#insert target += 1`), and an insertion chain's notes now include how the site
  itself was inserted.

- 2026-10-23 — Code insertion, phase 4 of 6: code made from values, `compiler.name` (only ever an identifier),
  `literal`, `type_code`, `list`, `parameters` and `arguments` of a function type, and `described_type` for a
  reflected member's type; looking at code with `code_kind`, `identifier_of`, `items_of` and `location_of`; and in
  quotes, `#insert` as a declaration's name, in parameter lists and in types (`ptr[mut #insert T]`). A scenario
  generates a function per member of a struct of function types, which is the syscall table's stubs' shape.

- 2026-10-23 — Code insertion, phase 3 of 6: `#insert` at the top level, where its code's declarations are the
  package's, and among a struct's fields, a union's variants, an enum's members, a match's patterns and a switch's
  cases. What goes inside something else is quoted with a word naming it, chosen with the Hemera author:
  `#code fields { }`, `variants`, `members`, `patterns` (match) and `cases` (switch), so `#code struct { }` stays a
  struct. A top-level `#insert` waits like an undecided `#if`; imports and builtins are used without waiting and
  checked once everything is decided. The syscall table's stubs can now be generated into the ABI package.

- 2026-10-23 — Code insertion, phase 2 of 6: `#insert` outside a quote puts code made at compile time into a body,
  statements among the statements around them and expressions in place, checked as if written there; errors in it
  are reported where it was written, then where it was inserted; `--show-inserted=file:line` prints what was put
  there. Not yet at the top level (phase 3) or in generics, and names resolve where the code lands until hygiene
  (phase 5).

- 2026-10-23 — Code insertion, phase 1 of 6 (`hemera-proposals/code-insertion.md`, asked for before M5's fourth
  stage): `#code(...)` and `#code { ... }` quote code as a `compiler.Code`, and `#insert` in a quote splices code, a type
  or a literal, binding like a prefix operator; `compiler.code_text` prints it, through a new tree printer that every
  file in Hemera's base, std and scenarios round-trips through. Found on the way: a line longer than 65535 characters
  hung the lexer, whose 16-bit column wrapped; it's an error now (E2007). Next: `#insert` outside quotes (phase 2).

- 2026-10-22 — `std/maps` gains `map_try_put` and `map_try_resize`, which give the allocator's error and leave the
  map as it was when growing fails; `map_put` asserts, which would let user space stop the kernel by running it out
  of memory. Ports keep their bindings in one (M5, stage 2). Tested in the `maps` scenario with an allocator that
  always fails.

- 2026-10-22 — `&cast[T](x).field` failed to parse: after `&`, the parser read the next token as a name, so it
  reported "Undeclared name. cast". Kernel code reaching an object's field by its address needs exactly that.
  It parses as the address of the cast's chain now; tests in the parser's valid scenarios and `using_fields`.
- 2026-10-22 — `base` gains `x86_64.system_call`, a system call answering in `rax`, `rdx` and `r8`, as SlopOS's
  do; `x86_64.syscall` gives only `rax`, Linux's way. Checked on Linux with `getpid` (the `system` scenario), and
  used by M5's tests until the ABI package generates stubs. The ABI package itself (`std/os/slop_os`) gains its
  first system calls, handles, rights and errors (`syscalls.hsc`).

- 2026-10-22 — Entry functions' generated code now clears `RFLAGS.AC` before the body, with `pushfq`, `andq`
  and `popfq` (`clac` faults on CPUs without SMAP). An interrupt gate leaves AC as user code set it, which with
  SMAP enabled lets the kernel reach user memory; `SYSCALL` already cleared it through `IA32_FMASK`. Found while
  writing M4's return to user mode; documented in Hemera's `docs/calling_convention.md` (*Entry Functions*).
- 2026-10-22 — M4's threads needed nothing else new from Hemera: `.entry` frames kept in thread objects and
  `return_to_user` from them, `xsave`/`xsaveopt`/`xrstor`/`xsetbv`, and a `#no_context` function as user code. Two
  small things: `base` has no count-leading-zeros intrinsic (the run queue finds its highest level by halves), and
  a result named like a local inside its function compiled without complaint.

- 2026-10-22 — The generator keeps scalar locals and parameters that nothing assigns to or takes the address of as
  values, rather than storing each in a stack slot and loading it back. The kernel's unoptimized IR went from 25,023
  instructions to 21,060 (loads 6,884 to 4,768, stores 3,992 to 3,071, allocas 2,729 to 1,808). As measured first,
  O2 takes the same time either way, since LLVM takes values out of memory cheaply (SROA and early CSE, about 55 ms on
  the kernel); unoptimized code generation got about 10% faster and the object about 1% smaller. The kernel build's
  time is in InstCombine, inlining and GVN, which only less code would cut.
- 2026-10-22 — A function type's defaults can be any expression, as a function's can: checked with the names the
  package and file where the type is written see, once, and generated in each caller from what that check found.
  A named function type's (an alias's, `Handler :: fn(...)`) are checked where it's declared, whether or not a call
  uses them; one written in place, like a field's, with the first call that leaves one out. Only one piece of work
  checks each default, so its errors are reported once. Before, a type's default had to be a literal, constant, enum
  member, `.{}`, `#caller_location` or a context field.
- 2026-10-22 — A race in checking: about one kernel build in thirty failed with "BootModule has no field name" at
  `modules[i] = .{name = ...}` in `src/boot/limine/convert.hsc`. A `.{...}` literal took the type expected
  there as it was, here a view parameter's elements, and a signature only needs its types declared, so another
  thread could still be laying `BootModule` out, with no fields yet. `Type.{...}` already waited for its type to be
  complete; `.{...}` now waits for the type expected too. 0 failures in 60 builds after, against 1 in 30 before.
  `build/failed_kernel_build.log` kept the output, as intended.
- 2026-10-22 — `std/time` was tiered `Os`, though it only reads `context.clock`, which every context has, and does
  calendar arithmetic. The kernel's clock test needed it, and the tier check refused; it's `Freestanding` now.

- 2026-10-22 — Freeing passes the alignment, decided with the Hemera author and documented in Hemera's
  `docs/memory.md` (*Allocators*). `free` and `free_array` passed alignment 0, so an allocator couldn't tell an
  over-aligned block from another of the same size, and the kernel heap refused alignment beyond a block's natural
  one. Now freeing and resizing pass the block's alignment as it was allocated, as `old_size` is its size: `free`
  and `free_array` pass the type's, and new `free_aligned` and `free_array_aligned` pair with `new_aligned` and
  `new_array_aligned`. `Array`, `SharedPtr` (which keeps the alignment in its header), directory listings and fibers
  pass theirs. The kernel heap now picks a block by size and alignment, serving 24 bytes aligned to 64 KiB, and a
  request past the frame allocator's largest block fails with `OutOfMemory` instead of tripping its assertion.
- 2026-10-22 — Defaults in function types, decided with the Hemera author and now in Hemera's `docs/functions.md`
  (*Defaults in Function Types*). `AllocatorFn` gives `location` a default, and checking accepted a call through an
  `Allocator`'s `function` that left it out, but generating it failed (E5002): a function type recorded only that
  a parameter had a default, and the generator looked for it on the called declaration. Now a function type keeps
  each default's expression, outside its identity, so types differing only in defaults still convert. A call
  through a function's name (or a constant naming one) uses the function's defaults; any other call, the callee's
  type's. A function that states its type inherits the type's defaults and can't change them (E4038). The compiler
  generates a function type's defaults when they're literals, constants, enum members, `.{}`, `#caller_location`
  or the context's fields. `std`'s `SharedPtr` and the kernel's heap test no longer pass `#caller_location` by hand.
- 2026-10-22 — `base`'s `fiber_destroy` freed a fiber with `free(fiber)`, which passes `size_of(Fiber)`, though
  `fiber_create` allocated `FIBER_BLOCK_SIZE` bytes, the fiber and its first stack segment; so did `fiber_create`'s
  own error path. Allocating whole frames hid it, since both sizes were one frame; the kernel's slab heap (M2), which
  tells blocks apart by size, caught it in the pool test. Both now free the whole block (`free_array` of
  `FIBER_BLOCK_SIZE` bytes).
- 2026-10-22 — M2's paging needed nothing new from the compiler: page-table entries through `ptr[mut u64]` with
  release stores, `for level in leaf..=3 #reverse` for walks, and the bounds prover taking `% 512` for table indexes
  and `count - 1` after `count >= 1 && count <= 4`. Two things it doesn't follow, worked around: a bound on what a
  call returns (an index helper had to become a helper that returns the entry's address), and `/ 64` on a bounded
  value (written `>> 6 % 64`). A hosted unit test imports the whole x86-64 arch package and runs its paging over a
  buffer standing in for physical memory.

- 2026-10-22 — Linking the kernel took 0.14 s, most of it Windows starting cmd.exe to run ld.lld; the compiler runs
  the linker directly now, found on the PATH: 0.03 s. The kernel builds in 1.33 s, the tests in 0.73, Hemera's test
  suite in 25 s. `--time-phases` now splits LLVM's time into simplifying the whole module (0.54 s for the kernel,
  inlining and the rest of O2's simplification) and the parts optimized and assembled at once (0.18 s). The
  simplification is LLVM's usual spread over its passes, nothing to cut alone; what would is less IR to start with.

- 2026-10-22 — A persistent compile-time JIT: each program has one, every run's module in a library of its own
  that links to the earlier ones, so a function compiled for one run, like the compile-time context's logger and
  allocator, isn't compiled again for the next. Generating the kernel (19 runs, one for each Limine request
  constant) went from 0.15 s to 0.06-0.1; the kernel builds in 1.4 s rather than 1.6, the tests in 0.76 rather
  than 0.9, and Hemera's test suite in 28 s rather than 32.

- 2026-10-21 — The kernel builds in 1.6 s rather than 2.2, the tests in 0.9 rather than 1.2. The build check
  (`checks.check_program`) took 0.35 s: each `compiler.find_constant(package, "PACKAGE_TIER")` worked the value out
  in a compile-time run of its own, though describing the program had just worked out every constant; values are
  kept now, by declaration, so it takes no time. And compile-time code is compiled with LLVM's quick code generator,
  since it's unoptimized and mostly runs once: describing the program went from 0.2 s to 0.08, generating the
  kernel from 0.27 to 0.15. What's left of generating is 19 small runs, one for each Limine request constant
  (`request[T](...)`), each compiling the compile-time context's logger and allocator again; compiling those once
  for all runs would take a persistent JIT.

- 2026-10-21 — SHA-512 from 550 to about 600 MB/s (OpenSSL's hand-scheduled assembly does 1,000 here): rounds unrolled
  eight at a time with the working words renamed rather than moved, each round's constant added to its schedule
  word first, majority from the last round's a ~ b, and whole blocks' words read straight from the input. Tried and
  dropped: a BMI2 and AVX2 copy of the compression, which LLVM made no faster (rorx, but the same count of other
  instructions); closing the rest of the gap would take the schedule interleaved into the rounds by hand, in
  assembly. Software AES (141 MB/s alone, 105 with GHASH) is at its algorithm's cost: about 100 instructions a byte
  for bitsliced AES on 64-bit words, as BearSSL's ct64; more needs vector registers, which the path exists to avoid.

- 2026-10-21 — Checking a program took about 140 ms, and up to 100 of it was waiting: when the last work
  finished, the thread that noticed stopped, but the others slept on until their 100 ms timeout, which the check
  waited for. Now they're woken: the kernel's check takes 31 ms, the build package's 94, and Hemera's front-end
  tests run in 4 s rather than 19 (the whole suite in 31 s rather than 47). Checking uses about one thread a
  physical core (half the logical processors), at most 8, which measured best. Also: the interned strings were
  found by hash alone, so two names whose hashes collided would have been the same name; they're found by text
  now, in 64 shards with a lock each. And Windows programs link with `/Brepro`, so they and their PDBs build to
  the same bytes every time, like ELF ones.

- 2026-10-21 — Parallel code generation: after LLVM simplifies the whole module (inlining across all of it), the
  compiler splits it into up to 8 parts, and optimizes and generates each on its own thread into its own object
  file. The kernel builds in 2.2 s rather than 2.7, the tests in 1.2 rather than 1.3, and Hemera's test suite in 47 s
  rather than 53; the kernel comes out byte for byte the same every time, and the same size as from one part. Found
  doing it: the module-level assembly the compiler writes (`#foreign` shims, fiber switches) defined its functions
  locally, which only works in one object file, so the split makes them global.

- 2026-10-21 — Compiler speed, second round: the kernel builds in 2.7 s rather than 4.8, the tests in 1.3 rather than
  1.7. `hemera --time-phases` prints each phase's time, which showed most of it was describing the program to the
  build's check (`src/build`): working out every package's constants took 2.4 s, since a constant holding functions,
  like a logger, failed its package's whole batch, which was then run one constant at a time, a compile-time run each,
  and the font's 26 KB of `#file_data` was copied with a store LLVM split into thousands. Now a constant that can't be
  kept is left out on its own, all packages' constants are worked out in one run, and a large constant is copied from
  a read-only global: 0.2 s. Checking uses at most 8 threads, which is quicker than 24, since past a few they mostly
  wait on the names registry. What's left: LLVM's O2 passes and code generation, about 1 s of the kernel's build,
  spread over the usual passes; the build check itself, 0.35 s; and checking each program, about 0.15 s.

- 2026-10-21 — Faster `std/crypto`, second round. The field's squaring has its own 15-product formula, and adding
  doesn't carry: X25519 42 to 28 us. Ed25519 verifying adds both multiples along one chain of doublings, with
  windows of signed digits (it's public, so needn't be constant time): 102 to 43 us. Signing reduces mod L a byte
  at a time rather than a bit, reads its table without a division per limb, and `Ed25519KeyPair`
  (`ed25519_key_pair`, `ed25519_sign_with`) keeps the public key signing needs: 45 to 28 us, 15 with a pair.
  BLAKE2b takes whole blocks straight from the input and compresses with AVX2, a row of v a vector: 495 to 1,250
  MB/s. Argon2id's compression does the same, 27 to 18 ms, with `argon2id_keyed_with(..., wide = false)` for a
  kernel. Compiler changes found by it: a constant that's a `#run` ran twice, the second time only to copy out
  what the first gave, and a static array of numbers from compile-time code was built an element at a time, which
  LLVM folds into a new array for each, quadratic: a 30 KB table took 1.3 s to build into a program, now 60 ms,
  as one dense constant. And a directive starting the line after a type alias with one, like `#if` after `Word ::
  distinct alias u32 #secret`, was read as another of the alias's.

- 2026-10-21 — The bounds prover's gaps left by the crypto work: a difference compared with a constant
  (`data.count - at >= 16`) now says `at + 16 <= data.count` once `at <= data.count` is known, so it can't wrap; sums of
  bounded values (`16 * b + 4 * j + k`) are bounded; and `x %% n`, floored, is never negative for a constant `n > 0`,
  even of a signed `x` (`%` stays truncated, so still not). Three `%` workarounds in `std/crypto` are gone.

- 2026-10-21 — Faster `std/crypto`: software AES bitsliced (Boyar and Peralta's S-box circuit, four blocks at once)
  with GHASH by masked integer multiplies, from under 1 MB/s to about 100; ChaCha20 eight blocks at a time with
  AVX2, or four in 128-bit vectors, and Poly1305 on 64-bit limbs, together 1 GB/s; BLAKE3's whole chunks eight or
  four at a time, 2.8 GB/s; SHA-256 with the SHA extensions, 1.5 GB/s; AES-NI four blocks at a time with GHASH's
  products reduced once per four, 1.4 GB/s; Ed25519 signing with a table of the base point's multiples worked
  out by `#run` while compiling, 43 us. Each vector or hardware path has a switch for a kernel without vector
  state (`hardware`, `wide`, the `_with` functions). Compiler changes found by it: the pass builder now gets the
  target machine, so LLVM costs inlining and vectorizing for x86-64 rather than generically, and inlines across
  `#target_features` (it couldn't before, which left AVX2 code calling SSE copies); a checker race, indexing a
  value whose type is an alias another thread hadn't resolved, a crash in about one build in a hundred under load;
  `x86_64.sha256_rounds2`, `sha256_message1` and `sha256_message2`; and Release builds keep a PDB, for tracing a
  crash. Found but left: the bounds prover doesn't take `data.count - at >= 16`, only `at + 16 <= data.count`,
  nor sums of several scaled loop names.

- 2026-10-20 — Compiler speed. A Release compiler, with a Release LLVM, builds SlopOS's kernel in 5 s rather than
  65, its tests in 1.6 s rather than 18.6, and runs Hemera's test suite in about a minute rather than ten: nearly
  all the time had been a Debug LLVM's code generation. `hemera` on the PATH should be `bin/Release`. Debug and
  Release now build side by side (Hemera's MLIR dialect library had one output for both, so they overwrote each
  other). Found along the way: a checker race, comparing an optional with what it holds (`error !=
  OsError.AlreadyExists`) before another thread finished the optional's type, a wrong type error in about one
  build in 40 under load, now waited for, with 1,140 parallel builds of every test clean; and an output path in a
  folder that doesn't exist crashed the compiler, now error E6000.

- 2026-10-20 — Large values, as Hemera's `docs/calling_convention.md` (*Large Values*) now says: a result or
  parameter over 16 bytes goes through a pointer, the result's passed first by the caller, the parameter a copy in
  the caller's frame; and large values are stored with memset and memmove rather than whole. LLVM had been copying
  them a value per byte (an optional of a 1.9 KiB hasher was 5,600 instructions), so `std/crypto`'s hash tests build
  in 1 s rather than 5 (70 on the Debug compiler that morning). The docs had the callee popping its arguments and
  result pointers among the stack parameters, which wasn't so; they say what's done now. Found along the way:
  another checker race, `compiler.release` on an `#owned` type before its type or its release function was known,
  a wrong error in about one build in ten under load, now waited for.

- 2026-10-20 — Encryption, phase 4 of cryptography: ChaCha20-Poly1305 and AES-256-GCM in `std/crypto`, AES-GCM
  with AES-NI and PCLMULQDQ or in constant-time software, tested against RFC 8439, NIST and Python's
  `cryptography`. Struct literals take secrets only in `#secret` fields; a pointer to a secret can't be cast to a
  pointer to what isn't (`rawptr` is the visible way past). A compiler crash found along the way: indexing
  through a pointer to an alias that another thread hadn't resolved yet.

- 2026-10-19 — Hashes, phase 3 of cryptography: `std/crypto` with SHA-256, SHA-512, HMAC, HKDF, BLAKE2b and
  BLAKE3, public and secret inputs and outputs, all checked by the secret rules, tested against published and
  independently computed values. Writing them found three gaps in the bounds prover (scaled indexes, bounded
  products, signed loop names from 0), now proven; `x & ~MASK` on unsigned values needs a cast of `MASK`, a
  small friction worth watching.

- 2026-10-19 — Secrets, phase 2 of cryptography (`hemera-proposals/cryptography.md`): `#secret` structs and
  distinct aliases, the compiler checking a secret never decides a branch, loop, index, pointer or division
  (E4037), secrets crossing functions only through `#secret` types, `#constant_time` on functions whose
  signatures hold secrets, with a warning when one holds none (W4002), `compiler.declassify` and `secret`,
  `intrinsics.select` without a branch, and `secure_zero` (Hemera `docs/memory.md`, *Secrets*).

- 2026-10-19 — Vectors, phase 1 of cryptography (`hemera-proposals/cryptography.md`): `vector[T, n]` and
  `v128`/`v256`/`v512` (Hemera `docs/types.md`, *Vectors*), base/intrinsics' vector and bit functions (`splat`,
  `select`, `rotate_lanes`, reductions, `rotate_left`/`right` and `byte_swap` on integers too),
  `#target_features` (`docs/directives.md`), and x86_64's AES and carryless multiply, tested against FIPS-197.
  Found along the way: a typed literal couldn't be an operand (`a < Words.{2, 2, 2, 2}`), now it can; and a
  `for` with `#reverse` couldn't be generated, now it can (Hemera `docs/control_flow.md`, *Range-based for*).

- 2026-10-19 — Integer literals are checked against the range of the type they become (`small : u8 = 300`, `-1`
  as a `u32`, `0xffff_ffff_ffff_ffff` defaulting to `int`), and arithmetic on known integers and untyped constants is
  worked out exactly as `docs/operators.md` defines it, so `255 + 1` as a `u8` is an error, `512 / 4` as a `u8` is
  128 (it used to be worked out in the `u8`, giving 0), and dividing by a known zero is an error (Hemera
  `docs/types.md`, *Number Formats*). Found writing `os.run_process`, where `0..<0xffff_ffff_ffff_ffff` ran no times.
  Optional and named function results, like `-> (f: (fn() -> int)?)`, now parse too.

- 2026-10-19 — Build packages' targets documented as they are (Hemera `docs/compilation.md`, *Build Packages*): one
  at a time, each parsed and checked on its own; sharing parsed files and parallel targets are planned. The
  adopted proposals were removed from `hemera-proposals/`, Hemera's docs being the reference, leaving only what's
  open (`build-programs.md`, `kernel-entry.md`) and `bitfields.md`'s decision.

- 2026-10-19 — Shared ownership, all five phases, with directions chosen with the Hemera author: `using` on named
  fields (`docs/types.md`, *Structs*), `mut` in type arguments (*Mutability in Type Arguments*), `#owned` types the
  compiler checks are released or moved, with `#release` and `compiler.forget`/`duplicate` (`docs/memory.md`, *Owned
  Types*), std/memory's `SharedPtr`, `WeakPtr` and `LocalPtr`, one-pointer handles to a block with strong and weak
  counts and what runs at the final release (*Shared Ownership*), and `#thread_bound`/`#crosses_threads` so a
  non-atomic `LocalPtr` stays on its thread (`docs/multitasking.md`). Data races through shared mutable pointers
  (Rust's `Sync`) stay out of scope.

- 2026-10-19 — Constraints on generics, phases 1 to 3 (finding functions by name dropped: functions a generic needs
  are passed), with directions chosen with the Hemera author: `#constraint` functions of requirements, structural,
  `T: A && (B || C)` and `where`, checked where instances are made (E4032) and, for constrained generics, in their
  bodies through archetypes (E4033), `compiler.satisfies` for `#if`, derived parameters and generic aliases, and
  std/maps' `HashMap` taking its hash function (Hemera `docs/types.md`, *Constraints*, *Checked Bodies*).

- 2026-10-19 — Small frictions: an optional function type is written in place as `(fn(n: int) -> int)?` (the
  parentheses make the `?` the function's), in fields, parameters and locals, so an alias like `SharedPtr`'s `Destroy`
  is a choice, not a need; `mut` can be written in an expression, like `compiler.Mutable(mut Config)` in an `#assert`; and
  `os.run_process` runs processes on Windows (`CreateProcessW`, pipes read by polling, arguments quoted for the C
  runtime) and Linux (fork and execve with a PATH search, a close-on-exec pipe for exec failures, poll), tested by
  running itself with arguments that need quoting.

- 2026-10-19 — Format string options, chosen with the Hemera author: `%{...}` after a placeholder,
  like `%{08x}`, `%2{>10}` or `%{.3}` (fill and alignment, `+`, `#` prefix, zero padding, width,
  precision, and `d`/`x`/`X`/`b`/`o`), the same in base's `output_format`, `text_buffer`'s
  `append_format` and compile-time messages, from one parser in `base/runtime/format.hsc`. A format
  string written in place, for a `format_string` parameter followed by `any...`, is checked where
  it's used (E4034): a placeholder without a value, `%0`, options that aren't well formed, or ones
  the value's type can't take. Hemera's `docs/format_strings.md`. The stack trace now writes its
  offsets with `%{#x}` rather than `text_buffer`.

- 2026-10-17 — Linking C on Linux (`compiler-plan.md` Phase 11, step 10): a hosted Linux program
  with `#foreign` functions of its own links libc dynamically, starts through it, makes pthreads,
  and takes callbacks.

- 2026-10-17 — A compiler quality pass over gaps found along the way: the bounds proofs now
  know an unsigned remainder by a constant is below it (wrapped or not), and keep what they knew
  about an integer field a store changes (`count -= 1` moves it, `count = 3` sets it; other paths
  are still forgotten, since they may alias); a generic value of the wrong kind is reported at the
  use (`Ring[u8, true]`), not at the generic; and a callback finds its carrier block in one load
  from the thread environment block on Windows. Each with a test.

- 2026-10-17 — `std/containers` (roadmap M0): `FixedArray[T, capacity]`, `RingBuffer[T, capacity]`,
  `Bitmap[size]` and an intrusive `List` of `ListLink`s, none allocating, in the freestanding
  tier, tested hosted on Windows and Linux. Found: the bounds proofs forget what they knew about a
  field once it's assigned, so `array.count -= 1` then `items[array.count]` isn't proven; reading
  `items[last]` before `array.count = last` is.

- 2026-10-17 — Two open questions settled with the Hemera author: `.AssertionHandler` is gone from
  `StackCheckFailure` (only `.Morestack` and `.Trap`; the compiler had quietly turned it into no
  check), and on Windows the thread environment block's stack bounds stay the thread's own, since
  system code only runs there and faults on segments reach vectored handlers first
  (`docs/calling_convention.md`, *Windows x64*).

- 2026-10-17 — Hosted programs and threads on Linux x86-64 (`compiler-plan.md` Phase 11, step 9),
  without a C library. Found: hosted Linux programs entered at `hemera_entry` with `_start`'s
  stack alignment and nothing to return to, were linked as PIEs nothing relocated, and lost
  `main` from stack traces when LLVM inlined it into the entry (Windows never did, since the two
  use different conventions there).

- 2026-10-17 — Parameter defaults can be any expression: they're checked with the function
  (before its parameters exist, with its package's names) and generated at each call that leaves
  them out, in the caller, with the caller's context (docs/functions.md, *Default Values*). A
  default that doesn't fit its parameter is E4015.

- 2026-10-17 — Generator gaps found in Phase 11: struct field defaults are now worked out as
  compile-time constants and used by literals that leave the field out and by declared variables
  (docs/types.md said so, but nothing did); a constant of a union with values (`PICKED : Shape :
  .Rectangle(3, 4)`, `DEFAULT_THREAD_STACK`) is built as a struct shaped like its variant, since a
  constant has no memory to build one in. Still not: a parameter default that's an expression
  rather than a literal, `context`, a named constant, an enum member or variant without values
  (`.Fast`, `.None`), or an empty struct literal (`Options.{}`), which work. Also: configuring the compiler applies the
  LLVM patches.

- 2026-10-17 — Callbacks from foreign code into Hemera (`compiler-plan.md` Phase 11, step 8), on
  Windows x64: `.c` functions with a context work, through an entry shim.

- 2026-10-17 — The fiber memory budget (`compiler-plan.md` Phase 11, step 7): `Fiber` is 160
  bytes, a fiber's block 1440 of 1536. Found: LLVM compared the stack pointer itself against the
  limit for frames under 256 bytes, which could use most of the 256-byte guard before morestack
  pushed anything; the limit-register patch now always compares the frame's end.

- 2026-10-17 — Allocating stack segments when a carrier's cache is empty (`compiler-plan.md`
  Phase 11, step 5): fibers on any thread, and plain threads past their own stack, now grow.
  Found: LLVM drops unused parameters of internal functions, the context included, so nothing can
  assume `rdi` holds one at a function's prologue.

- 2026-10-17 — `compiler-plan.md` Phase 11, step 4: `runtime.park` and `runtime.wake`, and a
  `Mutex` in `std/concurrency`. Found and fixed: a `match`'s bound values were the matched
  place's memory rather than copies, so `case Some(waiter) => { here.parking = null; ... waiter }`
  read null. Found, not fixed: `Fiber` grew to 240 bytes, which uses the memory budget's slack
  (1520 of 1536 bytes per fiber).

- 2026-10-16 — `compiler-plan.md` Phase 11, step 3: threads in hosted programs on Windows, a heap
  for `main`, and pool carriers that sleep. Found, not fixed: constants of a union with a payload,
  and struct field defaults inside a constant, can't be generated, and a parameter's default can
  only be a literal, `context`, or a simple constant.

- 2026-10-16 — `compiler-plan.md` Phase 11, step 2: foreign functions (`#library`, `#foreign`,
  `#link_name`) called through a shim that runs them on the thread's own stack.

- 2026-10-16 — `compiler-plan.md` Phase 11, step 1: fiber pools shared by several carriers,
  tested on SlopOS's CPUs. Found, not fixed: the bounds proofs treat a `u64` as possibly negative,
  so `(tail + i) % SIZE` isn't proven in bounds while `& MASK` is; `std/fiber` masks.

- 2026-10-16 — `compiler-plan.md` Phase 10, step 4: fibers and `morestack` on Windows, and a
  scheduler in `std/fiber`. Decided with the Hemera author: on Windows, Hemera's functions use
  System V's registers and classic frames without Windows unwind information (a second LLVM patch,
  `"classic-frame"`), so the switches and walks are the same code everywhere; frame-based SEH and
  C++ exceptions can't pass through them. Found on the way: `new_aligned`, `new_array_aligned`,
  `free` and `free_array` were still `todo`, so nothing could allocate through an allocator;
  comparing an optional with `null` wasn't generated; and hosted programs never set the carrier
  register, which a stack check reads in `main`'s prologue. All fixed.

- 2026-10-16 — `compiler-plan.md` Phase 10, step 3: stack traces through the fiber resume loop and
  across stack segments, and `capture_fiber_stack_trace`. The docs now say how segments are left
  out (two return addresses, `morestack`'s continuation and then `.grow`'s), and that the switches
  keep a fiber's `state` current, which the docs assumed but nothing did.

- 2026-10-16 — `compiler-plan.md` Phase 10, step 2: `morestack` and stack segments, tested in a
  kernel built with morestack. `docs/calling_convention.md` had `.grow` end with `ret PARAM_BYTES`,
  but on x86-64 the caller pops the parameters, so it's a plain `ret`; and it had the sizes in the
  other registers from LLVM's order, which the patch keeps. Both fixed in the docs.

- 2026-10-16 — `compiler-plan.md` Phase 10, step 1: fibers switch, on x86-64 frames that chain
  through `rbp`, tested in the kernel. Found: the resume loop leaves a re-entered frame's data
  below the stack pointer for a moment, so interrupts (or signals without an alternate stack) on a
  fiber's stack would overwrite it; the docs say so now. Windows' frame pointers don't always
  chain, which is an open question in `docs/multitasking.md`.

- 2026-10-16 — Value generics (`docs/types.md`, *Values in Generic Lists*): `Ring[T, capacity]`,
  inferred and explicit values, values in `#if` and as constants in bodies. Found on the way: the
  parser rejected any arithmetic in an array size inside a type (`u8[SIZE / 2]`) and in a generic
  value that starts with a name (`Ring[u8, SIZE * 2]`); both take constant expressions now.

- 2026-10-16 — `compiler-plan.md` Phase 9, step 2: bounds proofs (`docs/types.md`). Every index
  in Hemera's std and in SlopOS is now proven, which found an off-by-one in std's format string
  parsing and made the contracts the kernel relied on explicit as `runtime.assert`s. The idioms
  that make code provable are in CLAUDE.md. Fixed in the docs: the example compared with `<=` where
  it meant `<`, and a slice's start must be at most its end, which the example didn't check.

- 2026-10-16 — `compiler-plan.md` Phase 9, step 1: the checks on pointers into the stack
  (`docs/memory.md`). As written, the Returning rule made everything allocated through an
  allocator or `loc` parameter local, which broke base's own context and fiber code; Hemera now has
  `#unrestricted` structs (decided with the Hemera author), and `Allocator` and
  `SourceCodeLocation` are. The check found a hosted test returning a view of its own stack, and
  SlopOS functions that keep parameters without `#escaping`. `#escaping` is now part of whether a
  function type fits another, as documented. Converting to `any` copies the value into the frame,
  which the docs now say, so every `any` counts as local.

- 2026-10-16 — `compiler-plan.md` Phase 8, step 4c: SlopOS builds through its build package, with
  the house-rule checks. Fixed in Hemera on the way: reflection's `ImportInfo.from` kept the
  string literal's quotes (`"\"std\""`), so nothing matched `"std"`. Also found: two builds of the
  same kernel differed by a few hundred bytes. The compiler walked declarations in a map ordered by
  their names' addresses, which change from run to run, so the globals it keeps (Limine's
  requests) came out in a different order each time; reflection's lists did too. Fixed by sorting
  by name, and the object is now named after the root package's folder rather than the output
  file, so builds are byte-identical wherever they're written and whether or not they go through
  the build package. Hemera's docs now make that a rule (`docs/compilation.md`, Deterministic
  Output), and a test builds a kernel four times and compares the bytes. Building the kernel
  through the build package also takes longer than directly (about 67s against 24s with the debug
  compiler), since the build program and its checks are compiled and run first.

- 2026-10-16 — `compiler-plan.md` Phase 8, step 1: compile-time execution through LLVM's ORC JIT.
  Constants whose values call functions are computed while compiling, so the Limine requests'
  headers are built by functions instead of written out. Found and fixed on the way: returning a
  constant array as a view pointed at a copy on the stack.

- 2026-10-16 — Found while testing the frame allocator as a hosted program: a Windows program with
  a frame bigger than a page didn't link, since LLVM calls `__chkstk` and Hemera links no C
  library. The compiler now defines `__chkstk` itself, like `memcpy` and `memset`.

- 2026-10-16 — `compiler-plan.md` Phase 7, C3, done: entry functions. The x86-64 entries are one
  `.entry` function through `x86_64.entry_points`, plus a `.syscall_entry` function, so entries from
  user mode are possible and device vectors reach the kernel. Changed in Hemera on the way:
  `entry_points`'s handler may return (for NMIs), and a function can be a compile-time value.

- 2026-10-16 — `compiler-plan.md` Phase 7, C2, done: the other CPUs start through Limine at a
  `#calling_convention(.c) #no_context` entry, with no workaround needed. Found and fixed on the
  way: `_, ok :: f()` (a definition dropping a value with `_`) wasn't generated.

- 2026-10-16 — `compiler-plan.md` Phase 7, C1, done: type information at run time. Each type used
  as a value or in an `any` has a descriptor, `value.type == int` compares types, and
  `text_buffer.append_format` formats any value without allocating. The kernel's and the boot
  adapter's loggers format their parameters, and the boot log, timer, baseline check and
  framebuffer messages use format strings instead of building their text. Found and fixed on the
  way: comparing type values, and a type as an `any`, weren't generated. Found, not fixed: `for ...
  #reverse` isn't generated yet (std works around it).

- 2026-10-15 — `compiler-plan.md` Phase 7, group B, decided with the Hemera author and done:
  keywords in three tiers (no more `type_`, `package_`, `alias_`, `from_`), `null` only for
  `rawptr` and optionals with `ptr[T]?` a single pointer, `view_of` and `string_of` builtins,
  `stack_pointer` and `spin_hint` intrinsics, `#calling_convention(.c)` with `#no_context`, and
  `Result[void, E]`. In SlopOS: Limine's structures are typed (`Request[T]`, `ptr[T]?`, `cstring?`),
  the kernel's entry is `.c` and `#no_context`, the x86-64 entries share a `#no_context` helper,
  the ticket lock is std's, and the arch interface's `map` and `protect` return `Result[void, E]`.
  `std/raw` became `std/c_string`.

- 2026-10-15 — `compiler-plan.md` Phase 7, group A (on request): union payloads of any type, a race
  where generic instances like `Result[T, E]` were used before they were laid out (behind both
  "Ok holds 0 values" and the optional parameter that wouldn't take a value), variants without
  values through their union, `or_else` with a call that never returns, `.{...}` elements and
  `if` expressions as arguments, string `==` and slices, large copies with `memmove`, and finding
  `std` without `--install-path`. Also: a crash after errors, and stack traces on Windows. The
  kernel's workarounds for all of them are gone.

- 2026-10-15 — `#file_data("path")` (on request): a file's bytes as a `u8[N]` constant, read when
  compiling, with the path relative to the file using it (Hemera `docs/directives.md`, *Values*).
  The kernel embeds its console font with it, so `tools/psf_to_hemera.py` and the generated font
  source are gone.

- 2026-10-15 — The rest of roadmap M1 (on request): a framebuffer console with the Spleen PSF2 font,
  and stack traces from the assertion handler and kernel faults. Compiler changes, the second and
  third asked for:
  - Build time (a 26 KB font constant took minutes): integer array literals of constants are one
    dense constant; a view of an array points at the array instead of a copy, which is also what
    `docs/types.md` now says views do (a copy also meant changes through the view were lost);
    locals bigger than 64 bytes are zeroed with `memset` rather than one huge aggregate store.
  - `capture_stack_trace` is generated, through a walker the compiler adds; every function keeps
    its frame pointer, and the program's entry function ends the chain (Hemera
    `docs/calling_convention.md`, *Walking the Stack*).

- 2026-10-15 — The first M1 kernel (`compiler-plan.md` Phase 6, on request): `src/` boots from BIOS
  and UEFI through Limine, builds `BootInfo`, sets up the GDT, TSS, IDT and x2APIC, logs to the
  serial port, handles timer interrupts and halts; `tools/boot.py --expect 0` is its test. What it
  found is in *Needed to boot a kernel* above. Changes in Hemera:
  - Compiler, four bugs (asked for): `else if` attached its block to the `else`, so the block was
    never checked and generating it crashed; a varargs view passed on was only recognized as the
    last argument, against `docs/functions.md` (which `runtime.log_*` relies on); `_ = f()` crashed
    the parser's caller (the target node was lost); a call in a constant's value crashed code
    generation, and is reported as needing compile-time execution now.
  - `std/raw` (views and strings over memory from outside Hemera) and `std/text_buffer` (text in a
    fixed buffer), both freestanding; `CpuFeatures` in `std/os/slop_os` (`decisions/0019`).
  - Hemera `docs/packages.md`: the two packages in the tier table.

- 2026-10-15 — Compiler Phase 6, the freestanding slice (`compiler-plan.md`, on request): a Limine
  kernel built by Hemera boots in QEMU, with intrinsics, interrupt functions, `push_context ...
  from` and prologue stack checks; `tools/boot.py` runs it. Changes outside the compiler:
  - Hemera `docs/compilation.md`: *Target Options on the Command Line*, the flags standing in for
    `TargetOptions` until the build package works.
  - Hemera's LLVM patch (`apps/compiler/third-party/patches/llvm`): no `.note.GNU-split-stack` for
    a stack limit in a register.

- 2026-10-14 — Compiler Phase 5, lowering on a hosted program (`compiler-plan.md`, on request): a
  program with structs, unions, loops, `match`, `switch`, `defer`, generics, optionals and calls
  compiles to an executable that runs with the expected exit code. Changes outside code generation:
  - Parser: additive and multiplicative operators group left to right, as `docs/operators.md`
    expects; `10 - 3 - 2` was parsed as `10 - (3 - 2)`.
  - HMIR: an `if` op, and `continue` takes a depth, for a `switch` lowered to a loop.
  - Linking: a hosted program starts at the compiler's `hemera_entry` and needs only kernel32.

- 2026-10-14 — Compiler Phase 4, expressions and statements (`compiler-plan.md`, on request):
  function bodies type-check, with mutability, return and reachability checks; `base` and `std`
  pass. Decided: `new` returns `ptr[mut T]` (failure goes to the assertion handler); stubs call
  `todo()`. Changes outside the compiler, with reasons:
  - `base/builtin/builtin.hsc`: `todo`, a builtin that never returns, for code still to write.
    `docs/functions.md`, *Functions Still to Write*, describes it.
  - `base/runtime/alloc.hsc`: `new` returns `ptr[mut T]` and calls the assertion handler on
    failure (`docs/types.md` says so too); `new_array` returns its result; stubs call `todo()`.
  - `base/runtime/alloc.hsc`, `core.hsc`: alignments are `usize`, like `align_of`.
  - `base/compiler/code.hsc`: `SourceCodeLocation` is an alias of `runtime`'s, which was declared
    separately, so `#caller_location` fits both.
  - `std`: the 134 stubs call `todo()`; the scheduler's optional fiber; `formatting` imports
    `runtime`; `delete` is `free`; `create_default_logger` returns its logger; `Instant.{0, 0}`;
    `printf`'s parameter renamed; casts between `int`, `i32` and `usize`; `as_string`'s two results.

- 2026-10-14 — Compiler Phase 3, declarations and types (`compiler-plan.md`, on request): base is
  built into the compiler and compiled like any package; every declaration in `base` and `std`
  resolves to type information with its memory layout. Changes outside the compiler, with reasons:
  - `docs/types.md`, *Memory Layout*: sizes, C-like struct layout, `#align` only raising the
    alignment, tagged unions as a tag then each variant's values, enums the size of their backing
    type (all decided 2026-10-14); `char` is one byte of UTF-8; `c128` is 2 `i64`s, not 2 `i128`s.
    `docs/directives.md`, `#align`, to match.
  - `base/builtin/generic_types.hsc`: `Optional` and `Result`, out of `builtin.hsc`, which isn't
    compiled.
  - `base/compiler/types.hsc`: `TypeInfoUnion.variants` is a `UnionVariant[]` (types and offsets),
    replacing a `Map` that doesn't exist, plus `tag_type`.
  - `std/fiber/scheduler.hsc`: imports `runtime`, not a nonexistent `base/array`.
  - `std/string/string_conversion.hsc`: the pointer conversions are generic (`ptr[T]`), since a bare
    `ptr` isn't a type.

- 2026-10-14 — Compiler Phase 2, packages, names and `#if` (`compiler-plan.md`, on request): a name
  registry with lookup through imports, waiting on names, `#if` chains evaluated at compile time,
  and stopping with cycles and undeclared names reported when nothing can make progress. `std`
  resolves in full. Changes outside the compiler, with reasons:
  - `base/builtin/builtin.hsc`: added `i128`/`u128` (and their `be`/`le` forms) and `char`, which
    the docs and `std` use but `base` didn't declare.
  - `std/string/string_builder.hsc`: `package string_builder` → `package string`, its folder's
    package.
  - `std/logger/default_logger.hsc`, `std/fiber/fiber_queue.hsc`: `import runtime from "base"`,
    for `Logger`/`LogLevel` and `Fiber`.
  - No overloading (names are unique in a package, per `docs/packages.md`, *Name Collision*):
    `std/string/string_builder.hsc`'s `append` overloads became `append_chars`,
    `append_substring` and `append_char`, and their calls in `std/formatting` and `std/logger`.
  - `Optional` and `Result` moved from `base/runtime/core.hsc` to `base/builtin/builtin.hsc`,
    as `docs/types.md` describes them as built in.
  - Parser: a parameter's default can be any expression (it was only literals, which silently cut
    off any file using `allocator := context.allocator`, such as `base/runtime/alloc.hsc`); the right side
    of an assignment can be a typed literal; union payload types are children of their parentheses.
  - `docs/packages.md`, *Name Collision*: builtins follow the same rules, as if every file imported
    them. A package can declare a builtin's name, and reaches the builtin as `base.Result`.
  - `docs/packages.md`, *Names and `#if`*: a name waits only for the undecided `#if` chains that
    could change what it refers to, so chains are decided in the order their names need, and chains
    needing each other are a circular dependency.

- 2026-10-14 — Compiler Phase 1, the carrier register and stack check in LLVM (`compiler-plan.md`,
  on request): reserving the carrier register needs no patch (`+reserve-r14` on x86-64 in the in-tree
  LLVM, `+reserve-x28` on AArch64, `+reserve-x27` on RISC-V); `carrier()`/`set_carrier()` lower to
  `llvm.read_register`/`write_register`. The prologue check against `[r14]` needs a ~60-line patch to
  LLVM's segmented-stack prologue, kept as a patch file in Hemera's `apps/compiler/third-party/patches/llvm/`.
  No change to Hemera's calling convention is needed. Still to do: Hemera's `morestack` protocol,
  the `.AssertionHandler` failure mode, size thresholds, and AArch64/RISC-V prologues.

- 2026-10-13 — Compiler Phase 0 (`compiler-plan.md`, on request): fixed directives tested backwards,
  the wrong work-target union member, imports never followed (now resolved under `docs/packages.md`),
  a wrong loop index, and invalid MLIR for functions. Found while testing: the lexer read past the end
  of the file after a trailing comment on the last line (aborting the compiler, which is built
  without exceptions); a top-level `#if` before any definition could only hold imports. New
  `test/front_end` tests.

- 2026-10-13 — Segmented stacks for plain threads (Hemera `docs/multitasking.md`, *Stacks*):
  threads run Hemera code on segments like fibers (1 KiB first segment by default), with a native
  stack only for foreign calls, signals and fiber schedulers. Where the system doesn't give every
  thread a stack, the native stack is allocated on the first foreign call. `ThreadStack.Fixed` keeps
  a fixed stack. Documented without SlopOS references, at the Hemera author's request; the two
  `import slop_os` examples in `docs/packages.md` were made generic too.

- 2026-10-13 — Package structure (`decisions/0033`):
  - Imports take paths below built-in locations (`import slop_os from "std/os"`); `docs/packages.md`
    now also says what each kind of `from` names: a built-in location names the folder containing the
    package, a relative path names the package's own folder. Test: `valid_scenarios/imports.hsc`
    (the parser already accepted any string).
  - `std/os/slop_os/` holds the SlopOS ABI package (`slop_os`, freestanding, empty so far).
  - `TargetOptions.max_frame_size`: a compile error for larger stack frames (`docs/compilation.md`),
    since a house-rule check can't see frame sizes.

- 2026-10-13 — Compile-time constant arguments and generics (Hemera `docs/types.md`, *Generics*):
  a generic parameter with the same name as a value parameter makes it compile-time (integers, enums,
  booleans and functions); redundant explicit generics allowed with a warning. `docs/types.md`
  (*Generics*) documents binding, compile-time parameters and values in generic lists.
  `x86_64.entry_points` and `new` and friends (`T: type`) follow it. Parser (on request): value
  parameters (`struct[T, capacity: usize]`) and value arguments (`Ring[u8, 4096]`, `Settings[true,
  .Fast]`), and struct and array literals of generic and package-qualified types
  (`Pair[int, string].{...}`, `runtime.Context.{...}`). `Bits[64]` stays an array dimension in the
  parser; the type checker reads it as an argument if `Bits` is generic. Tests:
  `valid_scenarios/generics.hsc`, `E3017_11`.

- 2026-10-13 — Pushing a complete context (Hemera `docs/control_flow.md`, *Pushing a Whole Context*):
  `push_context name from value { }` pushes a copy of a whole `runtime.Context`; it doesn't combine
  with overrides. Freestanding entry points, interrupt functions and entry functions have no context
  until they push one, and can only call intrinsics before that (`docs/control_flow.md`).
  `runtime.MINIMAL_CONTEXT` (failing allocator, `DISCARDING_LOGGER`, `NO_CLOCK`, `NO_RANDOM`, the trap
  assertion handler) replaces "a context built from constants" in `docs/compilation.md`. Parser (on
  request): the `from` form; tests in `valid_scenarios/push_context.hsc` and `E3018_10`.

- 2026-10-13 — Kernel entry and return to user mode on x86-64 (Hemera `docs/calling_convention.md`, *Entry Functions*; other architectures in `hemera-proposals/kernel-entry.md`):
  `#calling_convention(.entry)` and `.syscall_entry` with compiler-generated entry paths
  (`docs/calling_convention.md`, *Entry Functions*); in `intrinsics.x86_64`: `RegisterFrame` (part of
  the convention version), `SYSCALL_VECTOR`, `SyscallScratch`, `entry_points`, `return_to_user`,
  `read_gs_base`, `xsave`/`xsavec`/`xsaveopt`/`xrstor`, `xgetbv`/`xsetbv`, `rdseed`, `rdrand`. No
  inline assembly. The parser already accepted both conventions; test:
  `valid_scenarios/entry_functions.hsc`.

- 2026-10-13 — Functions that never return (Hemera `docs/directives.md`, *Functions*):
  - `#never_returns`, on a declaration after the name or in a function type after the signature,
    part of the function's type. Checked in the body; code after a call is unreachable; the
    caller's `defer`s don't run; lowered to LLVM's `noreturn` plus `unreachable` after every call.
    No `or_else` fallback. `FunctionInfo.never_returns`, `TypeInfoFunction.never_returns`.
  - Marked: `intrinsics.trap`, `runtime.AssertionHandler` and `trap_assertion_handler`, `os.exit`
    (which traps until it's implemented). Documented in `docs/directives.md`.
  - Parser (on request): `#never_returns` on declarations, and at the end of a function signature,
    where it's the only directive taken, so a following `#if` still starts a statement. Test:
    `valid_scenarios/never_returns.hsc`.

- 2026-10-13 — Data written by the bootloader (Hemera `docs/directives.md`, *Constants*):
  - `#externally_initialized` on top-level constants: always emitted, never folded, read-only to the
    program, an error to read at compile time (LLVM's `externally_initialized` plus `@llvm.used`).
  - `#section(name)`, only together with `#externally_initialized`; every other constant goes in
    read-only data.
  - Array literals in Jai's syntax, `u64.[a, b]`, typed as a static array of that many elements.
  - Documented in Hemera's `docs/directives.md` (*Constants*), `docs/types.md` (*Static Arrays*) and
    `docs/faq.md`.
  - Parser (on request): array literals (`array_literal` in `docs/grammar.txt`, an `ARRAY_LITERAL`
    node), and `#externally_initialized`/`#section` added to the directives allowed on
    declarations. Tests: `valid_scenarios/array_literals.hsc`, `externally_initialized.hsc`,
    `E3012_05`, `E3022_05`. Checking that `#section` comes with `#externally_initialized` is left
    to semantic analysis.

Changes made to Hemera in response to SlopOS (newest first):

- 2026-10-12 — Type and enum semantics, answering SlopOS's reflection guesses (Hemera `docs/types.md`):
  - `==` on `type` values is exact, so even a plain alias differs from what it aliases; `types_are_aliases(a, b)` is the looser comparison the type checker uses.
  - Functions that change a dynamic array take a pointer (`array_add(&names, name)`), since a dynamic array passed by value is a copy of its count, capacity and data; read-only ones take an array view. `new` returns `ptr[mut T]`. Layouts are count first.
  - Pointer mutability (`docs/types.md`, *Mutability*): a struct's mutability covers what it stores inline, and a pointer field's own type decides whether what it points to can change. Fields and locals the runtime, scheduler and logger change through are now `ptr[mut T]` (carrier and fiber segments and links, scheduler queues, `fiber_create`'s result); `SharedPtr.value` is `ptr[mut T]` for now (see *Shared ownership* above). Iterating through a pointer to an array dereferences it explicitly, `for x in names^`.
  - `cast[T](some_enum)` gives the backing integer. `TypeInfoEnum.backing_type` is in the type info. Enum members can have explicit values, and a member without one is one more than the member before it.

- 2026-10-12 — Parser fixes and syntax decisions, in Hemera's compiler at the Hemera author's request (`decisions/0030`, amendment):
  - The parser silently stopped at the first top-level token it couldn't handle, so the smoke test had only ever checked its first 38 of 746 lines; and the lexer ended the file at any multiline string. Both fixed, and the whole smoke test parses.
  - Fixed, against the documented grammar: postfix `^`; `for &value`; `_ = f()`; `else if` conditions; `push_context` overrides; returning several values; struct members; named arguments; `#run` arguments; directive arguments (`#align(16)`, `#backed_by(u8)`, `#calling_convention(.interrupt)`); `#escaping` and `name := default` parameters; optional (`T?`) and package-qualified types; constants as array sizes; open-ended slices; several names in one declaration (`a, _ :: f()`); enum member values; `---` values; annotations; multi-statement `switch` cases; `return` in `match` arms and `switch` cases; declaration values that start with a name are expressions.
  - Decided: casts chain without extra parentheses (`cast[ptr[Foo]](data).bar`, `cast[T](x)^`); `or_return` always takes a value (`or_return void`, like `return void`); `match` arms start with `case` like `switch`, with no separators between arms; `alias` is required after `distinct` and optional otherwise (`my_int :: i32`), and a declaration's value can't start with `mut`; types work as values with `mut`, `fn` or several arguments in brackets (`data.type_ != ptr[mut Foo]`, `size_of(Result[int, string])`); line breaks mean nothing, and an expression continues as long as the next token can continue it (`docs/operators.md`, *Line breaks*). `docs/grammar.txt` matches the parser.
  - Tests: `valid_scenarios/` (one file per feature), new error scenarios, and a test that parses every `.hsc` file in `base/` and `std/`. It found and fixed: a stray `;`, `Result::Ok` (now `.Ok(...)`), intrinsics missing `:` before `---`, `default:` in a `switch` (now `case _:`), `match` as a variable name, and keywords as field names (`ImportInfo.alias_`, `TypeInfoAlias.is_distinct`).

- 2026-10-12 — Reflection and context extensions, modeled on Odin (Hemera `base/compiler`, `docs/multitasking.md`, *Context Extensions*):
  - `any` is documented as `data: rawptr` and `type_: type`; `TypeInfoEnum.values: u128[]`; memory layouts of strings, views and dynamic arrays (`runtime.StringView`, `ArrayView`, `ResizableArray`, `docs/types.md`).
  - `std/reflection`: `enum_member_name`, `equal` (Odin's `reflect.equal` rules) and `as_string` for strings, booleans and enums are written.
  - `Context.extensions`: a chain of `ContextExtension` nodes keyed by `type`, with `extension_node` and `get_extension(T)`. Nodes can live in the pushing frame; threads and fibers copy the chain when created (`copy_extensions`), instead of nodes being immortal. `user_data` stays (`docs/multitasking.md`, *Context Extensions*; `docs/memory.md`, *Contexts*).

- 2026-10-12 — Decided, and written into Hemera's docs and `.hsc` files:
  - Freestanding builds: `TargetOptions.startup_code`, `stack_check_failure` (`StackCheckFailure`: `Morestack`, `Trap`, `AssertionHandler`), `linker`; `intrinsics.set_carrier`; `CarrierBlock.program_data`. `docs/compilation.md` (*Freestanding Programs*) covers setting up a carrier and a constant context. Was items 1, 9 and 10, and *Carrier pointer without TLS*.
  - Linking: `lld` by default, ELF for `Linux`/`None`/`SlopOS`, PE/COFF for `Windows`/`UEFI`, Mach-O for `Mac` (`docs/compilation.md`, *Linking*). Was item 4.
  - `#calling_convention(.interrupt)` and `x86_64.InterruptFrame` (`docs/calling_convention.md`, *Interrupt Functions*). `#naked` left out: without inline assembly a naked body has nothing to contain. Was item 7.
  - Run-time checks (bounds, division by zero, empty optionals, stack overflow with `.AssertionHandler`) fail through `context.assertion_handler` (`docs/directives.md`). Was item 3.
  - Racy plain accesses are defined: register-sized values like `_no_fence` atomics, larger ones may tear (`docs/memory.md`, *Data Races*).
  - `--allow-run` only covers execution the build package started (`docs/compilation.md`, *Compile-Time Permissions*).
  - The calling convention is versioned (`hemera-abi-v1`), and fiber resume-loop and segment layouts are stable within a version (`docs/calling_convention.md`, *Version*). Was *Calling-convention version* and *Unwinding suspended fibers out of process*.
  - Not adopted: bitfields (integers and masks for now, `bitfields.md`) and generic atomics (waited for constrained generics, which exist since 2026-10-19; not taken up yet).

- 2026-10-12 — Made from SlopOS under `decisions/0030`:
  - `time.now()` reads `context.clock.wall` and returns `Result[Instant, ClockError]`; the default logger leaves out the date and time when it fails.
  - `SharedPtr` is thread-safe: atomic count, release decrement, acquire fence before destroying. Its functions now take a pointer.
  - `runtime.FAILING_ALLOCATOR`, for a `Context` before any heap exists (item 9).
  - `Architecture.riscv64`, with `s11` as the carrier register (`docs/calling_convention.md`).
  - `BuildOptions.root` documented to accept the canonical paths `find_packages` returns.
  - `_weak` compare-exchange in every ordering (`_weak_acquire`, `_weak_release`, `_weak_acquire_release`, `_weak_no_fence`).

- 2026-10-09 — Made from SlopOS under `decisions/0030`; the intrinsics, reflection data and target enums are declarations the compiler doesn't implement yet:
  - `std` tiers: a `tiers` package, and every `std` package declares `PACKAGE_TIER` in its `package_info.hsc` (a new convention for package docs and constants, `docs/packages.md`). Was item 2.
  - `std/time` uses `runtime.Instant`; `runtime.duration_between` turns two `MonotonicTime` readings into a `Duration`.
  - Reflection: `offset_of`, struct layout in `TypeInfoStruct`/`StructMember`, `type_info_of` returns a pointer, `PackageInfo.location`, `FunctionInfo.has_body`, `calls`, `used_types`; `reflection.enum_member_name` and `reflection.equal` (bodies still to write).
  - `base/intrinsics/x86_64` privileged instructions, imported per architecture by `base/intrinsics/platform.hsc` (was item 6) and `intrinsics.volatile_*` (was item 8).
  - `OperatingSystem.SlopOS`, `.UEFI`, `OutputType.FlatBinary`; `thread.hsc` branches for them.
  - `os.run_process` (`ProcessResult`, `ProcessError`), which reports a compile error without `--allow-run`.
  - Un-suffixed atomics documented as sequentially consistent.

- 2026-10-05 — Builds and compile-time reflection (`base/compiler/build.hsc`, `package.hsc`, `function.hsc`, `types.hsc`):
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
- 2026-10-03 — `_weak` compare-exchange (`base/intrinsics/atomics.hsc`).
- 2026-10-03 — `Context.clock: ptr[Clock]` and `Context.random: ptr[Random]`; `Instant` (wall clock), `MonotonicTime`, `Duration`, `ClockError` in `base/runtime`.
- 2026-10-01 — Declaration directives after the name (`main #export :: fn() {}`); `#export` documented.
- 2026-10-01 — `--package=<name>:<path>` to remap `base`/`std`/`user`/`vendor`; path parsing bugs fixed.
- 2026-10-01 — `rawptr` atomics; atomic load/store for `int`/`uint`/`uintptr`; `compiler_fence_acquire_release`.
- 2026-10-01 — `_` to ignore return values (`docs/functions.md`).
- 2026-10-01 — Arch interfaces and house rules: compile-time reflection checks rather than an `implements` feature (`decisions/0007`).
- 2026-09-30 — Atomic loads/stores, hardware and compiler fences, `_acquire_release`, compare-exchange returning `(old, success)`, increment/decrement returning the old value (`base/intrinsics/atomics.hsc`); racy plain accesses defined 2026-10-12 (Hemera
  `docs/memory.md`, *Data Races*).
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
