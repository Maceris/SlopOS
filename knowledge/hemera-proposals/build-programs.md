# Builds as Hemera Programs: What's Left

Status: **adopted** into `base/compiler` (2026-10-05). A build package registers targets, checks
and steps from its `#run` code; Hemera's `docs/compilation.md` (*Build Packages*, *Compile-Time
Permissions*) and `base/compiler/build.hsc` and `package.hsc` are the reference, and
`../decisions/0028-build-package.md` is how SlopOS uses it. `os.run_process` runs other programs
since 2026-10-19 (Windows and Linux), gated by `--allow-run`. This keeps only what's still open.

## Parse Once

**Building targets at the same time is done** (2026-10-23, Hemera's `docs/compilation.md`, *Build
Packages*): several at once (`--jobs`), each reporting in one piece and in order, the build's checks
taking turns, steps after every target, and the outputs the same as one at a time. SlopOS's whole
build went from about 7.7 s to about 4.0 s, now bound by the kernel alone: most of its 3.7 s is LLVM
simplifying the whole kernel module, on one thread.

Still open: **sharing parsed files between targets.** Measured 2026-10-23 on SlopOS's whole build:
599 files read, about 190 of them for the kernel and the build package alone, and lexing and parsing
all of them is about 250 ms of CPU time (181 ms lexing, 68 ms parsing), spread across each target's
checking threads and mostly off the kernel's path, so sharing would save tens of milliseconds there.
Checking changes a file's tree (insertions, types on nodes), so sharing would mean copying trees or
making them immutable. Not worth it yet; lexing, the larger half, may be worth making faster first.

## `find_packages`

`compiler.find_packages(folder, declares)` was declared but never implemented, and was removed from
`base/compiler` on 2026-10-25. SlopOS finds packages by folder instead, with `compiler.subfolders` and
`compiler.load_package`, its own build code deciding what to build (`../decisions/0028-build-package.md`,
revised 2026-10-16).
