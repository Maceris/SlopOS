# Builds as Hemera Programs: What's Left

Status: **adopted** into `base/compiler` (2026-10-05). A build package registers targets, checks
and steps from its `#run` code; Hemera's `docs/compilation.md` (*Build Packages*, *Compile-Time
Permissions*) and `base/compiler/build.hsc` and `package.hsc` are the reference, and
`../decisions/0028-build-package.md` is how SlopOS uses it. `os.run_process` runs other programs
since 2026-10-19 (Windows and Linux), gated by `--allow-run`. This keeps only what's still open.

## Parse Once, Build in Parallel

Documented 2026-10-19 in Hemera's `docs/compilation.md` (*Build Packages*) as it is today: targets
are built one at a time, each a program of its own whose files are read, parsed and checked for it,
with the work inside a target spread across threads. Planned, and stated there:

- **Sharing parsed files between targets.** Each target is still checked on its own, since its
  `#if` choices, settings and package paths can change what a file means.
- **Building independent targets at the same time**, with steps still waiting on the targets they
  depend on.

Neither may change what a build produces (Hemera's `docs/compilation.md`, *Deterministic Output*).
SlopOS feels this as build time once there are many programs and drivers; nothing is blocked on it.

## `find_packages`

`compiler.find_packages(folder, declares)` is declared but not implemented. SlopOS finds packages by
folder instead, with `compiler.subfolders` and `compiler.load_package`, its own build code deciding
what to build (`../decisions/0028-build-package.md`, revised 2026-10-16). It may be removed from
`base/compiler`.
