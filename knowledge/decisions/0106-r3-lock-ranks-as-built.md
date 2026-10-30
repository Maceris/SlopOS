# 0106: R3, Lock Ranks, as Built

Status: accepted
Date: 2026-10-30
Related: `0096` (the plan for R), `0053` (lock order), `0029` (checks), `0104`, `0105`, `../roadmap.md` *R*

## Context
`0096` planned R3: every kernel lock gets a rank, from `0053`'s order and the orders written in comments, `std` gains a
ranked spin lock, and with `robustness=on` each acquisition is checked against the CPU's held ranks and the interrupt
state, the kernel stopping on either. Hemera has no overloading, so the ranked lock is its own set of functions.

## Decision
- **`std`** (Hemera, this stage): `concurrency.HeldRanks`, one per CPU or thread, and `lock_ranked`, `lock_ranked_after`
  and `unlock_ranked` over the existing `SpinLock`. They take the lock either way and say whether it was in order: above
  every rank held, or, after, of the same rank at a higher address; and whether a lock given back was held. What to do
  about one out of order is the caller's.
- **The kernel's ranks are one table** (`kernel/locks.hsc`, `LockRank`), lowest taken first, each with the order it
  comes from. Every kernel lock is taken with `lock_at` or `lock_after` and given back with `unlock_at`, naming its
  rank; with `robustness=on` they check the order against `PerCpu.held_ranks` and that interrupts are off (every kernel
  lock is taken with them off: `arch.interrupts_enabled`, new on both architectures), and on a broken order the kernel
  says which lock, what it holds, and where from, and stops (`AssertionFailed`). Without it, they're `std`'s `lock` and
  `unlock`. The frame allocator's, the slab caches' and the architectures' locks are leaves, taking nothing but a slab's
  then the frame allocator's, in other packages, and are outside the table.
- **A house-rule check** (`check_kernel_locks`): no kernel function but the three wrappers calls `std`'s `lock` or
  `unlock`. `0096` hoped to check that every `SpinLock` field is ranked, which reflection can't do; this checks every
  acquisition instead, which is what the ranks are for. Shown to fire on one.
- **Two budgets' locks are taken by address** (`lock_budgets`): `move_charges` and `destroy_memory_budget` held both in
  whatever order came, safe only because `budgets_lock` was held, which the check can't see; by address, it needn't.
- **What the checks found, the ranks set from it**:
  - A run queue's lock is held while a `CpuTime`'s is taken, as the scheduler picks (`pick`, `level_of`): a run queue
    comes before a `CpuTime`, not after as first written.
  - A user fault on paged memory signals its pager's port with the address space's lock held; a DMA fault raises a
    device's watchers with `devices_lock` held, and watchers signal ports: so a space, then the devices list, then
    watchers, then a port.
  - `fiber_test` and `test_segments` masked interrupts and then unmasked them, whatever they'd found: boot, which runs
    with them masked, ran on with them unmasked, and took its locks so. They put back what they found now.
- **Every boot test and sweep runs with the checks on**, in `boot_tests.py --robustness`, on both architectures: all
  pass, as do the normal suites (7 unit tests, 103 boot tests).

## Alternatives considered
- **A `RankedSpinLock` type with its rank in it**: kernel objects are zeroed as they're made, so every one would need
  its rank set at each creation; naming the rank where the lock is taken needs nothing set, and reads as the order.
- **lockdep's order inferred from what runs**: `0096` chose declared ranks; the first runs showed where the declared
  order was wrong, and the table says why each is where it is.

## Consequences
- A new kernel lock gets a rank in `locks.hsc`, and the check holds every acquisition to it.
- R1 to R3 are done; 9c is next.
