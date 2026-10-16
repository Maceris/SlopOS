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

**Done** 2026-10-13. Small, independent, and worth doing before anything builds on them.

- [x] **Top-level directives are tested backwards** (`src/front_end/work.cpp`, `work_parse`, around
  line 235). `compare()` returns 0 for equal strings, but it's used as if it returned true, so any
  directive other than exactly `#if` takes the `#if` branch, and `#else` and `#run` are never
  recognized.
- [x] **`work_type_check` reads the wrong union member** for `DEFINITION` targets (`work.cpp`, around
  line 281): it passes `target.value.file_location`, but the target holds `.node`.
- [x] **Imports are never followed** (`work.cpp`, `work_parse`, around line 199): `ImportInfo` is
  filled in, but no `IMPORT` work is created, so only the input package is ever loaded. (Fixed
  properly in Phase 2.)
- [x] **Wrong loop index** in `mlir_process_block_in_function` (`mlir_generation.cpp`, line 36):
  `child->children[i]` should be `[j]`.
- [x] **Invalid IR** from `mlir_process_function`: it inserts a `return` at the start of the entry
  block, then appends the body as further blocks, and names every function `func_I_guess`.

- [x] **Found while testing:**
  - **The lexer read past the end of the file** after a comment that follows code on the last line:
    `std::getline` empties its string even when no line is left, so the comment's text was copied
    from an empty line ("invalid string position"). The compiler is built without exceptions, so on
    a worker thread this aborted the whole compiler.
  - **A top-level `#if` before any definition could only hold imports**, since the parser handled it
    as part of the import section. A top-level `#if` block now holds imports and definitions in any
    order, wherever it is (`top_level_block` in the grammar).
  - **`std::filesystem` calls that throw** in import handling now use their `error_code` forms, for
    the same reason as the lexer bug.
  - `main.cpp` now loads the HMIR dialect, which code generation emits; and the test executable
    reports debug-runtime assertions on stderr instead of in a dialog.

Imports are resolved under `docs/packages.md`'s rules (built-in locations with subfolders, relative
paths, `std` by default) and their packages loaded; imports inside a top-level `#if` wait for Phase 2.
A `return` inside a nested scope isn't emitted yet: it needs an HMIR op, since `func.return` must be
directly in its function (Phase 5).

**Done when:** each has a regression test where one is practical. Tests: `test/front_end/`
(imports followed, a missing import, an `#if` chain, `#else` without `#if`, valid IR for functions
and a declaration), and parser scenarios `top_level_if.hsc` and `trailing_comment.hsc`.

---

## Phase 1: Spike the Carrier Register and Stack Check in LLVM

**Done** 2026-10-14. Result: both are possible with no change to the calling convention, using a
feature LLVM already has and a ~60-line patch.

Hemera's calling convention reserves a carrier register (`r14` on x86-64, `x28` on AArch64, `s11` on
RISC-V) and puts a stack-limit check against `[carrier]` in every prologue
(`docs/calling_convention.md`).

