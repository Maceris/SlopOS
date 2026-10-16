# 0028: One Build Package, Using Hemera's Compiler API

Status: accepted (implemented 2026-10-16 as `src/build`)
Date: 2026-10-09
Related: `../hemera-proposals/build-programs.md` (adopted into Hemera's `base/compiler`),
`0029` (house-rule checks), `0004` (PIC), `0003` (x86-64-v3)

## Context
SlopOS produces many outputs from one source tree: the kernel, drivers, services, programs,
libraries, host-side tests and a boot image. Hemera has adopted the build proposal:
`base/compiler/build.hsc` lets a package with output type `.Nothing` register targets
(`add_target`), steps (`add_step`) and checks (`add_check`) from `#run` code, with
command-line options as defaults, per-target string settings (`target_setting`), finding
packages (`subfolders`, `load_package`), and a command-line grant
(`--allow-run`) for running processes or writing outside the output folder. This answers the
open question of whether settings are typed or strings: they are strings, because the build
package and each target are type checked separately and don't share types.

## Decision
- **One build package** builds everything (in `src/build/`, `0033`). Its location is decided with the package structure
  (`../open-questions.md`, *Scope*). There are no makefiles or scripts, and other Hemera code is
  never compiled through a `hemera` subprocess.
- **Discovery, not lists, by folder** (revised 2026-10-16). The package structure already puts
  packages in folders by role (`src/drivers/`, `src/services/`, `src/apps/`, `0033`), so the
  build package lists those folders with `compiler.subfolders`, loads each subfolder with
  `compiler.load_package`, and decides in its own code what to build from it: its folder, and
  any constant it declares, read with `find_constant` and compared by name, since a loaded
  package is checked as its own program. Only the kernel and the boot image step are named
  explicitly. Adding a driver never touches the build package. This replaces discovery by a
  declared `PROGRAM_KIND` through `find_packages(folder, declares)`, which needed the found
  constants typed by the build program; Hemera keeps `find_packages` declared, unimplemented,
  until there's evidence it's the better path, and may remove it.
- **Every target starts from `command_line_options()`** and overrides only what it must.
  `base` and `std` come from the Hemera repo, with no remapping (`0030`).
- **Kernel target:** `os = .None`, `entry = "kernel_entry"`, `relocation_model = .PIE`
  (`0004`, `0021`), `red_zone = false`, SIMD disabled through `cpu_features`, and the Limine
  linker script. **User-space targets:** `cpu = "x86-64-v3"` (`0003`), `os = .SlopOS` once
  Hemera has it.
- **Settings are strings with one owner each.** Setting names are string constants in a tiny
  freestanding `build_settings` package imported by both the build package and the consumers,
  so a misspelled name is a compile error instead of a silent default. The package that uses a
  setting defines its typed constant and parser in one place, and reports a bad value with
  `compiler.report_error`.
- **External tools only where Hemera can't do the work**, through `std`'s `os.run_process`
  (Hemera's `std/os`, OS tier). Building every target needs no permissions; only steps that run
  QEMU or the Limine installer need `--allow-run`. The boot image is written in Hemera.
- **House-rule checks are registered from the build package** (`0029`).

## Alternatives considered
- **Typed settings (`any`):** not what Hemera adopted, and a type from the build program
  doesn't exist in the target's program anyway.
- **An explicit list of targets:** simpler to read, but every new driver edits a shared file,
  and it duplicates what each package already says about itself.
- **`find_packages(folder, declares = "PROGRAM_KIND")`** (this decision's first version, like Go's
  `package main` with `./...`): the kind in the package itself, typed. But it repeats what the
  folder already says, and its promise that the found constants have the build program's types
  means loading packages into a program whose compile-time code is already running.
- **A separate build tool or makefiles:** a second language to maintain, and it loses typed
  options, integrated errors and shared parsing.

## Consequences
- The build package is ordinary Hemera code and a stress test of the compiler API.
- User-space targets use `OperatingSystem.SlopOS`, added to `base/compiler/target.hsc` on
  2026-10-09 (`0030`). Building them still needs the compiler to support the target.
- Running the system in QEMU from the build requires `--allow-run`; compiling never does.
- Implemented 2026-10-16 in `src/build`: settings `targets` (`all`, `kernel`, `tests`),
  `kernel_output` and `tests_output`; tests are found with `compiler.subfolders` (every `test`
  folder, named `<package>_test`). `tools/boot.py`, `boot_tests.py` and `unit_tests.py` build
  through it. There are no steps yet, so booting stays in `tools/boot.py`.
- `os.run_process` has to be written in Hemera's `std/os` before any step can run a tool.
