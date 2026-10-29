# Typed Log Records

Status: **accepted** 2026-10-27, its open questions decided with the owner, for M9's 9a (`../decisions/0092`,
`../design/observability.md` §2).

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

## Decided With the Owner (2026-10-27)

- **The schema hash covers layout and names**: names, members in order, sizes, alignments and the schemas of what a
  type holds, not its documentation comments, so editing a comment isn't a new type, or a new library interface.
- **A format string that isn't a literal is written as an argument**: a literal is named by its place in the image,
  anything else copied into the record, so every call that works today keeps working.

## Built (2026-10-27)

- **The schema hash is computed in `std`, not by the compiler** (chosen with the owner when building it): `std/schema`
  serializes a type canonically from its `TypeInfo` (`schema.write`) and hashes the bytes with BLAKE3
  (`schema.hash`), the same code at compile time and at run time, so the serialized schema and its hash can't
  disagree. `TypeInfo` gains no field; the logger caches each type's hash. The compiler builds descriptors in two
  places, and at compile time one can exist before its type is laid out, which a field would have had to cope with.
- **`schema.write_value`** writes a value with what it points to after it, each pointer as a distance from the value's
  start, and `rawptr`, functions, type values, `any` and `#union` structs holding pointers as 0, so nothing written
  gives away an address.
- **`runtime.in_image`** says whether an address is in the program's image, from the ELF or PE/COFF headers there,
  so the logger can tell a literal format string from one that isn't.
- On the way, a generic function's instances now keep what follows its name (`#no_context`, `#never_returns`,
  `#calling_convention`), which they had lost.

## Built for SlopOS's Logger (2026-10-29, 9a3, `../decisions/0093`)

- **The schema code is in `base`** (chosen with the owner): base's SlopOS logger writes records itself, so
  `schema_write`, `schema_hash` and `schema_write_value` moved into `base`'s runtime, with a plain BLAKE3
  (`hash_blake3`) beside std's; `std/schema`'s functions call them.
- **Format strings and schemas go in the ring the first time a process uses them**, until the bundle store can give
  them; a record still names a literal by its image offset and each argument by its schema hash.
- **`schema.render`** reads a value back by its schema as base's `output_format` writes it, for the events service.
