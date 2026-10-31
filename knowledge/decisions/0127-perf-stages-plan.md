# 0127: The Plan for Perf's Stages

Status: accepted
Date: 2026-10-31
Related: `0097` (Perf), `0112` (the benchmarks), `0050` (ticks), `0048` (paging), `0037` (lending), `0011` (budgets),
`../design/lessons.md` §9.1, `../design/scheduling.md` §4

## Context
`0097` put three of Perf's stages between milestones, each planned as it starts: tickless idle (`0050` left idle CPUs
ticking), large pages for the direct map and large memory objects, and storage bandwidth scheduled by the lent budget
(Linux's bug 12309). They're done before M10 (`0123`). Found on reading the kernel: the direct map already maps the
largest pages alignment allows, 1 GiB and 2 MiB (`address_space.hsc`, `map_range`), and the timer is already armed
one-shot or by TSC deadline each time. Lending is declared in protocols (`0037`, `0040`) but no server binds a loaned
CPU budget yet.

## Decision
Chosen with the project's owner:
- **Large pages for anonymous memory objects of 2 MiB or more**: their frames taken as 2 MiB runs from the buddy
  allocator where it has them, falling back to 4 KiB frames, and mapped with 2 MiB pages where the address and the
  offset align. Paged objects stay 4 KiB, as eviction (`0111`) works a page at a time.
- **Storage bandwidth through per-connection loans**: `0037`'s level 1 built in the storage servers: a client lends a
  CPU budget when it connects, the server runs that connection's work on it, and queues its requests by the loan's
  priority, so a background copy's writeback doesn't stall an interactive client's reads.

Decided here:
- **Tickless idle**: a CPU with nothing to run arms its timer for the next thing it has to wake for (a timer of a
  port's, a budget's refill) and none otherwise, rather than ticking; a CPU running a budget ticks as before.
- **In three stages**, each with an as-built record, on both architectures, each with a benchmark or test beside
  `tools/perf_tests.py`'s: **Pa** tickless idle (ticks on an idle machine counted, near none); **Pb** large pages for
  anonymous objects (a 2 MiB object's TLB entries, or its page tables, counted); **Pc** per-connection loans and
  storage requests by priority (an interactive read's latency beside a background writer, held to a bound).

## Alternatives considered
- **Large paged objects**: the pager supplying and evicting 2 MiB at a time, a larger change to eviction for objects
  that are mostly programs, whose hot parts are small.
- **A per-connection I/O class** set by the supervisor: smaller, but a second notion of priority beside the budget's,
  and no CPU fairness for servers.

## Consequences
- `../roadmap.md`'s Perf gains the three stages; B follows them.
