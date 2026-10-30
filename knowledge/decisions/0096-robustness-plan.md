# 0096: The Plan for Robustness Testing (R)

Status: accepted
Date: 2026-10-29
Related: `0005` (every error path handled), `0051` (generations), `0053` (lock order), `0054` (budgets), `0069`
(tests as programs, leaks checked through budgets), `0088` (the crash-state tester and fuzzer), `../design/lessons.md`
§9.5, `../roadmap.md` *R*

## Context
`0005` asks for every error path to be handled, and the code does handle them, but most are never run: a frame
allocation that fails halfway through making a process, a budget charge refused while a channel's rings are half
mapped, an IOVA allocator at the end of its range. Other kernels found these bugs late and the hard way: Linux's
`failslab` and syzkaller for error paths, Windows 95/98's hang at 49.7 days and the Boeing 787's power-down at 248 for
counters that wrap, `lockdep` for lock order inversions, fsyncgate (PostgreSQL, 2018) for a write error reported once
and then lost. `../design/lessons.md` §9.5 proposed a track, R, to run these tests from now on rather than after
something breaks. The catch-up (`../roadmap.md`) is under way and 9c is next; R's first stages test what's already
built, so they're cheapest now.

Hemera's build packages can give a target settings its code reads at compile time (`compiler.target_setting`,
`base/compiler/build.hsc`), so test-only machinery can be compiled into test builds and left out of every other.

## Decision
Chosen with the project's owner:
- **R is a track of its own, run between milestones' stages**, as A and D were, in six stages, each with an
  as-built record, on both architectures. R1 to R3 run after the catch-up and before 9c; R4 with 9c; R5 after 10a;
  R6 when Hemera can support it.
- **Test machinery is compiled in by a build setting, never present otherwise.** The build package gains
  `robustness=on`, which the kernel and programs read with `target_setting`; without it, every hook below is a
  compile-time `false` and its code isn't generated. Boot tests build one extra kernel with it, as they do for
  `stack_check=morestack`, and choose what it does through the command line. A release kernel can't be told to fail
  allocations, whatever its command line says (`lessons.md` §1.5).
- **The stages:**
  - **R1, fault injection.** Named **failure points** at every place the kernel can fail for want of a resource:
    frame allocation (`frames.allocate`, `allocate_below`, the per-CPU caches' refills), slab and heap allocation, a
    memory budget's `charge_new` and `charge_more`, a handle table's growth, a timer heap's growth, IOVA allocation.
    With `robustness=on`, a command line option `fail=<point>:<n>` (or `fail=any:<n>`) makes the *n*th pass through
    that point fail as if the resource were exhausted. `boot_tests.py` sweeps *n* for chosen boot tests, every value
    up to the number of passes a clean run makes (counted by the same hooks, `fail=count`), and each run must end in
    the test's expected success or a reported, typed error, never an assertion, a fault or a hang, and with no
    leak (`0069`'s budget check and the kernel's end-of-run report). Sweeps that would take too long take every value
    up to a bound and a stride beyond it. Hosted, `std` gains a **failing allocator** (an `Allocator` wrapping another
    and failing the *n*th call), and the unit tests of `frames`, `slab`, `slopfs`, `fat`, `gpt` and the ELF loader
    sweep it the same way. Programs get the same through `base`'s SlopOS page heap, for the services' own tests.
  - **R2, starting near the wrap.** With `robustness=on`, every counter that can wrap starts close to its limit, as
    Linux's `INITIAL_JIFFIES` starts the jiffies five minutes before wrapping: the monotonic clock's offset (so
    deadlines straddle the top of `u64`), object generations (`0051`) and handle generations a few uses before the
    point where an entry is retired, PCID and ASID tags at the end of their range, each DMA domain's IOVAs near its top,
    channel ring indices, and the timer heap's sequence numbers. Each start is a constant the kernel reads in one
    place, named next to the counter. Every boot test then runs once more on the R kernel. Hosted, the image builder
    can start a container's transaction numbers and birth times near their ends, for slopfs's tests.
  - **R3, lock order.** Every kernel lock gets a **rank**, from `0053`'s order (core, then port, then run queue) and
    the orders written in comments elsewhere (`kernel.budgets_lock` before a budget's lock); `std`'s `concurrency`
    gains a ranked spin lock, general-purpose (`CLAUDE.md` rule 3), whose acquisition, with `robustness=on`, checks
    the CPU's held ranks and stops the kernel on an inversion or on a lock taken with interrupts in the wrong state.
    The ranks are a table in one file, so the order is written once. A house-rule check (`0029`) that every kernel
    `SpinLock` is ranked follows if Hemera's reflection can find struct fields of a type.
  - **R4, storage faults** (with 9c). A **faulty block** connection: a partition server option, under `robustness`,
    that fails chosen reads and writes and tears chosen writes; slopfs and the FAT server must report a failed write to
    every `Sync` after it on the affected files, never only the first (fsyncgate), and never return data a failed write
    should have changed. The crash-state tester (`0088`) gains failed writes beside torn ones.
  - **R5, chaos** (after 10a, when there's something to watch). A boot test that, for a configured time, kills a
    random service or driver from those the supervisor restarts, checks the system answers again within a deadline,
    and at the end checks every budget is back where it started.
  - **R6, schedule exploration** (when Hemera can support it). Hosted tests of the lock-free code (the frame caches,
    slab magazines, the shootdown's handshake) under a model checker that chooses the interleaving of every atomic
    operation, as `loom` and CHESS do. It needs Hemera's atomics to be interceptable in a test build, proposed to Hemera
    when R6 starts.
- **Bugs found are fixed in the stage that finds them**, each with the failing case kept as a regular test, and
  recorded in the stage's as-built record.

## Alternatives considered
- **Fault injection always compiled in, off by default**: one kernel to test, but every release kernel carries the
  hooks and a command line that can turn them on.
- **Random failures (a probability) instead of the *n*th**: finds more combinations per run, but a failure doesn't
  reproduce from its command line alone; the *n*th pass is deterministic, and a seeded random mode can come later.
- **Robustness as part of H**: H comes after M11, by which time every error path written since M5 has waited a year
  to run once.
- **Kernel-only first**: the services hold most of the error paths written since M7, and the hosted packages are the
  cheapest to sweep; doing both in R1 costs one `std` allocator.
- **`lockdep`'s inference of the order from what runs**: finds orders nobody wrote down, but SlopOS's are written down
  (`0053`), and checking a declared rank is simpler and states the intent.

## Consequences
- The build package gains `robustness`; `boot_tests.py` gains the R kernel and the sweeps; `std` gains a failing
  allocator (R1) and a ranked spin lock (R3), logged in `../hemera-feedback.md`.
- Every kernel resource that can run out gets a named failure point, so adding one later means adding its point too:
  a convention for `../conventions.md`.
- Sweeps make the boot tests slower; they run in their own script (`boot_tests.py --robustness`), not on every change.
- 9c starts after R3; `../roadmap.md` places R.
