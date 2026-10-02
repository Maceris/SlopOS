# Proposal: Builds as Hemera Programs

Status: proposal for Hemera's compiler API (`base/compiler`), driven by SlopOS needs.

Hemera has no build system: you point the compiler at a project's root package and its
imports decide what gets compiled. That covers one program. SlopOS produces many outputs:
a kernel, drivers, services, programs, libraries, host-side tests and a boot image. This
proposal describes how a build of many outputs can be an ordinary Hemera program, without
adding a build language.

All API names below are invented to show the shape of the idea, and folder paths like
`src/kernel` are placeholders (SlopOS's package structure isn't drafted yet).

## 1. The Model

- A **build package** is a normal package whose `#run` code registers **targets** through a
  compiler API. The build package's own output type is `.Nothing` (already in
  `base/compiler/build.hsc`).
- A **target** is a root package plus a `BuildOptions` value: architecture, OS, output type,
  entry, and so on. The compiler builds every registered target, in parallel where possible.
- **Steps** are Hemera functions run after the targets they depend on, e.g. packing a boot
  image from the kernel and driver binaries.
- Invocation stays the same: `hemera --package=std:std_proposal build`.

```
package build

import compiler from "base"

build :: fn() {
    compiler.add_target(
        name = "kernel",
        root = "src/kernel",
        os = .None,
        output = .Executable,
        entry = "kernel_entry",
    )

    // Discovery instead of listing: any package declaring PROGRAM_KIND is a target,
    // so adding a driver never touches this file.
    for program in compiler.find_packages("src", declares = "PROGRAM_KIND") {
        compiler.add_target(
            name = program.name,
            root = program.path,
            os = .SlopOS,
            output = output_kind_for(program),
        )
    }

    compiler.add_step(pack_boot_image, after = compiler.all_targets())
}

#run build()
```

## 2. What Makes It Convenient

- **Defaults from the command line.** Configuration (Debug/Release), optimization level and
  `--package` paths given on the command line become the defaults for every target. A target
  overrides only what differs, so `hemera -O3 build` does the obvious thing.
- **Discovery through reflection.** Program packages declare what they are as a constant
  (`PROGRAM_KIND :: ProgramKind.Driver`), the same mechanism as `PACKAGE_TIER`. The build finds
  them with the reflection API (`reflection-checks.md`, R1/R2/R5).
- **One compiler process, shared work.** Source files are read and parsed once for all targets.
  Type checking and code generation happen per *distinct target configuration*, because
  `OS`, `TARGET_ARCH` and other compiler-provided constants differ between targets, so `#if`
  branches and constant values can differ. Targets with identical options share everything.
- **One mechanism for builds and house rules.** The build package is also where house-rule
  checks are registered (`../decisions/0007-house-rules-compile-time-checks.md`). If the
  compiler lets build code observe each target as it's type checked (as Jai's metaprogram
  receives compiler messages), every check runs against every target with no extra wiring.
- **Clear errors.** Errors are reported per target (`[kernel] src/kernel/... error`), and the
  build continues with independent targets so one failure shows everything else that's wrong.

## 3. Per-Target Constants Come From the Compilation Context

Hemera's globals must resolve to a constant at compile time, but computing that constant
can run arbitrary code, and while compiling there is a compiler-provided context that code can
read (`OS` and `TARGET_ARCH` are formalized in `base` this way). So build configuration needs
**no new mechanism**: a target's settings are just values in its compilation context, and a
package reads them into ordinary constants.

```
// In the build package:
compiler.add_target(
    name = "kernel",
    root = "src/kernel",
    os = .None,
    output = .Executable,
    settings = {"LOG_LEVEL": "debug", "TRACE_IPC": "true"},    //HEMERA(guess): map literal
)

// In the kernel:
LOG_LEVEL :: #run parse_log_level(compiler.target_setting("LOG_LEVEL", default = "info"))
TRACE_IPC :: #run compiler.target_setting("TRACE_IPC", default = "false") == "true"

#if TRACE_IPC {
    // ...
}
```

