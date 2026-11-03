# 0163: 11a1, Entry Values, as Built

Status: accepted
Date: 2026-11-02
Related: `0162` (M11's plan), `0044` (entries as manifests), `0068` (missing grants), Hemera's `docs/compilation.md`
(Entry Parameters)

## Context
`0162`: an entry takes typed values as well as handles, written by whoever launches it into one page granted as
`arguments`, so the shell can call a program with what its manifest says it takes.

## Decision
- **Which parameters are values** (Hemera's compiler): a parameter is a handle only if its type is a 4-byte distinct
  alias or struct named for a kind of handle base's runtime knows (`slop_os_kind_of`), or an optional of one; any other
  type is a value, which the checker allows unless it is or holds a function, a type, an `any` or a `rawptr`. The
  generated entry asks `runtime.os_entry_value` for each value parameter, by its name, with its type's descriptor and
  the slot to fill.
- **The page** (base's runtime): a header (a magic, the count of values, every byte's count), then each value: its
  parameter's name's and its own byte counts, its type's schema hash, the name, and the value as `schema_write_value`
  writes one, each padded to 8 bytes. The runtime maps the grant the first time it's asked, finds the value by name,
  takes it only if its schema hash is its parameter type's, copies it to the heap, and makes each distance in it a
  pointer into the copy again (`schema_read_value`), checking each lies within what was written. An optional parameter
  is `None` without a value; a required one without one, or of another type, ends the process with the code for a
  missing grant.
- **The writer** (Hemera's `std/os` `launch`): a grants struct's fields that aren't handles are written into the page,
  an optional one only when it's `Some`; the page is the launcher's own grant, given back if the launch fails. The
  grants are read through an `any`, since a struct holding views of the caller's stack can't be pointed to otherwise.
- **Tests**: Hemera's SlopOS program scenario takes a number, a string and an optional; on SlopOS, `test_values`
  launches a copy of itself with a number, a string, a list of strings, an enum's member and a record, which the copy
  reads back and checks.

## Alternatives considered
- **One record parameter for all the values**: less in the compiler, but every program would wrap its options.

## Consequences
- The manifest, the schema of the entry's type, already describes the values, so the shell needs nothing more to call a
  program with them.
- A launcher with grants struct fields of a type that was a 4-byte "handle" by shape only now writes them as values.
