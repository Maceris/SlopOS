# 0037: Scheduling Policy in User Space, Budgets Lent per Connection

Status: accepted
Date: 2026-10-13
Related: `0011` (budgets), `0012`, `0023`, `0035`

## Context
`../design/scheduling.md` proposed where scheduling policy lives, the kernel's mechanism, and how
budgets are lent for calls between processes.

## Decision
- **A fixed kernel dispatcher, with parameters set from user space** (`../design/scheduling.md` §1).
  The kernel dispatches and enforces budgets on every CPU, and never waits on user space. A
  scheduler service holds the root CPU budget, splits it, and adjusts parameters on a slow
  timescale. If it crashes, the system keeps running on the last parameters.
- **Priority belongs to the budget, not the thread** (§2). Only `Demote` is implemented at first.
  `Throttle` (hard reservations) waits until something needs it.
- **The latency goal is soft real-time:** glitch-free audio, not proven deadlines.
- **Lending** (§4) is explicit, through budgets and handles. The default is **level 1, a
  per-connection loan**. Per-request loans and priced requests are options a protocol can choose.
  Servers may refuse connections or requests for their own reasons.

## Alternatives considered
See `../design/scheduling.md` §1: all policy in the kernel, every decision in user space
(scheduler activations), and verified policy code in the kernel (`sched_ext`).

## Consequences
- How a protocol type declares its lending level belongs with protocol tags and idempotence
  (`../open-questions.md`, *IPC and data*).
- CPU affinity for budgets, and the per-thread page shared with the kernel, stay open
  (`../design/scheduling.md` §5).
