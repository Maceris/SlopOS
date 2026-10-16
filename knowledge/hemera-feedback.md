# Hemera Feedback Log

The stated goal of SlopOS is to test how Hemera's design scales in real-world use. This
file is where that evidence accumulates: what the language and `std` make easy, hard or
impossible. Entries are currently **design pressure** from planning; once code exists, most
come from marker comments in the source (`grep -rn "HEMERA(\|STD(" src/`, see `conventions.md`).

Detailed designs live in `hemera-proposals/`; this file is the index and status board.
Since `decisions/0030`, SlopOS changes Hemera's `base/`, `std/`, `examples/` and `docs/`
directly; those changes are logged here too, with the reason. An item is done once it's
documented in Hemera's `docs/` or declared in its `.hsc` files, even if the compiler doesn't
implement it yet: most of the OS isn't expected to build with today's compiler anyway.
Compiler work (`apps/`) is done only when the Hemera author asks for it (`decisions/0030`,
amendment), and is logged here too.
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
| Format strings have no options, like hexadecimal or a width, so the stack trace appends its offsets with `text_buffer` (pointers do format in hexadecimal) | friction | `kernel/stack_trace.hsc` |
| A constant's value can't call a function until there's compile-time execution, so the Limine requests' headers are written out | gap | `boot/limine/requests.hsc` |
| An optional function type with a result can't be written in place: `(fn(n: int) -> int)?` doesn't parse, and `fn(n: int) -> int?` makes the result optional; it takes an alias | friction | Hemera's hosted test |

### Language and library design

