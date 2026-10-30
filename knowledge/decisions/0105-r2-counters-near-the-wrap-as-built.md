# 0105: R2, Counters Near the Wrap, as Built

Status: accepted
Date: 2026-10-30
Related: `0096` (the plan for R), `0104` (R1), `0008` (generations), `0051` (handles), `0084` (edu_dma),
`../roadmap.md` *R*

## Context
`0096` planned R2: with `robustness=on`, every counter that can wrap starts close to its limit, as Linux's
`INITIAL_JIFFIES` does, and every boot test runs once more on that kernel. Each start is a constant next to its counter.

## Decision
- **Monotonic time starts at 2^63 nanoseconds** (`kernel/clock.hsc`, `MONOTONIC_START`), about 292 years: code that
  narrows a time to 32 bits or makes it signed fails at once. Decided with the project's owner, in place of `0096`'s
  start a few minutes before `u64` wraps: that would have made every deadline in the kernel, `std` and the services
  compare by difference, and `NO_DEADLINE` (the largest `u64`) indistinguishable from a time just short of the wrap.
  From 2^63, now plus any timeout still doesn't wrap. A deadline is turned back into counter ticks from where time
  starts (`ticks_at`); the hardware counter itself starts where it does.
- **Generations start a few uses before retirement**: a fresh handle entry's at `0xfffc` of its 16 bits
  (`HANDLE_GENERATION_START`), a fresh kernel object's at `0xfffffffc` (`OBJECT_GENERATION_START`), which a new slab
  writes into each of its objects (`SlabCache.fresh_offset`, `fresh_value`). Retiring a slot, which `0008` designed and
  nothing had run, runs in every test now; a retired object is no longer counted as in use (`slab.retire`), which the
  "objects left" check needed.
- **Address-space tags** are searched from 4 below the top of their range, round to 1 (`TAG_SEARCH_FROM`), so the
  last PCIDs and ASIDs are used.
- **DMA domains** offer their top 64 MiB first (`HIGH_DEVICE_BYTES`), as a free range from the start, to what can
  reach them; the bottom-up cursor stops below it. A device that reaches less, by the limit it asks with, gets low
  addresses as before.
- **Channel rings' indices** start 256 bytes before `u32` wraps (`RING_INDEX_START`): free-running, masked to the ring,
  and read and written only by the kernel, so they wrap within each ring's first few messages.
- **The timer heap** has no sequence numbers to start; its order is by deadline alone.
- **Every boot test runs on the robustness kernels** too, in `boot_tests.py --robustness`, before the sweeps. All pass,
  and the sweeps; a few runs timed out only while the normal suites ran beside them, and passed again on their own.
- **Found**: `edu_dma` asked for DMA memory with no limit, though QEMU's edu device addresses 28 bits; with a domain's
  high addresses it was given ones the device can't reach. It asks with its device's limit now (`EDU_DMA_LIMIT`).

## Alternatives considered
- **Time just before the wrap**, as `0096` had it: above.
- **Lowering where a slot retires** instead of starting near it: it would test a different number than the one used.
- **The image builder starting a container's transactions near their end**, which `0096` offered for slopfs's tests:
  its transaction and birth numbers are `u64`s counted once per commit, which no test comes near; left.

## Consequences
- A counter added later that can wrap gets a start beside it, as these have.
- R3 is next.
