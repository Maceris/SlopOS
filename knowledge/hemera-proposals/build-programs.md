# Proposal: Builds as Hemera Programs

Status: **adopted** into `base/compiler` (2026-10-05). `base/compiler/build.hsc`
(`BuildOptions`, `add_target`, `add_step`, `add_check`, `target_setting`,
`BuildPermissions`, `report_error`) and `base/compiler/package.hsc` (`find_packages`,
`find_constant`, `ProgramInfo`) are the reference for exact names and signatures. This
document keeps why SlopOS needs it, how SlopOS uses it (`../decisions/0028-build-package.md`)
and what is still open (§7).

## 1. Why

Hemera has no build system: you point the compiler at a project's root package and its
imports decide what gets compiled. That covers one program. SlopOS produces many outputs:
a kernel, drivers, services, programs, libraries, host-side tests and a boot image. A build
of many outputs is an ordinary Hemera program, without a separate build language.

## 2. The Model (as adopted)

- A **build package** has output type `.Nothing`. Its `#run` code registers **targets**
  with `compiler.add_target(options)`, each a root package plus a `BuildOptions`.
- `compiler.command_line_options()` returns what was given on the command line as defaults,
  so a target overrides only what differs, and `hemera -O3 build` does the obvious thing.
- **Discovery:** `compiler.find_packages(folder, declares = "PROGRAM_KIND")` returns every
  package declaring that constant, so adding a driver never touches the build package.
  The constant's value is evaluated in the build program, so it has the build's types and
  can be cast directly.
- **Steps** (`add_step`) are Hemera functions run after the targets or steps they depend on,
  receiving each target's output path (`TargetOutput`).
- **Checks** (`add_check`) run on every target once it is type checked, receiving its
  `BuildOptions` and its whole `ProgramInfo`. This is where house-rule checks hook in
  (`reflection-checks.md`, `../decisions/0029-house-rule-checks-in-build.md`).
- **Settings** are per-target strings that the target reads with `compiler.target_setting`.

Folder paths below (`src/kernel`, `src`) are placeholders until the package structure is
drafted (`../open-questions.md`, *Scope*).

```
package build

import compiler from "base"
import checks from "../checks"                                  // placeholder locations
import build_settings from "../build_settings"

build :: fn() {
    kernel := compiler.command_line_options()
    kernel.name = "kernel"
    kernel.root = "src/kernel"
    kernel.entry = "kernel_entry"
    kernel.target_options.os = .None
    kernel.target_options.output_type = .Executable
    kernel.target_options.relocation_model = .PIE               // decisions/0004, 0021
    kernel.target_options.red_zone = false                      // design/arch-x86-64.md
    kernel.target_options.cpu = "x86-64-v3"                     // decisions/0003
    kernel.target_options.cpu_features = "-sse,-sse2,-avx,-avx2"
    kernel.target_options.linker_script = "src/kernel/kernel.ld"
    append(&kernel.settings, compiler.TargetSetting.{build_settings.LOG_LEVEL, "debug"})  //HEMERA(guess): dynamic array append
    _ = compiler.add_target(kernel)

    for program in compiler.find_packages("src", declares = "PROGRAM_KIND") {
        options := compiler.command_line_options()
        options.name = program.name
        options.root = program.path                             //HEMERA(guess): root accepts the canonical (absolute) path find_packages returns
        options.target_options.os = .SlopOS                     //HEMERA(gap): no OperatingSystem.SlopOS yet
        options.target_options.output_type = output_type_for(&program)
        _ = compiler.add_target(options)
    }

    compiler.add_check(checks.check_program)
    _ = compiler.add_step(pack_boot_image, compiler.all_targets())
}

#run build()
```

## 3. Per-Target Settings

Settings are strings (`TargetSetting { name, value: string }`). This answers the question
this proposal asked (typed `any` or strings): the build package and each target are type
checked separately, because `OS`, `TARGET_ARCH` and `#if` branches can differ, so a type
defined in one doesn't exist in the other. Each consumer parses, and reports a bad value
with `report_error`:

```
// In the kernel:
LOG_LEVEL :: #run parse_log_level(compiler.target_setting(build_settings.LOG_LEVEL, default = "info"))
TRACE_IPC :: #run compiler.target_setting(build_settings.TRACE_IPC, default = "false") == "true"

#if TRACE_IPC {
    // ...
}
```

Anything depending on `LOG_LEVEL` waits until it's computed, as with any other compile-time
constant. Because settings are per target, the same package can be built with different values
in one build without conflict. SlopOS keeps setting names as string constants in a small
`build_settings` package imported on both sides, so a misspelled name fails to compile
instead of silently reading the default (`../decisions/0028-build-package.md`).

## 4. Programs, Packages and Entry Points

The rule stays "a program has one root package". What generalizes is the entry point, now
`BuildOptions.entry` ("empty means `main` for executables, and no entry for libraries"):

