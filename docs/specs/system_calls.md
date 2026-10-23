# System Calls

The system calls user space makes, how it makes them, and what they answer. Defined in the ABI package,
Hemera's `std/os/slop_os` (`syscalls.hsc`), which the kernel and user space both import
(`../../knowledge/design/system-abi.md`, `0025`, `0038`).

Status: **implemented, and growing** (roadmap M5). Unstable until ABI v1 (`0027`): numbers, layouts and
errors can still change. Four-digit numbers like `0008` refer to decision records in
`../../knowledge/decisions/`.

## Making a Call

On x86-64, with `SYSCALL`:

| Register | Going in | Coming back |
|---|---|---|
| `rax` | The call's number (`slop_os.Syscall`) | 0 for success, otherwise the error's tag (from 1) |
| `rdi`, `rsi`, `rdx`, `r10`, `r8`, `r9` | Up to six arguments | `rdx` and `r8`: up to two values; the rest as they were |
| `rcx`, `r11` | | Clobbered by `SYSCALL` |

Every other register is kept, including Hemera's carrier register. Until the ABI package generates stubs,
Hemera code calls `x86_64.system_call`, which gives `rax`, `rdx` and `r8`.

## Handles and Rights

A handle is a 32-bit value the kernel chooses (`slop_os.Handle`), opaque to user space; 0 is never one.
Each refers to one kernel object in the calling process's handle table, with rights, and one handle to
each object is its owning one (`0008`).
- **Closing the owning handle destroys the object**, and with it everything it owns: every handle to it,
  in every process, then fails with `ObjectGone`.
- **A closed handle is no longer a handle**: using it fails with `InvalidHandle`, even once its entry is
  reused.
- **Rights** (`slop_os.Rights`, `0010`): `RIGHT_DUPLICATE` and `RIGHT_TRANSFER` for every kind, then per
  kind: `RIGHT_SPACE_THREADS` and `RIGHT_SPACE_MAP` for an address space; `RIGHT_PORT_WAIT` and
  `RIGHT_PORT_BIND` for a port; `RIGHT_CHANNEL_MAP` for a channel end. An owning handle has every right.
  Duplicating keeps or drops rights, never adds them.

Object kinds (`slop_os.ObjectKind`, `0034`): `MemoryBudget`, `CpuBudget`, `Memory`, `AddressSpace`,
`Thread`, `Process`, `Channel`, `Port`, `Irq`, `IoPortRange`, `IommuDomain`. So far processes, threads,
address spaces, ports and channels exist.

## Calls

