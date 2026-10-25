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

### Language and library design

| Topic | State | Details |
|---|---|---|
| Builds of many outputs | Adopted (2026-10-05) in `base/compiler/build.hsc`; `os.run_process` runs processes since 2026-10-19 (Windows and Linux); targets built several at once since 2026-10-23 (`--jobs`), SlopOS's build from 7.7 s to 4.0 s. Still open: sharing parsed files between targets, measured to save little so far; `find_packages` is unimplemented and may be removed | `hemera-proposals/build-programs.md`; `decisions/0028` |
| Kernel entry on AArch64 and RISC-V (needed after M3, `0022`) | x86-64 done 2026-10-13; hosted AArch64 (code generation, the stack check, fibers, Linux) done 2026-10-23 (`decisions/0062`), AArch64 kernel entry and system registers 2026-10-24 (`decisions/0063`); RISC-V waits for the third architecture. The same pattern is outlined for the others: a frame type, `.entry`, an entry-table intrinsic (AArch64's `VBAR_EL1` table), `return_to_user` (`eret`, `sret`), and system-register instructions | `hemera-proposals/kernel-entry.md` |
| Relative pointers and endian-specific integers | Done (2026-10-24): decided with the project's owner as the proposal suggested, then `docs/types.md` (*Relative Pointers*, *Endian-Specific Types*, *Implicit Casting*) and the compiler, with hosted tests `endian_types`, `relative_pointers` and `relative_to_itself` and front-end tests for the errors | `hemera-proposals/relative-pointers-and-endian-types.md` |

### Smaller gaps

- `x & ~MASK` with `x` unsigned and `MASK` an untyped constant is refused: `~0xff` is the untyped -256, out of
  `u64`'s range, so `MASK` needs a cast (`~cast[u64](MASK)`). Found writing `std/crypto` (2026-10-19), still so.
  Severity: friction.
- A function declared inside a function can't be generic yet, nor have several names (E4024, E4018); hoisting
  it to the package works. Left out when nested functions became declarations (2026-10-23). Severity: nice.
- A pointer to a `mut` view can't be written: in `ptr[mut u8[]]`, the `mut` is the pointer's, so the view it
  points to only reads. Nothing has needed one yet (2026-10-23, read-only unless `mut`). Severity: nice.

### Hemera's docs against its compiler (survey, 2026-10-24)

Small programs written from the examples in each of Hemera's `docs/`, built with the Release compiler and run on
Windows x64. Each item is something the docs describe that doesn't work. Only what the docs promise is listed:
things they leave out, like `==` on structs, aren't. The ones a "strong fit" in section 4 depends on are marked
**(SlopOS)**.

Fixed the same day (Hemera's compiler, with tests): the four that gave wrong code or missed an error without saying
so.

- `#fall_through` now runs the next case: code generation sets a flag the next case's condition reads, the bounds and
  ownership analyses carry the case's end into the next case, and one with no case after it is an error (E4002).
  Hosted test `fall_through`, and an owner moved again through a fall-through in `owned_errors`.
- `!` on `b16`/`b32`/`b64` compares with 0, rather than flipping every bit, which left a true value true. Hosted test
  `wide_booleans`.
- A multiline string is its lines after their `\\`, as written, joined by newlines, with none after the last; it was
  only the first line, with its `\\` read as an escape. Code generation, the bounds prover's count of a constant
  string, and format-string checking all read literals through one `ast::string_value` now. `docs/types.md` says
  what the string is, which it didn't before. Hosted test `multiline_strings`.
- A struct that isn't `#scoped` holding a `#scoped` one in place, in an array or in an optional is an error (E4014).
  Front-end tests `stack_scoped_field` and `stack_scoped_in_array_field`. `base` and `std` still build under
  `--generate-all`.
- Found while testing those: ownership treated every `switch` as possibly running no case, even one with `case _`, so
  releasing an owner in every case was reported as releasing it on only some paths. It now counts `case _`. An enum
  `switch` that names every member still counts as possibly running none.

Fixed later the same day, with the proposal decided (`hemera-proposals/relative-pointers-and-endian-types.md`):

- Endian-specific integers and floats are stored in their own byte order. They convert implicitly to their native
  type and wider native ones, swapping their bytes, compute as those (so `+=` on one is an error), and become one
  only by a `cast` or from a literal. `u32le` is its own type on every target.
- Relative pointers are set by assigning a `ptr[T]`, the offset from their own address, checked at run time to fit
  and not to be 0 (a pointer to itself, which an optional one would read as None), and read where they're stored as
  the `ptr[T]` they hold. They're never null, `relptrN[T]?` is None at offset 0, they can't point into the stack, and
  nothing with one in it is a value of its own (variables, parameters, results, literals, casts, whole-value
  assignments: E4040). Their pointer arithmetic is gone.
- The stale docs above are fixed, `checking.cpp`'s two stale TODOs say what happens instead, and
  `type_checking.cpp` and `mlir_generation.cpp` are gone, with the work type and test only they used.

Fixed with SlopOS's M7 7c (`decisions/0074`), the gaps its drivers would meet first:

- `match` and `switch` on strings generate a byte comparison of each case (`cstring` cases still don't). Hosted test
  `string_cases`.
- A `#union` struct's literal is built in memory: zeroed, then each member it names stored at its offset, in order, so
  a later one overwrites what it overlaps; the others' defaults are left out once one is named. A constant's literal
  still can't name an overlapping member. Hosted test `union_literals`.
- A dynamic array of a `#scoped` struct is an error wherever it's written, a local's type included, since its elements
  are on the heap. Front-end test `scoped_dynamic_local`.
- Found on the way: base's runtime had no grant kinds for 7b's `Device` and `DmaDomain`, so an entry parameter of either
  ended its process with `EXIT_MISSING_GRANT`; `std`'s asserts now check them like the others.

Fixed 2026-10-25 (Hemera's compiler, with hosted tests), the survey's plain bugs, with the design questions among them
decided with the project's owner:

- **Complex numbers and quaternions** are floats, as Odin's are: `c32`, `c64` and `c128` are two `f16`s, `f32`s or
  `f64`s, real then imag, and `q64`, `q128` and `q256` four, imag, jmag, kmag, then real; `c16` and `q32` are gone. They're
  written with imaginary literals (`2i`, `1.5j`, `3k`), which default to `c128` and `q256`; their parts are `.real`,
  `.imag`, `.jmag` and `.kmag`; they have `+ - * /` (the complex and Hamilton products), unary `-`, `==` and `!=` but no
  order, arithmetic with a real number of their parts' type, and casts between sizes. `std/math` has `conjugate`,
  `magnitude` and `part_of`, over a new `intrinsics.square_root`. Hosted test `composites`, on Linux too.
- **`#file_path`** is the path of the file it's in, as a string.
- **`==` between type values** follows plain aliases, as running code always did and as "a plain alias is the type it
  names" says: the docs' "exact" `==` was the error. It works at compile time (`#assert`, `#if`), and
  `types_are_aliases` with it, now taking type values worked out at run time too. Hosted test `type_values`.
- **A struct field's default** can be a float or string literal, or any constant or function named, of a type the field
  takes. Hosted test `field_defaults`, front-end test `field_default_mismatch`.
- **Two optionals compared** are equal when both are `None` or both hold equal values. Hosted test
  `optional_comparisons`.
- **`#run` as an array's count**, or a generic's value; **multi-dimensional array types** as values
  (`size_of(i8[10][5])`); and **a string literal's members** (`"abc".count`, `"abc"[1]`), as a constant's had
  since 7f. Hosted test `constant_sizes`.

Still open, from the same survey:

Builds fail where the docs say it works:

- **A variadic parameter followed by another** (`fn(fiz: bool, some: int..., fuzz: f32)`, from
  `functions.md`) only works when the variadic is passed on as a view: `bar(true, 20, 20, 2)` says `fuzz` has no
  value. Decided with the project's owner (2026-10-25), still to build: several variadics, or parameters after one,
  are allowed only when a call can always be split, each group's type unable to convert implicitly to the next's (and
  for `a: A..., b: B..., c: C...`, `A` and `C` too, since `b` can be empty). The docs' example is then an error, since
  an untyped `3` could be an `int` or the `f32`; `fuzz: bool` after `int...` would be fine. Severity: nice.
- **Types declared inside a function** (E4024), **generic macros** (E4024), and **`#insert` or a macro call in a
  generic's body** (E4024). The last is in `compilation.md` as not done yet; the first two aren't mentioned.
  Severity: nice.
- **Several names in one declaration**, `x, y, z := 0, 0, 0`, is a parse error (E3017). `operators.md` only
  shows assigning several at once, so this may be by design. Severity: nice.

Targets and runtime:

- **macOS / Mach-O** is in `compilation.md`'s linking table, but only ELF and PE/COFF can be linked (E7000), and a
  build package's target for Mac is refused. RISC-V, which `multitasking.md` gives a carrier register (`s11`),
  can't be built.
- **Signals**: `multitasking.md` describes per-carrier alternate signal stacks, but the runtime installs no signal
  handlers on Linux. This doesn't affect SlopOS (section 2, *Fibers*).

What worked, from the same survey: the pipe operator with `_` and `$n`, chained and multi-target assignments,
`%%` and `>>>`, the optional and result operators (with `Result[void, E]`), `break n`/`break all`, `with` loops,
`#at_least_once`, `#reverse`, `match` on unions with nested patterns, ranges and booleans, variadics (including
`any...`), named and default parameters, optional functions, `f16`, `i128`/`u128`, `any` and type info, vectors,
`#backed_by`, generics (value parameters, constraints, derived parameters, generic aliases, `mut` type arguments),
`using` through pointers, layout directives, stack-pointer escape checks, `#escaping`, `#owned`/`#release`,
secrets, the read-only context, `push_context`, `#run`/`#assert`, `#is_compile_time`, `#insert` (statements,
expressions, fields), hygienic macros, `#file_data`, constants made by calls (structs and strings too), import
aliases, `base.` names, format-string options and their checking.

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

Resolved items are removed once they're done, as everything up to 2026-10-23 was, and the kernel build that
failed once on 2026-10-16 (two checker races that explain it were fixed since, and it hasn't recurred); they're in this file's
history up to commit `052f203`, where references like "item 9" or "Resolved 2026-10-15" from older records
lead.

- **The compiler's one crash** (an access violation building the x86-64 kernel, 2026-10-24), resolved 2026-10-25: its
  likely cause, a read past the end of a function's type in the house rules' descriptions that AddressSanitizer found,
  was fixed that day, and the many SlopOS builds of M7's stages since, `hemera-asan` builds of every target among them,
  haven't crashed. The compiler still writes a crash dump if it ever does.

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
