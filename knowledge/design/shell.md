# The Shell

Status: **proposed** 2026-10-24, for roadmap M11. Builds on `../decisions/0018` (the shell language isn't Hemera;
arguments are grants; globs are `FileSet`s), `0044` (entry signatures as manifests) and
`../problems-and-directions.md` §3, §4 and §9. The syntax below is a sketch to argue about, not a specification. The
choices still to make are at the end and in `../open-questions.md`, *Shell*.

## 1. What Goes Wrong Elsewhere

| Problem | Where | SlopOS answer |
|---|---|---|
| Unquoted variables are split on whitespace and globbed again; an empty variable turns `rm -rf "$DIR/"*` into `rm -rf /*` (Steam for Linux, 2015) | POSIX `sh`, bash | Variables hold values, which are never re-parsed (§3) |
| A file named `-rf` is read as an option; every program must accept `--` | Every Unix tool | Options are the shell's syntax, matched against the manifest; a value is never an option (§3) |
| Errors are ignored by default; `set -e` has famously surprising exceptions; a pipeline's failure is hidden without `pipefail` | `sh` | A failed command is an error value that stops the script unless handled (§5) |
| Everything is text: programs parse each other's human-readable output (`ls`), and locales break the parsers | Unix | Programs return typed values and streams; the shell renders them (§4) |
| A script runs with all of its user's authority, so `curl … \| sh` is trusting everything | Every shell | A script declares its parameters and gets only what it's given (§7) |
| Each program hand-writes argument parsing, help and completion, inconsistently | Every OS | All three come from the manifest (§3, §6) |
| Objects in the shell, text outside it: external programs still exchange bytes | PowerShell, Nushell | Every program speaks typed values (`0044`), so there's no "external command" boundary |
| Exit codes are a byte | POSIX | Results are the entry function's typed `Result` |

## 2. Shape of the Language

- **Interactive first**, readable second, a scripting language third (`0018`: Hemera is a poor fit for the first).
- **Values:** booleans, integers, sizes (`4MiB`), durations (`250ms`), instants, strings, paths, lists, records,
  enums by member name, `Stream[T]`, and handles (`File`, `Dir`, `Channel[P]`). Each maps to a Hemera type through
  its schema (`protocols.md` §5), so a value passed to a program is checked against its parameter's type.
- **Names:** `let x = ...` binds; there's no global environment, only the shell's own variables, which are never
  inherited by programs.
- **Paths** are the shell's: `notes/todo.md` is resolved beneath the shell's current directory, a `Dir` it holds;
  `~/notes` beneath the home `Dir`; other roots (`sys:`, a USB stick's `usb:`) are names the shell binds to handles
  it was given. A program never sees a path, only the handle the shell opened (`0046`).

```
search "TODO" ~/src/**/*.hsc --ignore-case          # a call: positional and named arguments
let big = list ~/media | where size > 1GiB         # a pipeline, its result bound to a name
big | sort size | take 10                           # rendered as a table by the shell
copy ~/notes/plan.md usb:/backup/ or { warn "no stick" }   # handling an error
```

## 3. Calls Through Manifests

- A word in command position names an installation (`software.md` §6), a shell function, or a built-in. Its manifest
  (`0044`, from the bundle store) lists the parameters, their types, defaults and documentation.
- **Arguments** are matched to parameters by position or by `--name`; `--flag` is shorthand for `--flag true` on a
  `bool`. Matching is the shell's: values are never examined for leading dashes.
- **Each value is parsed by its parameter's type:** text for a `string`, a pattern for a `Regex` (compiled by the
  shell to report errors before launch), a member name for an enum, `5s` for a `Duration`.
- **Grants from types** (`0018`, `security.md` §6): a `ReadOnlyFile` parameter is opened read-only, a `File` writable,
  a `Dir` as a directory beneath the shell's handle, a `FileSet` from a glob as a directory plus a filter. A
  `File[]` given a glob is expanded to handles, up to a limit, with a suggestion to declare `FileSet` beyond it.
  `Channel[P]` parameters come from what the session can reach, or from the powerbox.
