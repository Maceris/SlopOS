# Separately Compiled Libraries with Typed Imports

Status: **proposed** 2026-10-27, for M9's 9e (`../decisions/0092`, `0045`, `../design/software.md` §7,
`../design/system-abi.md` §7). The largest piece of Hemera work in M9.

## Why SlopOS Needs It

SlopOS shares libraries by content hash (`0045`): a program names the exact hashes it was built with, the loader maps
each library's text once for every process using it, and a security fix substitutes one hash for another only once
the toolchain has checked the new interface against the old. Linking by name alone, as ELF and PE do, lets a changed
signature crash at run time; SlopOS wants a mismatch to be a load error naming the import.

## Where Hemera Is

Every program is compiled whole, from source, with everything it imports. `OutputType.DynamicLibrary` exists in
`base/compiler`, and `#export` marks a function as part of a library's or program's public interface (`docs/
directives.md`), but there's no way to build a program against a library compiled apart from it, and nothing records
what an export's type is.

## Proposal

1. **A library is a package built on its own** (`OutputType.DynamicLibrary`, position-independent, for a pinned
   calling-convention version): its `#export`ed functions are its interface, compiled once. Its text has no
   relocations (calls within it are relative; what it reaches outside goes through its own table), so it can be one
   read-only memory object mapped at a different address in every process.
2. **An interface record**, in a section of its own: each export's name and the schema hash of its function type
   (`typed-log-records.md`'s `compiler.schema_hash`, which covers parameter and result types and the calling
   convention), and the schemas of the types they use, so the bundle store can check compatibility without the
   source. The library's hash covers its code and the record.
3. **Building against a library**: the build package names it (by its built file now, by its hash in the bundle store
   later), and the program imports the library's package as it imports any other, for its types, constants, generics
   and compile-time code; calls to its `#export`ed, non-generic functions become imports instead of being compiled in.
   Generic functions, `#insert`ed code and anything else instantiated by the caller stay in the caller, as they do now.
   An import names the library's hash, the export's name and its type's schema hash.
4. **Binding is the loader's**: SlopOS's ELF loader resolves each import through the substitution policy, checks the
   name and the type hash against the library's interface record, and writes the address into the program's import
   table, which is read-only once bound. No lazy binding, no PLT stubs written at run time. A mismatch fails the load
   with the import named.
5. **A compatibility check**, `hemera --check-interface old new`: every export of `old` is in `new` with the same type
   hash, and every type changed only as `0040`'s append-only rules allow; substitution accepts only what passes. It's
   the same check the ABI package's and protocols' release checks need (`0025`, `0040`).
6. **Libraries' own data**: each process gets its own copy of a library's globals, mapped beside its text; a library's
   `#run` code runs when the library is built.

## Open Questions

- **Inlining across the boundary**: a call into a library is never inlined, so a fix in the library reaches every
  caller; small exported functions cost a call. Proposed: never inlined.
- **What `#export` means for a program**: a program's exports today are for linkers and C. Proposed: unchanged; only a
  `DynamicLibrary`'s exports form an interface record.
- **The context**: every Hemera call passes the context (`system-abi.md` §7), so its layout is part of the library
  ABI; whether the pinned version is a number the compiler declares, or the hash of `Context`'s schema.
- **Hosted libraries**: whether Linux and Windows get the same typed libraries (as `.so`/`.dll` with the record
  beside them), so libraries can be tested hosted, or only SlopOS's loader binds them.