| Number | Call | Arguments | Gives |
|---|---|---|---|
| 0 | `HandleClose` | handle | nothing; the object is destroyed if it was the owning handle |
| 1 | `HandleDuplicate` | handle, rights | a non-owning handle with those rights; needs `RIGHT_DUPLICATE`, and every right asked for |
| 2 | `HandleInfo` | handle | the object's kind, and the handle's rights |
| 3 | `ThreadExit` | | never returns: the calling thread is destroyed |
| 4 | `ThreadCreate` | address space, entry, stack pointer, argument | an owning handle to a new thread, started; needs `RIGHT_SPACE_THREADS`. The thread starts at entry with the argument in the first argument register and every other register zero (`0026`) |
| 5 | `ProcessCreate` | | an owning handle to a new process, owned by the caller's |
| 6 | `AddressSpaceCreate` | | an owning handle to a new, empty address space |
| 7 | `ClockMonotonic` | | the monotonic clock, in nanoseconds since the kernel's timer started (`0009`) |
| 8 | `PortCreate` | | an owning handle to a new port |
| 9 | `PortBindWake` | port, key | nothing: a wake binding for key; needs `RIGHT_PORT_BIND` |
| 10 | `PortWake` | port, key, bits | nothing: key's wake binding's packet, with bits ORed into it; needs `RIGHT_PORT_BIND` |
| 11 | `PortSetTimer` | port, key, deadline | nothing: a timer packet for key at deadline (monotonic nanoseconds), binding key if it isn't yet; setting it again moves it. Needs `RIGHT_PORT_BIND` |
| 12 | `PortUnbind` | port, key | nothing: the binding goes, with a packet it had queued; needs `RIGHT_PORT_BIND` |
| 13 | `PortWait` | port, packets, capacity, deadline | how many packets it wrote at packets, up to capacity and 64: at once if any are queued, otherwise once one is, or 0 at deadline (`NO_DEADLINE` for none). Needs `RIGHT_PORT_WAIT` |
| 14 | `ChannelCreate` | ring bytes | owning handles to a new channel's two ends; rings of ring bytes each way, a power of two from 1 KiB to 128 KiB, 0 for the default 1 KiB |
| 15 | `ChannelMap` | end, address space, address | nothing: the channel's memory, `channel_memory_size` bytes, mapped read/write at address, page-aligned. Needs `RIGHT_CHANNEL_MAP` and `RIGHT_SPACE_MAP`; one mapping per end |
| 16 | `ChannelUnmap` | end | nothing: the end's mapping, unmapped |
| 17 | `ChannelNotify` | end, signals | nothing: `SIGNAL_READABLE` or `SIGNAL_WRITABLE`, raised on the other end |
| 18 | `ChannelWrite` | end, payload, size, batch | nothing: one message into the end's ring, with handle batch (`NO_BATCH` for none), raising Readable if the reader waits |
| 19 | `ChannelRead` | end, buffer, capacity | the next message's size, and its flags and batch (batch in the high 16 bits): its payload copied to buffer, raising Writable if the writer waits |
| 20 | `ChannelSendHandles` | end, handles, count, batch | nothing: count handles (u32s at handles, up to 64) moved out of the caller's table into batch (0 to 15) on the other end. Each needs `RIGHT_TRANSFER` |
| 21 | `ChannelTakeHandles` | end, batch, handles, capacity | how many: the batch's handles, in the caller's table, written at handles; `NO_HANDLE` for any whose object is gone |
| 22 | `ChannelNotifyAndWait` | end, signals, port, packets, capacity, deadline | as `ChannelNotify`, then `PortWait`; a thread the notify wakes is made ready on the caller's CPU |
| 23 | `PortBind` | port, object, signals, key, mode | nothing: a `Signal` packet for key when the object raises any of signals; needs `RIGHT_PORT_BIND`. Mode `Once` (1) disarms it once its packet is queued, and binding the same key to the same object arms it again; `Persistent` (2) doesn't |

Threads, processes, address spaces, ports and channels a call creates are owned by the calling thread's process.

## Ports

A port is the one wait mechanism (`../../knowledge/design/ipc.md` §3, `0052`). Each binding has a key the
caller chose, unique on its port, and a packet slot of its own, so delivering never allocates: a packet
already queued takes a new event in (wake bits ORed together). Packets are taken oldest first; threads
waiting are woken most recent first, one for each packet newly queued. Closing a port wakes every thread
waiting on it, with `ObjectGone`.

`slop_os.Packet`, 32 bytes:

| Field | |
|---|---|
| `key: u64` | The binding's key |
| `kind: PacketKind` (u32) | `Signal` (1), `Timer` (2), `User` (3) |
| `reserved: u32` | |
| `data: u64[2]` | `Signal`: the signals raised since it was last taken; `Timer`: the deadline it was set for; `User`: the bits raised since it was last taken |

## Channels

A channel has two ends, each an object with a handle of its own, and two rings, one each way, in memory
both ends' holders can map (`../../knowledge/design/ipc.md` §2, `0035`, `0053`). End A (the first handle
`ChannelCreate` gives) writes ring 0 and reads ring 1; end B the other way round.

The memory, `channel_memory_size(ring)` bytes:

| Offset | |
|---|---|
| 0 | `RingIndices` for ring 0, 128 bytes: `tail` and `producer_waiting` on one cache line, `head` and `consumer_waiting` on the next |
| 128 | `RingIndices` for ring 1 |
| 256 (`CHANNEL_RINGS_OFFSET`) | ring 0, ring bytes |
| 256 + ring bytes | ring 1 |

