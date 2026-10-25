# 0076: virtio-blk and the Block Protocol as Built

Status: accepted
Date: 2026-10-24
Related: `0070` (the plan for M7), `0074` (drivers' bundles), `0075` (drivers that listen), `../design/storage.md` (M8's
storage stack), `../design/ipc.md` (bulk data in shared memory), `../../docs/specs/programs.md`, `../roadmap.md` M7

## Context
M7's fifth stage (7e): virtio-blk and the `block` device-class protocol (`0070`), which M8's partition servers,
container services and volume servers build on (`../design/storage.md`). `ipc.md` sends anything larger than a message
through shared memory a message names. Asked here: how data travels (DMA memory the driver makes for each connection,
which the client reaches through a window, rather than the client's own memory bounced, or data inline in messages);
how many requests a client may have in flight (several, tagged, rather than one at a time); what the protocol addresses
(blocks, with a description of the disk, rather than bytes); and what uses the disk in 7e (a disk check service, rather
than a test program driving the device itself).

## Decision
As asked, built:
- **The `block` protocol** (`src/protocols/block`): 512-byte blocks; `Read` and `Write` of a `Transfer` (the client's
  tag, a first block, a count, an offset in the buffer), `Flush` with a tag, each answered with `Finished` (the tag
  and a `Status`: `Done`, `OutOfRange`, `ReadOnly`, `DeviceError`, `Busy`) when the device finishes it, in any order;
  `Describe`, answered with the block count, the buffer's size, and whether it's read-only and flushes; `GetBuffer`,
  answered with a window onto the connection's buffer; `Connect`. Lending is `PerConnection`: the client's budget pays.
- **Buffers**: a connection's is DMA memory the driver makes at its first `GetBuffer`, 64 KiB, in the driver's domain;
  the client gets a read-write window, and the device reads and writes the memory directly.
- **The virtio transport** frees descriptors only when the device gives back the chain they're in (`offer_chain`,
  `take_used`), and holds queues of up to 64 descriptors in its one page.
- **`virtio_blk`** (`src/drivers/virtio_blk`): `VERSION_1`, and read-only and flush if the device offers them; the
  capacity from its configuration; up to 16 requests in flight across its clients, each a header, the data and a
  status byte chained, answered with its client's tag; `Busy` when every slot or descriptor is taken. Without a flush,
  writes are durable when done and `Flush` is `Done` at once.
- **The disk check** (`src/services/disk_check`), which the supervisor starts with a connection to the first disk if
  there is one: it reads the mark `tools/boot.py` wrote in block 0, writes its own into block 1, flushes, reads it back,
  and reads blocks 2 to 9 with eight requests in flight, each holding its number. `boot.py --disk` makes the image and
  `--expect-disk-block` checks it afterwards: the boot test on both architectures sees the guest's write on the host.
- **Found on the way, fixed**: `boot.py`'s console link (`0075`) let QEMU start before it had connected, and QEMU drops
  what a console writes with nothing connected, so a busy host could lose the banner and the test with it. QEMU now
  waits for the connection (`wait=on`).

## Alternatives considered
- **The client's memory, bounced**: the client owns its memory, at a copy a transfer.
- **Data inline**: no shared memory at all, but every transfer copied through the ring, at most a few KiB a request.
- **One request at a time**: a simpler driver, which M8 would have to revisit to keep a disk busy.
- **Bytes**: friendlier for small clients, but every layer would check alignment again.
- **A test program only**: no service would use the disk, and the supervisor's path wouldn't be exercised.

## Consequences
- M8's partition server forwards requests with the same offsets into a window of the same buffer, narrowing block
  numbers to a partition's range.
- A connection's buffer bounds one request to 64 KiB; a client splits larger transfers.
- `Busy` is the client's to retry: the driver queues nothing beyond its slots.
- The IOMMU stage (`0072`'s D) maps each connection's buffer into the domain, and nothing else.