- **Library packages** have no entry point and can be imported by anything.
- **Program packages** are the roots of targets. Programs never import other programs (a
  house-rule check).
- **The target names its entry function.** The kernel entry is called by Limine with its
  own convention, drivers start with capabilities rather than `argv`, and libraries have no
  entry at all. (The kernel still needs a no-runtime build and an entry calling convention:
  `../hemera-feedback.md` items 1 and 7.)
- **`#export`** marks a library's or program's public interface, and `FunctionInfo.is_exported`
  exposes it to compile-time code. SlopOS programs export several typed functions, and the
  shell builds command-line interfaces from those signatures (`../problems-and-directions.md` §4):

  ```
  search #export :: fn(pattern: string, files: File[], ignore_case := false) -> Stream[Match] {
      // ...
  }
  ```

- The same root package can be several targets: a driver built for SlopOS and its tests
  built for the host, for example.

## 5. Running External Programs

1. **Compiling other Hemera code: use the compiler API, never a `hemera` subprocess.** A
   subprocess loses typed options, integrated errors and shared parsing.
2. **Running genuinely external tools** (QEMU, the Limine installer, maybe `git` to stamp a
   version): a normal `std` OS-tier function usable at compile time. It doesn't exist yet;
   it belongs in Hemera's `std/os` (§7):

   ```
   os.run_process(program: string, arguments: string[], working_directory: string? = null)
       -> Result[ProcessResult, ProcessError]
   ```

**Gating (adopted):** compile-time code can't run processes or write outside the output
folder unless the command line grants it (`--allow-run`); code reads what it was granted
with `compiler.build_permissions()`. `os.run_process` at compile time should check it and
fail with a clear error rather than leave enforcement to each caller.

**Prefer Hemera over external tools when it's real work.** Writing the FAT32 boot image in
Hemera (roadmap M8) is better dogfooding than calling `mkfs.fat`.

## 6. `BuildOptions` Fields SlopOS Asked For

All present in `build.hsc`:

| SlopOS need | Field |
|---|---|
| Many outputs in one build | `name`, `output_path` |
| The target's entry package | `root` |
| Kernel/driver/library entry points | `entry` |
| Remap `base`/`std` per target when needed | `package_paths` (`PackagePath`) |
| User space x86-64-v3; kernel without SIMD | `target_options.cpu`, `cpu_features` |
| Red zone off for the kernel | `target_options.red_zone` |
| Explicit PIC/PIE (`../decisions/0004`) | `target_options.relocation_model`, `code_model` |
| Kernel layout for Limine | `target_options.linker_script` |
| Per-target constants (§3) | `settings` |
| Steps that need other targets' outputs | `add_step(step, after)`, `TargetOutput` |

## 7. Requirements and What's Still Open

| # | Need | State |
|---|---|---|
| B1 | Register multiple targets from `#run` code in a `.Nothing` build package | **Done**: `add_target` |
| B2 | Targets inherit command-line options as defaults | **Done**: `command_line_options()` |
| B3 | Find packages and read their declared constants | **Done**: `find_packages(folder, declares)`, `find_constant` |
| B4 | Per-target settings readable as compile-time constants | **Done**: `settings`, `target_setting()` (strings, §3) |
| B5 | Post-build steps with dependencies on target outputs | **Done**: `add_step`, `BuildNode`, `TargetOutput` |
| B6 | Entry function per target; `#export` for public interfaces | **Done**: `entry`, `#export`, `FunctionInfo.is_exported` |
| B7 | Build code observes each target's type-checked program | **Done**: `add_check`, `CheckFunction`, `ProgramInfo` |
| B8 | Process spawning in `std`, gated at compile time | **Gate done** (`--allow-run`, `build_permissions()`); `os.run_process` still to write in Hemera's `std/os` |
| B9 | The `BuildOptions` fields in §6 | **Done** |
| B10 | Parse once, type check per distinct target configuration, build in parallel | Per-target type checking is implied by `TargetSetting`'s comment; sharing parsed files and building in parallel isn't documented. Worth stating in Hemera's `docs/compilation.md` |

Still open on the Hemera side:

- **Target enums:** `OperatingSystem` has no `SlopOS` (or `UEFI`), `Architecture` has no
  `riscv64`, and `OutputType` has no raw/flat binary (`../hemera-feedback.md`, *Target enums*).
- **Permission scope:** `--allow-run` is granted to the whole build, so `#run` code in any
  package the build package imports gets it too. SlopOS would prefer the grant to reach
  only the build package's own code, or to be a value build code passes on explicitly
  (permissions as capabilities). Not urgent while every dependency is first-party.
- **`root` paths:** `root` is "relative to the build package", while `PackageInfo.path` is
  canonical. Either `root` should accept canonical paths, or `PackageInfo` could also carry
  the path relative to the folder given to `find_packages`.
- **B10 documentation** (above).