- [x] **Reserving the carrier register needs no patch.**
  - **x86-64:** the in-tree LLVM has `+reserve-r8` to `+reserve-r15` (upstream since 2026-03, PR
    #180242; Visual Studio's clang 19 predates it). Under register pressure without it, `r14` is
    saved and used; with `+reserve-r14` it's neither saved nor used.
  - **AArch64:** `+reserve-x28` (LLVM reserves `x1`–`x7`, `x9`–`x15`, `x18`, `x20`–`x28`).
  - **RISC-V:** `+reserve-x27` (`s11`) exists, but this build of LLVM only includes the X86, AArch64
    and ARM targets (`LLVM_TARGETS_TO_BUILD`), so RISC-V must be added before that port.
- [x] **`intrinsics.carrier()` and `set_carrier()`** lower to `llvm.read_register` and
  `llvm.write_register` with `!"r14"` (x86-64 accepts `r14` by name) or `!"x28"`: one `mov` each.
- [x] **The prologue check needs a patch** to `X86FrameLowering::adjustForSegmentedStacks`. LLVM's
  `"split-stack"` prologue already has Hemera's shape (compare `rsp` for small frames, `lea` the
  frame's end for large ones, branch out of line), but reads the limit from thread-local storage
  at a fixed offset per OS, refuses every other OS (including `x86_64-unknown-none`), and calls
  libgcc's `__morestack`. The patch, `apps/compiler/third-party/patches/llvm/0001-x86-split-stack-limit-register.patch`
  in the Hemera repo, adds function attributes:
  - `"split-stack-limit-register"="r14"` and `"split-stack-limit-offset"="0"`: compare against
    `[r14 + 0]`, on any platform;
  - `"split-stack-failure"="trap"`: `ud2` instead of calling `__morestack`, for `.Trap`.

  On `x86_64-unknown-none` it produces the documented prologue (`cmp rsp, [r14]` / `lea r11, [rsp -
  FRAME]; cmp r11, [r14]` / `jbe` to an out-of-line `ud2`), passes the machine verifier, carries its
  own lit test, and leaves LLVM's existing segmented-stack tests passing.
- [x] **How it's carried:** a patch file applied to the unchanged upstream submodule
  (`git apply`), checked with `git apply --check` after each LLVM update. 58 lines of code plus a
  39-line test, in one function that changes rarely upstream. A fork of `llvm-project` is the
  alternative if patches multiply.

**Still to do in the patch, for Phase 6 and later** (none changes the language):
- [ ] **Hemera's `morestack` protocol** (`docs/calling_convention.md`, *Growing the Stack*): a minimal
  frame, the body's address in `rax`, `call morestack`, `ret PARAM_BYTES`, instead of libgcc's
  `__morestack` (frame size in `r10`, argument size in `r11`). Only the out-of-line block changes.
- [ ] **`.AssertionHandler`:** call a named function instead of trapping.
- [ ] **Thresholds:** LLVM compares `rsp` directly for frames under 256 bytes and checks every function
  with a frame; Hemera's convention uses `STACK_SMALL` (128) with a 256-byte `STACK_GUARD`, and skips
  leaf functions whose frame fits in 128 bytes. Either add attributes for both, or adjust Hemera's
  constants to LLVM's (a 512-byte guard would keep the reasoning).
- [ ] **AArch64 and RISC-V have no segmented-stack prologue in LLVM at all** (only x86 and 32-bit ARM
  do), so their check is new code in `AArch64FrameLowering` and `RISCVFrameLowering`: larger than the
  x86 patch, and needed when those ports start (after M3).
- [ ] **Applying the patch in the build:** CMake could apply `third-party/patches/llvm/*.patch` before
  configuring LLVM, so a fresh clone builds the patched compiler without a manual step.

## Phase 2: Packages, Names and `#if`

**Done** 2026-10-14. The foundation of the type checker.

- [x] **Import resolution** (`docs/packages.md`, *Imports*): built-in locations with subfolders,
  relative paths, aliases, default `std`, missing packages reported (from Phase 0), now including
  imports inside a top-level `#if`.
  - **Imports from `base` aren't loaded:** `base` is the interface to what the compiler provides, so
    `import runtime from "base"` resolves to a compiler-provided package without reading its files.
- [x] **The name registry** (`src/front_end/names.cpp`): every top-level declaration, keyed by
  package and name, with its file and node.
  - **Names are unique in a package,** functions included: there's no overloading. Duplicates are
    E4009. (Monomorphized instances, and the same name in different packages, are told apart by
    internal mangled names when lowering, Phase 5.)
  - **Lookup** (`docs/packages.md`, *Name Collision*): unqualified, a name is a generic parameter,
    the package's own declaration (which always wins), an imported package, or a name declared by
    exactly one of the file's imports and the builtins, which count as an import every file has.
    Declared by two of those and not the package, it's ambiguous (E4012) and must be qualified
    (`runtime.Fiber`, or `base.Result` for the builtin).
  - **The package's own declaration can be in a file not parsed yet, or an `#if` not decided yet**
    (`docs/packages.md`, *Names and `#if`*). A name the package doesn't declare waits until its files
    are parsed and no undecided `#if` chain in it has a branch declaring the name. If the name isn't
    found in the imports or builtins either, it also waits for undecided chains in the same file with
    an import in a branch, since what that package declares isn't known until it's loaded. A name
    found while such a chain may still add an import is checked again once all work is done, and
    reported as ambiguous if the new import declares it too. `#if` conditions use the same rules, so
    chains are decided in the order their names need; chains needing each other are a cycle (E4007).
- [x] **Waiting on names:** each declaration gets a `TYPE_CHECK` work that walks it and asks for
  every name it uses. A name not yet declared parks the work on that name; declaring it wakes the
  work.
  - **Need levels:** a name is needed either *declared* or *resolved* (everything it uses is itself
    there). Pointers, views, `&` and function signatures only need their names declared, so mutually
    recursive functions and types that point at each other don't wait on each other. A struct field
    by value and a constant's value need theirs resolved.
  - **Waits** are on `NAME_DECLARED` (package, name) or `DECLARATION_RESOLVED` (a declaration).
    Parked work is requeued when its key is satisfied, including when an import makes the name
    visible.
- [x] **Detecting that compilation can't continue:** the scheduler keeps an exact count of work
  queued or running. When it reaches 0 with work still parked, nothing can resume, so it reports:
  - **cycles**, as E4007 with each step, including `#if` chains and what in them may provide a
    name ("This #if needs BAR, which the #if on line 7 may import (import foo, line 8); ...");
  - **names that are never declared**, as E4008;
  - **anything else still parked**, as E4011, so a scheduler bug can't look like a hang.

  Compilation then stops.
- [x] **`#if` / `#else_if` / `#else`:** an `IF_ELSE` work evaluates the chain with a small constant
  evaluator: booleans, integers, comparisons, `and`/`or`/`not`, named constants, and `TARGET_ARCH`
  and `OS` from the command line. The chosen branch's imports and definitions are then processed
  like the file's own. A condition that needs a declaration inside its own branch is a cycle; a
  condition that isn't a boolean is E4010.
- [x] **Tests:** `test/front_end/` scenarios for each of the above, and `ResolvesStd`, which
  resolves every `std` package.

**Done when:** every package of `std` loads with its imports, `#if` picks the right blocks for a
given target, and a program that can't make progress stops with its cycles and undeclared names
reported, rather than hanging. (`base` isn't loaded but must still parse, which a parser test
checks.)

- [x] **Found while testing:**
  - **The scheduler's per-thread queues raced:** a thread stealing work and the queue's owner both
    updated its head and tail without synchronizing, so one work could run twice or an empty slot be
    read (intermittent crashes). All general work now goes through the shared, thread-safe queue;
    a thread is woken whenever work is queued. Per-thread queues can come back with a proper
    work-stealing deque if profiling ever asks for it.
  - **A counter leak** left the "threads searching" count high, so idle threads slept for their
    full timeout and tests took seconds.
  - **The lexer freed shared strings:** it interned each comment's text, then deleted it from the
    shared string table, which another thread lexing the same comment could still be using.
  - **The parser dropped the rest of a file silently** on some failures, such as a parameter
    default that wasn't a literal (`allocator := context.allocator`, used throughout `base`). A
    default is now any expression, the right side of an assignment can be a typed literal
    (`x = Type.{}`), and a failure that doesn't report its own error now reports E3017.
  - **The package-name check (E4006)** read the name from the wrong node, so it never fired.
  - **Union payload types** are now children of their parentheses in the AST, like a call's.
  - **Fixes to `std`:** `string_builder.hsc` declared `package string_builder` in the `string`
    folder, and two files used `runtime` names without importing it. Its four `append` functions
    overloaded each other, so three were renamed: `append_chars` (pointer and length),
    `append_substring` (string, start, length) and `append_char`.
  - **`Optional` and `Result`** moved from `base/runtime/core.hsc` to `base/builtin`, since
    `docs/types.md` describes them as built in.
  - The compiler, like the test executable, now reports debug-runtime assertions on stderr instead
    of in a dialog.

**Left for later phases:** names used in a file that imports `base` are accepted unchecked if
nothing else declares them, until the compiler has `base`'s declarations itself (Phase 3).
Statement bodies aren't walked yet, only declarations (Phase 4).

---

## Phase 3: Declarations and Types

**Done** 2026-10-14, except what's left for Phase 4 at the end.

- [x] **Base is built into the compiler** (decided 2026-10-14): the build embeds `base/*.hsc` in the
  compiler (`src/front_end/embed_base.cmake`, each file in parts of 4 KiB), and an import from
  `base` compiles that copy like any package, without reading the disk. Relative imports inside base
  (`import x86_64 from "./x86_64"`) stay inside it. `base/builtin` describes the compiler's own names
  and isn't compiled, except `generic_types.hsc`, which holds `Optional` and `Result` (moved there
  from `builtin.hsc`) and is loaded into every program.
