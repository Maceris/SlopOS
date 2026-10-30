# 0109: 9c2, the Config Store and `Config[T]`, as Built

Status: accepted
Date: 2026-10-30
Related: `0107` (9c's plan), `0108` (typed files), `0044` (manifests and the system configuration), `0046` (typed
files), `0071` (validators), `0094` (the bundle store, the pattern followed), `../design/software.md` §4

## Context
`0107` made each value a directory of typed files on the system volume, kept the newest 16 versions, and had a program
reach only its own values, through a `Config[T]` in its entry, with the supervisor holding the connection that hands
them out. 9c1 (`0108`) gave files their types.

## Decision
- **The protocol** (`src/protocols/config`): a connection speaks `ConfigValue`, and reaches one owner's value. A
  program's entry takes it as `config.Config[T]`, one end, whose manifest kind is `Config` (Hemera's base: an entry
  parameter of kind `Config` is a channel that must speak `ConfigValue`, whatever `T` is). Requests: `Declare` (T's
  schema hash and `T.{}`'s bytes, the program's compile-time default), `Read`, `Write` (an override, and a bit for each
  of T's top-level fields it sets), `Next(version)`, answered once the value is past that version, `History(back)` and
  `Rollback(version)`; on the supervisor's connection only, `ValueFor(owner, name)` and `UseDirectory`. A value is at
  most 1792 bytes, so a default and an override fit one message.
- **Merging is the program's**: what's answered is the default, the override and its fields; `config.read[T]` checks
  both are `T`s (`std`'s `holds_value`, `0108`) and merges them field by field into one value, copying what each
  field's `Relative`s hold after it. The store knows a value's schema hash, not its type, so it checks sizes, and the
  program checks types: `config.write[T]` refuses bytes that aren't a `T` before it sends them.
- **The config service** (`src/services/config_service`, not in the boot set) keeps `<owner>/<name>/` in the system
  volume's `config` directory: a typed file per version, named by its number, holding the schema hash, the default,
  the override and its fields, its author (the owner's name, the connection's label) and the wall-clock time; and
  `newest`, a typed file naming the newest. A version is written before `newest` names it, and the one 16 before it is
  deleted after, so a store stopped between them has the version before, whole.
- **Declaring again**: the same type and default changes nothing; the same type with a new default makes a version
  with it, the override kept; another type, as a program's new version may declare, makes a version without the
  override, which the new type couldn't read. Versions of another type are kept for `History`, and `Rollback` to one
  is refused as `WrongType`.
- **The supervisor** starts the config service once it has the system volume, as it does the bundle store, keeps the
  other end of its listener, gives it the `config` directory again when the volume's server is started again, and asks
  for a program's connection by owner and name as it launches it: hello is given `settings: Config[HelloSettings]?`.
  `system_config`'s wiring check counts a `Config[T]` as served by whatever takes a `Listener[ConfigValue]`.
- **Test**: on every boot from the image builder's disk, hello declares its settings, writes an override of two of its
  three fields, reads them back merged over the default through `Next`, sees its own name as the author, and rolls the
  override back.

## Alternatives considered
- **Merging in the store**: it would need each value's type information, which a schema hash doesn't give it; a
  program has its own type at hand.
- **A connection per program from a listener**: the store would have to tell which program a connection is; the
  supervisor already knows what it's launching.

## Consequences
- Left from `0107`'s 9c2: writes as transactions over several values, which need typed files in `Dir` transactions
  (`0108`), and the user's override beside the system's (`../design/software.md` §4), which waits for accounts (M10).
  Writing another owner's value through the supervisor's connection comes with 9c3.
- 9c3 next: the system configuration at run time.
