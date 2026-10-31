# 0119: The Plan for 9e, Shared Libraries and Substitution

Status: accepted
Date: 2026-10-31
Related: `0092` (M9's plan), `0045` (content-addressed libraries), `0094` (bundles), `0114` (generations),
`../hemera-proposals/typed-linking.md`, `../design/software.md` §7, `../design/system-abi.md` §7

## Context
Hemera builds typed libraries (`typed-linking.md`, built 2026-10-27): a package built on its own as an
`OutputType.DynamicLibrary`, position-independent, with an interface record of each export's name and type hash, the
calling convention and `Context`'s hash. A program's calls to it go through an import table that `runtime.bind_libraries`
fills before `main`, checking every import; Linux and Windows bind them, SlopOS doesn't yet. `0045` names a library by
its hash, shares its text between processes, and substitutes one hash for another only when the new interface passes the
check against the old, by a policy kept in the config store. A bundle already has a `libraries` field, always empty.

## Decision
Chosen with the project's owner:
- **The program's runtime binds**, as on Linux: whoever launches a program gives it each library it imports as a grant,
  `library:<name>`, read-only paged memory from the bundle store (or a boot module), after the substitution policy.
  Before `main`, `base`'s runtime maps the library's text from that memory, shared and read/execute, copies and relocates
  its data privately, checks its interface record, and fills the import table. The process manager stays as it is.
- **The first library is a real package**: `service_kit`, which nearly every service uses, the boot set's among them, so
  the library is in the boot set too, and its text is shared from the first boot.

Decided here:
- **Where a program's libraries come from**: the build writes each program's library list beside it (as it writes its
  manifest); the store builder puts each library in the store as an object and lists it in the program's bundle; the
  generation builder puts the boot set's libraries in the generation, as boot-set files.
- **The substitution policy** is the config store's value `substitutions` of owner `system`: entries "hash X is
  replaced by hash Y", each accepted only if Y's interface record passes the check against X's, read from the two
  objects, and applied by whoever launches, the supervisor and the storage manager, when it looks up a bundle's
  libraries. It applies at the next launch; programs running keep what they were bound to.
- **In three parts**, each with an as-built record, on both architectures:
  - **9e1, libraries on SlopOS**: the build making libraries for SlopOS, `base`'s runtime binding them on SlopOS from
    their grants (text shared from the memory given, data copied, relocations applied), and a test program bound to a
    small library, refused one with an export's type changed.
  - **9e2, `service_kit` as a library**: its functions exported, every service bound to it, the root task and the
    process manager's own loads given it from the boot set, the supervisor's launches from the store, and its text
    shared between every process, seen in the frames used.
  - **9e3, substitution**: the policy in the config store, checked against interface records, applied at launch,
    recorded and reversible; tested with a second build of `service_kit` with one export more.

## Alternatives considered
- **The process manager binding**: one trusted place, but it would learn bundles, interface records and import tables,
  and `base` would keep another path for the hosts.
- **A test library first**: a smaller start, with real code moved later; `service_kit` is small enough to be the test
  and the first saving at once.

## Consequences
- `../roadmap.md` lists 9e's three parts; 9e1 is next. With 9e, M9 is done.
- Moving more shared code into libraries (protocol code, `std`'s collections) follows as it's worth it.
