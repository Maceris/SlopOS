# 0145: Rings in a Dying Space, and Frames Given Back Twice

Status: accepted
Date: 2026-11-02
Related: `0144` (the faults the parallel boot tests found first), `0008` (type-stable objects), `0128` (quiescent
points), `../../tools/boot_tests.py`

## Context
Booting the tests 8 at once found a kernel page fault on x86 once in 149 tests: `destroy_object`, destroying a
channel end, locked a "port" at `0xffff810000000070`. That value is a handle table entry's tag (`TAG_VALID`, generation
0xffff): the end's core, which isn't type-stable, held a handle table page's bytes. Each core is referenced once by
each end and once by each mapping of its rings, and the paths that let go of those references balance; so the core's
page was most likely handed out twice, by a frame given back twice. It didn't happen again in about 2,100 boots since,
with checks for it, so its cause isn't known. Looking for it found one way a frame could be freed twice, and that the
frame allocator's per-CPU caches couldn't catch one.

## Decision
- **A ring in a space being destroyed** is only taken off the space's list by `unmap_ring`, never unmapped page by
  page: the space's tables are released whole, without its lock, once a grace period has passed, which the CPU
  destroying the ring's end may have passed through already, so unmapping could free a table the release frees too.
  Whichever of the two takes the ring off the list, under the space's lock, lets go of the core.
- **Cached frames have a state of their own** (`STATE_CACHED`): giving a frame to a CPU's cache needs it allocated,
  taking one needs it cached, and the allocator's `free` already needs it allocated, so a frame given back twice, to a
  cache or the allocator, fails an assertion where the second give is, with its stack trace, rather than being handed
  out twice. A byte written per frame given or taken.
- **The boot tests** count a test that faulted among the others as failed, even if it passes alone (`0144`'s runner).
- `test_pager`'s pager counts a page before it supplies it, which wakes the program, rather than after.

## Alternatives considered
- **Making cores type-stable**: a core's memory would only ever hold cores, hiding a double free rather than finding it.
- **Logging every core freed**: kept for a scratch kernel only; too much output for every boot.

## Consequences
- The fault, if it comes back, is likelier to stop at an assertion naming who gave a frame back twice.
- Timing-sensitive tests seen to fail under load, reported FLAKY and passing alone: lending's priority, the console's
  echo after a driver restart, and `test_pool`'s spread over CPUs.
