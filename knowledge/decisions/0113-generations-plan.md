# 0113: The Plan for 9d, Generations, Updates and Installations

Status: accepted
Date: 2026-10-30
Related: `0092` (M9's plan), `0097` (boot items placed in 9d), `0107` (9c's plan), `0110` (the system configuration at
run time), `0109` (the config store), `../design/software.md` §5, §6, `../design/lessons.md` §1, `../roadmap.md` M9

## Context
`0092` made 9d a generation's record and its boot set on the ESP, updates written beside the running generation and
chosen at boot, rollback, boot assessment by the supervisor, and installations with `AppData` and `Config[T]`. `0097`
added dependency kinds with degraded boots instead of hangs, the pinned recovery generation, and the ESP budgeted, with
boot-set files shared by hash. `0110` left overrides of what starts before the config store (the root task's services
and CPU shares) to generations. Limine boots SlopOS until the Hemera bootloader (B), and there's no network.

## Decision
Chosen with the project's owner:
- **Limine chooses a generation by its entries**: the update service rewrites `limine.conf` on the ESP with an entry
  per kept generation, newest first and the default, each loading that generation's boot set, and the recovery
  generation's last. Rollback is choosing an older entry at the menu, or the update service making an older generation
  the default. Skipping an unhealthy tentative generation automatically waits for B's boot counting.
- **An update is staged on the system volume**: a generation record and its objects, put in the bundle store. The
  update service installs it. A network source can feed the same path later. For tests, the image builder stages a
  second generation built from the same tree.
- **The ESP keeps the current generation, the previous one, and the recovery generation**. Boot-set files are named
  by their hashes and shared between them. A generation is written only if it fits beside those, and older ones are
  collected.
- **A dependency's kind comes from its type**: a `Channel[P]` is required, a `Channel[P]?` optional, and a `late` list
  in `system_config` marks what needn't be up for the system to report healthy. A required dependency has a deadline,
  a default from the configuration that a service can set, and the wiring check checks all of it.

Decided here, as the plan's own:
- **The update service** is a new service, given the ESP (through the storage manager), the bundle store and the
  supervisor's report of health. It writes generations; nothing else writes the ESP's `boot` directory.
- **Installations are the system's only** until there are sessions (M10): entries in the system configuration, each
  with its data directory given as `data: AppData` and its configuration as `Config[T]`.
- **Rebooting**: there's no reboot yet, so a boot test boots the same disk image again (`boot.py`), its second boot
  as the ESP's `limine.conf` says.
- **What 0110 left**: overrides of the root task's services and of CPU shares are applied when a generation is made,
  so they need generations made on the device, which this plan doesn't build (updates are staged). They stay open.
- **In five parts**, each with an as-built record, on both architectures:
  - **9d1, generations on the ESP**: a generation's record (its number, the kernel's hash, the boot set's hashes, the
    system records' hash, the bundle store's root, its command line, and whether it's tentative, permanent or the
    recovery generation), written by the build. The image builder lays the ESP out with boot-set files named by
    hash, one record per generation, and `limine.conf`'s entries. The root task is told which generation it booted.
  - **9d2, dependency kinds and boot assessment**: required, optional and late; deadlines; a degraded boot that starts
    what doesn't depend on what's missing and writes a degraded-boot record; and the supervisor's report of healthy,
    once every service the configuration lists, but the late ones, has started and answered.
  - **9d3, the update service**: installing a staged update (its objects checked by hash, the ESP's room checked
    first, its boot-set files written, its record, then `limine.conf`), a tentative generation made permanent once
    the supervisor reports it healthy, rollback, and collecting what the kept generations don't use. Tested by
    booting the same disk twice.
  - **9d4, installations**: the system's installations in its configuration, `AppData` as an entry parameter's kind
    beside `Config[T]`, an installation updated to another bundle and its data kept, and uninstalled with its data
    and configuration.
  - **9d5, the recovery generation**: written once, pinned and never collected, booting the boot set, the console and
    what B and M10 add to it; its `limine.conf` entry last.

## Alternatives considered
- **One `limine.conf` entry and a file naming the current generation**: the root task would read the ESP itself
  before storage is up, which Limine's modules exist to avoid.
- **Generations made on the device**: they'd carry configuration changes without new code, as `0110`'s overrides
  need, but no new programs; staged updates come first, as an update with new code is the case that has to work.
- **As many generations as fit**: more to roll back to, at the cost of the ESP's budget deciding how many.
- **Every dependency's kind written in `system_config`**: it repeats what the optional types already say.

## Consequences
- `../roadmap.md` lists 9d's five parts; 9d1 is next.
- B's boot counting reads the generations 9d writes, and its recovery key boots 9d5's entry.
