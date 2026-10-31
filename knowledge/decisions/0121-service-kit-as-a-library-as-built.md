# 0121: 9e2, `service_kit` as a Library, as Built

Status: accepted
Date: 2026-10-31
Related: `0119` (9e's plan), `0120` (libraries on SlopOS), `0045` (content-addressed libraries)

## Context
`0119` makes `service_kit` the first real library: every service bound to it, the root task's and the process
manager's own loads given it from the boot set, the supervisor's launches too, its text shared between every process.
`0120` gave launched test programs the boot set's libraries from the root task, one launch site.

## Decision
- **How a launched program gets its libraries** (with the owner): `std`'s `os.launch` gives it every `library:<file>`
  grant the launcher holds itself, with the rights to read, run and pass it on, except those `LaunchOptions.libraries`
  names, which it gives instead. So every launch site, about twenty in the root task, the supervisor and the storage
  manager, passes `service_kit` on unchanged, and the supervisor's substitutions (9e3) are the explicit ones.
- **The root task**: the kernel labels a boot module whose name ends in `.library` `library:<name>`, not
  `module:<name>`, so the root task's runtime binds it before its `main` as any program's does. What the root task
  loads itself with the process builder, the entropy service and the process manager, gets its libraries too.
- **`service_kit`** moved to `src/libraries/service_kit`, built as `service_kit.library`, and every SlopOS program links
  it; one that doesn't call it has no import of it, and binds nothing. Seven functions are `#export`ed: the clients'
  three, `text_of_label`, `word_after`, `number_of` and `has_word`. `text_of` and `read_records` aren't: each program
  compiles them in, since they reserve addresses, and a library's copy of `base` has a process state of its own, empty
  (`../hemera-feedback.md`).
- **`boot.py`** puts every `.library` in the boot set: in a boot disk's generation, and so in the store by its hash.

## Alternatives considered
- **Every launch site passing libraries itself**: nothing given implicitly, at the cost of twenty edits and a rule
  each new launch site has to remember.
- **Inheriting only, no override**: substitution would then have to happen where the supervisor's own grants come
  from, the root task, before any policy can be read.
- **Exporting `text_of` and `read_records`**: they'd fail in the library until `base` shares the program's process
  state with its libraries.

## Consequences
- Every program is given every library in the boot set, the test ones too (`greeting`, `greeting_changed`,
  `service_kit_plus`): 4 grants of the 32 a `Load` takes. The supervisor, with 26 of its own, has 30.
- The frames `service_kit`'s text takes are shared by construction (mapped from the one module's memory); no test
  counts them.
- 9e3 next: substitution by the config store's policy.
