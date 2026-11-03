# 0172: 11c, Pipelines and Rendering, as Built

Status: accepted
Date: 2026-11-03
Related: `0162` (M11's plan), `0165` (streams), `0170` (calls), `../design/shell.md` §4

## Context
11c: `a | b` between programs over typed streams, the built-in stages, and results rendered from their schemas. A
program's records are a `Sink[T]` named `output` (`0164`), and its input a `Stream[T]` named `input` (`0162`). The
shell meets T only in manifests.

## Decision
- **T in manifests**: `Stream[T]` and `Sink[T]` hold a member `records : T[0]`, no bytes, in a struct that's
  `#packed #align(4)` so it's still a 4-byte handle. T is then in the schema of every entry that takes one, so a
  manifest says what records a program reads and writes. `std`'s stream gained, for code that knows T only by its
  schema hash: `untyped_writer_on` (optionally not waiting for the reader's answer to `Open`),
  `untyped_reader_on`, and `end_without_waiting`.
- **A pipeline**: programs next to each other run together, each one's `output` connected straight to the next one's
  `input`. Their T is checked to be the same (by the schema hash of each manifest's T) before any starts. The first
  takes what comes before it, if anything; the shell reads what the last writes. A program's `output` is always read
  when it's last, so a call alone has its records as its value, a list. A required `input` with nothing before it, an
  input with no `input` parameter, and an `output` missing before another program are errors found before anything
  starts. The first stage to fail is the pipeline's error.
- **Into a program**: a list's items, or a value alone, are written as records of its input's T (the same encoding as
  arguments, `0170`). They go into a ring big enough for all of them, and the shell sends `Open` without waiting for
  the answer. So the shell never waits on a program that opens its output first, or that writes before it has read
  everything.
- **Out of a program**: each record is decoded by the manifest's schema into the shell's values: integers, bools,
  text, an enum's member's name, a `Duration`, a record of a struct's fields, an optional's value or null, a union's
  variant, a list of an array's items, and what a pointer points to. Text and names are copied, since the record's
  bytes are the stream's and the manifest's go with the call.
- **Built-in stages**, on values in the shell: `where expression` keeps the items it's true for, and `map expression`
  is each item's value of it. In both, each item's fields are bound as names and the item as `it`. `sort [field]
  [--descending]` is a stable sort by the field or the item; `take n` keeps the first n. `group field` gives a record
  for each value, in the order first met, of the value, `count` and `items`. A value or expression can only be a
  pipeline's first stage.
- **Rendering**: a list of records shows as a table: a column for each field in the order first met, headed by its
  name, as wide as its widest cell, two spaces apart. Text in cells is unquoted.
- **Tests**: a boot test renders a program's rows as a table; filters, maps, sorts, takes and groups them; connects
  two programs; writes a list into one; and checks four errors. `test_shell_calls` gained an `input` and an `output`
  of rows. The language test still passes.

## Consequences
- A program connected to the shell on both sides gets all its input before the shell reads its output: no deadlock,
  but what's given is held in memory, sized to fit.
- Values from records lose their type: an enum's member is text, a `u64` a whole number (a size isn't shown as one
  unless it's the shell's own). Rendering by type names or hints from manifests is for later.
- Tables are as wide as their cells; nothing wraps or truncates them to the terminal's width yet.
