# 0108: 9c1, Typed Files and Names, as Built

Status: accepted
Date: 2026-10-30
Related: `0107` (9c's plan), `0046` (typed files, names compared byte for byte), `0097` (invisible characters),
`0040` and `0071` (schemas and validators), `0089` (transactions)

## Context
`0046` gave a file an optional schema hash, with `std`'s typed open checking its bytes; the config store's values are
typed files (`0107`). `0097` had slopfs refuse names that show something other than their bytes. slopfs's object
record already had room for a schema hash, unused.

## Decision
- **The files protocol carries a type**: `files.Info.schema` gives a file's schema hash (all zeros for bytes alone),
  and `dir.OpenFile.schema` asks for one: a file made has it, one there already must have it, or the open fails with
  the new `FileError.WrongType`. All zeros asks for neither. `OsError` gains `WrongType` beside it.
- **The volume server keeps it** in the file's record (`slopfs.set_schema`, `Info.schema`), and gives it with `Info`.
  A typed open isn't followed through a stored link, which a link on its way then refuses as `IsALink`, and isn't taken
  in a `Dir` transaction (`WrongType`), whose log keeps no types yet. The FAT server refuses every typed open with
  `WrongType`: FAT has nowhere to keep one.
- **`std`'s typed files** (Hemera, `std/os/slop_os_typed_files.hsc`): `open_typed_in[T]`, `read_typed_in[T]`, which
  gives the bytes only if they hold a `T`, and `write_typed_in[T]`, which writes only bytes that do; `value_bytes` for a
  value built as a message is (`begin`, `append`), `typed_value[T]` and `items_of` to read one. A read-only open checks
  the type from `Info` once it's open. A value is checked as a message's is, booleans and enums in range and
  `Relative`s within the bytes, by walking its type's information at run time; a type holding a handle is never held.
  The checks the protocols generate at compile time weren't reused: their code names `os` from its callers' packages.
- **Names** (`0097`): slopfs's `name_holds` decodes a name as UTF-8 and refuses one that isn't, and one with a C0 or C1
  control, a bidirectional control or any of Unicode's default ignorable code points, the invisible characters UTS #39
  lists, as `InvalidName`. Names are still compared byte for byte, unnormalized.
- **Tests**: slopfs's hosted test refuses five such names and takes an accented one, and keeps a schema; `disk_check`
  writes a typed file on the system volume through `std`, reads it back checked, is refused it as another type and
  refused a value that isn't one, and is refused a typed file on the EFI system partition.

## Alternatives considered
- **Types through links and in transactions**: the far volume's open, and the transaction's log, would each carry the
  schema; left until something needs them, as refusing them can't let a wrong type through.
- **A FAT sidecar for types**: a hidden file per typed file, which other systems would show and lose.

## Consequences
- 9c2, the config store, keeps its values as typed files.
