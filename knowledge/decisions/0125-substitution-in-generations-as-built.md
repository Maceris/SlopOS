# 0125: 9f2, the Substitution Policy in Generations, as Built

Status: accepted
Date: 2026-10-31
Related: `0123` (9f's plan), `0122` (substitution, live), `0113`, `0116` (generations and the update service),
`../design/lessons.md` §2.1

## Context
`0123` makes data that TCB services load part of a generation, the substitution policy first: applied from boot, a
change staged as a generation and kept only if it boots healthy. `0122` had the supervisor read the policy from the
config store and apply it to what it launched next.

## Decision
- **The policy is a boot-set file**, `substitutions.records`: the schema hash of `bundle.Substitutions`, then its bytes
  (`src/substitution`). A generation without one has no substitutions.
- **The root task applies it**, at boot, before it starts anything: each entry whose `from` is the hash of one of its
  libraries and whose `to` is another of them that passes `library_interface.check` is a substitute, given in place
  of the library to everything the root task launches or loads itself (the entropy service and the process manager
  too), which passes it on (`os.launch`). So every process but the root task runs with it, the supervisor included.
  The substitute is in the generation's boot set, so nothing else need be up.
- **A change is asked for in the config store** (`system/substitutions`, as in `0122`): after a healthy boot, the
  supervisor passes it to the update service (`Substitute`, with the generation booted). Unless the newest generation
  has that policy already, the update service checks each entry, `from` a library of the booted generation's boot set
  and `to` one there or in the bundle store; one that fails refuses the whole policy, logged with why. Otherwise it
  writes the booted generation again, numbered after the newest, with the policy as its `substitutions.records` and
  each substitute in its boot set as `<the first 16 hex digits of its hash>.library`, tentative and first in
  `limine.conf`. The next boot runs it, and boot assessment keeps it or rolls it back, as any generation.
- **Nothing applies a policy live**: `0122`'s reading by the supervisor, and its substitutes in `LaunchOptions`, are
  gone. `src/substitution` holds what the root task, the supervisor and the update service share: the policy's file,
  mapping and hashing libraries, and the check.
- **The update protocol's rings are 4 KiB** (`update.RING_BYTES`): a `Substitute`, a policy of 8 entries, didn't fit
  the default rings, so the request never arrived.
- **Tests**: on a boot disk, booted twice: the first boot's supervisor asks for `greeting` in `service_kit`'s place,
  refused by the update service, then `service_kit_plus`, staged as generation 2; the second boot runs generation 2,
  the root task substitutes it, the supervisor's own `service_kit` is `service_kit_plus`, and generation 2 is made
  permanent once healthy.

## Alternatives considered
- **The supervisor resolving substitutions at boot**: it starts too late for itself and what the root task starts.
- **Staging only the valid entries of a policy**: a policy that's partly applied is harder to reason about than one
  refused with why.

## Consequences
- A substitution takes a reboot, as the kernel's and the boot set's changes do; 9f3 applies service-only generations
  live, which a policy change isn't.
- Rolling back to a generation without a substitution undoes it, as `lessons.md` §2.2 wants warned of when rollback
  is the user's (M11).
