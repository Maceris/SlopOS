# 0011: Resource Budgets: Separate Memory and CPU Budget Objects, Charges Follow Ownership

Status: accepted
Date: 2026-10-02

## Context
`0008` stores kernel objects in global typed pools, and rejected seL4's retype-from-Untyped
model, deferring kernel memory accounting to "other ways". Principle 4 (everything is owned)
and `../problems-and-directions.md` §11 (budgets, not overcommit) need every kernel
allocation to be charged to someone, so a process can't exhaust kernel memory and killing
an owner returns its memory. `../design/threads.md` already charges a thread's control
block to a caller-supplied memory capability.

## Decision
**Two budget object types, kept separate.**
- **Memory budget:** a quota of physical memory. User memory (frames backing memory
  objects) and kernel memory (pool slots, handle-table entries, page tables) are charged
  to it.
- **CPU budget:** a scheduling context (share or period/time, policy to be decided). Most
  programs never touch one. They run on a CPU budget shared from their launcher or session.
  Dedicated CPU budgets are for services, drivers and timing-sensitive work.
- Budgets are kernel objects owned in the ownership tree (`0008`). A budget can be split
  into child budgets, which is how a launcher gives a new process part of its own.

**Global pools, charged per creation.**
- Kernel object pools are global, per type (`0008`). Creating an object charges the
  creator's memory budget a fixed per-type cost, including the handle-table entry. When a
  pool needs more slots, it takes physical memory charged to the budget that caused the
  growth.
- Destroying an object returns its charge. The pool's slot returns to the free list after
  the quiescent period (`0008`).

**Charges follow ownership, and receiving is explicit and fallible.**
- When an owning handle is transferred, the object's charge moves from the sender's
  memory budget to the receiver's.
- While a message carrying an owning handle is in transit, the object stays owned by and
  charged to the sender. If the sender dies first, the object is destroyed, which is
  principle 4 unchanged.
- A process receives a message explicitly. If its budget can't absorb the owned objects in
  the message, the receive fails with `BudgetExceeded` and the message stays queued. The
  receiver can then grow its budget and retry, or discard the message. Discarding destroys
  the owned objects it carried.
- Non-owning handles carry no object charge. Only the receiver's new handle-table entry
  is charged.

## Alternatives considered
- **seL4 retype / Genode donation** (the caller passes the memory for each kernel object):
  exact, but every creation call grows a memory argument and user space manages
  kernel-object memory by hand. Charging a budget gives the same accounting with less ceremony.
- **One combined budget object:** simpler, but CPU budgets matter only to a few programs, and
  seL4 MCS shows scheduling contexts are useful to pass along separately (a client lending
  its CPU time to a server for a call).
- **Charge stays with the creator after a transfer:** a process could then hold objects
  billed to a budget whose owner died, which blurs principle 4.

## Consequences
- Every creation syscall can fail with `BudgetExceeded`, and so can a receive.
- `../design/threads.md`'s `memory: MemoryCap` argument to `thread_create` becomes the
  memory budget handle. Whether thread creation also takes a CPU budget, or inherits one,
  is decided with the scheduler.
- A server that creates objects for clients pays for them unless it makes clients pay.
  Typically the client supplies a memory budget or sends the object with ownership. This
  matters for the per-connection objects in `0010`.
- Pool growth must be designed so that a budget-exhausted process can't push a pool into
  a state where other processes' creations fail.
