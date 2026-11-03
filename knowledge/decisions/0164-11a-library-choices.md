# 0164: 11a's Library Choices

Status: accepted
Date: 2026-11-02
Related: `0162` (M11's plan), `0163` (entry values), `../design/shell.md` §4

## Context
Building 11a's parts of Hemera's `std` raised four choices `0162` didn't settle, made with the owner.

## Decision
- **A stage's output** is a `Sink[T]` parameter named `output`, the writing end of a stream, as its input is a
  `Stream[T]` named `input`: entries return an `int`, so a stream can't be a result. `a | b` connects `a`'s `output`
  to `b`'s `input`, and the last stage's `output` goes to the shell, which renders what comes.
- **Time zones** are TZif files on the system volume, `zoneinfo/`, which the image builder copies there; `std/time`
  reads them through a `Dir` the program is given.
- **Regular expressions** take RE2's syntax, but for what can't be linear: literals, `.`, classes (`[a-z]`, `\d`, `\w`,
  `\s` and their negations), `^` and `$`, groups and alternation, `*`, `+`, `?` and `{n,m}`, their non-greedy forms,
  and a case-insensitive flag, matching code points; no backreferences or lookaround.
- **The terminal client and line editor** are `std/terminal`: a client of the terminal protocol, and a line editor on
  it with history and completion hooks, shared by the shell, the editor and any tool.

## Alternatives considered
- **An entry returning a stream**: work in the compiler and runtime for results, where a parameter does the same.
- **Zones compiled into `std`**: no files, but a rebuild for every rule change.
- **A smaller regular expression core**: less to write, but counted repetition and flags are expected of any search.
- **Line editing in the shell only**: every other tool would write its own.

## Consequences
- The shell's manifests show both ends of a stage by name, `input` and `output`.
- The image builder gains the zone files.
