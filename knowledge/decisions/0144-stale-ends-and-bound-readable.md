# 0144: A Stale End in a Batch, and Readable Armed by Binding

Status: accepted
Date: 2026-11-01
Related: `0099` (binding for Readable to an end with messages waiting), `0011` (handles in flight), `0140` (the root
task's services started again), `0143` (where both showed up)

## Context
Two faults showed up in the boot test that kills the events service, the clock service, the storage manager and a
partition server in turn, once 10b3's account service made each disk boot busier:
- **A kernel page fault** on AArch64 (a write at address 8), in `channel_take_handles`. A batch in flight held a copy
  of a channel end (not its owning handle), whose owner destroyed the end; after a grace period the end was released,
  its `core` set to 0. Taking the batch called `let_go_of_end` on it, which took the lock of a core that was gone.
- **A hang**: a service took a new client (a `Connect`) into a place an earlier client had left, below the one its
  pass had reached, and bound it to its port before any message came. A channel raises Readable only once its reader
  has found it empty (ipc.md §5), and nothing had read the new end, so its first request woke nothing, and the service
  never read it. Here virtio_blk missed a restarted partition server's `Describe`, which the storage manager waited on,
  and the supervisor on it.

## Decision
- **`let_go_of_end`** checks the end's generation before it touches the end's core: one that's no longer the end with
  that generation was destroyed, and may have been released, so there's nothing to let go of. One that still is can't
  be released while the caller is in the kernel, since this CPU hasn't passed a quiescent point, so its core is there.
  `drop_batch` and `channel_take_handles` both reach it.
- **Binding for Readable arms the end**, as a read that finds it empty does: `port_bind` sets the ring's
  `consumer_waiting` before it looks for waiting messages, so the next message raises Readable whether or not a read
  has come first. A mapped ring's reader that doesn't want the extra wake clears it with its first read, as it would.
- **Tests**: `test_channels` sends a copy of an end, closes the end's owning handle, waits past a grace period, and
  takes the batch, which gives `NO_HANDLE` in its place; and binds an empty end for Readable, writes one message without
  reading first, and has its port woken.

## Alternatives considered
- **Services reading each new client at once** (`service_kit.add_client` reading it, or every serve loop passing again
  after a client is added): every service with clients would need it, and a missed one hangs only sometimes.
- **Clearing a batch's copies when their end is destroyed**: it would mean finding every batch an end is in.

## Consequences
- A binding for Readable can bring one packet more than before, for a message a read would have found anyway.
