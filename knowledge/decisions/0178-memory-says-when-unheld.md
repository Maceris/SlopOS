# 0178: Memory Says When No One Else Holds It, So the Bundle Store Can Close Objects

Status: accepted, and built (below)
Date: 2026-11-05; accepted and built 2026-11-06
Related: `0051` (objects and handles), `0054` (memory objects), `0094` (the bundle store), `0176` (11d, Read),
`../design/software.md` §2

## Context
The bundle store gives an object as paged memory it supplies (Get): one memory object per object, however many ask,
so a program's pages are read once and shared. The store owns each one, and can't know when the last process that
was given a handle to it, or mapped it, has let it go: the kernel counts nothing of the kind (`0051`: closing the
owning handle destroys an object, and every other handle goes stale). So an object stays open while the store runs,
and the store keeps at most `MAX_OBJECTS`, 64; past that, Get answers Missing. 11d's `Read` gives small objects as
copies, keeping nothing open (`0176`), which leaves only executables, but a system that runs more than 64 programs
over its life, as 11e's tools will make likely, still runs out, and nothing comes back but restarting the store.

## Proposal
- **The kernel counts a memory object's holders**: the handles to it that aren't its owning one, in any process, and
  its mappings. A duplicate or a new mapping adds one; closing a handle, unmapping, or a process's end, which does
  both, takes one away. Moving a handle between processes doesn't change the count. Windows (`0054`) hold their
  parent, as a mapping does.
- **A signal, `SIGNAL_UNHELD`**, raised on the owning handle while the count is 0, and lowered when it isn't: bound to
  a port like any signal, `Persistent`, so the owner hears each time its object becomes unheld. Like Zircon's
  `ZX_VMO_ZERO_CHILDREN`, but counting handles and mappings, since SlopOS gives memory out as handles, not as clones.
- **The store closes what's unheld, when it needs room**: it binds each open object's owning handle for
  `SIGNAL_UNHELD`, and marks it unheld when the packet comes. A Get that finds no free slot closes the least recently
  given of the unheld instead of answering Missing, so a program run again soon still finds its pages in memory. A
  Get of an object marked unheld hands it out again and clears the mark.
- **No race with a Get**: the store reads the signal's state just before closing (a query of a handle's raised
  signals, `handle_signals`, if there isn't one yet), since a packet can be older than a Get that came after it. Only
  the store hands its objects out, and it does so on its one thread, so nothing else can make one held meanwhile.
- **Tests**: a kernel test of the count through duplication, transfer, mapping and a process's end; a store test that
  runs more programs than `MAX_OBJECTS` one after another, each started, run and ended, every Get answered.

## Alternatives
- **More slots**: postpones it, and each slot holds a file connection and a pager binding, so it costs the volume
  server too.
- **Read executables too**: copies a program's every page on every launch, losing the sharing Get is for.
- **Close the least recently given whatever its state**: a running program's pages would stop being supplied, and it
  would fault.
- **Reference-counted objects throughout**: `0051` chose owners and generations so destruction is explicit and
  immediate; counting only memory's holders, as a signal, keeps that.

## Open Questions
- Whether other objects want the signal too, as channels' ends have PeerClosed; nothing needs it yet.
- Whether a pager should hear when an object's pages stop being mapped anywhere, to drop them sooner than pressure
  makes it (`0153`).

## Consequences, if accepted
- A kernel change: a count on memory objects, kept on every duplicate, close, map, unmap and process end, and a
  signal; a syscall to read raised signals, if there isn't one.
- The store's slots become a cache: executables stay in memory while there's room, and are closed only when
  something else needs the slot and no one holds them.

## As Built (2026-11-06)
- **The count**: `Memory.held`, changed atomically. A duplicate (`handle_duplicate`), a non-owning grant the root task
  makes, a mapping and a window add one; closing a non-owning handle, a mapping's `take_down`, a window's destruction,
  a dropped batch's or an uninstallable handle's non-owning memory handle, and a freed table's (`free_table`, at a
  process's release) take one away. A handle moved between tables doesn't change it, on its way included. An object
  destroyed meanwhile isn't counted: its slot isn't used again until every CPU passes a quiescent point.
- **`SIGNAL_UNHELD`** (bit 6) is raised for a memory object's two watchers' slots each time the count falls to 0;
  `port_bind` takes a memory object's owning handle. **`memory_holders`** (syscall 77) gives the count, to the
  owning handle only, in place of a general query of raised signals.
- **The store doesn't bind the signal**: it asks `memory_holders` of each open object when it needs a slot, and
  closes the one given out longest ago with none (`unheld_slot`, `close_slot`), taking its pages off its lists. Asking
  at the moment it chooses needs no binding, and leaves no packet older than a Get to reason about. `store_objects=N` on
  the command line keeps fewer open, for its test.
- **Tests**: `test_memory` counts through a duplicate, a mapping, a window, a channel and a process's end, checks only
  the owner asks or watches, and hears the signal; a boot test keeps the store to 16 objects, asks `help` about 20
  programs one after another, and finds every one.