- **Before anything runs**, the whole command line is checked: unknown parameters, missing ones, values that don't
  parse, pipelines whose types don't meet. The error points at the word.

## 4. Pipelines and Rendering

- **`a | b`** connects `a`'s `Stream[T]` result to `b`'s `Stream[T]` parameter marked as its input (proposed: the
  parameter named `input`), checked for the same `T` before either starts. A `Stream[T]` travels over a channel as
  batches of records in a shared buffer, with backpressure (`std`, 11a); `Stream[u8]` is a byte stream.
- **Built-in stages** (`where`, `sort`, `take`, `map`, `group`) run in the shell on typed records, so a filter
  doesn't need a process.
- **Rendering** is the shell's: a record as fields, a stream of records as a table, any value through its schema
  (`protocols.md` §5), so a program returns data and never formats it for a terminal. A program that wants the
  terminal itself (an editor) takes a `Terminal` parameter.

## 5. Errors

- A call's result is the entry's `Result`. An error **stops a script** at that line, rendered with its type's
  variant and data, unless it's handled: `cmd or { ... }`, `try { ... } catch e { ... }`, or `cmd?` to pass it to
  the caller of a shell function.
- In a pipeline, the first stage to fail ends the pipeline and its error is the pipeline's, with which stage it came
  from.
- **Interactively**, an error is shown and the prompt comes back; nothing is "exit code 1".

## 6. Interactive Use

- **Completion** from manifests: parameter names, enum members, paths by listing the `Dir` beneath which they'd
  resolve, installations by name.
- **Help** is the manifest's documentation comments, shown by `help cmd` and inline while typing.
- **History** in the shell's installation data (`software.md` §6), never shared between sessions unless granted.
- **Jobs** are child processes the shell owns. Ctrl-C reaches the shell as the terminal's `Interrupt`
  (`console-and-sessions.md` §2); the shell sends the foreground job `Stop` over its lifecycle channel and kills it
  (the `kill` right, `0017`) if it hasn't ended after a grace period. The kernel has no such request (`0056`'s
  termination signals report an end, they don't ask for one), so the lifecycle channel is a `std` protocol every
  launched program is given (in 10a, with `Ping`, `0097`), which `std` turns into a cancellation the program can wait on.
  Background jobs get their own terminal or none.

## 7. Scripts Are Programs

- A script begins with its parameters, typed like an entry's:
  ```
  param photos: FileSet, into: Dir, --dry-run = false
  ```
  so it has a manifest, the shell completes and checks its calls like any program's, and it can be installed.
- Running a script starts the shell's interpreter in a new process with only the script's grants, never the
  invoking shell's authority. A downloaded script can do only what its parameters say.

## 8. Implementation

- A tree-walking interpreter in Hemera to start: a parser producing tagged unions, values allocated in per-command
  arenas, calls through `std/os`'s `launch` with the startup block built from the parsed arguments.
- The same manifest code generates GUI forms in M15 (`display.md`).

## Also Proposed (`lessons.md` §4, 2026-10-30)

Decided when M11 is planned:
- Automatic snapshots per volume, and removal from the shell's tools recoverable through `recover` (§4.1).
- `Progress` on the lifecycle channel, drawn on the job's line (§4.2).
- Errors rendered with the parameter they came from, and hints per error variant from the manifest (§4.2).
- Completion inserting stored bytes, and "did you mean" for paths that match only after normalization (§4).

## 9. Open Questions

- The language's name and syntax: the sketch above, or closer to an existing shell (Nushell's, fish's) for
  familiarity.
- How a pipeline stage's input parameter is marked: a naming convention, a type (`input: Stream[T]` as the first
  `Stream` parameter), or an annotation once Hemera can read parameter annotations through reflection.
- Whether shell functions can be exported as programs of their own, and how a script's helper functions are reused.
