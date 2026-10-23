# 0053: Channels as Built

Status: accepted
Date: 2026-10-22
Related: `0035` (IPC and ports, amended for the ring size), `0024` (direct and kernel access), `0011`
(budgets absorb received objects), `0051` (objects), `0052` (ports), `../design/ipc.md` §2, §5,
`../roadmap.md` M5

## Context
M5's third stage builds `../design/ipc.md` §2's channels. Memory objects and general mapping calls come
with the next stage, and the sketch left the mechanics of mapping, signals and handle batches open.

## Decision
Chosen with the project's owner:
- **Rings are 1 KiB each way by default**, so both rings and their 256 bytes of indices fit one page
  (amending `0035`'s 2 KiB, which with the indices needed two). A channel can ask for up to 128 KiB.
- **Mapping is a channel call for now**: `ChannelMap(end, space, address)`, at an address the caller picks,
  and `ChannelUnmap`. Closing an end unmaps it. The rings become a memory object with the next stage.
- **A mapped end can't be sent** (`Mapped`); `std` unmaps first. An end in flight can't be mapped.
- **All of the sketch's optional parts are in**: `ChannelRead`/`ChannelWrite` for ends without
  `RIGHT_CHANNEL_MAP`, `ChannelNotifyAndWait`, and `Once` bindings.

As built:
- **Each end is an object**; the two share a core with the ring memory, contiguous frames. The core lives
  while an end isn't released or a mapping is left. A mapping goes on its address space's list of rings
  and holds the core; it's let go of when it's unmapped, or when the space is released. So memory a
  thread still running in a dying space can reach is never freed under it, and unmapping never touches
  tables a released space freed.
- **Signals**: `ChannelNotify` raises Readable or Writable on the other end; PeerClosed is raised when
  an end closes, and stays raised, so a later binding sees it at once. `PortBind(port, object, signals,
  key, mode)` makes a signal binding, up to 4 per end; `Once` disarms after each packet, and binding the
  same key to the same object arms it again (like `EPOLLONESHOT`). The ring layout gains
  `producer_waiting`, on the producer's cache line, so a full ring's writer can be woken by the reader.
- **Kernel access** (`0024`): `ChannelRead` and `ChannelWrite` play the reader's and writer's part on the
  same memory, through the direct map, reading each header once and checking every index against the
  ring (`Corrupt` otherwise); when they find the ring empty or full they set the waiting flag, as a
  mapping reader or writer would, so the other side's doorbell reaches them.
- **Handle batches**: 16 per end, up to 64 handles each, allocated when sent. Sending moves handles out
  of the sender's table; an object whose owning handle is sent stays the sender's process's until the
  batch is taken (`0011`), and a batch dropped untaken destroys such objects. The message naming the
  batch is the sender's to write; the kernel doesn't tie the two.
- **`ChannelNotifyAndWait`** makes a thread its notify wakes ready on the caller's CPU, where it runs
  once the caller waits, with the message just written in that CPU's cache. Lending the caller's CPU
  budget waits for budgets as objects.
- **Destroying objects that hold each other** (an end in a batch on another channel, whose end is in a
  batch on a third...) is iterative: a destroy running on a CPU queues further ones (`destroy_later`) for
  the outermost to finish, so the kernel stack never grows with a chain a process built.

## Alternatives considered
- **One object for the channel, with two handles to it**: ends couldn't be closed separately, so
  PeerClosed would have nothing to come from.
- **Freeing the ring memory when the second end is released, unmapping in closes only**: a mapping in a
  space being destroyed could still be used by its last threads after the memory was reused.
- **One binding per end**: simpler, but an end watched by both a fiber scheduler and a supervisor's port
  would need a second channel.
- **Kernel-side batch slots preallocated per channel** (the sketch's 16 slots): 16 x 64 handles each way is
  tens of KiB for every idle channel; batches are allocated when sent instead, which isn't on a notify path.

## Consequences
- `std`'s channel package (M6) does the ring protocol, picks mapping or kernel access by the right, and
  writes the message naming a batch.
- Cores and batches aren't charged to memory budgets yet (M5, budgets), nor is `BudgetExceeded` checked
  when taking handles.
