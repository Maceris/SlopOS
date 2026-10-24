# 0068: Typed Entry Points and std's SlopOS Port as Built

Status: accepted
Date: 2026-10-24
Related: `0044` (typed entry points and the system configuration), `0040` (protocols), `0058` (the plan
for M6), `0067` (the process manager), `../design/system-abi.md` §6, `../../docs/specs/programs.md`,
`../roadmap.md` M6

## Context
M6's fourth stage (6d). `0044` made a program's entry signature its manifest and the system configuration a
compile-time value whose wiring the build checks; `0058` put typed entry points, the wiring check, `std/os`
(exit, time, random, launching) and the startup code's ABI check in 6d, with the kernel's user-mode tests
moving into programs. Until now `main` took nothing, a program found its grants by label, the services'
grants were strings in `system_config`, and only the entropy service had a seed.

## Decision
Chosen with the project's owner:
- **The compiler fills `main`'s parameters** on `os = .SlopOS`: the generated entry asks base's runtime
  for each one by its name and its type's name, which finds the grant of that name and checks its kind.
- **Typed ends, hand-written messages**: `std/os` has `Channel[P]` and `Listener[P]`, `P` a type named after
  the protocol, and a 64-bit tag from `P`'s name. Messages stay fixed-layout structs; generated encodings and
  validators come with variable-size messages.
- **The wiring is checked in `system_config` itself**: it names each service's entry function, so the check
  runs when it's compiled, and grants come from parameter names rather than strings.
- **A seed in every startup block**: each program's loader draws one, and base's runtime seeds
  `context.random` from it in the process.
- **Launching is typed by the program's entry**: `os.launch(..., hello.main, grants)`, where `grants`'
  fields must be the entry's parameters, by name and type, checked at compile time.
- **An optional parameter** (`T?`) is `None` without its grant; a missing required one ends the process
  before `main`.
- **The tests' move is its own stage, 6e**, so this one stays reviewable.

As built:
- **Hemera's compiler**: on SlopOS, an entry parameter must be a handle, a 4-byte distinct alias or struct,
  or an optional of one (E4014 otherwise); on other systems a hosted entry with parameters is the existing
  "no entry point" error. The entry calls `runtime.os_entry_grant(name, kind, required)` for each, and builds
  the parameter, an optional's tag included. Documented generically in Hemera's `docs/compilation.md`, *Entry
  Parameters*.
- **base's runtime for SlopOS**: `os_entry_grant` reads the startup block's grants, with a table of kinds by
  type name (`Channel` and `Listener` are both channel ends); the ABI check, ending the process with 125 if
  the block isn't version 1 or is too small; 126 for a missing grant; and `SYSTEM_RANDOM`, ChaCha20 from the
  block's seed with fast key erasure, under a lock, which traps without a seed as `NO_RANDOM` does.
  `std/os/slop_os` checks base's copies of the layouts, the kinds and the version against its own.
- **The ABI** (version 1): a grant is 48 bytes, with the protocol tag of a channel end (`Grant.tag`), and the
  seed is every process's. `slop_os.EXIT_WRONG_ABI` and `EXIT_MISSING_GRANT` name the codes.
- **std/os**: `Channel[P]`, `Listener[P]`, `protocol_tag[P]()` (FNV-1a of `P`'s name), `speaks(channel)`,
  which compares a startup grant's tag; `send`, `receive`, `try_receive`, `call`, `port_for` and `accept`,
  moved from SlopOS's `src/protocols`; and `launch[F, G]`, constrained by `EntryGrants(F, G)`, which splits a
  budget off the caller's, makes the process and its space, and sends the manager a `LoadRequest` with each of
  `grants`' handles labeled by its field and tagged by its type, skipping an optional's `None`. The process
  manager's protocol moved into std (`std/os/slop_os/process_manager`), since `launch` speaks it; its
  `LoadRequest` gained the grants' tags and needs 2 KiB rings (`RING_BYTES`).
- **The services' entries**: the root task takes `platform`, `debug_log` and `command_line`; the entropy
  service `log` and `clients`, a `Listener[Entropy]`; the manager `log`, `entropy` and `clients`, a
  `Listener[ProcessManager]`; the supervisor `log`, `manager`, `root` and `hello_module`; `hello` an optional
  `log` and `manager`. The root task holds the other end of each listener and connects services through it
  (`protocols.connect`, a `CONNECT` with the new end), its own connection to the manager being the listener
  itself. It loads the entropy service and the manager with grants labeled after their parameters, and
  launches the supervisor with `os.launch`; the supervisor launches `hello` the same way.
- **`system_config`** names each service's entry (`entry = type_of(hello.main)`), and `check_wiring` runs at
  compile time: every `Channel[P]` a service takes, optional or not, needs a service taking a `Listener[P]`, or
  the root task, which serves `ROOT_TASK_SERVES` (the supervisor's reports). A miss fails the build saying
  which service's which parameter.
- **Found in Hemera on the way, fixed (`0047`)**: a compile-time `cast` of an enum member to an integer
  (`#assert cast[u32](ObjectKind.Memory) == 3`) wasn't a constant; now it is, for the package's own enums and
  another package's.

## Alternatives considered
- **A `std` wrapper over a parameterless `main`**: no compiler change, but boilerplate in every program, and
  the manifest would be another function's signature.
- **All of `0040` now**: generated encodings and validators, before anything sends a variable-size message.
- **A build check over all programs' manifests**: closer to `0044`'s wording, but sharing state across checks is
  untested in Hemera, and `system_config` can name the entries directly.
- **Random bytes over a channel**: fresh entropy, but a grant and a round trip for every program.
- **An untyped grant list for launching**: simpler, with nothing checking a launcher's grants.

## Consequences
- A program's manifest is its `main`; a launcher states its grants as a struct the compiler checks against it,
  and `system_config` checks the whole system's wiring.
- Protocol tags are by name until protocols have versions; a renamed protocol type is a different protocol.
- Tags are checked when a program asks (`os.speaks`), not on every message.
- Programs with a missing required grant end with 126, which their starter sees; no test exercises it yet,
  nor the ABI check's 125, until 6e's test programs.
- 6e: the kernel's user-mode tests become programs that the root task runs in test mode.
