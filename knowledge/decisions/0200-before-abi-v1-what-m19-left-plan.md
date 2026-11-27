# 0200: Before ABI v1, What M19 Left, Planned

Status: accepted
Date: 2026-11-27
Related: `0199` (M19, RISC-V), `0197` (Before M19, the pattern), `0025` and `0027` (the ABI), `../hemera-feedback.md`,
`../roadmap.md`
Before ABI v1

## Context
M19 is built, and nothing was planned after it. The owner chose, on 2026-11-27, a short catch-up of what M19 left
that every later run would trip over, and then ABI v1 (`0025`, `0027`), which the roadmap kept for once the system ran
on two architectures; it runs on three. Two things qualify:

- **The linker on the PATH.** A RISC-V program has its control-flow property note only if the `ld.lld` that links it
  knows RISC-V's; Visual Studio's, lld 19, drops it, and the program then runs without landing pads or shadow stacks.
  M19 put Hemera's own LLVM's `bin` first on the PATH by hand, which a new shell forgets (`0199`, *As Built: R6*).
- **Flaky boot tests.** M19's last full runs had four tests fail among the others and pass alone. The microphone's was
  two races in the test, fixed in R7; three are left: x86-64's sound (a gap, and the 1500 Hz tone measured low),
  AArch64's release generation whose command line the bootloader won't edit, and RISC-V's file search, which ran past
  its time.

## Decision: C1, the linker beside the compiler
Hemera links with the `ld.lld` or `lld-link` in its own executable's folder when there's one, and otherwise the one on
the PATH, as now; a target's own `linker` still wins. Hemera's build puts the linkers its own LLVM builds (the `lld`
target, with Hemera's patches) beside `hemera`, as `base` and `std` ship beside it. The build cache keys a program by
the linker found, as it does already, so one linked before isn't taken for one linked by the other. `compilation.md`
says where the linker comes from.

Tests: a Build test links with a PATH that has no linker on it and finds the one beside the compiler; SlopOS's boot
tests run with only Hemera's `bin/Release` on the PATH, and RISC-V's programs keep their property note.

## Decision: C2, the flaky tests waiting on conditions
Each of the three gets its race found and a wait on what it needs, as R7 gave the GUI login and the microphone, with
the cause recorded here as built. Where the cause is the host falling behind rather than a race, as QEMU's audio
backend dropping samples when every core is busy, the test measures what the system controls, and says what it leaves
to the host. Done when two full runs in a row, all three architectures, have none failing among the others.

## Alternatives considered
- **The PATH step kept, documented**: every new shell, and every new machine, would make it again, and a run that
  forgot it passes most tests while RISC-V's programs quietly lose their CFI.
- **Refusing an lld too old**: catches the mistake, but still needs the right one found; finding it beside the compiler
  makes the mistake hard to make.
- **Straight to ABI v1**: its tests are the same boot suites, which would go on failing now and then.

## Consequences
- Hemera's `bin` folder is the whole toolchain: the compiler, its `base` and `std`, and its linkers.
- The boot suites become a signal again: a test failing among the others means something.
- ABI v1 is planned next, its own decision.
