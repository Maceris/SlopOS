# Reproducible Builds

Status: **proposed** 2026-10-27, its open questions decided the same day, for M9 (`../decisions/0092`): needed by 9b, where programs are stored by hash.

## Why SlopOS Needs It

The bundle store keys every program and library by the BLAKE3 hash of its bytes (`../design/software.md` §2), and a
bundle's hash names exactly one build. If the same sources built twice gave different bytes, every build would be a
new hash: the store would fill with copies, a generation couldn't be rebuilt to check it, and substitution
(`../decisions/0045`) couldn't tell a real change from noise.

## Where Hemera Is

`docs/compilation.md` (*Deterministic Output*) already promises the same output for the same inputs, wherever it's
written and however the work was spread across threads, and orders everything it walks by something in the source.
Measured 2026-10-27: SlopOS's 27 programs, built twice into different folders, came out byte for byte the same.

What isn't the same is **where the sources are**. `#caller_location` gives a location's file as its absolute path, so
`D:\Documents\Programming\SlopOS\src\services\disk_check\disk_check.hsc` and `D:\Hemera\std\os\files.hsc` are in the
built `disk_check.elf`, and the same commit checked out elsewhere, or built on another machine, hashes differently.
Debug info already names files relative to their roots (`<base>/runtime/assertion.hsc`, `src/main.hsc`, in
`hemera --symbolize`'s output).

## Proposal

1. **Locations name files as debug info does**: relative to the root package's folder, and `<base>/...` and
   `<std>/...` for the compiler's own, wherever they're installed. Stack traces and assertion messages read the same,
   shorter.
2. **The promise extended to where the sources are**: the same sources, checked out anywhere, built by the same
   compiler with the same options, give the same bytes. `docs/compilation.md` says so, and what's in the output that
   could vary (debug info's compilation directory, PDB paths, any time stamp the linker writes) is fixed or relative.
3. **A test in Hemera's suite**: one program built twice, from two copies of its sources in different folders, with
   different thread counts, compared byte for byte, for each object format (ELF, PE/COFF) and with and without
   `--debug`.

The same compiler means the same compiler's hash: SlopOS's builds record which compiler made them, and a new compiler
is expected to change hashes.

## Decided With the Owner (2026-10-27)

- **Compile-time code's inputs are its own choice**: a build package's or `#run`'s code that reads the clock or a
  changing file makes its build differ, as `docs/compilation.md` already says; the compiler doesn't flag it.
- **Reproducible across hosts**: a SlopOS program built on Windows and on Linux comes out the same, byte for byte;
  the test builds on both, the Linux build on Hemera's Linux test host.