Anything depending on `LOG_LEVEL` waits until it's computed, as with any other compile-time
constant. Because settings are per target, the same package can be built with different values
in one build without conflict.

**Question:** should settings be typed (the build passes an `any`, the package casts) or
strings (simple, but every consumer parses)? Typed values match Hemera better, but the build
package and the consuming package must then share the type's definition.

## 4. Programs, Packages and Entry Points

The rule stays "a program has one root package". What generalizes is the entry point:

- **Library packages** have no entry point and can be imported by anything.
- **Program packages** are the roots of targets. Programs never import other programs (a
  house-rule check).
- **The target names its entry function**; `main` is only the default. SlopOS needs this:
  the kernel entry is called by Limine with its own convention, drivers start with
  capabilities rather than `argv`, and libraries have no entry at all.
- **`#export`** (now in Hemera's `docs/directives.md`) marks a library's or program's public
  interface. SlopOS programs export several typed functions, and the shell builds command-line
  interfaces from those signatures (`../problems-and-directions.md` §4):

  ```
  search #export :: fn(pattern: string, files: File[], ignore_case := false) -> Stream[Match] {
      // ...
  }
  ```

- The same root package can be several targets: a driver built for SlopOS and its tests
  built for the host, for example.

## 5. Running External Programs

Two separate needs:

1. **Compiling other Hemera code: use the compiler API, never a `hemera` subprocess.** A
   subprocess loses typed options, integrated errors and shared parsing, and brings quoting
   and path differences between platforms.
2. **Running genuinely external tools: needed.** SlopOS will run QEMU to boot the image, the
   Limine installer, and maybe `git` to stamp a version. This is a normal `std` OS-tier
   function usable at compile time:

   ```
   os.run_process(program: string, arguments: string[], working_directory: string? = null)
       -> Result[ProcessResult, ProcessError]
   ```

Guidance and safeguards:
- **Prefer Hemera over external tools when it's real work.** Writing the FAT32 boot image in
  Hemera (planned in roadmap M8 anyway) is better dogfooding than calling `mkfs.fat`.
- **Gate side effects at compile time.** `docs/compilation.md` already warns that compiling
  untrusted code is unsafe. Once compile-time code can spawn processes, that risk grows. Options:
  - a flag such as `--allow-run` that build code must have before it can spawn processes or
    write files outside the output folder;
  - (more in the spirit of SlopOS) the compiler hands build code a context carrying those
    permissions explicitly, so a dependency's `#run` can't use them unless passed along.

## 6. `BuildOptions` Additions SlopOS Needs

Current `base/compiler/build.hsc` has backend, configuration, and target (architecture, OS,
output type). Per target, SlopOS also needs:

| Field | Why |
|---|---|
| `name`, output path | Many outputs in one build |
| root package | The target's entry package |
| `entry` | Kernel/driver/library entry points differ from `main` |
| package paths | `std` → `std_proposal` (per target, defaulting to the command line) |
| CPU and features | User space targets x86-64-v3; kernel disables SIMD |
| red zone off | Kernel code (`../design/arch-x86-64.md`) |
| code model / PIC | PIC everywhere (`../decisions/0004`), but should be explicit |
| linker script or section placement | Kernel layout for Limine |
| settings | Per-target constants (§3) |
| dependencies | Steps that need other targets' outputs |

## 7. Requirements Summary

| # | Need |
|---|---|
| B1 | Register multiple targets from `#run` code in a build package with output `.Nothing` |
| B2 | Targets inherit command-line options as defaults |
| B3 | Find packages and read their declared constants (shares R1/R2/R5 with `reflection-checks.md`) |
| B4 | Per-target settings readable as compile-time constants |
| B5 | Post-build steps with dependencies on target outputs |
| B6 | Entry function chosen per target; `#export` for public interfaces |
| B7 | Build code can observe each target's type-checked program (house-rule checks) |
| B8 | Process spawning in `std` (OS tier), gated by an explicit permission at compile time |
| B9 | The `BuildOptions` fields in §6 |
| B10 | Parse once, type check per distinct target configuration, build targets in parallel |