| Topic | State | Details |
|---|---|---|
| Builds of many outputs | Adopted (2026-10-05) in `base/compiler/build.hsc`. Still open: documenting parse-once/parallel builds (B10); `os.run_process`'s body (`std/os/process.hsc` only checks `--allow-run` so far) | `hemera-proposals/build-programs.md` §7; `decisions/0028` |
| Kernel entry on AArch64 and RISC-V (needed after M3, `0022`) | x86-64 resolved 2026-10-13 (see Resolved). The same pattern is outlined for the others: a frame type, `.entry`, an entry-table intrinsic (AArch64's `VBAR_EL1` table), `return_to_user` (`eret`, `sret`), and system-register instructions | `hemera-proposals/kernel-entry.md`, *Other Architectures* |
| Cryptography in `std` (needed with networking and remote login) | Open, from `decisions/0042` and `0043`: X25519, Ed25519, ChaCha20-Poly1305 or AES-GCM (with AES-NI detection, `0019`), a hash (SHA-256 or BLAKE3), and Argon2id. Constant-time implementations; freestanding where possible, so the kernel and boot code can use them | — |
| Shared ownership like C++'s `shared_ptr` | `std/memory`'s `SharedPtr[T]` holds a `ptr[mut T]` for now. To brainstorm: what language or compiler features would make a shared pointer work like C++'s. Starting points: sharing an immutable value (`shared_ptr<const T>`), which needs mutability as something a generic can take, or a separate read-only wrapper; counting copies automatically, which needs copy and destroy hooks, or move-only types, since today every owner calls `increment`/`decrement` by hand; using it like the value (`shared.field`), since `.` only dereferences real pointers; allocating the count with the value (`make_shared`); weak references | — |

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
  `hemera-proposals/context-extensions.md`. Since 2026-10-04 the kernel also needs a carrier
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
- **Sandboxed compilation.** A SlopOS that compiles software on-device could run `#run` code
  with no capabilities at all, which answers the untrusted-compilation problem.

## 3. Resolved

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

- 2026-10-13 — Segmented stacks for plain threads (`hemera-proposals/segmented-thread-stacks.md`):
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

- 2026-10-13 — Compile-time constant arguments and generics (`hemera-proposals/compile-time-parameters.md`):
  a generic parameter with the same name as a value parameter makes it compile-time (integers, enums,
  booleans and functions); redundant explicit generics allowed with a warning. `docs/types.md`
  (*Generics*) documents binding, compile-time parameters and values in generic lists.
  `x86_64.entry_points` and `new` and friends (`T: type`) follow it. Parser (on request): value
  parameters (`struct[T, capacity: usize]`) and value arguments (`Ring[u8, 4096]`, `Settings[true,
  .Fast]`), and struct and array literals of generic and package-qualified types
  (`Pair[int, string].{...}`, `runtime.Context.{...}`). `Bits[64]` stays an array dimension in the
  parser; the type checker reads it as an argument if `Bits` is generic. Tests:
  `valid_scenarios/generics.hsc`, `E3017_11`.

- 2026-10-13 — Pushing a complete context (`hemera-proposals/push-complete-context.md`):
  `push_context name from value { }` pushes a copy of a whole `runtime.Context`; it doesn't combine
  with overrides. Freestanding entry points, interrupt functions and entry functions have no context
  until they push one, and can only call intrinsics before that (`docs/control_flow.md`).
  `runtime.MINIMAL_CONTEXT` (failing allocator, `DISCARDING_LOGGER`, `NO_CLOCK`, `NO_RANDOM`, the trap
  assertion handler) replaces "a context built from constants" in `docs/compilation.md`. Parser (on
  request): the `from` form; tests in `valid_scenarios/push_context.hsc` and `E3018_10`.

- 2026-10-13 — Kernel entry and return to user mode on x86-64 (`hemera-proposals/kernel-entry.md`):
  `#calling_convention(.entry)` and `.syscall_entry` with compiler-generated entry paths
  (`docs/calling_convention.md`, *Entry Functions*); in `intrinsics.x86_64`: `RegisterFrame` (part of
  the convention version), `SYSCALL_VECTOR`, `SyscallScratch`, `entry_points`, `return_to_user`,
  `read_gs_base`, `xsave`/`xsavec`/`xsaveopt`/`xrstor`, `xgetbv`/`xsetbv`, `rdseed`, `rdrand`. No
  inline assembly. The parser already accepted both conventions; test:
  `valid_scenarios/entry_functions.hsc`.

- 2026-10-13 — Functions that never return (`hemera-proposals/no-return.md`):
  - `#never_returns`, on a declaration after the name or in a function type after the signature,
    part of the function's type. Checked in the body; code after a call is unreachable; the
    caller's `defer`s don't run; lowered to LLVM's `noreturn` plus `unreachable` after every call.
    No `or_else` fallback. `FunctionInfo.never_returns`, `TypeInfoFunction.never_returns`.
  - Marked: `intrinsics.trap`, `runtime.AssertionHandler` and `trap_assertion_handler`, `os.exit`
    (which traps until it's implemented). Documented in `docs/directives.md`.
  - Parser (on request): `#never_returns` on declarations, and at the end of a function signature,
    where it's the only directive taken, so a following `#if` still starts a statement. Test:
    `valid_scenarios/never_returns.hsc`.

- 2026-10-13 — Data written by the bootloader (`hemera-proposals/externally-initialized-data.md`):
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

- 2026-10-12 — Type and enum semantics, answering the guesses in `hemera-proposals/reflection-checks.md` (Hemera `docs/types.md`):
  - `==` on `type` values is exact, so even a plain alias differs from what it aliases; `types_are_aliases(a, b)` is the looser comparison the type checker uses.
  - Functions that change a dynamic array take a pointer (`array_add(&names, name)`), since a dynamic array passed by value is a copy of its count, capacity and data; read-only ones take an array view. `new` returns `ptr[mut T]`. Layouts are count first.
  - Pointer mutability (`docs/types.md`, *Mutability*): a struct's mutability covers what it stores inline, and a pointer field's own type decides whether what it points to can change. Fields and locals the runtime, scheduler and logger change through are now `ptr[mut T]` (carrier and fiber segments and links, scheduler queues, `fiber_create`'s result); `SharedPtr.value` is `ptr[mut T]` for now (see *Shared ownership* above). Iterating through a pointer to an array dereferences it explicitly, `for x in names^`.
  - `cast[T](some_enum)` gives the backing integer. `TypeInfoEnum.backing_type` is in the type info. Enum members can have explicit values, and a member without one is one more than the member before it.

- 2026-10-12 — Parser fixes and syntax decisions, in Hemera's compiler at the Hemera author's request (`decisions/0030`, amendment):
  - The parser silently stopped at the first top-level token it couldn't handle, so the smoke test had only ever checked its first 38 of 746 lines; and the lexer ended the file at any multiline string. Both fixed, and the whole smoke test parses.
  - Fixed, against the documented grammar: postfix `^`; `for &value`; `_ = f()`; `else if` conditions; `push_context` overrides; returning several values; struct members; named arguments; `#run` arguments; directive arguments (`#align(16)`, `#backed_by(u8)`, `#calling_convention(.interrupt)`); `#escaping` and `name := default` parameters; optional (`T?`) and package-qualified types; constants as array sizes; open-ended slices; several names in one declaration (`a, _ :: f()`); enum member values; `---` values; annotations; multi-statement `switch` cases; `return` in `match` arms and `switch` cases; declaration values that start with a name are expressions.
  - Decided: casts chain without extra parentheses (`cast[ptr[Foo]](data).bar`, `cast[T](x)^`); `or_return` always takes a value (`or_return void`, like `return void`); `match` arms start with `case` like `switch`, with no separators between arms; `alias` is required after `distinct` and optional otherwise (`my_int :: i32`), and a declaration's value can't start with `mut`; types work as values with `mut`, `fn` or several arguments in brackets (`data.type_ != ptr[mut Foo]`, `size_of(Result[int, string])`); line breaks mean nothing, and an expression continues as long as the next token can continue it (`docs/operators.md`, *Line breaks*). `docs/grammar.txt` matches the parser.
  - Tests: `valid_scenarios/` (one file per feature), new error scenarios, and a test that parses every `.hsc` file in `base/` and `std/`. It found and fixed: a stray `;`, `Result::Ok` (now `.Ok(...)`), intrinsics missing `:` before `---`, `default:` in a `switch` (now `case _:`), `match` as a variable name, and keywords as field names (`ImportInfo.alias_`, `TypeInfoAlias.is_distinct`).

- 2026-10-12 — Reflection and context extensions, modeled on Odin (`hemera-proposals/reflection-checks.md`, `context-extensions.md`):
  - `any` is documented as `data: rawptr` and `type_: type`; `TypeInfoEnum.values: u128[]`; memory layouts of strings, views and dynamic arrays (`runtime.StringView`, `ArrayView`, `ResizableArray`, `docs/types.md`).
  - `std/reflection`: `enum_member_name`, `equal` (Odin's `reflect.equal` rules) and `as_string` for strings, booleans and enums are written.
  - `Context.extensions`: a chain of `ContextExtension` nodes keyed by `type`, with `extension_node` and `get_extension(T)`. Nodes can live in the pushing frame; threads and fibers copy the chain when created (`copy_extensions`), instead of nodes being immortal. `user_data` stays (`docs/multitasking.md`, *Context Extensions*; `docs/memory.md`, *Contexts*).

- 2026-10-12 — Decided, and written into Hemera's docs and `.hsc` files:
  - Freestanding builds: `TargetOptions.startup_code`, `stack_check_failure` (`StackCheckFailure`: `Morestack`, `Trap`, `AssertionHandler`), `linker`; `intrinsics.set_carrier`; `CarrierBlock.program_data`. `docs/compilation.md` (*Freestanding Programs*) covers setting up a carrier and a constant context. Was items 1, 9 and 10, and *Carrier pointer without TLS*.
  - Linking: `lld` by default, ELF for `Linux`/`None`/`SlopOS`, PE/COFF for `Windows`/`UEFI`, Mach-O for `Mac` (`docs/compilation.md`, *Linking*). Was item 4.
  - `#calling_convention(.interrupt)` and `x86_64.InterruptFrame` (`docs/calling_convention.md`, *Interrupt Functions*). `#naked` left out: without inline assembly a naked body has nothing to contain. Was item 7.
  - Run-time checks (bounds, division by zero, empty optionals, stack overflow with `.AssertionHandler`) fail through `context.assertion_handler` (`docs/directives.md`). Was item 3.
  - Racy plain accesses are defined: register-sized values like `_no_fence` atomics, larger ones may tear (`docs/memory.md`, *Data Races*; `atomics.md` §3 option 2).
  - `--allow-run` only covers execution the build package started (`docs/compilation.md`, *Compile-Time Permissions*).
  - The calling convention is versioned (`hemera-abi-v1`), and fiber resume-loop and segment layouts are stable within a version (`docs/calling_convention.md`, *Version*). Was *Calling-convention version* and *Unwinding suspended fibers out of process*.
  - Not adopted: bitfields (integers and masks for now, `bitfields.md`) and generic atomics (waits for constrained generics).

- 2026-10-12 — Made from SlopOS under `decisions/0030`:
  - `time.now()` reads `context.clock.wall` and returns `Result[Instant, ClockError]`; the default logger leaves out the date and time when it fails.
  - `SharedPtr` is thread-safe: atomic count, release decrement, acquire fence before destroying (`atomics.md` Example C). Its functions now take a pointer.
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
