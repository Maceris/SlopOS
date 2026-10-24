# 0059: User Programs as Built

Status: accepted
Date: 2026-10-23
Related: `0058` (the plan for M6), `0004` (PIC), `0026` (thread start), `0028` (build package), `0033`
(package layout), `../design/system-abi.md` §5 and §6, `../../docs/specs/programs.md`, `../roadmap.md` M6

## Context
M6's first stage (6a): programs as executables of their own. Hemera's `base` had an empty branch for
`os = .SlopOS`, and the compiler had no SlopOS target at all. The startup block's contents were sketched
(`system-abi.md` §6) but not defined, `memory_map` takes an explicit address the kernel doesn't choose, and
nothing let a process end itself. 6a's output can't run before 6b's loader does.

## Decision
Chosen with the project's owner:
- **`base` keeps its own copy** of the few call numbers it makes and of the startup block's first fields
  (`base/runtime/slop_os.hsc`), as `linux.hsc` does Linux's. The ABI package (`std/os/slop_os/startup.hsc`)
  asserts at compile time that they match its own, so a mismatch is a build error, in every build that
  imports it, the kernel's included. The ABI stays in `std`, outside the compiler's embedded `base`.
- **The startup block names a free range** of the process's address space, which its loader puts at a
  random place; the runtime maps its own memory there. The kernel stays out of address-space layout.
- **`process_exit(code)`**, a new call (45): the calling process is destroyed with its subtree, and the
  `Signal` packet its `SIGNAL_TERMINATED` raises carries the code in `data[1]`, or `EXIT_KILLED` when it
  was destroyed any other way. `main`'s result is the code. The process object is gone by then, so the code
  travels with its end rather than through a call on a stale handle.
- **The ELF loader moved into 6a**, as `src/elf_loader`, unit-tested on the programs the build makes.

As built:
- **Hemera's compiler targets SlopOS:** `OSType::SlopOS` (`--os=slopos`, and `os = .SlopOS` in a build
  package), ELF for LLVM's unknown OS. The startup code is the entry itself, `hemera_entry`, called with the
  startup block's address, which it keeps in the runtime's process state; after `main` it calls
  `runtime.os_exit_process`. It's linked `-static -pie --no-dynamic-linker`, so its loader relocates it.
- **`base`'s SlopOS runtime:** Hemera's page heap, now shared with Linux (`page_heap.hsc`), on pages that are
  memory objects of their own, mapped read-write in the free range with each one's handle in a page in
  front; the monotonic clock; `process_exit` for ending and for a failed assertion. No output, random
  numbers or threads yet.
- **`slop_os.StartupBlock`** (`docs/specs/programs.md`): the ABI version and the block's size, handles to the
  process, its address space and its budget, the free range, and `CpuFeatures`.
- **The build package builds programs:** every folder in `src/apps`, `src/services` and `src/drivers`, as
  `<name>.elf` (`targets=programs`, `programs_output`). The first is `src/apps/hello`. `boot.py` carries them
  as Limine modules (`--programs`), the kernel logs each, and `unit_tests.py` gives each test their folder.
- **The loader** (`src/elf_loader`): `read`, `load` and `relocate`, allocating nothing, refusing everything
  that isn't a position-independent x86-64 executable with relative relocations, segments on pages of their
  own and none writable and executable.
- **Found in Hemera on the way, fixed (`0047`):** `#assert` couldn't evaluate `cast`, the bitwise operators
  or shifts; generated stubs for calls that never return couldn't take parameters.

## Alternatives considered
- **The ABI package in `base`**: one copy, but SlopOS's ABI embedded in the compiler, and every ABI change a
  compiler rebuild.
- **The kernel choosing mapping addresses**, as `mmap` does: an address allocator per space in the kernel.
- **Exiting by killing itself, with no code**: results would only come back through channels.
- **Checking only the built ELFs' headers in 6a**, leaving the loader to 6b.

## Consequences
- 6b's kernel loader is the shared one: it reads the root task's module, loads it into a memory object, and
  maps its segments with windows onto it, then writes the startup block.
- Addresses the heap takes from the free range aren't reused, and a page of each mapping holds its handle;
  both are simple for now and may change once programs map a lot.
- A program can't create a thread in another process: `thread_create` makes one in the caller's process, so
  starting a process another one built needs a call of its own (6b).
