# 0052: Ports, Blocking and Timers as Built

Status: accepted
Date: 2026-10-22
Related: `0035` (IPC and ports), `0009` (time through a syscall), `0051` (objects), `../design/ipc.md` §3,
`../roadmap.md` M5

## Context
M5's second stage builds `../design/ipc.md` §3's ports: bindings, timers, waking, and threads that block.
The sketch there left some calls and the mechanics open.

## Decision
- **A binding is made before anything is delivered to it**, so delivering never allocates. Bindings come
  from a type-stable pool, with a generation changed when they're unbound, found by key through a hash map
  per port (`std`'s, through the new fallible `map_try_put`). So far two kinds:
  - **wake bindings**, made with a new call, `PortBindWake(port, key)`, which the sketch's `port_wake`
    needs to stay allocation-free; `port_wake` ORs bits into their packet;
  - **timer bindings**, made or moved by `PortSetTimer(port, key, deadline)`, deadline in monotonic
    nanoseconds; one packet per setting.
  Channel signals, IRQs and process events become bindings as their objects arrive.
- **Ready bindings are taken oldest first; waiters are woken most recent first**, one per packet newly
  queued. A packet that's already queued takes a new event in without waking anyone.
- **`PortWait(port, packets, capacity, deadline)`** gives up to 64 packets, checks first that the thread
  can write where they'd go (else `BadBuffer`, losing nothing), and writes them through the address space's
  table and the direct map. With nothing to take it blocks: the thread saves its vector state, leaves its
  CPU, and waits on the port. Woken by a packet, its deadline or the port's destruction, it's made ready,
  and finishes its wait when it next runs, on whichever CPU: it takes what's there, or blocks again if
  another waiter took it first (a continuation, `0023`).
- **Timers are per CPU**: a binary heap of entries the things that time out keep themselves, so arming
  allocates only when a heap grows. A CPU's timer is programmed for its next tick or its earliest
  deadline, whichever is sooner, so deadlines fire on time rather than at ticks. An entry fires from the
  heap's lock, then checks what it's for (a binding's generation, a wait's sequence) before acting, so
  late firings do nothing. Slack, to coalesce timers, is taken and not used yet.
- **`ClockMonotonic`** gives the kernel's monotonic clock in nanoseconds, the time deadlines are in (`0009`).
- **Error tags are one numbering**: `PortError` reuses `HandleError`'s tags for the same meanings.

## Alternatives considered
- **`port_wake` on keys with no binding, queuing a new packet**: allocates on a notify, and lets a waker
  fill a port without bound.
- **Waking a waiter by writing its packets into its memory from the waking CPU**: the waking CPU would
  write into another address space at an arbitrary time, and a second waiter could still take nothing.
- **Firing timers at ticks only**: simpler, but a deadline would be up to 10 ms late, against
  `../design/scheduling.md`'s latency goal.

## Consequences
- A server binds once per connection and waits on one port; idle connections cost a binding each.
- Bindings aren't yet charged to a memory budget (M5, budgets).
