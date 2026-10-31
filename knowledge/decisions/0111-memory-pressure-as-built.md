# 0111: 9c4, Memory Pressure, as Built

Status: accepted
Date: 2026-10-30
Related: `0107` (9c's plan), `0097` (memory pressure), `0094` (paged memory, the bundle store), `0011` (no
overcommit), `0052` (ports), `../design/lessons.md` §9.2

## Context
`0097` gave memory budgets a pressure signal, raised at a threshold the holder sets and bound to a port, and pager-backed
memory clean pages it can give back under pressure, with the pager choosing which. But every memory object, paged
memory too, was charged its whole size when it was made, and budgets never overcommit (`0011`). Giving a page back would
free a frame and no budget, so pressure on a budget couldn't be relieved by it.

## Decision
- **Paged memory is charged a page at a time** (with the project's owner): its page array when it's made, then each
  page as its pager supplies it. A supply the budget can't take fails with `BudgetExceeded`. A page given back returns
  its charge. A pager's budget then holds what it keeps in memory, and pressure on it means something.
- **The pager chooses, by a clock over accessed bits** (with the owner):
  - `memory_evict(memory, offset)` gives a supplied page back. It's taken out of the page array first, so the next
    touch waits for the pager again. It's unmapped from every space that maps it, through windows too, with each
    space's entry cleared under the locks. Once every CPU has flushed it (a shootdown per space, with no lock held), it's
    freed and uncharged.
  - A page more than `MAX_EVICT_SPACES` (16) spaces map is refused as `MappedWidely` and left alone; a page so widely
    shared is no cache to shrink. `NotSupplied` refuses a page that isn't there.
  - `memory_page_accessed(memory, offset)` says whether any mapping touched the page since it last asked, and clears
    the marks (`take_accessed`, new in the arch interface). It doesn't flush, so a CPU still holding the entry can touch
    the page unmarked, which only makes it look colder.
  - x86-64 keeps the accessed bit in hardware. On AArch64, the kernel turns on `TCR_EL1.HA` where `FEAT_HAFDBS` is
    there (a new `CpuFeature`). Without it, every page reads untouched, and the clock is oldest first.
  - CLOCK-Pro or ARC, as `0097` suggests, come later, when there's something to measure them with.
- **The pressure signal**: `memory_budget_set_threshold(budget, bytes)` (`RIGHT_BUDGET_CHARGE`, 0 for none), and
  `port_bind` on a budget for `SIGNAL_PRESSURE` by whoever may charge it. It's raised once what the budget has charged
  reaches the threshold, after the budget's lock is let go. It's raised again only once the budget has fallen below the
  threshold and reached it again, and at once if it's reached when the threshold is set. The packet's detail is what's
  charged.
- **The bundle store gives its pages back**:
  - Its pages are a cache its budget pays for. It sets its threshold at three quarters of its limit, or at what
    `CacheLimit` asks past what its other charges are.
  - Under pressure, or when a supply is refused, it runs a clock over the pages it has supplied. A page touched since
    the hand last passed it is passed, and one that wasn't is given back, until it's under twelve sixteenths of the
    threshold. Twice round at most, so a cache of nothing but touched pages still shrinks.
  - `Evictions` reports how many pages it has given back.
- **ABI v11**: the three calls go at the end of the table, `SIGNAL_PRESSURE` is bit 5, and `NotSupplied` and
  `MappedWidely` are new `MemoryError`s. `docs/specs/system_calls.md` lists them, and the two calls of `0099` it lacked.
- **Tests**:
  - `test_pager`: pages are charged as they're supplied; a touch is reported once; pressure is raised as a supply
    reaches the threshold; a page given back is uncharged, refused when given back again, and supplied again when
    read; a page never supplied is refused.
  - `test_store`: hello's program, read whole twice with only 64 KiB of pages kept, is given back and read again as it
    goes.

## Alternatives considered
- **Whole-size charging, kept**: giving pages back would only free frames for the machine as a whole, with nothing for
  a budget's pressure to relieve.
- **Oldest first, without accessed bits**: less kernel work, but hot pages go as readily as cold ones.
- **The kernel choosing**: against `0097`'s "the pager decides which".

## Consequences
- The session manager asking idle installations to save and stop under pressure is 10c's (`0097`).
- Other caches, a volume server's, can watch their budgets the same way when they have something to give back.
- 9c5 next: the Perf baselines and R4's storage faults.
