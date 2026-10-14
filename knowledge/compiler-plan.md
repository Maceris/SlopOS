# Plan: Getting Hemera's Compiler to Type Checking and a Booting M1 Kernel

Status: **plan**, 2026-10-13. Written from a survey of `apps/compiler` at Hemera commit `caa1d7c`.
Compiler work happens only when the Hemera author asks for it (`decisions/0030`, amendment); this
document orders the work so each request can pick up the next step.

**Goal:** SlopOS code is type-checked as it's written, and a Hemera kernel boots in QEMU, prints to
the serial port, sets up its descriptor tables, takes a timer interrupt, and halts (roadmap M1).
Not the whole compiler: compile-time execution, reflection, the build API, value generics, fibers
and `morestack` wait until the design settles.

---

## Where the Compiler Is

About 12,000 lines of C++ (excluding LLVM and the HMIR dialect).

| Part | Where | State |
|---|---|---|
| Lexer, parser | `src/lexer`, `src/parser` (~4,500 lines) | **Done.** Matches `docs/grammar.txt`; 17 tests, including parsing all of `base` and `std` |
| Work scheduler | `src/front_end/front_end.cpp` | **Working.** Work-stealing threads, plus one thread for MLIR and LLVM work |
| Packages and files | `src/front_end/work.cpp` | **Partial.** Loads and parses the input package; imports are recorded but never followed |
| Type representation | `include/front_end/type.h`, `src/front_end/type.cpp` | **Started.** `TypeInfo` structs for builtins, arrays, structs, functions; nothing builds them from source |
| Type checking | `src/front_end/type_checking.cpp` (247 lines) | **Skeleton.** Only counts `return` values |
| `#if`, `#run` | `work_if_else`, `work_execution` in `work.cpp` | **Not started** (empty) |
| MLIR generation | `src/front_end/mlir_generation.cpp` (200 lines) | **Skeleton.** Emits one placeholder function |
| HMIR dialect | `mlir/` (~700 lines) | **Started.** `scope`, `loop`, `defer`, `break`, `continue`, `end`, and a tested `defer` expansion pass |
| Lowering MLIR → LLVM | `src/main.cpp` (`//TODO(ches) Lower`) | **Not started.** A dummy LLVM module is generated instead |
| LLVM backend, linking | `src/back_end/llvm.cpp` | **Working.** Target machine, optimization pipeline, object files, `lld` |
| Front-end tests | `test/front_end/` | Empty |

LLVM is a submodule at an upstream development commit (`llvmorg-23-init`), built from source, so
patching it is possible.

---

## Phase 0: Fix Known Bugs

Small, independent, and worth doing before anything builds on them.

- [ ] **Top-level directives are tested backwards** (`src/front_end/work.cpp`, `work_parse`, around
  line 235). `compare()` returns 0 for equal strings, but it's used as if it returned true, so any
  directive other than exactly `#if` takes the `#if` branch, and `#else` and `#run` are never
  recognized.
- [ ] **`work_type_check` reads the wrong union member** for `DEFINITION` targets (`work.cpp`, around
  line 281): it passes `target.value.file_location`, but the target holds `.node`.
- [ ] **Imports are never followed** (`work.cpp`, `work_parse`, around line 199): `ImportInfo` is
  filled in, but no `IMPORT` work is created, so only the input package is ever loaded. (Fixed
  properly in Phase 2.)
- [ ] **Wrong loop index** in `mlir_process_block_in_function` (`mlir_generation.cpp`, line 36):
  `child->children[i]` should be `[j]`.
- [ ] **Invalid IR** from `mlir_process_function`: it inserts a `return` at the start of the entry
  block, then appends the body as further blocks, and names every function `func_I_guess`.

**Done when:** each has a regression test where one is practical.

---

## Phase 1: Spike the Carrier Register and Stack Check in LLVM

The highest-risk item, and independent of the front end, so it can run early or in parallel.

Hemera's calling convention reserves a carrier register (`r14` on x86-64, `x28` on AArch64, `s11` on
RISC-V) and puts a stack-limit check against `[carrier]` in every prologue
(`docs/calling_convention.md`).
- LLVM has reserved-register features on AArch64 and RISC-V (the kind behind Clang's `-ffixed-x18`;
  whether they cover `x28` and `s11` is part of the spike), but **x86-64 has no option to reserve an
  arbitrary general register**.
- LLVM's segmented-stack prologue (`"split-stack"`) compares against a thread-local slot, not
  against a register-relative address.

- [ ] Hand-write LLVM IR for two functions and compile it with the in-tree `llc`, to find out what
  it takes to (a) keep `r14` out of register allocation on x86-64, and (b) emit
  `cmp rsp, [r14]` / `jb .grow` in the prologue. Likely a small patch to the LLVM fork: a new calling
  convention, or a reserved-register feature, plus a change to `X86FrameLowering`.
- [ ] Check the same on AArch64 (`x28`) to confirm the cheaper path there.
- [ ] Write down the patch's size and how it will be carried across LLVM updates.

