# 0122: 9e3, Substitution, as Built

Status: accepted
Date: 2026-10-31
Related: `0119` (9e's plan), `0121` (`service_kit` as a library), `0045` (content-addressed libraries), `0110` (the
system configuration's override), `0109` (the config store)

## Context
`0119` keeps the substitution policy in the config store, as the value `substitutions` of owner `system`: entries
"hash X is replaced by hash Y", each accepted only if Y's interface record passes the check against X's, applied by
whoever launches, at the next launch; programs running keep what they were bound to.

## Decision
- **The policy** is `bundle.Substitutions`: a count and at most 8 `Substitution`s, each `from` and `to`, hashes.
  Writing it isn't checked; reading it is.
- **The supervisor applies it**: it reads the policy once the config store has started, as it reads the system
  configuration's override, and again whenever it's asked to. An entry is taken when `from` is the hash of one of the
  supervisor's own libraries, the bundle store has `to`, and `to` passes `library_interface.check` against it. What the
  supervisor launches from then on is given the substitute in its library's place (`LaunchOptions.libraries`, which
  overrides what `os.launch` passes on), and what that launches inherits it. Each taken entry is logged with the
  substitute's hash, each refused one with why, and the count. Emptying the policy takes it back at the next launch.
- **`library_interface`** (`src/library_interface`, plain Hemera on bytes) reads a library's interface record from its
  file as Hemera's `--check-interface` does, by its program headers and dynamic relocations: every export of the old
  must be in the new with the same type hash, for the same calling convention and `Context`. A library's length comes
  from its ELF headers, as a boot module's memory is a page's multiple.
- **Libraries in the store**: a generation's objects are on the ESP, so the generation builder also puts each boot-set
  `.library` in the store's objects, by its hash, where a substitution's `to` is found, and pins it there,
  `library_<name>`, so `Collect` keeps it.
- **`service_kit_plus.library`**: `service_kit` built again with the build's setting `service_kit_build=plus`, one
  export more (`build_name`), which stands in for it; the reverse doesn't.
- **Tests**: a hosted test of `library_interface` on libraries made in bytes. With `test_substitution`, on a boot disk,
  the supervisor writes a policy putting `greeting` in `service_kit`'s place, refused (an export isn't there any more),
  then `service_kit_plus`, taken, and hello started again with it; then empties the policy, and hello is started again
  with `service_kit`.

## Alternatives considered
- **Checking at write**: the config store doesn't know libraries, and a policy written on another system, or before a
  library changed, has to be checked where it's applied anyway.
- **Substitutes from bundles' library lists**: the store builder would list each program's libraries in its bundle;
  with inheritance (`0121`), the supervisor's own libraries are the ones to replace, so the policy names them by hash
  and the store gives the substitute.

## Consequences
- What the root task starts before the config store, and the supervisor itself, keep the boot set's libraries until
  the next boot; a substitution of those waits for generations to carry it (with B).
- With 9e, M9 is done.