- [x] **Primitive types** with sizes and alignments in bytes, for 64-bit targets.
- [x] **`struct`** (fields, defaults, `using`, anonymous structs, `#packed`, `#align`, `#union`,
  `#scoped`), **`union`** (tagged), **`enum`** (`#backed_by`, member values), **`alias`**,
  **`distinct alias`**, and `X :: Y`, an alias when `Y` is a type.
- [x] **Pointers** (`ptr[T]`, `ptr[mut T]`, `rawptr`, relative pointers), **optionals** (`T?`, an
  instance of `Optional`), **arrays** (fixed, views, dynamic), `string`, `cstring`, `any`, `type`.
- [x] **Function types**: parameters (named, defaults, `#escaping`, varargs), results (several,
  named), `#never_returns`, `#calling_convention(...)`.
- [x] **Generic types**: each set of arguments makes an instance (`Pair[int, string]`), resolved by its
  own work, with its parameters bound. Aliases that aren't distinct give the same instance.
- [x] **Constants** with types, untyped constants, `---` declarations, `#externally_initialized`
  and `#section` (only together; reading one at compile time is an error).
- [x] **Memory layout** for every type (decided 2026-10-14, now in `docs/types.md`, *Memory Layout*):
  - structs are C-like;
  - `#align(n)` only raises the alignment, and sets it exactly with `#packed`;
  - a tagged union is the smallest unsigned tag at offset 0, then each variant's values like
    struct fields, all variants overlapping;
  - `char` is one byte.
