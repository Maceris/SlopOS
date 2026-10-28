# Typed Log Records

Status: **proposed** 2026-10-27, for M9's 9a (`../decisions/0092`, `../design/observability.md` §2).

## Why SlopOS Needs It

SlopOS's events service keeps log records as a format string and typed arguments, rendered when they're read: a
value can't forge a line, nothing is formatted that nobody reads, and records can be queried by their arguments'
fields. Each record names its format string by an identifier, and holds its arguments in their protocol layout
(`../decisions/0040`) with their schemas' hashes. A program writes records into a ring it shares with the service.

## Where Hemera Is

The logger's interface is already what this needs: `context.logger`'s functions take the format string, the arguments
as `any...` and the caller's location (`base/runtime/logger.hsc`), and formatting is the logger's own business. So the
interface stays; SlopOS's logger (in `base`'s runtime for `OS == .SlopOS`) writes records instead of lines. What it
can't do yet:

1. **Name a type stably.** An `any` carries its `TypeInfo`, but nothing gives a hash of a type that's the same in every
   build and every program, which the record needs to say what its argument is, and the events service needs to find
   its schema in the bundle store.
2. **Write a value in its protocol layout from an `any`.** Protocols do it at compile time, from their types
   (`os.protocol_code`); a log argument's type is only known at run time, through its `TypeInfo`, and a string or a
   slice in it has to be copied after it, with a relative pointer, as `os.append` does.
3. **Name the format string.** Hashing it on every call costs; its place in the program's image doesn't, and is the
   same every run (`runtime.image_offset`), so a record can name it by the program's hash and that offset, and the
   events service reads the string from the program in the bundle store.

## Proposal

1. **A type's schema hash, from the compiler**: BLAKE3-256 of the type's serialized `TypeInfo` (`0040`'s schemas),
   canonical (names, members in order, sizes, alignments, and the schemas of what it holds), as
   `compiler.schema_hash(T)` at compile time and a field of every `TypeInfo` at run time. Typed linking needs the same
   hash for functions' types (`typed-linking.md`), and the bundle store keeps the serialized schema under it.
2. **`std` writes any value in its protocol layout from its `TypeInfo`**, with what it points to after it as
   relative data, for the types protocols allow (plain data, strings, slices, arrays, structs, unions, enums); a
   pointer is written as what it points to, once. A type it can't write (a function, `rawptr`) is written as its
   schema hash alone, rendered as `<type>`.
3. **A format string literal's offset, kept**: the logger takes the offset of a literal format string in the image;
   one that isn't a literal is written as an argument of its own.

Hosted programs keep today's logger, formatting lines as they do now.

## Open Questions

- Whether the schema hash should cover documentation comments (which the shell's help reads) or only the layout.
  Proposed: only what affects the layout and names, so a comment's change isn't a new type.
- Whether `log_*` should refuse a format string that isn't a literal at compile time, rather than writing it as an
  argument.
