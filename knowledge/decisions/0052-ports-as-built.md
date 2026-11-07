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

## Found later: a binding's port read as half an address (2026-11-06)
A full boot-test run once failed "rolls a staged generation back when it boots degraded, and boots the one before",
which passed booted again alone. Its second boot faulted writing to `0xffff813d00000070`, 0x70 past that boot's direct
map base, which is physical address 0. The write was in `destroy_object`, at `kernel+0x49a0c`: `destroy_channel`
letting go of an end's bindings, `drop_end_binding` calling `lock_bound_port`, which took the lock at 0x70 in what the
binding's port read as.
- **What was wrong**: `lock_bound_port` reads a binding's port without a lock, through a binding an end kept after
  its port freed it, counting on the slot to read as the old port, 0 or the new one. `new_binding` made the slot anew
  with `binding^ = Binding.{}`, which compiles to the kernel's `memset`, and that writes a byte at a time, lowest
  first. Partway, the port's low bytes were zero and its high ones still the old port's. The direct map's base has its
  low 32 bits clear and ports are below 4 GiB, so with four bytes zeroed the port read as the direct map's base, and
  its lock as 0x70 on, where nothing is mapped. With fewer bytes zeroed it would have read as RAM that isn't a port,
  and locked that. Bindings are freed and made again all the time when the root task ends and every process is torn
  down while the other CPU still runs, which is when the run hit it. The generation, zeroed and written back, could
  likewise be read part zeroed, and so taken for an older generation.
- **What it does now**: `new_binding` sets the port to 0 in one atomic store and fences, zeroes the rest of the slot
  but its generation (`zero_but_generation`), and stores the new port in one atomic store at the end. `free_binding`
  changes the generation in one atomic store. A reader sees the old port, 0 or the new one, and a generation that only
  goes up. `new_object` zeroes a slot around its generation the same way, since `is_live` reads it through stale
  handles (`0051`).
- **Checked by `test_binding_reuse`** (`binding_reuse_test.hsc`): the boot CPU unbinds one binding and binds it again
  on two ports in turn 20,000 times, while the other CPUs read its port and generation without a lock. With
  `new_binding` as it was, the x86-64 boot failed both times it ran, reading that boot's direct map base as the
  port, as the fault had. The AArch64 boot failed once among the other tests and passed alone, so it's the weaker
  check.
