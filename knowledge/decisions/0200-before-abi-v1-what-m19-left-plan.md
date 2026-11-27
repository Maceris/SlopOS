# 0200: Before ABI v1, What M19 Left, Planned

Status: accepted; built
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

## As Built: C1 and C2 (2026-11-27)
- **C1, the linker beside the compiler.** Hemera looks for `ld.lld` and `lld-link` in its own folder first, then on
  the PATH (`back_end/linker.h`), the back end and the build cache alike. Its build copies its own LLVM's `lld` there
  under both names, and on Windows the DLLs the compiler and `lld` load, and those they load in turn, resolved as it
  builds (`copy_runtime_dlls.cmake`: vcpkg's `z.dll`, `libxml2.dll` and its `iconv-2.dll`): the compiler itself had
  needed vcpkg's folders on the PATH for `z.dll`. A Hemera test links a Windows and a Linux program with nothing on the
  PATH; RISC-V's programs keep their property note with Visual Studio's lld 19 first on it; the boot suites ran with
  only Hemera's `bin/Release` on the PATH, after the system's.
- **C2, the flaky tests.**
  - AArch64's release command line: the bootloader's line was cut short, as `SerialKeys` read the serial port off a
    socket QEMU reset when the machine ended with keys sent it never read, and a reset on Windows drops what was
    received and not yet read. QEMU now writes the serial file itself (the chardev's `logfile`), and the socket is
    only for the keys and for watching.
  - x86-64's mix: its second stream starts as its client runs, which a busy host puts off, so the half second in the
    middle of the whole sound caught it before it started. The check takes the half second, of 40 through the sound,
    where every tone is nearest its level.
  - RISC-V's file search: not a race but `search` crashing, an execute fault on its first run, once, under load. Not
    reproduced since; the test now runs `crashes` at its end and wants none, so another says where.
  - The microphone's two races were fixed in R7.
  - Done: two full runs in a row, all three architectures, 459 of 459 each, none flaky.
- **Found on the way:**
  - A CPU locking up (`[fatal] lockup`), twice in M19's last runs, once in a shutdown and once in a generation's
    rollback, neither seen since; RISC-V has no NMI to make the stuck CPU say where it is, so `boot.py` asks QEMU for
    every CPU's registers the moment the kernel says one locked up, and prints them with the run.
  - Instruction fetches made to see code before it's mapped executable, which real hardware needs and QEMU doesn't:
    RISC-V's `map` runs `fence.i` here and the SBI's remote `fence.i` on the other harts, and AArch64's cleans the data
    cache to the point of unification and invalidates every CPU's instruction cache, unless `CTR_EL0`'s IDC and DIC
    say it needn't. x86-64's caches are coherent.
- **Tests:** Hemera's 305 of 305 on Windows and 85 of 85 on Linux; the boot suites as above.