- [x] **How it works:**
  - **Classifying:** when a declaration is declared, its syntax says what it is: a type (struct,
    union, enum, alias or function type), a generic type, a function, or a value. A type's
    `TypeInfo` exists from then on, so pointers can refer to it before its layout is known.
  - **Recorded lookups:** the name walker records what each name resolved to, and an evaluator
    (`src/front_end/declarations.cpp`) builds the types from that once everything held by value is
    resolved. A value that turns out to name a type, like `X :: Y`, is only known to be a type once
    it's resolved, so a pointer to it waits for that.
  - **One object per type:** types made from others (pointers, arrays, function types, anonymous
    structs) are one object each. Making them anew on each attempt multiplied `Optional`
    instances of function types endlessly.
- [x] **Fixes to `base` and `std` found by this:**
  - `compiler.TypeInfoUnion` used a `Map` type that doesn't exist; it now has `variants: UnionVariant[]`
    (each with its value types and offsets) and its `tag_type`.
  - `std/fiber/scheduler.hsc` imported a nonexistent `base/array`; it now imports `runtime`.
  - `std/string/string_conversion.hsc` used `ptr` and the relative pointers without a target; those
    functions are now generic (`ptr_to_string :: fn[T](value: ptr[T])`).
- [x] **Tests:** layouts for the documented types (`string` and `runtime.StringView`, views,
  `ResizableArray` and `T[..]`, `any`), the struct examples in `docs/types.md`, unions, enums,
  optionals, aliases, function types, constants, generic instances, type errors. `ResolvesStd` and
  `ResolvesBase` check every declaration has its type information.

**Done when:** every declaration in `base` and `std` resolves to type information, and layout
tests pass for the documented layouts (`StringView`, `ArrayView`, `ResizableArray`, `any`).

**Left for Phase 4**, since each needs expressions typed:
- a parameter's or field's type from its default, like `allocator := context.allocator` (left null);
- untyped constants, and constants whose value is an expression (left null);
- generic functions, instantiated for each call, and the three binding rules;
- values in generic lists (`Ring[u8, 4096]`), which nothing in `base` or `std` uses yet;
- `same_type` comparing pointers and arrays structurally, so `ptr[index]` is `ptr[int]`.

---

## Phase 4: Expressions and Statements

**Done** 2026-10-14: `base`, `std` and the examples type-check, and the error scenarios report what
`docs/` says. SlopOS's `src/` has no code yet.

- [x] **Literals and untyped constants:** an integer, float, string, boolean or null takes the type
  it's used as, and a constant like `LIMIT :: 10` is untyped the same way. Also the implicit-casting
  rules, and the operators, including the pipe `|>`. Raw and relative pointers allow arithmetic.
- [x] **Calls:** positional and named arguments, defaults, `#caller_location`, varargs (and passing
  a varargs view on), and generic functions.
  - **Generic calls** bind each generic parameter explicitly (`empty[string]()`), from a
    compile-time parameter (`new(T)`), or by matching argument types (`T` in `ptr[T]`, `T[]`,
    `Pair[T, U]`, `T?`). Giving one twice is warning W4000.
  - **Instances:** each binding makes an instance of the function, whose body is checked with its
    parameters bound.
- [x] **Values:** member access, through one pointer automatically; indexing and slicing; `cast`,
  `bit_cast` (same size), `auto_cast`; struct literals (in order, or by name) and array literals,
  generic and package-qualified; enum shorthand, and `.Variant(values)` for unions.
- [x] **Control flow and optionals:**
  - `match`, which must cover every value its subject can be (E4026), and `switch`;
  - `if` as an expression;
  - optionals and `Result`: `?`, `or_return`, `or_else`, `or_break`, `or_continue`, `is_some`,
    `is_none`.