- **Messages** are an 8-byte `MessageHeader` (`size: u32`, `flags: u16`, `handle_batch: u16`) and the
  payload, padded to 8 bytes. A payload is at most `channel_max_payload(ring)`: half the ring, and 64 KiB,
  less the header. Indices are byte counts that wrap; a message is committed by a release store of `tail`.
- **Waking**: a reader that finds the ring empty sets `consumer_waiting`, fences, looks again, then waits
  on its port; a writer commits, fences, and calls `ChannelNotify` if it sees `consumer_waiting`. A writer
  short of room does the same with `producer_waiting`, and the reader raises Writable.
- **Through the kernel**: without `RIGHT_CHANNEL_MAP`, `ChannelRead` and `ChannelWrite` do the reader's and
  writer's part on the same memory, including setting the waiting flags when they fail with `Empty` or
  `Full`, and ringing the doorbell (`0024`).
- **Signals**: `SIGNAL_READABLE` and `SIGNAL_WRITABLE` are raised by the other end, `SIGNAL_PEER_CLOSED` once
  it's closed, and stays raised: binding to an end whose peer is closed queues a packet at once. An end
  can be bound to 4 ports at once.
- **Handles** go in batches: 16 per end, up to 64 handles each. Sending moves them out of the sender's
  table; the message naming the batch is the sender's to write. An object whose owning handle is sent
  stays the sender's process's until the batch is taken; a batch never taken, because its end closed, is
  dropped, and objects whose owning handles were in it are destroyed. An end can't be sent while its rings
  are mapped, nor through its own channel, nor mapped while it's in flight.
- **Closing an end** unmaps its rings, drops its bindings and the batches sent to it, and raises
  PeerClosed on the other. The memory is freed once both ends are gone and no mapping of it is left.

## Errors

`slop_os.HandleError`:

| Tag | Error | Why |
|---|---|---|
| 1 | `InvalidHandle` | Not a handle of this process, or a closed one |
| 2 | `ObjectGone` | The object was destroyed, or its owner is being destroyed |
| 3 | `MissingRight` | The handle lacks a right the call needs |
| 4 | `WrongKind` | The handle isn't to the kind of object the call takes |
| 5 | `TableFull` | The process has 65535 handles |
| 6 | `OutOfMemory` | |
| 7 | `NoSuchCall` | No call has that number |

Calls on a port fail with `slop_os.PortError`, whose tags mean the same where they're shared:

| Tag | Error | Why |
|---|---|---|
| 1 to 6 | as above | |
| 8 | `KeyInUse` | The key is bound already, or bound to another kind of binding |
| 9 | `NoSuchKey` | No binding has that key, or not one of that kind |
| 10 | `BadBuffer` | Packets would go where the thread can't write; nothing was taken |
| 11 | `TooManyBindings` | The object has as many bindings as it takes |

Calls on a channel fail with `slop_os.ChannelError`, the same where tags are shared:

| Tag | Error | Why |
|---|---|---|
| 1 to 6, 10 | as above | |
| 12 | `PeerClosed` | The other end is closed (for `ChannelRead`: and nothing is left to read) |
| 13 | `Full` | No room in the ring for the message |
| 14 | `Empty` | No message in the ring |
| 15 | `TooBig` | A payload bigger than `channel_max_payload`, or more than 64 handles |
| 16 | `BufferTooSmall` | The message, or the batch, doesn't fit; the first value is its size, or its count |
| 17 | `Mapped` | The end's rings are mapped already, or it can't be sent while they are |
| 18 | `BadAddress` | Not a page-aligned user address, something is mapped there, or (`ChannelUnmap`) nothing is |
| 19 | `BatchInUse` | The batch already holds handles not yet taken |
| 20 | `NoSuchBatch` | No batch by that number, or nothing in it |
| 21 | `Corrupt` | The other end broke the ring: impossible indices or header |
| 22 | `NotTransferable` | A handle to one of the channel's own ends |
| 23 | `InFlight` | The end is in a batch not yet taken |
| 24 | `InvalidSize` | The ring isn't a power of two from 1 KiB to 128 KiB |

## Not Yet

Memory objects and budgets as objects, IRQ objects, process control and interception come with the rest
of M5 (`../architecture/kernel.md`, Not Built Yet).
