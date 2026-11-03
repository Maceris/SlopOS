# 0170: 11b2, Calls Through Manifests, as Built

Status: accepted
Date: 2026-11-02
Related: `0162` (M11's plan), `0163` (entry values), `0169` (the language's core), `../design/shell.md` §3

## Context
11b's second part: a word in command position that isn't a variable or a built-in names a program, which the shell
finds, reads the manifest of, gives what its parameters ask for, launches and waits for (`shell.md` §3). The shell
needs the program and its manifest from the bundle store, a way to launch from a manifest known only as it runs, and
the grants its parameters' types ask for.

## Decision
- **Programs from the session manager**: a new protocol, `programs` (`src/protocols/programs`), answers `Find(name)`
  with a program of the store's boot root, its executable and its manifest as read-only memory, or `Missing`. The
  session manager serves it on one connection per session, given to the shell, bound to its port under `PROGRAMS_KEY`
  plus the session's number, closed when the session is. The shell gets nothing else of the store's: it can't put,
  pin, root or collect.
- **The shell launches**: it's given its own connection to the process manager, and launches each program in a
  process of its own (the jobs of `shell.md` §6 are its), with 4 MiB split off its 16 MiB budget, a lifecycle channel,
  and copies of its clock and locale pages; it waits for the program's end on its port. Its exit code is the call's
  result: 0 is nothing, any other an error, "`name` ended with `code`", and a program killed is "was ended". No log
  records' ring yet.
- **Hemera's `std`**, for launchers that meet entries as they run:
  - `std/schema`'s `parse` reads a schema's bytes into its types: each one's kind, size, name, members, inputs and
    outputs, enum members, union variants, array dimensions, and places they refer to. `write_rooted` writes the
    schema of any one of them, renumbered from it, which `hash_rooted` hashes as `schema.hash` hashes that type.
  - `std/os`'s `launch_named` launches with `NamedGrant`s (a label and a handle) and `NamedValue`s (a name, the
    parameter type's schema hash, and the value as `write_value` writes one); the typed `launch` now gathers its
    grants and values and launches the same way.
- **Arguments**: `--name` goes to the parameter of that name, the argument after it its value, except a bool's, where
  `--name` alone is true unless `true` or `false` follows. Every other argument goes, in order, to the next parameter
  not yet given that takes one by position. A bool not given is false; an optional not given is None; anything else
  missing is an error naming it and its type.
- **Values by type**, written as the entry reads them: integers from a number, a size, or a bare word, checked
  against the type's range; bools; strings from text or a path; an enum's member by name; a `Duration` from a duration
  or a bare word like `250ms`; a struct from a record with its fields; an optional's Some; a list for a view. A value
  that doesn't fit says why, after the parameter's name.
- **Grants by type**: a `Channel[Terminal]` is a new connection to the shell's terminal, given without an argument; a
  `Channel[Dir]`, `Channel[File]` (opened, made if it isn't there) and `Channel[ReadOnlyFile]` come from a path beneath
  the shell's home (`~` and `.` are the home, a leading `~/` is dropped, a leading `/` is refused). Any other grant is
  left out if it's optional, and an error if it isn't. Errors come before anything starts, and grants made for a call
  that doesn't start are closed.
- **Typing faster than a client reads**: found by this part's test, whose lines are longer than one delivery of
  input. The terminal service's decoded input holds 32 events, and a burst decoded past that was dropped. It now
  reads the serial line only for as many bytes as there's room for events, and again once a delivery makes room. Keys
  from the input service wait in a queue of 256 for room, and the secure attention key is taken at once and empties
  that queue. The input service keeps 256 events for its reader and delivers up to an `Input`'s worth at a time,
  keeping the rest, where it used to drop what one `Read` didn't take.
- **Tests**: a boot test calls `test_shell_calls` (a new test program) by position and by name, with a bool alone, an
  enum's member, a duration, a list and a directory beneath the home, and the terminal given unasked. It then checks
  an exit code as an error, a value missing, a word that isn't a number, a member that isn't one, and `test_values`'s
  required `DebugLog`, a grant the shell can't make. `std/schema`'s scenario reads an entry's schema back and checks
  each parameter's rooted hash, names and members.

## Consequences
- The root task's grants are 61 of 64 with `test_shell_calls`; the tools of 11e can't all be boot modules.
- The shell waits for a call without reading its terminal: Ctrl-C reaches the program, not the shell, until jobs in
  11d.
- A program's result is only its exit code until 11c renders results from their schemas.
- Defaults aren't in manifests yet: a parameter is optional only as an optional type.