**Done when:** there's a known way to get both, or a concrete reason the calling convention needs
to change (which then goes back to the language design).

---

## Phase 2: Packages, Names and `#if`

The foundation of the type checker.

- [ ] **Import resolution** (`docs/packages.md`, *Imports*): built-in locations with subfolders
  (`"std/os"`), relative paths naming the package folder, `./` for shadowed locations, aliases with
  `as`, default `std`. Create `IMPORT` work per import, fill `ImportInfo.package`, report missing
  packages.
- [ ] **Symbol tables:** per-file and per-package identifiers (`FileInfo.identifiers`,
  `PackageInfo.identifiers`), duplicate detection, package-qualified lookup (`runtime.Fiber`).
- [ ] **Waiting on names:** work that needs a name not yet declared parks until it is, and is
  woken when it's declared (the out-of-order compilation model). `Dependencies`,
  `WorkTracking.blocked` and `parked_work` exist unused. Parked work records exactly what it waits
  on (a name in a scope, a type's layout, a constant's value), so the waits form a graph.
- [ ] **Detecting that compilation can't continue** (Hemera `docs/packages.md`, *Circular
  Imports*): the compiler must notice when no work can ever make progress, and stop with errors
  instead of hanging.
  - **When:** every queue is empty, no worker is running anything, and some work is still parked.
    The scheduler checks this when its last active worker goes idle (`threads_running`,
    `parked_work`).
  - **What to report:**
    - **Cycles:** find the cycles in the wait graph (strongly connected components), and report
      each one with the location of every step, like "`A` needs `B`, which needs `A`".
    - **Names that are never declared:** parked work waiting on a name nothing will declare.
    - Anything still parked after those, as an internal error, so a scheduler bug can't look like
      a hang.
  - **Then** stop compilation, since nothing parked can resume.
  - **Cycles that must not be reported,** because they don't block anything: circular imports
    (`docs/packages.md`), mutually recursive functions (a call needs the callee's signature, not
    its body), and types that refer to each other through pointers (a pointer's layout doesn't
    depend on what it points to). A struct containing itself by value is a real cycle, since its
    size depends on itself.
  - The same check covers later sources of waiting: `#run` needing a type that depends on that
    `#run`'s result, `#if` conditions that depend on declarations inside them, and generic
    instances that need themselves.
- [ ] **`#if` / `#else_if` / `#else`:** a small evaluator for constant expressions over built-in
  constants (`TARGET_ARCH`, `OS`) and named constants, including `#if` around imports and
  definitions. Not the `#run` interpreter.
- [ ] **Tests:** `test/front_end/` with valid and error scenarios, in the style of the parser's.

**Done when:** every package of `base` and `std` loads with its imports, `#if` picks the right
blocks for a given target, and a program that can't make progress stops with its cycles and
undeclared names reported, rather than hanging.

---

## Phase 3: Declarations and Types

- [ ] Primitive types, including explicit-endian integers (`docs/types.md`).
- [ ] `struct` (fields, defaults, `using`, `#packed`, `#align`, `#union`, `#scoped`), `union`
  (tagged), `enum` (`#backed_by`, member values), `alias`, `distinct alias`.
- [ ] Pointers (`ptr[T]`, `ptr[mut T]`, `rawptr`, relative pointers), optionals (`T?`), arrays
  (fixed, views, dynamic), `string`, `any`, `type`.
- [ ] Function types: parameters (named, defaults, `#escaping`, `#caller_location`, varargs),
  results (several, named), `#never_returns`, `#calling_convention(...)`.
- [ ] Generics: type parameters on structs, unions and functions; instantiation; the three binding
  rules (`docs/types.md`, *Generics*). Value parameters can wait.
- [ ] Constants with types, untyped constants, `---` declarations, `#externally_initialized`,
  `#section`.
- [ ] Memory layout (size, alignment, offsets) for every type, as `docs/types.md` (*Memory Layout*)
  specifies, since `size_of`, layout asserts and code generation all need it.

**Done when:** every declaration in `base` and `std` resolves to type information, and layout
tests pass for the documented layouts (`StringView`, `ArrayView`, `ResizableArray`, `any`).

---

## Phase 4: Expressions and Statements

- [ ] Literals and untyped constants; the implicit-casting rules (`docs/types.md`, *Implicit
  Casting*); operators (`docs/operators.md`), including greedy continuation across line breaks
  (already in the parser).
- [ ] Calls: positional and named arguments, defaults, `#caller_location`, varargs, generics.
- [ ] Member access with automatic dereference, indexing and slicing, `cast`/`bit_cast`/`auto_cast`,
  struct and array literals (including generic and package-qualified types), enum shorthand.
- [ ] `match` (with exhaustiveness), `switch`, `if` as an expression, optionals and `Result`,
  `or_return`/`or_else`/`or_break`/`or_continue`, `is_some`/`is_none`.
- [ ] Definitions (`::`, `:=`, `: T :`, `: T =`), assignment with **mutability checks**
  (`ptr[mut T]`), `defer`, `loop`/`for`/`with`, `break`/`continue`.
