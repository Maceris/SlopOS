# 0044: Typed Entry Points as Program Interfaces and Manifests

Status: accepted
Date: 2026-10-13
Related: `0012` (root task and boot configuration), `0013` (linked code is trusted code), `0017`
(supervisor), `0018` (granting authority), `0028` (build package), `0035`, `0040` (protocols)

## Context
`../problems-and-directions.md` §4 leaned toward programs exporting typed functions instead of
parsing `argv`. Open were whether the entry signature is also the program's manifest of static
authority, how a service declares the protocols it offers, whether the system configuration is a
type-checked Hemera value, and how one program calls another's functions.

## Decision
- **A program's entry-point signature is its manifest.** Each parameter's type says what the program
  receives at launch:
  - plain values (`Regex`, `int`, enums) are parsed from the command line by the shell;
  - `ReadOnlyFile`, `File` and `FileSet` are opened with exactly those rights (`0018`);
  - `Channel[P]` is a connection to a service speaking `P`;
  - `Listener[P]` receives incoming connections for `P`.

  Anything more is asked for at runtime through the powerbox. The build reads the signature through
  reflection and stores the manifest in the program's bundle metadata, so the shell and launchers
  know it without loading the program. The startup block carries the actual values
  (`../design/system-abi.md` §6).
- **A service declares what it offers with the same signature:** its `Listener[P]` parameters are
  the protocols it serves, and its `Channel[P]` parameters are its dependencies. The supervisor
  creates both ends when it starts the service. There is no separate service manifest.

  ```
  storage :: fn(clients: Listener[Dir], disks: Channel[Block][], config: Channel[Config]) {/* ... */}
  ```

- **The system configuration is a Hemera value computed at compile time**, in a `system_config`
  package: the services, their parameters, and how they're wired. The build checks that every
  `Channel[P]` parameter is satisfied by a service's `Listener[P]` for the same protocol, reporting
  a mistake as a compile error, and compiles the result into the boot image as the typed boot
  configuration (`0012`). Runtime changes go through the config store later, with the same types.
- **Calling another program's functions works both ways, chosen by the caller:**
  - **In process:** link the other program's package like a library. It runs with all of the
    caller's authority (`0013`).
  - **Out of process:** the build generates a protocol from the other program's exported functions,
    one request variant per function, and the caller talks to it over a channel. This is the
    recommended choice for code from someone else.

## Alternatives considered
- **A separate manifest file** (Android's, Flatpak's): a second description that can disagree with
  the code.
- **Services registering their protocols at runtime:** the wiring couldn't be checked when building.
- **Only out-of-process calls:** every reuse of a function would cost a process and a context switch.

## Consequences
- `Listener[P]` joins `std`'s SlopOS layer next to `Channel[P]`.
- The shell builds parsing, help, completion and launch grants from manifests
  (`../problems-and-directions.md` §4).
- The build gains two steps: extracting manifests, and checking the system configuration's wiring.
