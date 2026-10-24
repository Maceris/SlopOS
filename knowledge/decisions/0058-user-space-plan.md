# 0058: The Plan for User Space (M6)

Status: accepted
Date: 2026-10-23
Related: `0004` (PIC and ASLR), `0012` (root task), `0026` (thread start), `0028` (build package), `0044`
(typed entry points and the system configuration), `../design/system-abi.md` §5 and §6, `../roadmap.md` M6

## Context
M6 makes programs executables of their own, which the kernel and then the process manager load. Until now,
user-mode code has been boot tests inside the kernel's image, which is why tests map the kernel's code.
`0012` left open how the root task is loaded ("a minimal, non-relocating program loader of its own for
the first few boot modules, or the boot modules are prelinked"). Nothing lets a user program write output
before a console driver exists (M7). `0044` plans the boot configuration as a compile-time Hemera value
with its wiring checked by the build, a large piece to start with.

## Decision
Chosen with the project's owner:
- **One shared ELF loader**, a freestanding package used by the kernel (for the root task, `modules[0]`),
  by the root task (for its first services) and by the process manager. It accepts position-independent
  executables only: it maps each segment with its protection (W^X), applies `R_X86_64_RELATIVE`
  relocations, places the image at a random base, and refuses anything else.
- **A debug-log capability**: a kernel object, like the platform capability, that the root task receives
  and can pass on. A system call writes a line to the kernel's log. It's a handle, so no program writes
  output without being given it.
- **The typed boot configuration from the start, kept small**: a `system_config` package, a compile-time
  Hemera value compiled into the root task, listing M6's few services. The build checks its wiring
  (each `Channel[P]` against a `Listener[P]`) once typed entry points exist, in stage 6d.
- **ASLR's randomness comes from an early entropy source**, as `0012` plans: the root task seeds it from
  the boot seed and the process manager draws from it over a channel. The kernel uses its own entropy for
  the root task.

M6 comes in four stages:
- **6a, user programs as executables:** `base`'s runtime for `os = .SlopOS` (the entry stub from `0026`,
  an allocator on memory objects, exit, the clock, the assertion handler), the build package building
  `src/apps`, `src/services` and `src/drivers` as PIE executables carried as boot modules, and the
  startup block's first version (ABI version, `CpuFeatures`, startup grants).
- **6b, the kernel starts the root task:** the shared loader, the root task's process, stack and startup
  block, everything `0012` hands it, and the debug-log capability. Boot tests start a real root task.
- **6c, root task and process manager:** `system_config`, budgets split, the process manager (and a stub
  supervisor) started from boot modules, the early entropy source, and programs loaded for a requester that
  owns and pays for them. Boot tests check a program outlives the process manager.
- **6d, the start of `std`'s SlopOS port:** typed entry points from the startup block (`0044`) and the
  build's manifest and wiring checks, `std/os` (exit, time, random, launching programs), and the startup
  code's ABI version check. The user-mode boot tests move out of the kernel into programs of their own.

## Alternatives considered
- **A prelinked root task**, copied in at a fixed address: keeps ELF parsing out of the kernel, but gives
  the root task no ASLR and adds a second program format.
- **Output only through channels**: no new system call, but nothing could print before M7, so tests would
  report through exit codes and shared memory.
- **A hard-coded list of services** for M6, with `system_config` waiting for M7: less now, but the root
  task's start would be written twice.
- **RDRAND in each loader**: simpler, but specific to x86 and around the seed the system is designed on.

## Consequences
- The kernel parses ELF for exactly one file; a bug there is in the TCB, so the loader is unit-tested over
  buffers like the frame allocator.
- The debug-log capability joins the kernel's objects (`0034`) and the syscall table; whether it outlives
  M7's console is decided then.
- Each stage gets an "as built" record, as M5's did.
