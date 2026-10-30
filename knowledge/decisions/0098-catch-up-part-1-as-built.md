# 0098: Catch-up Part 1, as Built

Status: accepted
Date: 2026-10-30
Related: `0054` (memory budgets), `0068` (typed entry points), `0093` (the events service), `0094` (the bundle store),
`0095` (storage restarts), `../roadmap.md` *Catch-up*

## Context
The roadmap's catch-up part 1: what M5 to M8 planned and didn't build. Chosen with the project's owner: the kernel
keeps a sixteenth of the memory free at boot out of the root budget, and at least 8 MiB. Building the rest found five
bugs, each of which restarts made reachable.

## Decision
- **The kernel's own share** (`memory_budgets.hsc`, `kernel_reserve`): the root budget is the memory free once the
  kernel is up, less a sixteenth of it, at least `MIN_KERNEL_RESERVE` (8 MiB), never more than half; `kernel_reserve=<MiB>`
  on the command line asks for another amount. Its heap, the objects it makes for itself and objects' page arrays come
  from the same frames, so a fully charged root budget no longer leaves it none. The kernel logs the amount.
- **Programs that can't start, as their starters see them** (`test_exits`): a copy of the program launched as if its
  entry took nothing ends with `EXIT_MISSING_GRANT` (126), and one the process builder gives another ABI version (the
  builder's `abi_version`, for tests) ends with `EXIT_WRONG_ABI` (125).
- **The system volume served again**: the supervisor watches its connection to the system volume (`SYSTEM_KEY` plus a
  generation, so a close of one already replaced is told apart), and once it closes, opens it again through the
  storage manager, retrying on a timer until the volume is served; then it gives the events service its directory
  (`Store`) and the bundle store its own (`UseDirectory`, new). The store reopens an object's file when a read finds
  its connection gone, and keeps a page it couldn't read until it has a directory again, never supplying it wrong.
- **A partition server's dependents killed and served again** is tested: the storage protocol's `TestRestart(disk)`,
  refused unless the storage manager was started with `test_storage_restart`, kills that disk's partition server and
  answers once it's started again. The servers depending on it are let go at once, their keys unbound, so a client
  asking meanwhile finds nothing stale.
- **Rings owned by their launcher** (ABI 9, `memory_read`, `memory_write`): a ring was the events service's memory,
  mapped by its program, so the events service ending unmapped every program's ring, and a program that then logged
  faulted. Owned by the program instead, a program that logged and ended at once took its last records with it, before
  the service read them (hello's after the process manager ended). So the launcher owns it: the events service gives
  the ring's owning handle away in `Opened`, and the supervisor keeps it in the program's entry, giving the program a
  handle that doesn't own it; once the program has ended, the supervisor gives it back (`Retire`), and the service
  reads every ring, then closes it. The service reads and writes rings through the kernel's copies, with handles that
  don't own them, never mapping them, so a ring that's gone is `ObjectGone` to it, never a fault; and its own end leaves
  the rings to the supervisor, their programs writing on, their records lost until they're started again.
- **Bugs found on the way**:
  - The supervisor's `dial` made a port bound to the listener for every dial, and never closed it; a listener has
    room for only a few bindings, so after a handful of dials to the storage manager, dialing it failed.
  - `service_kit.add_client` only ever appended, so a service took `MAX_CLIENTS` (16) clients in its life, not at
    once; with restarts, virtio-blk ran out, and partition servers couldn't open partitions. It now takes a client in
    the place of one that left (`add_client_index` says where), unbinding the place's last key.
  - virtio-blk kept a client's DMA buffer by its place, so a client taking a place over would have had the last one's
    buffer; and what the device finished for a client that left was answered to whoever had its place. A place has a
    generation, which each request carries; a buffer a client left is closed once nothing in flight uses it.
  - virtio-input set a new client's cursor at the end of its clients, wherever the client went.
  - The storage manager's test wait took the port's packets meant for its main loop, whose clients then waited for
    a wake that had come; it reads its clients again after such a wait.
- **Tests**: "keeps the kernel's share of memory out of the root budget" (`kernel_reserve=24`); "ends a program missing
  a grant, or told another ABI version, as its starter sees"; the 9a4 restart test, with `test_storage_restart`, kills
  the first disk's partition server once everything has started, sees the system volume's servers end, the system
  volume served again, and the bundle store read hello's manifest through it, then kills the storage manager as before.

## Alternatives considered
- **A fixed kernel reserve, or one per CPU**: simpler or more exact, but a sixteenth scales with the machine.
- **Rings owned by their programs**: no launcher involved, but a program's last records went with it.
- **The events service tolerating a ring's unmapping**: a fault can't be caught.
- **The logger writing through the kernel too**: no mapping anywhere, but a system call per record, which `0093` ruled
  out.

## Consequences
- Typed files in `Dir` (`0046`) go to 9c, as the roadmap says.
- A program whose records went to an events service that ended logs nowhere until it's started again; a program
  could be given a new ring by its launcher, which needs a way to hand a running program a grant.
- Part 2 of the catch-up is next.
