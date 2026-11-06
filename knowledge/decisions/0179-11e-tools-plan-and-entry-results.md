# 0179: 11e, the Tools and Scripts, and What a Program's Entry Gives Back

Status: accepted; 11e1 built (below)
Date: 2026-11-06
Related: `0162` (M11's plan), `0169` to `0172` (the shell, calls through manifests), `0176` (11d, documentation),
`../design/shell.md`, Hemera's `docs/compilation.md` (Entry Parameters, Entry Results)

## Context
11e is the last of M11's stages (`0162`): the tools and scripts as programs. A tool that fails today says so only by
its exit code, a number, or by a log line the shell doesn't show; the shell can't say which argument was wrong or what
to do about it, though the program's documentation has an `@error` line for each of its errors (`0176`). The tools
need that first, so it's 11e's first part.

## Decision
11e in six parts:
- **11e1, what an entry gives back**: a program's `main` can give back a value, most usefully a `Result`, which the
  shell shows: an `Ok`'s value as the call's, an `Error` by its variant, the parameter it names and its `@error` hint.
- **11e2, files**: listing, copying, moving and removing, with automatic snapshots before what removes or overwrites,
  and recovering from them; a path that matches only after normalizing (case, separators) gets "did you mean".
- **11e3, reading values**: search, and a viewer and pager for any typed value.
- **11e4, the system**: the process tree, grants, installing.
- **11e5, the editor**.
- **11e6, scripts**: `param` lines, so a script has a manifest and runs with only its grants.

**Entry results** (11e1):
- **The program writes it**: on SlopOS a `main` whose result isn't an integer has its value handed by the generated
  entry to base's `runtime.os_entry_result`, which writes it in the memory the launcher gave as the grant `result`:
  a header, `SlopOsResultHeader` (a magic number, whether it's an `Error`, the size, the type's schema hash), then the
  value as `schema.write_value` writes it. The exit code is 1 for an `Error`, 0 otherwise, so a launcher that doesn't
  give the grant still learns which. A program without the grant writes nothing.
- **The launcher reads it**: `std/os`'s `LaunchOptions.result` grants it; `entry_result` reads it back once the
  program has ended, at most 1 MiB, null when nothing was written.
- **The shell**: a call whose program's entry gives back a value (its manifest says so) gets 64 KiB of memory, made by
  the shell, granted write-only. When the program ends (not killed), the shell checks the schema hash against the
  manifest's, decodes it as it decodes any record, and unwraps the `Result`: an `Ok`'s value becomes the call's value
  when the call is the last of a pipeline with no output of its own; an `Error` becomes the call's error, which `try`,
  `or` and `?` handle like any other.
- **An error names its parameter with `os.ParameterName`**: a field of that type in the error variant's payload holds
  the parameter's name. The message is `name --parameter: Variant: hint`, the hint from the `@error` line for the
  variant in the program's documentation; each part left out when it isn't there.

## Alternatives
- **Errors as log lines**: the shell would parse text, and nothing would check that a program's errors are what its
  documentation says.
- **A typed result over the lifecycle channel**: needs the program to keep its channel open to the end, and a message
  size limit; memory is written once, after `main`, and needs nothing from the program but its return.
- **Exit codes mapped through the documentation**: numbers, without what the error holds.
- **The parameter's name as a string field by convention**: any `string` would do, so nothing tells a name from a
  message; a type of its own says it's a parameter.

## Consequences
- Tools give back `Result`s and the shell shows their errors with no code of their own for it.
- Hemera's compiler gains the entry's side (and Hemera's docs Entry Results); `std/os` the launcher's.

## As Built, 11e1 (2026-11-06)
- **Hemera**: the generated SlopOS entry calls `os_entry_result` for a non-integer result, making the memory a result
  too large for registers is given back through itself, since the entry has no function state of its own (the first
  build stopped at E5002 there; a freestanding test, `BuildsSlopOSProgramGivingAResult`, covers it). Base's
  `os_entry_result` writes the header last, after the value, so a program that ends partway leaves no header.
  `std/os`: `LaunchOptions.result`, `EntryResult`, `entry_result`, `MAX_ENTRY_RESULT`, `ParameterName`.
- **The shell**: `src/apps/shell/results.hsc` (`result_place`, `result_grant`, `read_result`, `error_message`,
  `parameter_named`); a call keeps the memory and closes it at its end, and a failed launch closes the grant's copy.
- **Test**: `test_shell_results`, a `main` giving back `Result[Summary, ResultsError]`, one error holding an
  `os.ParameterName`; a boot test runs it fine, with each error, and inside `try`, on both architectures.
