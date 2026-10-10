# 0028: One Build Package, Using Hemera's Compiler API

Status: proposed
Date: 2026-10-09
Related: `../hemera-proposals/build-programs.md` (adopted into Hemera's `base/compiler`),
`0029` (house-rule checks), `0004` (PIC), `0003` (x86-64-v3)

## Context
SlopOS produces many outputs from one source tree: the kernel, drivers, services, programs,
libraries, host-side tests and a boot image. Hemera has adopted the build proposal:
`base/compiler/build.hsc` lets a package with output type `.Nothing` register targets
(`add_target`), steps (`add_step`) and checks (`add_check`) from `#run` code, with
command-line options as defaults, per-target string settings (`target_setting`), package
discovery by declared constant (`find_packages(folder, declares)`), and a command-line grant
(`--allow-run`) for running processes or writing outside the output folder. This answers the
open question of whether settings are typed or strings: they are strings, because the build
package and each target are type checked separately and don't share types.

## Decision
- **One build package** builds everything. Its location is decided with the package structure
  (`../open-questions.md`, *Scope*). There are no makefiles or scripts, and other Hemera code is
  never compiled through a `hemera` subprocess.
- **Discovery, not lists.** Every program package (driver, service, program, test) declares
  `PROGRAM_KIND :: ProgramKind.<Kind>`, and the build package registers each package
  `find_packages` returns. Only the kernel and the boot image step are named explicitly.
  Adding a driver never touches the build package.
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
- **A separate build tool or makefiles:** a second language to maintain, and it loses typed
  options, integrated errors and shared parsing.

## Consequences
- The build package is ordinary Hemera code and a stress test of the compiler API.
- User-space targets can't be expressed until `OperatingSystem.SlopOS` exists. The enum member
  can be added to `base/compiler/target.hsc` from here (`0030`), but the compiler must support
  the target (`../hemera-feedback.md`, *Target enums*); written as `//HEMERA(gap)` until then.
- Running the system in QEMU from the build requires `--allow-run`; compiling never does.
- `os.run_process` has to be written in Hemera's `std/os` before any step can run a tool.
