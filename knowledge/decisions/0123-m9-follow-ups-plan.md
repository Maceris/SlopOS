# 0123: The Plan for M9's Follow-ups, 9f

Status: accepted
Date: 2026-10-31
Related: `0092` (M9's plan), `0094` (the bundle store), `0113` (generations), `0116` (the update service), `0119` to
`0122` (9e), `../design/lessons.md` §2, `../design/software.md` (*Also Proposed*)

## Context
With 9e, M9's five stages are built. What's left before M10 (with B and Perf's stages, planned on their own):
- `0094` left the process manager loading by bundle hash, with the substitution policy, for 9e. 9e had launchers
  resolve both instead: the supervisor reads bundles and the policy and gives the process manager memory (`0121`,
  `0122`).
- `0094` shared a program's code from the store's memory but copied a boot module's, which couldn't be mapped to run.
  `0120` let it be.
- A library's copy of `base` had a process state of its own, empty, so `service_kit` couldn't export the two functions
  that reserve addresses (`0121`, `../hemera-feedback.md`).
- `lessons.md` §2's proposals were to be decided when 9c to 9e were planned, and weren't: data that TCB services load
  in the generation (§2.1), updates without lost work (§2.3), settings from schemas (§2.4), `Secret[T]` (§2.5), and The
  Update Framework's metadata (§2.2).

## Decision
Chosen with the project's owner:
- **Data TCB services load is part of a generation** (§2.1), the substitution policy first: it's a boot-set file of the
  generation, by hash, which the root task and the supervisor apply from boot. The config store's
  `system/substitutions` becomes how a change is asked for: written, it's checked, and the update service stages the
  booted generation again with the new policy, booted next and kept only if it's healthy, so a bad policy is rolled
  back by boot assessment. Nothing applies a policy live any more. The trust store, keymaps and time zones follow when
  they exist.
- **A generation that changes only services applies live** (§2.3): when the update service installs one whose kernel,
  boot set and command line are the booted one's, the supervisor restarts each service whose bundle changed from its
  new bundle, and the generation is assessed and made permanent as if booted. One that changes the kernel or the boot
  set waits for the next boot; nothing reboots without the user.
- **`Secret[T]` isn't added** (§2.5): Hemera already has `#secret` types (its `docs/memory.md`, *Secrets*), so formatting
  as `<secret>`, refusal in typed log records and wiping become more of what `#secret` means, designed in 10b against
  the account service's passphrases and keys.

Decided here:
- **The process manager doesn't load by bundle hash**: the launcher resolves bundles and substitutions, as 9e built it;
  `0094`'s item is closed.
- **Boot modules' code is shared**: the root task gives a program's module the right to run it, so whoever loads it
  maps its code from the module's memory, as from the store's.
- **A library shares the program's process state**: its interface record says where its `base` looks for it, and
  `runtime.bind_libraries` points it at the program's (Hemera's side). `service_kit` exports `text_of` and
  `read_records` too.
- **Left where they belong**: The Update Framework's metadata and the staged-rollout field with bundles from elsewhere
  (M13); settings rendered from schemas with the shell's tools (M11), the config store's overrides already answering
  "what did I change" field by field.
- **In three parts**, each with an as-built record, on both architectures: **9f1** code shared (boot modules, a
  library's process state); **9f2** the substitution policy in generations; **9f3** live updates of services.

## Alternatives considered
- **Keeping the policy live in the config store** (`0122` as built): simpler, and a change applies at the next launch,
  but a bad policy, like any data a TCB service loads, then has nothing to roll it back.
- **Live updates deferred to M11**, when a shell can ask the user: the supervisor's restarts are already there, and
  nothing about restarting a service needs asking.

## Consequences
- `../roadmap.md` gains 9f; B and Perf's stages are planned as they start, before M10.
- `0122`'s live reading of the policy is replaced by 9f2.
