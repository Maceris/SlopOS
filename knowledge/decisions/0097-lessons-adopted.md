# 0097: What's Adopted From the Lessons of Other Systems

Status: accepted
Date: 2026-10-30
Related: `0013` (threat model), `0042` (unlocking), `0046` (storage model), `0050` (ticks), `0092` (M9's plan), `0096`
(R), `../design/lessons.md`, `../roadmap.md`

## Context
`../design/lessons.md` (2026-10-29) went through the roadmap from B onward for what other systems get wrong that the
plans didn't answer yet. `0096` planned its R track. The rest was open: two more tracks, boot items for B and 9d, the
trusted path in M10, native names, a revisit of the threat model, and some twenty smaller items across M9 to M16.

## Decision
Chosen with the project's owner:
- **Perf, a track of numbers kept**, as `lessons.md` §9.1 proposes: benchmarks as boot tests with recorded baselines
  (IPC round trip, page fault, thread and process creation, a program's start, file create and `Sync`, boot to
  healthy), failing on a regression beyond a margin, landing in **9c** so later milestones have baselines. Tickless
  idle (which `0050` left for later), large pages for the direct map and large memory objects, and storage bandwidth
  scheduled by the lent budget come as stages between milestones, planned when each starts.
- **Memory pressure** (`lessons.md` §9.2): a pressure signal on memory budgets, raised at a threshold the holder sets
  and bound to a port, and clean pages of pager-backed memory objects given back to their pager under pressure, in
  **9c**; the session manager asking idle installations to save and stop before anything fails, in **10c**. **No
  swap**; compressed memory is the first thing tried if one is ever needed.
- **Native names refuse invisible characters** (adds to `0046`, whose byte-for-byte comparison stands): slopfs refuses
  names containing C0 or C1 controls, bidirectional controls (U+202A–U+202E, U+2066–U+2069) or the invisible
  formatting characters Unicode's UTS #39 lists, with `InvalidName`. No normalization is required; the shell bridges
  NFC and NFD differences when completing and matching paths (`lessons.md` §4). In **9c**, with typed files in `Dir`.
- **Boot** (`lessons.md` §1), all four groups:
  - **Dependency kinds** in `system_config` (required with a deadline, optional, late), checked by the wiring check;
    a missing required dependency boots **degraded** with a report instead of hanging, and counts against boot
    assessment only for services the generation marks essential. In **9d**.
  - **A recovery generation**, pinned and never collected, booting the boot set, the console, the account service and
    a shell, reached by a key at the bootloader and automatically when every normal generation's counter has run out;
    and the **ESP budgeted**: a generation is written only if it fits beside the current and the recovery generations,
    with boot-set files named by hash and shared. In **9d** and **B**.
  - **The command line locked**: it's a field of the generation, editable at the bootloader only for a generation
    built for development, and release kernels are built without the `test_*` options. In **B**.
  - **Panic records** kept across the reset (a reserved region, copied to the ESP by the bootloader) and shown on the
    next boot; **a seed file** on the ESP, mixed into the boot seed and rewritten before the kernel runs, and the VM
    Generation ID watched by the entropy service. In **B**, the showing in **10a**.
- **The trusted path always answers** (`lessons.md` §3.1): the input and terminal services, the session manager, the
  powerbox and the account service (and the compositor in M15) run on a reserved budget at the highest user priority,
  never lent away, with memory the session's programs can't exhaust; the secure attention key's menu lists the
  session's programs with their use and can end them. **The lifecycle channel moves from 11a to 10a** and gains
  `Ping`, answered by `std` on its own fiber; a program that misses it is shown as not responding.
- **The threat model** (`0013`), on which the owner had no preference, takes the cheapest step only: in **H**, the
  kernel logs at boot which transient-execution issues apply to its CPU and which cheap mitigations are on, from
  `IA32_ARCH_CAPABILITIES` and AArch64's ID registers, so the trade `0013` made is visible. `0013`'s scope is
  unchanged. Two items stay open, decided when their milestone is planned: sealing the system volume's key to a
  measured boot set, as an option off by default, with **B**; and forgetting a volume's key on suspend (`0042`), once
  suspend exists after **P**.
- **Everything else in `lessons.md`** (signed updates through TUF's metadata, live updates of services, `Secret[T]`,
  settings from schemas, recovery keys, accepting new keyboards, locale as a context value, recoverable removal,
  progress, watchdogs, the network's and the GUI's items) goes into its milestone's design note as **proposed**, and is
  decided when that milestone is planned, as M8's and M9's were.

## Alternatives considered
- **Benchmarks only**, leaving tickless idle, large pages and bandwidth scheduling until a benchmark shows a need:
  cheaper now, but storage bandwidth is the one users feel first, and it's cheaper to design into the services early.
- **Compressed memory as a planned stage**: nothing needs it yet, and budgets with no overcommit already avoid the
  thrashing it answers elsewhere.
- **Requiring NFC names**: no two names that look the same, but copying a file from a FAT stick or a Mac could fail on
  its name.
- **Leaving `0046` as is**: right-to-left overrides would still disguise names everywhere but the terminal.
- **The lifecycle channel staying in 11a**: the terminal service would have nothing to tell a hung program from a busy
  one until the shell exists.
- **Deciding every smaller item now**: they depend on designs (the config store, the compositor) not yet settled.

## Consequences
- `../roadmap.md` places Perf, memory pressure and the items above in 9c, 9d, B, 10a, 10c and H.
- `../design/storage.md`'s name rule gains the refused characters; the other design notes gain their proposed items.
- `../open-questions.md` *Lessons* keeps only the sealed boot option and keys on suspend.
- `../design/lessons.md` stands as the record of the pass; its items are decided here or in their milestones.
