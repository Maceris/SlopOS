# Proposal: Code Values, `#insert` and Hygienic Macros

Status: **agreed** 2026-10-22; phases 1 to 4 done 2026-10-23 (*Phases*). Quotes of what goes inside something else
are named for their contents: `#code fields { }`, `variants`, `members`, `patterns` and `cases` (chosen 2026-10-23). In bodies, `#insert` changes the tree in
place, so generics, whose instances share one tree, wait for a per-instance form. Asked for before M5's fourth stage, whose
generated ABI package needs it (`../design/system-abi.md` §4). Directions chosen with the Hemera author:
- **`#insert` works on code, not strings.** Compile-time code builds code as syntax trees, from quotes and
  from what reflection gives, leaning on type safety and the editor support real Hemera gets. Parsing
  source text into code (Jai's string `#insert`) isn't part of this; it can be added later as
  `compiler.parse` if a real use needs it (*Later*).
- **`#code { ... }` and `#code(...)` quote; `#insert` splices**, inside a quote as in a program: one
  directive meaning "put this code here", whether "here" is a program or code being built.
- **Hygienic macros** come with it, since they're the same machinery: compile-time functions that take
  code and give code, expanded where they're called, **marked at the call with `!`** (`swap!(a, b)`),
  since their arguments aren't evaluated as written.
- **Hygiene has no escape hatch:** a name reaches the caller's scope only if the caller passed it in.
- **Code is plain trees,** checked where it lands, so declarations whose names and types come from data
  can be built.

## Problem

Some code is best written as data and generated:
- **The syscall table** (`../design/system-abi.md` §4) should be one list of typed declarations that
  gives the user-space stubs, the kernel's dispatch, the interception filter bits and the documentation.
  Today each call is written out by hand three times (the enum, the stub at each use, the dispatch's
  `if number == ...`), and nothing checks that they agree.
- **Protocol stubs** (`../design/protocols.md`, `0040`): typed messages, their validators and their
  encoders, from a protocol's declaration.
- **Repetitive kernel code**, like the per-kind `match` in `objects.hsc`'s destroy and release, which has
  to name every kind of object again.
- **Hemera's own intrinsics**: `base/intrinsics/atomics.hsc` is 722 bodiless declarations, every atomic
  operation for every integer type and every ordering, written out by hand, which the generator then
  matches by name prefix. They're a product of three short lists.

Hemera can compute anything at compile time (`#run`, compile-time parameters, `type_info_of`,
`compiler.package_info`), and look at a function's parameters and types (`compiler.FunctionInfo`), but
compile-time code can only give **values**: numbers, strings, structs of them. It can't give a function,
a declaration, a statement or an expression. Generics make instances of code someone wrote; they can't
make code whose shape depends on data, like a function per member of a table.

## What Hemera Already Has

- **Compile-time execution** (`docs/compilation.md`): code reached by `#run` or a constant is checked,
  generated, and run through a JIT, once, with its result a constant. Checking that needs the value waits
  for it; a value that needs itself is a cycle error.
- **Declarations that aren't known yet** (`names.h`, `PackageProgress::pending_chains`): a top-level
  `#if` chain not yet decided may still declare names, so a lookup that doesn't find a name waits for the
  package's pending chains before failing or taking an import's. An `#insert` at the top level is the
  same situation: it may declare names nobody can know until it runs.
- **Bodies are checked into side tables** (`checking.h`, `CheckedBody`): what each node is lives in a map
  by node, and a local is known by the node that defines it. So generic instances share one tree, and
  inserted code only needs fresh nodes where the same code goes in twice.
- **Reflection** (`base/compiler`): `FunctionInfo` with parameters, types, defaults, `#escaping`;
  `TypeInfo` for every type; `package_info`, `find_function`, `find_constant`; `report_error` at a
  location; `#caller_location`.

## Prior Art

| Language | Code as data | Insertion | Hygiene |
|---|---|---|---|
| **Jai** | `Code` values from `#code`, and `compiler_get_nodes` to walk and change them | `#insert` of a string or a `Code`; `#expand` macros | Names a macro declares don't leak; a backtick (`` `x ``) reaches the caller's scope. String inserts are the common case in practice, and the hardest to read |
| **Nim** | `NimNode` trees; `quote do:` with backticked splices | Macros return trees, expanded at the call | Templates are hygienic, with `{.inject.}` to export a name; macros' `quote` gensyms locals |
| **Rust** | `macro_rules!` on token trees; procedural macros on `TokenStream`, in a separate crate | At the call, `name!(...)`, or attributes and derives | Mixed-site: locals are hygienic, items and paths aren't. Proc macros are tokens, so they parse and re-print code |
| **Racket / Scheme** | Syntax objects carrying scope sets | `syntax-rules`, `syntax-case` | The reference model: every identifier carries the scopes it came from (Flatt, "Binding as Sets of Scopes", POPL 2016) |
| **Julia** | `Expr` trees; `quote ... end` with `$` splices | Macros at `@name` | Hygienic by renaming locals, with `esc()` to opt out per expression |
| **Swift** | SwiftSyntax trees, built by a plugin in another process | Freestanding `#name(...)` and attached `@Name` macros | Generated names through `makeUniqueName`; macros can only add code, never change what they're attached to |
| **Zig** | None | None: `comptime`, `inline for` and `@Type` make types and unroll code, but can't declare functions | n/a |
| **C++26** | Reflections (`^^x`), P2996; token sequences `^^{ ... }` with `\(x)` splices proposed in P3294 | `queue_injection` of token sequences | Not hygienic: injected tokens are looked up where they land |
| **MetaOCaml, Terra** | Typed quotes (`.< e >.`), staged | Running or splicing a quote | Lexical: a quote's names are bound where it's written |

What carries over: trees rather than tokens or text (Nim, Julia, Racket, Swift); quotes with typed
splices for building them (everyone but Zig); hygiene by marking where an identifier came from rather
than by renaming text (Racket's scope sets, simplified); and Swift's rule that a macro adds code but
never changes code it was given.

## Design

### 1. `Code` values and quotes

`compiler.Code` is a compile-time-only value: a syntax tree the compiler keeps, which compile-time code
holds by handle. Like a pointer, it can't reach the program (`docs/compilation.md`).

A **quote** makes one from Hemera written in place, parsed but not checked:

```
// One expression, one statement or a block of them, or top-level declarations
square :: #code(x * x)
body :: #code {
    total += item
}
```

What a quote is (expression, statements, declarations) is decided by where it's inserted, and an error
there if it can't be that: the same tree can't be both a declaration and an expression.

**Splices** put values into a quote when it's evaluated, written `#insert expression`, the same directive
that puts code into a program (section 3), with parentheses where the expression would run on, as for
`#run`:

| What's spliced | Becomes |
|---|---|
| `Code` | That tree, copied |
| A `type` value | That type, as a type node (no name lookup: it's the type itself) |
| An integer, float, boolean, character, enum member or string | A literal of it |
| A function value | That function, resolved, like a type |
| `compiler.Name` (below) | An identifier |
| A view or array of `Code` | Its elements, in order, as a list: arguments, statements, members, cases |

```
// A stub per syscall, as a list of declarations
stub_for :: fn(call: compiler.FunctionInfo, number: u32) -> compiler.Code {
    return #code {
        #insert compiler.name(call.name) :: fn(#insert parameters_of(call)) -> #insert result_of(call) {
            raw :: x86_64.system_call(#insert number, #insert arguments_of(call))
            return #insert decode_result(call)
        }
    }
}
```

**Names** are the one place a string meets code: `compiler.name("handle_close")` gives a
`compiler.Name`, which only splices as an identifier, and has to be one (letters, digits and `_`, not a
keyword), or it's an error at the call. A name never parses into anything else, so it's not source
text. Tables like the syscall table, and lists like the atomics' operations, are where generated names
come from:

```
// base/intrinsics/atomics.hsc, generated: every operation, type and ordering
ORDERINGS :: string.["", "_acquire", "_release", "_acquire_release", "_no_fence"]
INTEGERS :: type.[u8, u16, u32, u64, i8, i16, i32, i64]

#insert atomics()

atomics :: fn() -> compiler.Code {
    declarations : compiler.Code[..]
    for T in INTEGERS {
        for ordering in ORDERINGS {
            suffix :: format("_%%", type_name(T), ordering)
            array_add(&declarations, #code {
                #insert compiler.name(concat("interlocked_exchange_add", suffix)) : fn(target: ptr[mut #insert T], value: #insert T) -> #insert T : ---
                #insert compiler.name(concat("interlocked_increment", suffix)) : fn(target: ptr[mut #insert T]) -> (old: #insert T) : ---
                // ... and the rest of the operations
            })
        }
    }
    return compiler.list(declarations)
}
```

Nothing here is parsed from text: the types are type values, and each name is checked to be one
identifier.

### 2. Building and inspecting code

`base/compiler` gets a small API over `Code`, for what quotes can't say:
- **Making**: `name`, `literal(any)`, `type_code(type)`, and `list(Code[])` for a list of statements,
  arguments or declarations.
- **Inspecting**, for macros that take code: `kind(code)` (an enum of node kinds, a stable subset of the
  compiler's), `children(code)`, `identifier_of(code) -> string?`, and `location(code)`.
- **No changing a tree in place.** Code is made, combined and copied, never edited, so a quote's tree
  can be shared and a macro can't change what it was given (Swift's rule).

The node kinds compile-time code sees are an API of their own, separate from the compiler's internal
`NodeType`, like `PackageInfo` is separate from what the compiler tracks (`package.hsc`).

### 3. `#insert`

`#insert expression` runs `expression` at compile time, which gives `Code`, and puts that code where the
`#insert` is, to be checked as if written there:

| Where | The code must be | Example |
|---|---|---|
| Top level of a file | Declarations | `#insert syscall_stubs(Syscalls)` |
| In a body, as a statement | Statements | `#insert unrolled(4, body)` |
| In an expression | An expression | `x := #insert sum_of(fields)` |
| In a struct, union or enum's members | Members | `#insert flags_from(Permissions)` |
| As a `match`'s or `switch`'s cases | Cases | `#insert cases_for(slop_os.Syscall)` |

How it fits the compiler:
- **At the top level**, an `#insert` is pending like an undecided `#if` chain: a name the package doesn't
  declare yet may come from it, so lookups wait for it before taking an import's or failing. Once it has
  run, its declarations are declared like any parsed file's. Code an `#insert` runs needs what it reaches
  checked first, so a generator that needs a name the insert declares is a cycle error (E-new), saying
  which.
- **In a body**, checking parks at the `#insert` until it has run, then checks the inserted nodes in
  place. A generic's instances each run their `#insert`s, since the code can depend on `T`; the result
  for the same arguments is the same, and is kept once.
- **Fresh nodes**: each insertion copies the tree, so two insertions of one quote are different locals,
  and side tables keyed by node stay right.
- **Errors** in inserted code are reported where the code was written, the quote or the macro, with a
  note for each step it was inserted through: `inserted at main.hsc:12 by syscall_stubs`. Debug info
  gives inserted code the lines of its quote.
- **Determinism** (`docs/compilation.md`): an insertion's output depends only on its inputs, and a
  package's declarations are ordered by their source position, an insertion's at the `#insert`'s.
- **Seeing what was made**: `--show-inserted=file:line` prints the code an `#insert` or a macro call
  made, formatted as Hemera, so generated code can be reviewed and diffed. The printed form is for
  reading, never parsed back.

### 4. Macros

A **macro** is a compile-time function marked `#macro`, whose parameters of type `compiler.Code` take
their arguments' syntax rather than their values, and whose result is inserted at the call. A call is
marked with `!` after the name, `swap!(a, b)`, so a reader sees that the arguments aren't evaluated as
written; calling a macro without it, or a function with it, is an error:

```
// Runs body with each of a struct's fields, unrolled: field is the field's name, value its value
each_field #macro :: fn(value: compiler.Code, field: compiler.Code, body: compiler.Code, T: type) -> compiler.Code {
    ...
}

swap #macro :: fn(a: compiler.Code, b: compiler.Code) -> compiler.Code {
    return #code {
        temporary :: #insert a
        #insert a = #insert b
        #insert b = temporary
    }
}

swap!(x, temporary)    // still right: the macro's temporary isn't the caller's
```

- Parameters that aren't `Code` are compile-time parameters as they are today: types, integers, enums,
  functions.
- A macro's result is inserted as if by `#insert` at the call: an expression where the call is an
  expression, statements where it's a statement.
- A macro can call other macros, and the expansion depth is limited (the limit's error names the chain).
- Arguments are spliced where the macro puts them, so an argument used twice is evaluated twice, as
  written. Macros that mean to evaluate once bind the argument to a local first, which hygiene keeps
  private.

### 5. Hygiene

Every identifier node carries where it came from: written in the file, or made by a particular
expansion (one mark per `#insert` or macro call, made fresh each time). Looking a name up follows two
rules, a simplified form of Racket's scope sets:
- **A name a quote wrote** (a macro's `temporary`) sees locals the same expansion defined, then the
  top-level names of the package the quote is in, and its imports. Never the caller's locals, and
  never a caller's import: a macro in `std` that writes `runtime.assert` means `std`'s `runtime`.
- **A name from an argument** (`x` and `temporary` in `swap!(x, temporary)`) keeps the caller's mark, so it
  sees the caller's locals and nothing the macro defined.

So a macro can't capture a caller's variable by accident, and a caller can't shadow what the macro
calls. When a macro is meant to introduce a name the caller sees (an `each_field!` that gives the body
`field` and `value`), the name comes from the caller, as an argument, which already has the caller's
mark. There's no other way to reach the call site: no `caller_name`, no marked splice. If real macros
show a need, it's added then, explicitly.

`#insert` follows the same rules: code a generator quoted resolves in the generator's package, and names
made by `compiler.name` resolve where the `#insert` is, since that's what a generated declaration's name
is for. Top-level declarations an `#insert` makes are declared in the package it's in, like code written
there.

### 6. Restrictions

- **Only at compile time:** `Code` can't be a field of a type that reaches the program, a run-time
  parameter, or a constant's value.
- **Inserting adds; it never changes** code that's there.
- **No reading the program from inside a body's insert** beyond what reflection already allows: what an
  insert sees is checked first, as for any compile-time code, and the cycle rules are the same.
- **Unsafe as any compile-time code** (`docs/compilation.md`): generators run with the program's
  compile-time permissions.

## Phases

1. **Code values and quotes**: `compiler.Code`, `#code(...)` and `#code { ... }`, splices of `Code`,
   types and literals, and the handle bridge between JIT code and the compiler's trees.
2. **`#insert` in bodies and expressions**, with copies, side tables, error notes and `--show-inserted`.
3. **`#insert` at the top level** and in members and cases, with pending inserts in name lookup, and
   the cycle error.
4. **Names and the building and inspecting API**, and reflection reaching it (`FunctionInfo` to
   parameters as code).
5. **Macros and hygiene**: `#macro`, marks, the two lookup rules, and the depth limit.
6. **First users**: `base/intrinsics/atomics.hsc` generated from its three lists; the SlopOS ABI
   package's syscall table, generating the stubs and the kernel's dispatch (M5's fourth stage); and the
   per-kind matches in the kernel's object code.

Each phase gets parser and checker scenarios, and back-end scenarios that run what was inserted.

## Decided

1. **Quotes and splices**: `#code { }` and `#code(...)` quote; `#insert` splices into a quote, as it
   inserts into a program. They're one operation (work out code now, put it here), as in Template
   Haskell's `$( )` and Scala 3's `${ }`, which also use one syntax for both; Lisp's unquote and Julia's
   `$` are separate only because those languages have no top-level insert to share it with. `#(...)` was
   considered, and rejected as too vague, with no name after `#`; `#splice` was the alternative name.
   **In nested quotes**, an `#insert` belongs to the innermost `#code` around it; there's no way to
   splice at an outer quote's level from inside an inner one, which generators of generators don't need
   yet.
2. **Macro calls are marked**: `name!(...)`.
3. **No hygiene escape**: names reach the caller only through arguments.
4. **Plain trees**, checked where they land; no typed quotes for now.
5. **Inspecting code starts small**: kinds (a stable enum of its own), children, identifiers and
   locations, growing with what real macros need, since whatever compile-time code sees becomes an API
   to keep stable.

## Later

- **Parsing text into code** (`compiler.parse(string) -> Code`), Jai's string `#insert`, for code that
  really is text, like a grammar or a table in another language. Left out until something needs it;
  everything known so far, the atomics included, is built from names, types and quotes.
- **Typed expression quotes** (`Code[T]`), checked when quoted, if generators turn out to want their
  errors early.
