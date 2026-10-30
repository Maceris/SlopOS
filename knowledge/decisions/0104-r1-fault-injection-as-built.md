# 0104: R1, Fault Injection, as Built

Status: accepted
Date: 2026-10-30
Related: `0096` (the plan for R), `0005` (every error path handled), `0056` (process control), `0069` (tests as
programs), `0089` (slopfs apart), `0094` (the bundle store), `../roadmap.md` *R*

## Context
`0096` planned R1: named failure points in the kernel that `fail=` makes fail, swept by `boot_tests.py`, and a failing
allocator for the hosted tests. Hemera has no mutable globals, so where the injection state lives had to be chosen,
and the sweeps found what they're for: error paths that had never run.

## Decision
- **The machinery** (`src/robustness`): `ON`, from the build setting `robustness=on`, and without it every `#if ON`
  leaves its code out. Seven failure points, `robustness.Point`: `frame` (`frames.allocate`, `allocate_below`,
  `take_frame`), `slab` (`slab.allocate`, `take`), `heap` (the kernel heap's allocator function), `budget`
  (`charge_new`, `charge_more`), `handles` (a handle table's growth), `timers` (a timer heap's growth) and `iova`
  (`take_device_addresses`). Each pass calls `robustness.fails`, which counts it and says whether it fails.
- **Where the state is**: in the frame allocator, `FrameAllocator.faults`, since everything that can run out reaches it:
  `frames` and the slab through the allocator they're given, the kernel through `kernel.frames` (`kernel/faults.hsc`'s
  `fails`, which needs this CPU's state and is false before it). The command line's `fail=<point>:<n>`, `fail=any:<n>`
  or `fail=count` is parsed only in a robustness kernel, and set on the allocator as it's made, so every pass counts.
  A failing pass says so (`faults: failing frame pass 193`) and the kernel logs where from (`on_fail`); when the kernel
  stops it reports every point's passes (`faults: passes ...`).
- **The boot sweeps** (`boot_tests.py --robustness`): robustness kernels for both architectures; for each of
  `SWEEP_TESTS` (the kernel alone, `test_channels`, `test_memory`, `test_threads`, `test_control`, `test_exits`), a
  counting run, then a run failing each pass up to 48 and about 48 more spread over the rest, eight at once. A run may
  halt, stop for want of memory, or end its root task with nothing of anyone else's left (`objects left`); never fault,
  fail an assertion or hang. A robustness kernel whose root task didn't start checks what's left when it halts, a
  grace period later (`ROOT_END_TICKS`), as for a root task that ended: destroying its process takes one per step. The
  last sweeps: every run of all twelve (six tests, two architectures) passed, 1195 runs.
- **Test programs get a deadline**: the root task's `test_deadline=<seconds>` kills a test program that hasn't ended by
  then and ends with 26. A test whose own setup an injected failure broke waits for good otherwise; the sweeps give it
  20 seconds, so the kernel's cleanup after a kill is swept too.
- **The hosted sweeps** (`unit_tests.py --robustness`): `std`'s `memory.FailingAllocator` (Hemera, this stage) wraps
  `context.allocator` in each swept test's `main` (`src/robustness/hosted`, `SLOPOS_FAIL`=`count`, `alloc:<n>` or
  `point:<n>`), and `frames_test` and `slab_test` give their allocator's failure points the same. A run must end with a
  check's code, not crash or hang; one that ends with 0, finishing despite the failure, must leave no more blocks
  allocated than the counting run (one stopped at a failed check skipped its own cleanup, so its blocks say nothing). An
  out-of-memory assertion in a test's own code (a `*_test.hsc` file) is the harness, and allowed; anywhere else it's a
  bug. A failed allocation says where it was asked for (`FailingAllocator.failed_at`).
- **Decided with the project's owner**:
  - A process whose last thread is destroyed, by an unresolved fault or any way but `process_exit`, ends as killed,
    and its watchers learn it (`Process.live_threads`, `end_process_if_last`). `0056` left the process with no threads,
    which nobody watching it ever heard of.
  - `base`'s dynamic arrays gain `array_try_reserve`, `array_try_add` and `array_try_copy`, which give the error and
    leave the array as it was, as `std`'s `map_try_put` does; slopfs and the services use them where running out must
    be handled.
- **What the sweeps found, fixed**:
  - The kernel faulted when the root memory budget, the platform capability or the root CPU budget couldn't be made at
    boot: their callers used 0. It stops for want of memory now, and `out_of_memory` stops every CPU once there's a
    kernel.
  - A process's last thread destroyed by a fault left the process, and whoever waited for it, hanging (above).
  - Failed `port_bind`s were discarded where something then waited for what they'd bind: the root task's watches (it
    ends with 14 or 15 now), the partition server's and the container service's connections (refused, with what they
    held given back; the partition server also leaked its driver connection on two other failures), the supervisor's
    (said).
  - The bundle store's collection deleted objects still reachable whenever it couldn't read a root, a pin, a bundle or
    the pins' directory, for any reason, not only memory: `mark` says whether it read everything through, and a
    collection that can't stops before deleting anything.
  - slopfs asserted when memory ran out, through `runtime.new` and base's arrays: every node and buffer comes from
    `make` now, giving `Error.OutOfMemory` (and the files protocol's `NoMemory`), each taken before what it's for changes
    anything; a node is made before it's placed, a copy is kept among the dirty nodes before the old one is given back,
    `leaf_compact` packs in place with no memory at all, and the space's lists get their room (`space_room`) before a
    change, so recording one never stops halfway. A release that can't be recorded for want of memory leaves its blocks
    allocated: lost until the container is checked, never given out while something may still name them. `verify`
    says `OutOfMemory` rather than calling a walk it couldn't finish a leak.
  - The events service reserves what a ring's entries can add before reading them; without it, they wait in the ring,
    whose drops are counted as ever.
  - Every service and driver ends with 99 when there's no memory for its own state, rather than asserting.
  - A root task that couldn't start left its process and everything made for it, and the firmware tables kept for it:
    the process is destroyed now, which destroys the rest, and the tables with it.
  - The frames and slab tests used allocations they hadn't checked.

## Alternatives considered
- **A pointer to the state in each allocator**: the frame allocator is the one every point reaches already.
- **Failing a probability of passes**: `0096` chose the nth pass, which reproduces from the command line, though with
  two CPUs which pass is the nth can vary between runs.
- **Allowing out-of-memory assertions everywhere**: they're what `0005` rules out, a service ending where it could say
  no.

## Consequences
- `conventions.md`: a resource that can run out gets a failure point; a call's error isn't discarded where something
  then waits for it.
- Sweeps take about half an hour each, so they run on their own (`--robustness`), not with every change.
- R2 is next.
