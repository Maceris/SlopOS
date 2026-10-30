# 0110: 9c3, the System Configuration at Run Time, as Built

Status: accepted
Date: 2026-10-30
Related: `0107` (9c's plan), `0109` (the config store), `0044` (the system configuration and its wiring check), `0093`
(the scheduler service), `../design/software.md` §4, §5

## Context
`0107` put the system configuration in the boot set and the store: the build serializes `system_config` with its
schema into the boot set, the root task checks it at boot with the build's code and gives it to the supervisor and the
scheduler service, which stop linking it, and changes made at run time are overrides in the config store, applying at
the next boot until 9d makes them generations. Left open, and chosen with the project's owner: what an override may
change, and how one reaches a boot before generations.

## Decision
- **An override changes per-service tunables only** (with the owner): a service's memory budget, CPU share, restart
  policy and DMA trust. Which services there are, and their wiring, stay the build's: the supervisor's code starts each
  one its own way.
- **The supervisor applies overrides** (with the owner): the root task starts from the boot set's configuration; once
  the config store is up, the supervisor reads the override and applies it to everything it starts after that,
  restarts included. What started before the store, the root task's services and the supervisor's first, gets
  overrides with 9d's generations. A bad override can't keep the system from booting.
- **The data** (`src/system_records`, plain Hemera that builds anywhere): `SystemRecords`, fixed-size plain data,
  flags and enums as bytes, so every copy is checked before it's trusted. Each service's entry becomes a manifest of
  its parameters: each one's name, kind (a channel, a listener, a `Config[T]`, or something else), its protocol's tag,
  and whether it's optional. `check` is the one check, made by the build and at boot: counts within bounds, names and
  modules well formed and distinct, budgets within 1 GiB, CPU shares within their periods, drivers started by the
  supervisor, and the wiring check, every channel and every `Config[T]` served. `apply` applies a `SystemOverrides`
  (at most 16 services' `Tunables`) and checks the result the same way.
- **The build**: `system_config.RECORDS` is worked out at compile time and checked with `system_records.check`, which
  replaces `check_wiring`. The build package writes it beside the root task as `system.records`, which `boot.py` makes
  a module of the boot set. The root task imports `system_config` only so the build has it to write.
- **At boot**: the root task reads `system.records`, checks it, and ends with 30 before starting anything if it isn't
  one. It starts its services from it, and gives a read-only copy to the scheduler service, which takes its shares and
  the default share from it, and to the supervisor. Both check it again with `service_kit.read_records`, and neither
  links `system_config`.
- **The override** is the config store's value `services` of owner `system`. The supervisor declares it, reads it
  once the store has started, and keeps the boot set's records apart, so an override applies to them afresh. It writes
  one only if `apply` takes it.
- **Found on the way**:
  - The wiring check never checked optional channels: it unwrapped an optional by its first variant, which is `None`.
    Now it looks for `Some`, so the 87 optional parameters are checked too.
  - Hemera's compiler gave up when compile-time code that was still gathering what it reaches came to a constant whose
    own `#run` reached a function not checked yet. It now waits for that function as it would for its own calls
    (`generate.cpp`, `executed_constant`).
- **Limits raised**:
  - The supervisor's 25 grants passed a `Load`'s 24, so `std`'s process manager protocol and the process builder take
    32 now, and a connection to the manager has rings of 4 KiB, which a `Load` of 32 needs.
  - A connection to a config value has rings of 8 KiB (`config.RING_BYTES`), so the largest message, a default and an
    override, fits. With the default rings, the system's override, about 1.3 KiB, couldn't be sent.
- **Tests**: a hosted test of `check` and `apply`; every disk boot reads an empty override; `test_system_config`
  writes an override of hello's budget, has one of a budget of 0 refused, reads it again as a boot would, and sees
  hello started again on 3 MiB.

## Alternatives considered
- **Writing the merged configuration onto the ESP for the next boot**: covers every service, but a bad override that
  passes the check could stop the system booting, with no rollback before 9d.
- **Overrides that add or turn off services**: the supervisor would have to start services generically from their
  manifests.
- **Relatives in the records**: the record format would need `std`'s message layout, which only builds for SlopOS; the
  build's side runs as compile-time code on the host.

## Consequences
- A CPU share override is kept and checked, but the scheduler service splits its budgets before the store is up, so it
  applies with 9d, as do overrides of the root task's services.
- The boot set has one more module, and the root task one more grant.
- 9c4 next: memory pressure.