- [ ] `push_context` (overrides and `from`); the read-only context; functions without a context
  (`docs/control_flow.md`).
- [ ] Return checking: every path returns a value of the right types; `#never_returns` bodies can't
  finish, and code after their calls is unreachable.
- [ ] Builtins: `size_of`, `align_of`, `offset_of`, `type_of`, `type_info_of` (types only for now),
  `#assert`.
- [ ] Run type checking on all of `base` and `std` in a test, the way the parser test parses them,
  and on SlopOS's `src/`.

**Deferred to later phases:** `#escaping` and stack-pointer escape analysis, `#scoped`, proving
indexes are in bounds (run-time bounds checks until then), `#run`, reflection, value generics.

**Done when:** `base`, `std` and SlopOS's `src/` type-check, and the error scenarios report what
`docs/` says they should.

---

## Phase 5: Lowering, Proven on a Hosted Program

- [ ] Generate MLIR from the checked AST: functions with the context as an implicit first argument,
  locals, control flow through HMIR (`scope`, `loop`, `defer`, `break`, `continue`) and the standard
  dialects (`arith`, `cf`, `func`, `memref` or `llvm`), struct and array values, calls.
- [ ] Lower HMIR (after the existing `defer` pass) and the standard dialects to MLIR's LLVM dialect,
  then translate to LLVM IR. Replace `fill_out_dummy_module` in `src/main.cpp`.
- [ ] Constants as LLVM globals (read-only data), including function pointers and nested structs.
- [ ] A hosted test on Windows: a program whose entry returns an exit code, linked with `lld-link`
  and run by the test suite. The minimal startup code it needs (or `startup_code = false` with a
  hand-written entry) is part of this step.

**Done when:** a small Hemera program with structs, loops, `match`, `defer` and calls compiles,
links and runs with the expected exit code.

---

## Phase 6: The Freestanding M1 Slice

What `docs/specs/boot_info.md`, `docs/specs/arch_interface.md` and roadmap M1 use.

- [ ] **Target:** `x86_64-unknown-none` ELF, `red_zone = false`, SIMD disabled in `cpu_features`, the
  kernel code model, position-independent code, `ld.lld` with a linker script, no C runtime.
  Until the build package works (it needs `#run`), add command-line flags for the linker script,
  red zone, entry symbol and `startup_code`.
- [ ] **Intrinsics** (`base/intrinsics`): the x86-64 instructions through LLVM inline assembly
  generated by the compiler, volatile loads and stores, atomics and fences, `trap`,
  `carrier`/`set_carrier`, `capture_stack_trace` (can wait).
- [ ] **Directives:** `#externally_initialized` (LLVM `externally_initialized` global, kept with
  `llvm.used`) and `#section`; `#calling_convention(.interrupt)` (LLVM `x86_intrcc`);
  `#never_returns` (LLVM `noreturn` plus `unreachable` after calls); `#export`.
- [ ] **Contexts:** `push_context ... from`, `runtime.MINIMAL_CONTEXT`.
- [ ] **Carrier register and stack check** with `stack_check_failure = .Trap`, using what Phase 1
  found. Until then, build the slice with stack checks off and the context passed as an ordinary
  first argument, and switch over afterwards.
- [ ] **Harness** (outside the compiler, in SlopOS): a script that builds a Limine boot image and runs
  it in QEMU with serial output captured, used as an end-to-end test.

**Done when:** the M1 kernel boots in QEMU from a Hemera build: Limine requests answered,
`BootInfo` built, GDT, TSS and IDT loaded, serial output, a timer interrupt handled, halt.

---

## After M1

In roughly the order SlopOS needs them:
- **Entry functions** (`.entry`, `.syscall_entry`, `entry_points`, `return_to_user`) for M4–M6.
- **`#run` and compile-time execution**, then **reflection** and the **build API**
  (`base/compiler`), which unlock the build package and house-rule checks (`decisions/0028`, `0029`).
- **Memory-safety analyses:** `#escaping`, pointers into the stack, `#scoped`, bounds proofs.
- **Value generics** (`docs/types.md`, *Compile-Time Parameters*).
- **Fibers, `morestack` and segmented stacks** (`docs/multitasking.md`), for user space.
- **AArch64**, right after M3 (`decisions/0022`), where the carrier register is the cheaper case.

## Risks

| Risk | Where it bites | Mitigation |
|---|---|---|
| x86-64 carrier register needs an LLVM patch | Phase 6, and every later phase | Phase 1 spike first; keep the patch small; AArch64 and RISC-V don't need it |
| Out-of-order compilation can't continue (cycles, names never declared) but isn't noticed | Phase 2 onward | Detect when nothing can make progress, report cycles with every step's location and undeclared names, then stop; error scenarios for each kind of cycle and for the cycles that must stay legal |
| Documented semantics turn out inconsistent when implemented | Phases 3–4 | Expected, and the point: log it in `hemera-feedback.md` and fix the docs |
| Debug builds of LLVM are huge and slow | Every phase | Release builds of LLVM with a debug build of the compiler, as the README suggests |
