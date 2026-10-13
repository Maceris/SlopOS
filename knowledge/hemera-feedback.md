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

Nothing open: everything M1 needs from Hemera is now in its docs or `.hsc` files (see
Resolved, 2026-10-12). Items 1–10 are referred to by number there and elsewhere.

### Language and library design

| Topic | State | Details |
|---|---|---|
| Builds of many outputs | Adopted (2026-10-05) in `base/compiler/build.hsc`. Still open: documenting parse-once/parallel builds (B10); `os.run_process`'s body (`std/os/process.hsc` only checks `--allow-run` so far) | `hemera-proposals/build-programs.md` §7; `decisions/0028` |
| Shared ownership like C++'s `shared_ptr` | `std/memory`'s `SharedPtr[T]` holds a `ptr[mut T]` for now. To brainstorm: what language or compiler features would make a shared pointer work like C++'s. Starting points: sharing an immutable value (`shared_ptr<const T>`), which needs mutability as something a generic can take, or a separate read-only wrapper; counting copies automatically, which needs copy and destroy hooks, or move-only types, since today every owner calls `increment`/`decrement` by hand; using it like the value (`shared.field`), since `.` only dereferences real pointers; allocating the count with the value (`make_shared`); weak references | — |

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
