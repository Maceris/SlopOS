# 0054: Memory Objects and Budgets as Built

Status: accepted
Date: 2026-10-23
Related: `0011` (resource budgets), `0010` (child memory objects), `0008` and `0051` (objects), `0053`
(channels, whose consequence about charging this settles), `../design/kernel.md` §2, `../roadmap.md` M5

## Context
M5's fourth stage, first part (4a): memory budgets and memory objects. `0011` decided budgets charged per
creation, following ownership, but left open which budget pays, what an object costs, and what closing a
budget does. Nothing was charged until now, so a process could exhaust kernel memory.

## Decision
Chosen with the project's owner:
- **A memory object is charged its whole size when it's made, and filled lazily**: frames come zeroed on
  first touch, through the page-fault handler. Budgets never overcommit, so a touch fails only if the
  machine is out of frames. A fault outside committed memory destroys the thread until fault packets come
  with process control.
- **Everything is charged** (`0011` in full): objects' slots and what they hold, handle-table pages, page
  tables, port bindings, channel cores and rings, handle batches.
- **Creation calls take the budget that pays** (`ProcessCreate(budget)`, `PortCreate(budget)`,
  `ChannelCreate(budget, ring)`, `ThreadCreate(budget, space, ...)`, `MemoryCreate(budget, size)`), with
  `RIGHT_BUDGET_CHARGE`, so a server can make a client pay. **A process also has a budget**, the one
  `ProcessCreate` was given: its handle-table pages are charged there, and owning handles it takes move
  their objects' charges there.
- **Closing a child budget moves its charges to its parent**, which takes back the limit it had charged
  for it; nothing is destroyed.
- **Anonymous memory and budgets only, for now**: `MemoryBudgetCreate`, `MemoryBudgetInfo`, `MemoryCreate`,
  `MemoryMap`, `MemoryUnmap`. Child windows (`0010`) and device memory come with the IRQ and device work.
- **A kernel object costs its slot**, plus what it holds, fixed per kind; what it grows later is charged
  as it grows. Pool growth isn't charged separately: the slot charge covers it.

As built:
- **Each object's header names its budget and its charge**, and it's on its budget's list. Charging takes
  the budget's lock; closing a child or moving charges for a taken batch takes `kernel.budgets_lock`
  first, so no one waits on a second budget's lock while holding another's. Growth is charged to the
  object that grew; giving it back checks the object is still the one charged (its generation), since
  once it's destroyed its release gives back its whole charge, what it held included.
- **Handle-table entries** are paid for by the table's pages, charged to the process as the table grows,
  rather than per entry: a non-owning duplicate costs its share of a page.
- **Taking a batch moves all its owned objects' charges or none**: if the taker's budget can't take them,
  `ChannelTakeHandles` fails with `BudgetExceeded` and the batch stays (`0011`).
- **The root budget** is of the frames free once the CPUs are up and boot memory is back. It's the
  kernel's, and the budgets processes are given are split from it. Objects the kernel makes for itself are
  charged to no budget.
- **Memory objects** keep their frames in a two-level page array made with them (charged too), up to
  `MAX_MEMORY_SIZE`, 1 GiB. A mapping is on its space's list and its memory's; whoever claims it (unmapping
  it, closing the memory, destroying the space) takes it down: off the space's list first, under the
  space's lock that faults hold while they map, then unmapped, then off the memory's list. So no page of
  memory being destroyed is mapped after its mapping is gone, and its frames are freed after the grace
  period. `MemoryMap` and `ChannelMap` refuse ranges the other holds.
- **Protection**: read, write, execute; writable and executable together is refused (W^X). Execute
  implies read, as x86-64 can't do otherwise without protection keys.

## Alternatives considered
- **Committing frames when memory is made**: simpler faults, but every reservation costs physical memory
  at once; lazy filling with the full charge keeps the no-overcommit promise without it.
- **Charging only memory objects for now**: a process could still exhaust kernel memory with ports,
  bindings or handles.
- **Only the process's own budget**: a server would always pay for what it makes for its clients.
- **Destroying what a closed budget paid for**: budgets would become a second ownership tree, crossing
  the one processes form (`0008`).
- **Charging pool growth to whoever grew the pool** (`0011`'s pool paragraph): exact, but whoever grows a
  pool pays for slots others then use.

## Consequences
- Every creation call takes a budget handle; the generated ABI package (4d) keeps them first.
- The root budget promises the frames free at boot, but the kernel's own allocations (its heap, objects
  it makes for itself, the root's page arrays) come from the same frames, so a fully charged root budget
  can still meet `OutOfMemory`. Reserving the kernel's share is for when the root task exists (M6).
- A port's hash map of bindings and the kernel heap behind handle batches grow outside the fixed charges;
  their growth is bounded by what's charged (a binding per slot, 16 batches per end).
- `std`'s allocators for SlopOS (M6) make memory objects and map them; a pager and fault packets come with
  process control.