- [x] **Statements:** definitions (`::`, `:=`, `: T :`, `: T =`, `: T`, several names), assignment
  (several targets, chained, compound) with mutability checks, `defer`, `loop`/`with`/`while`,
  `for` over ranges and arrays (`&` by reference, with an index), `break`/`continue`.
  - **What can be changed:** a constant can't, and neither can anything reached through `ptr[T]`
    without `mut`. Elements of views and dynamic arrays can, since they live elsewhere; a static
    array's follow its variable.
  - **The context is read-only:** `&` on it gives a pointer without `mut`.
- [x] **`push_context`**, with overrides or `from`, and functions without a context: entry and
  interrupt functions (`#calling_convention`, after the name) can't use `context`, and can only call
  intrinsics, until they push one (E4027).
- [x] **Return checking:**
  - every path that finishes returns the results;
  - a `#never_returns` function can't finish;
  - code after `return`, `break`, `continue` or a never-returning call is unreachable (E4025);
  - a loop without a condition or a break never finishes.
- [x] **Builtins:** `size_of`, `align_of`, `offset_of`, `type_of`, `type_info_of` (also of a type
  value, like an `any`'s `type_`), `types_are_aliases`, `max_value`/`min_value`, `#assert`,
  `#is_compile_time`, and `todo()` (below).
- [x] **Tests:** `ResolvesStd` and `ResolvesBase` now type-check every body, `ChecksBodies` covers the
  valid forms, and `ReportsBodyErrors` has one scenario per rule (19). SlopOS's `src/` has no code
  yet.

**Decided while doing this** (2026-10-14):
- **`new` returns `ptr[mut T]`**, as `docs/types.md` says, and calls the assertion handler if it
  can't allocate. `new_aligned` and `new_array` still return the error.
- **Stubs call `todo()`,** a builtin in `base/builtin` that never returns, so an empty body with
  results is an error. The 134 stubs in `std` call it now.

**Found in `base` and `std`:**
- **`base`:**
  - `new_array` didn't return its result.
  - Alignments were `int`, while `align_of` is `usize`.
  - `SourceCodeLocation` was declared twice; `compiler`'s is now an alias of `runtime`'s.
- **`std`:**
  - The scheduler used an optional fiber as a fiber.
  - `formatting` didn't import `runtime`.
  - `delete` (which doesn't exist; it's `free`).
  - `create_default_logger` didn't return its logger.
  - `Instant.{0}` gave one of two fields.
  - `printf`'s parameter `format` hid the function `format`.
  - Mixed `int`/`i32`/`usize` without casts.

**Compiler changes along the way:**
- The parser now takes a parenthesized operand after a unary operator (`!(a == b)`), wraps a switch
  case's statements in a block, and gives `#assert` its condition.
- Reports drop exact repeats, since work that waits starts over and finds the same errors again.
- `base/runtime` is loaded into every program, for `context`.

- [x] **Finished afterwards** (the same day):
  - **`#if` in a function body:** its conditions are decided at compile time, and only the branch
    it picks is checked, as if written in place.
  - **Compile-time values** (`buffer(16)`): a function's generic parameter named by a
    non-`type` parameter takes a constant, an integer, enum or boolean (not a variable, E4010).
    Each value makes its own instance, where the parameter is a constant that can size an array.
    One value in brackets after a type that isn't generic, like `u8[count]`, is an array's count.
  - **Piped calls:** `_` fills in the piped values in order, `$1` and `$2` by number, and
    otherwise they all come first. The call's arguments are inside its parentheses.
  - **`break 2`** must be inside two loops or switches; `continue` only counts loops.
  - **`#assert`** evaluates `size_of`, `align_of` and `offset_of`, in a body or at the top level.
  - **Fixed:** a race where `base.Result` and `T?` could look for `base/builtin`'s generic types
    before it was loaded; and an ambiguity reported twice when a declaration was retried.

**Deferred to later phases:** `#escaping` and stack-pointer escape analysis, `#scoped`, proving
indexes are in bounds (run-time bounds checks until then), `#run`, reflection, value generics.

**Done when:** `base`, `std` and SlopOS's `src/` type-check, and the error scenarios report what
`docs/` says they should.

---

## Phase 5: Lowering, Proven on a Hosted Program

**Done** 2026-10-14: `test/back_end/scenarios/hosted` compiles, links and runs with exit code 42
(`Hosted.RunsProgram`), at `-O0` and `-O2`.

- [x] **Generate MLIR from the checked AST** (`src/middle_end/generate.cpp`), from what the checker
  records for each body: what every expression is, each name's head, each local where it's
  defined, a cast's target, and the branch each `#if` picked. Starting from `main`, each function,
  instance and constant is generated the first time it's used.
  - The LLVM dialect directly, not `arith`/`cf`/`memref`. Values are laid out like their types:
    structs are packed LLVM structs with padding as bytes, so offsets match `docs/types.md`;
    strings and views are `{count, ptr}`; a union is its tag, then bytes.
  - Every function takes the context, a pointer, first; several results come back as a struct.
  - Every local is a stack slot (`alloca` in the entry block), which LLVM promotes to registers.
  - Control flow is HMIR: `scope`, `loop`, `if` (new), `defer`, `break`, `continue` (now with a
    depth) and `return`. A `switch` is a loop that runs once, so `break` leaves it and `continue`
    counts past it. `match` is a chain of `if`s.
- [x] **Lowering:** `hemera-defer`, then `hemera-lower-control-flow` (new), which turns HMIR into
  `llvm.br`/`llvm.cond_br`/`llvm.return`; then the module is translated to LLVM IR. This replaces
  `fill_out_dummy_module`. `-S` writes the `.ll`; `-s` the `.mlir`.
- [x] **Constants as globals:** a typed constant is a read-only internal global, made when first
  used. Its initializer is built from values only (a constant using another inlines its value),
  and `#section` and `#externally_initialized` carry over. String literals are private globals with
  a null after them.
- [x] **Hosted entry:** `hemera_entry` makes a zeroed context, calls `main` (`fn()` or `fn() -> int`)
  and exits with its result through `ExitProcess`. Returning from the entry only ends the thread,
  so a loader worker thread's code could become the process's. It defines `_fltused`, which LLVM
  refers to in code using floating point on Windows. It links with
  `lld-link /entry:hemera_entry /subsystem:console /nodefaultlib kernel32.lib`.
- [x] **Parser fix found by the test:** `+ - | ~` and `* / % %% & << >> >>>` grouped to the right
  (`10 - 3 - 2` was 9); they group to the left now.

**Not generated yet** (E5002 says which): functions defined inside functions, struct fields'
default values, comparing strings, structs and type values, matching strings, joining strings,
`#run`, `type_of`, `type_info_of`, `min_value`/`max_value`, `any`'s type, calls to bodiless
functions other than `trap`, parameter defaults beyond literals, constants, `#caller_location` and
context fields, and constants whose value needs memory (like a union holding values). No
divide-by-zero check, no stack probes (big frames would need `__chkstk`), and `std`'s stubs, like
`println`, still trap.

---

## Phase 6: The Freestanding M1 Slice

What `docs/specs/boot_info.md`, `docs/specs/arch_interface.md` and roadmap M1 use.

**Compiler side done** 2026-10-15: `test/back_end/scenarios/freestanding` in the Hemera repo is a
small Limine kernel that sets up a carrier block and a context, checks atomics, volatile accesses,
the carrier register and x86-64 instructions, loads an IDT, and ends in an interrupt function
entered through a stack check that traps. `tools/boot.py` boots it from BIOS and UEFI, exit code
42. The M1 kernel boots too (below), so Phase 6 is done.

- [x] **Target:** command-line flags for what the build package will set (Hemera
  `docs/compilation.md`, *Target Options on the Command Line*): `--os=none` (ELF, linked with
  `ld.lld -nostdlib -static`, `-pie --no-dynamic-linker` for position-independent code),
  `--no-startup-code`, `--entry`, `--no-red-zone`, `--stack-check=trap`, `--code-model`,
  `--relocation-model`, `--linker-script`. SIMD is off through `--cpu-features`; Limine doesn't
  enable SSE, and LLVM vectorizes byte loops with it otherwise. Both a static kernel (kernel code
  model) and a PIE boot.
  - `memcpy`, `memmove`, `memset` and `memcmp`, which LLVM calls for large copies, are generated as
    byte loops, since nothing links a C library.
  - Fixed on the way: `--output` was ignored, values of flags like `--cpu-features` were split at
    commas, and a missing input folder aborted the compiler.
- [x] **Intrinsics** (`base/intrinsics`), each compiled in place, never a function:
  - x86-64 instructions as inline assembly: interrupts, `lgdt`/`lidt`/`ltr`, `load_segments`
    (data segments, then `cs` with a far return), `swapgs`, ports, MSRs, control registers,
    `invlpg`, `xsave` and friends, `cpuid`, `rdtsc`, `rdrand`/`rdseed` (optional by the carry
    flag). `read_gs_base` reads the MSR, which works without FSGSBASE.
  - Volatile loads and stores; every atomic, by its name: orderings from the suffix, `_weak`,
    compare-exchange giving `(old, success)`; fences, with the compiler fences single-thread.
  - `trap`, `mem_copy`/`mem_copy_non_overlapping`/`mem_zero`, `carrier`/`set_carrier` (`r14`).
  - Not yet: `capture_stack_trace`, the fiber intrinsics, `entry_points` and `return_to_user`
    (after M1, with entry functions).
- [x] **Directives:** `#externally_initialized` (LLVM `externally_initialized`, and kept with
  `llvm.used` even when nothing reads it) and `#section`; `#calling_convention(.interrupt)`
  (`x86_intrcc`, the frame pointer `byval`); `#never_returns` (`noreturn`, `unreachable` after
  calls); `#export` (the plain name, external).
- [x] **Contexts:** `push_context ... from` (the parser puts the value under `from`, which the
  checker didn't check either); `runtime.MINIMAL_CONTEXT` as a constant global. A constant can take
  another's address, like `&DISCARDING_LOGGER`.
- [x] **Carrier register and stack check:** `+reserve-r14` on x86-64, always. With
  `--stack-check=trap`, every function that takes a context gets Phase 1's prologue check. The
  LLVM patch is applied to the submodule now, and also leaves out `.note.GNU-split-stack` for a
  register limit, which made `ld.lld` ask for `__morestack_non_split`. Functions without a context
  (entry points, interrupt functions) have no check, so calls from them aren't inlined, which
  would drop the callee's check.
- [x] **Harness:** `tools/boot.py` (this repo): builds a kernel package or takes an ELF, makes a
  Limine ISO with xorriso, boots it in QEMU (BIOS or `--uefi`) with serial captured, and turns
  `isa-debug-exit` back into the kernel's exit code; `--expect` makes it a test.
- [x] **The M1 kernel** (`src/`), 2026-10-15: `boot/limine` builds `BootInfo` from Limine's
  responses; `arch/x86_64` sets up the GDT, TSS (with IST stacks), IDT, x2APIC and its timer
  (TSC-deadline, or the APIC timer measured against the TSC), checks the x86-64-v3 baseline, and
  decodes faults into `Fault`; `kernel` keeps per-CPU state behind the carrier block, logs through a
  locked console, and halts after three timer interrupts. `tools/boot.py --expect 0` boots it from
  BIOS (and `--uefi`); `--command-line "test_exit test_fault"` expects 1, `--cpu qemu64` expects 2.
  Writing it took four compiler fixes (`hemera-feedback.md`, Resolved 2026-10-15).
  - Then the rest of roadmap M1: a framebuffer console (`kernel/console`, PSF2 with the Spleen
    font, scrolling), and stack traces from the assertion handler and kernel faults, through
    `capture_stack_trace` (now generated: frame pointers everywhere, the entry function ends the
    chain). `--command-line "test_exit test_assert"` expects 3; `tools/boot_tests.py` runs all five
    boot tests.

**Done when:** the M1 kernel boots in QEMU from a Hemera build: Limine requests answered,
`BootInfo` built, GDT, TSS and IDT loaded, serial output, a timer interrupt handled, halt.

---

## Phase 7: Gaps Found Building M1

Proposed 2026-10-15. Writing the M1 kernel found what the language and compiler still lack
(`hemera-feedback.md`, *Needed to boot a kernel*). The source marks each one
(`grep -rn "HEMERA(\|STD(" src/`); fixing one means removing its workaround and marker too.
`#file_data` is done already (Resolved 2026-10-15). The rest falls into three groups. A is bugs
and small fixes, where the docs already say what should happen. B needs the Hemera author to
decide something first. C is larger work.

**Done when:** every row of that table is resolved or moved to a later phase on purpose, and
`grep -rn "HEMERA(" src/` lists only the gaps those later phases cover.

### A. Bugs and small fixes

In the parser and checker, each with a test. Probably one session for all of them.

- [ ] **Union variants with any type:** `union_body` only takes identifiers in a variant's
  parentheses, so `User(ptr[mut T])` and `Ipi(arch_interface.IpiKind)` don't parse. Parse each with
  the type parser. Removes the aliases in `kernel/entry`.
- [ ] **`Ok(value)` on a `Result` from another package:** "Ok holds 0 values" when `T` and `E` are
  the other package's types. Probably the generic instance is made before its arguments are
  resolved. Removes `init_console`'s pointer.
- [ ] **A value for an optional parameter:** `SourceCodeLocation` isn't accepted for
  `SourceCodeLocation?`, although `fits()` says a value fits an optional of its type. Find where
  arguments skip that rule.
- [ ] **A variant without values, through its union** (`ConsoleError.UnsupportedFramebuffer`) is a
  value, not a function.
- [ ] **`or_else` with a call that never returns** as its default (`or_else boot_failed(...)`):
  `#never_returns` calls fit any type, the way `todo()` does.
- [ ] **`.{...}` as an array literal's element**, taking the element type from the array; and an
  `if` expression as a call's argument.
- [ ] **Strings:** `==` and `!=` (a length check, then `memcmp`); slicing a string gives a string;
  indexing an untyped string constant. Removes `same_text` and the `bit_cast[string]` slices.
- [ ] **Large copies:** values bigger than 64 bytes are copied with `memcpy`, like zeroing, rather
  than as LLVM aggregates. Then `parse_font` can return its `Font` again.
- [ ] **Finding `std`:** without `--install-path`, look next to the compiler (an installed layout),
  then in the source tree it was built from. Removes `boot.py`'s `--install-path`.

### B. Decisions first

Each is small to implement once decided. Recommendations first:

- **A `Result` without a value.** `Result[void, MapError]` doesn't parse.
  - *Recommended:* allow `void` as a generic argument, with `Ok` taking no value when `T` is
    `void`. It reads like the docs and `ipc.md` already write it.
  - *Or:* keep `E?` for "nothing, or an error", as `arch_interface.map` does now. It needs no
    language change, but a `?` read as "maybe an error" is the opposite of the usual reading.
- **Keywords that crowd out names.** `all` and `from` are keywords, so `TlbBatch.all` and a
  parameter called `from` can't exist.
  - *Recommended:* make them contextual: `from` is a keyword only after `push_context name`, and
    `all` only after `break` or `continue`.
  - *Or:* leave them reserved, and say so in `docs/keywords.md`.
- **`ptr[T]?` and nullable pointers.** Optionals carry a tag today, so a C structure's pointer can't
  be `ptr[T]?`.
  - *Recommended:* `ptr[T]?`, `rawptr?`, `cstring?` and function types' optionals are one pointer,
    null for `None`. Document it in `docs/types.md`, so foreign layouts can use them. Removes the
    `rawptr` fields in `boot/limine/protocol.hsc`.
- **A view from an address and a count.**
  - *Recommended:* a builtin `view_of(data: ptr[T], count: usize) -> T[]` (and one for strings), in
    `base/builtin`, documented as unchecked, the way `cast` to a pointer is. The memory-safety
    analyses (after M1) can then treat every use as a place to prove. `std/raw` becomes thin
    wrappers, or goes.
- **Enum value names.**
  - *Recommended:* a builtin `name_of(value)` for enum values, from the same type information as
    `any` (C1). Removes `feature_name`.
- **Two small intrinsics.**
  - *Recommended:* `intrinsics.stack_pointer()`, for code that sets up its own stack limit (L0's
    boot stack).
  - *Recommended:* `intrinsics.spin_hint()` (x86 `pause`, Arm `yield`, RISC-V `pause`), so the
    ticket lock can move to `std/concurrency`.
- **Functions something else calls without a carrier or a context.** Limine starts the other CPUs
  by calling a function with the C convention, like the kernel's own entry. Today only the
  program's entry (`--entry`) is compiled that way.
  - *Recommended:* a directive, `#entry_point`, for any function entered from outside Hemera: the
    platform's C convention, no context and no stack check, and the end of the frame pointer
    chain. The body sets up a carrier and pushes a context, like `kernel_entry` does. The
    program's entry becomes one of these, and `--entry` just names which one starts the program.
    Unblocks `start_cpu` (M3).

### C. Larger work

In the order SlopOS needs them:

1. **Type information at run time:** each type used as an `any` gets a generated descriptor (the
   `TypeInfo` that `base/compiler` describes: kind, size, members, an enum's names), so
   `any.type` is real. Then `std/formatting` gets a freestanding core that formats into a
   `TextBuffer`, and the kernel's logger formats its parameters. Unblocks formatted logging and
   `name_of`, and is half of reflection.
2. **`#entry_point`** (from B), for M3's other CPUs.
3. **Entry functions** (`.entry`, `.syscall_entry`, `entry_points`, `return_to_user`), for M4–M6.
   The kernel's interrupt functions then become one `.entry` function, without their repeated
   setup.
4. The rest of *After M1*, unchanged.

### Order

A first, since it's quick and every later SlopOS change runs into those bugs. Then the B
decisions, made together and implemented in one go. Then C1, which most of the kernel's remaining
workarounds wait on. C2 before M3, and C3 before M4.

## After M1

In roughly the order SlopOS needs them, after Phase 7 (which covers entry functions):
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
