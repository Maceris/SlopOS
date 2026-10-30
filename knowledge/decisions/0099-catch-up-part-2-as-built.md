# 0099: Catch-up Part 2, as Built

Status: accepted
Date: 2026-10-30
Related: `0037` (CPU budgets), `0050` (the kernel's budget test), `0055` (IRQ affinity), `0069` (test programs),
`0073` (MSIs), `0093` (the events service), `0098` (catch-up part 1), `../roadmap.md` *Catch-up*

## Context
The roadmap's catch-up part 2: what M9 planned and didn't build. Chosen with the project's owner: a CPU budget's CPUs
come from `system_config`, which the scheduler service sets, and an IRQ goes to a CPU of its driver's budget's.
Building it found two scheduler bugs, a lost-records gap in `0098`'s rings, a lost wake in port bindings, and a bug
in `std`'s schema renderer.

## Decision
- **`test_budgets` is a program** (`0069`): the kernel's budget test (`0050`, the `test_budgets` command-line word and
  its timer hook) is gone. The program launches two copies of itself, a pair of threads on a budget of 30 ms every
  100 ms at priority 10, and a rival on 60 ms at priority 5, each given a launch-only duplicate of its budget, and a
  page to count in; on one CPU, the pair counts 20% to 55% of the counts, split 35% to 65% between its two.
- **Two scheduler bugs** it found:
  - A budget's threads overran it by up to a tick each, and `charge` dropped the overrun, so a shared budget got more
    than its share. `CpuTime` keeps the overrun as `debt`, which refills pay first.
  - A thread queued at its budget's level while another of the budget's threads spent it still ran at that level.
    `pick` checks a dequeued thread's level again, and queues it where it belongs if that changed.
- **Every service the supervisor starts logs through `base`'s logger** (`0093`): console, the storage manager,
  disk_check, edu_dma and the virtio drivers use `runtime.log_info`, so their records go to their rings, labeled with
  their names by the events service. Their serial lines are the events service's echoes.
- **Rings adopted** (`events.Adopt`): `0098` left a program's records lost once the events service ended, until it
  was started again. A restarted events service is given every running program's ring by the supervisor, as handles
  that don't own them. Their doorbells went with the service before, so it reads adopted rings every 20 ms. It moves
  the ring's `reader` on (base's `SlopOsEventsRing`, a field that was reserved), and the logger, seeing a new reader,
  gives its format strings and schemas again from its next record.
- **CPU affinity** (ABI 10, `0055`):
  - `CpuTime.cpus`, a bit per CPU index (CPUs past 63 are always allowed). A child budget starts with its parent's CPUs.
    `cpu_budget_set_cpus` (`RIGHT_CPU_BUDGET_SET`) sets them, and refuses a mask with no online CPU, one outside the
    parent's, or one not covering each child's. The root's are every CPU. `cpu_budget_info` gives them as a sixth word.
  - The scheduler respects them: `make_ready` moves a thread to a CPU it may run on (`cpu_for`), a CPU steals only
    threads it may run (`take_for`), and a thread found running or queued where it may no longer run is made ready
    on one of its CPUs. New threads start on the next CPU in turn among their budget's.
  - IRQs, wired and message-signaled, are routed to the next CPU in turn among their owner's budget's CPUs, so a driver
    on a budget kept to some CPUs has its interrupts there with no call. `irq_set_cpu` moves an MSI to a given CPU of
    the caller's budget: a route on the new CPU first, then the IOMMU's remapping entry rewritten in place (VT-d), or
    the event's LPI moved with the ITS's `MOVI` (AArch64), or a new message for the driver to program (x86-64 without
    remapping, where what the device raises before then is lost); then the old route is freed.
  - `system_config`'s `CpuShare` has `cpus`, 0 for every CPU, which the scheduler service sets on the budget it splits
    for that share. No service names any yet.
- **A binding hears of messages already waiting** (the kernel's `port_bind`): Readable is raised only for a reader
  that found its end empty, so an end bound with messages already in it never woke its port. Services read every
  client in a pass, which covered a client added during the pass while new clients went at the end. Since `0098`,
  `add_client` puts a new client in the place of one that left, which can be before the one being read; virtio-blk
  then never read the first request of a restarted partition server's new connection, and the restart tests hung,
  now and then. Binding for Readable to an end with messages waiting now queues a packet at once, as binding to an end
  whose peer is closed already did.
- **`std`'s `schema.render`** wrote 0 as nothing: `add_unsigned`'s digit loop was checked before its body. It writes
  a 0, and the schemas scenario checks it.
- **Tests**: "gives a thread its CPU budget" is the program test, on `-smp 1`. "runs a CPU budget's threads on its CPUs",
  on `-smp 2`: a spinner on a budget of 1.5 CPUs at priority 20 kept to CPU 0, and a counter at priority 10 also kept
  to CPU 0, counts less than a tenth as much as it does once its budget is moved to CPU 1, as CPU 1 doesn't steal
  it. A throughput comparison didn't work, because QEMU here runs the two CPUs in turn, not at once. The refusals are
  checked too. The MSI test moves edu's MSI to CPU 1, programs its message again, and takes it there, and a CPU that
  isn't one is refused. The restart test sees the storage manager's records after the events service is started again.

## Alternatives considered
- **A mask applied only when threads are next made ready**: simpler, but a thread that never blocks would keep its
  CPU for good.
- **IRQs left where they were made, moved only by `irq_set_cpu`**: every driver would have to move its own, and know
  its budget's CPUs.
- **Rerouting an MSI on AArch64 by discarding and mapping its event again**: no new command, but an interrupt in
  between is lost.
- **Giving adopted rings new doorbells**: the program would need to be handed a new channel while running, which
  nothing does yet (`0098`).

## Consequences
- Part 3 of the catch-up, the house-rule checks, is next.
- A thread's CPU isn't visible to user space, so tests show affinity by what runs, not by where.
