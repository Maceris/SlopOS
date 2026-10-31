# 0130: Pc, Per-Connection Loans and Storage Requests by Priority, as Built

Status: accepted
Date: 2026-10-31
Related: `0127` (Perf's stages), `0037` (scheduling and lending), `0040` (protocols' lending), `0089` (the volume
server), `../design/scheduling.md` §4, `../design/lessons.md` §9.1

## Context
`0127`, with the owner: `0037`'s level-1 loan built in the storage servers, which queue requests by the loan's
priority, so a background writer doesn't stall an interactive client's reads (Linux's bug 12309). Nothing could bind a
server's thread to a budget its client lent, and processes don't hold their own CPU budget's handle.

## Decision
Two choices the owner left to the build, made here (with the owner's go-ahead to proceed):
- **The kernel's call**: `thread_use_cpu_budget(budget)`, the calling thread on a budget it holds with
  `RIGHT_CPU_BUDGET_BIND` from now on, or on its process's again with `NO_HANDLE`; what it ran until then charged to the
  budget it was on (ABI 12). A thread on a budget that's destroyed runs on its parent, as every thread on it does.
- **Who lends**: whoever wires the connection, from the client's own budget, as the client holds no handle to it. The
  supervisor lends each service it opens a directory of the system volume for (the bundle store, the config store,
  the update service) that service's budget, which the scheduler service gives it.

And:
- **The protocol**: `std`'s `dir` gains `Lend(CpuBudget)`, answered `Done`, or `Unsupported` by a server that takes no
  loans (the FAT server). What's opened through a lent connection has a copy of its loan.
- **The volume server** serves its clients' requests one at a time, always from the connection whose loan has the
  highest priority of those with one waiting, ties taken in turn from the one after the last served, running on that
  loan while it serves it. The storage manager's and the links' connections are drained as before. A connection
  without a loan is served at priority 0, after every loan. The container service, whose one client per volume is a
  volume server, isn't changed.
- **Tests**: on a boot disk on one CPU, a connection lent the console's budget (priority 200) and six lent hello's (the
  default's, 100), each with a backlog behind a change and a Sync; the high one's two requests are answered ahead of
  all of it. With priorities ignored, taking connections in turn, six of the backlog are answered first, and the test
  fails, which was checked.

## Alternatives considered
- **A loan per request** (`0037`'s level 2): more messages for the same effect on storage, whose work is the
  connection's.
- **The client lending itself**, given its budget's handle at launch: every program would hold a handle to its budget
  for this one use; the supervisor holds them already.

## Consequences
- Bundles, configuration and updates are read and written at their services' priorities; a background writer's
  backlog waits behind them.
- Serving one request at a time costs: on AArch64, `file_create_sync` (not held to its baseline) went from about 441 to
  605 million instructions, the scan for the highest priority and two calls per request. A scan of only the connections
  with something waiting, from the port's packets, would take most of that back.
- Programs that open files through the storage manager's grants aren't lent anything yet; installations' `AppData`
  (`0117`) and M10's sessions are where that's wired next.
