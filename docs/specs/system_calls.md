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
  `RIGHT_PORT_BIND` for a port; `RIGHT_CHANNEL_MAP` for a channel end; `RIGHT_BUDGET_CHARGE` for a memory
  budget; `RIGHT_MEMORY_READ`, `RIGHT_MEMORY_WRITE` and `RIGHT_MEMORY_EXECUTE` for a memory object;
  `RIGHT_IRQ_ACK` for an IRQ; `RIGHT_PROCESS_INSPECT`, `_READ_MEMORY`, `_WRITE_STATE`, `_INTERCEPT` and
  `_KILL` for a process, over its whole subtree (`0017`). An owning handle has every right.
  Duplicating keeps or drops rights, never adds them.

Object kinds (`slop_os.ObjectKind`, `0034`): `MemoryBudget`, `CpuBudget`, `Memory`, `AddressSpace`,
`Thread`, `Process`, `Channel`, `Port`, `Irq`, `IoPortRange`, `IommuDomain`, `Platform`, the authority over
the machine's hardware (`0039`, `0055`), and `Intercept`, a debugger's hold on a subtree (`0056`). So far
all but I/O-port ranges and IOMMU domains exist.

## Calls

| Number | Call | Arguments | Gives |
|---|---|---|---|
| 0 | `HandleClose` | handle | nothing; the object is destroyed if it was the owning handle |
| 1 | `HandleDuplicate` | handle, rights | a non-owning handle with those rights; needs `RIGHT_DUPLICATE`, and every right asked for |
| 2 | `HandleInfo` | handle | the object's kind, and the handle's rights |
| 3 | `ThreadExit` | | never returns: the calling thread is destroyed |
| 4 | `ThreadCreate` | budget, address space, entry, stack pointer, argument | an owning handle to a new thread, started; needs `RIGHT_SPACE_THREADS`. The thread starts at entry with the argument in the first argument register and every other register zero (`0026`) |
| 5 | `ProcessCreate` | budget | an owning handle to a new process, owned by the caller's, whose budget the budget is |
| 6 | `AddressSpaceCreate` | budget | an owning handle to a new, empty address space |
| 7 | `ClockMonotonic` | | the monotonic clock, in nanoseconds since the kernel's timer started (`0009`) |
| 8 | `PortCreate` | budget | an owning handle to a new port |
| 9 | `PortBindWake` | port, key | nothing: a wake binding for key; needs `RIGHT_PORT_BIND` |
| 10 | `PortWake` | port, key, bits | nothing: key's wake binding's packet, with bits ORed into it; needs `RIGHT_PORT_BIND` |
| 11 | `PortSetTimer` | port, key, deadline | nothing: a timer packet for key at deadline (monotonic nanoseconds), binding key if it isn't yet; setting it again moves it. Needs `RIGHT_PORT_BIND` |
| 12 | `PortUnbind` | port, key | nothing: the binding goes, with a packet it had queued; needs `RIGHT_PORT_BIND` |
| 13 | `PortWait` | port, packets, capacity, deadline | how many packets it wrote at packets, up to capacity and 64: at once if any are queued, otherwise once one is, or 0 at deadline (`NO_DEADLINE` for none). Needs `RIGHT_PORT_WAIT` |
| 14 | `ChannelCreate` | budget, ring bytes | owning handles to a new channel's two ends; rings of ring bytes each way, a power of two from 1 KiB to 128 KiB, 0 for the default 1 KiB |
| 15 | `ChannelMap` | end, address space, address | nothing: the channel's memory, `channel_memory_size` bytes, mapped read/write at address, page-aligned. Needs `RIGHT_CHANNEL_MAP` and `RIGHT_SPACE_MAP`; one mapping per end |
| 16 | `ChannelUnmap` | end | nothing: the end's mapping, unmapped |
| 17 | `ChannelNotify` | end, signals | nothing: `SIGNAL_READABLE` or `SIGNAL_WRITABLE`, raised on the other end |
| 18 | `ChannelWrite` | end, payload, size, batch | nothing: one message into the end's ring, with handle batch (`NO_BATCH` for none), raising Readable if the reader waits |
| 19 | `ChannelRead` | end, buffer, capacity | the next message's size, and its flags and batch (batch in the high 16 bits): its payload copied to buffer, raising Writable if the writer waits |
| 20 | `ChannelSendHandles` | end, handles, count, batch | nothing: count handles (u32s at handles, up to 64) moved out of the caller's table into batch (0 to 15) on the other end. Each needs `RIGHT_TRANSFER` |
| 21 | `ChannelTakeHandles` | end, batch, handles, capacity | how many: the batch's handles, in the caller's table, written at handles; `NO_HANDLE` for any whose object is gone |
| 22 | `ChannelNotifyAndWait` | end, signals, port, packets, capacity, deadline | as `ChannelNotify`, then `PortWait`; a thread the notify wakes is made ready on the caller's CPU |
| 23 | `PortBind` | port, object, signals, key, mode | nothing: a `Signal` packet for key when the object, a channel end, a process (with `RIGHT_PROCESS_INSPECT`) or a thread, raises any of signals, or for an IRQ an `Irq` packet for its interrupts, signals unused; needs `RIGHT_PORT_BIND`. A process or a thread can be watched by 2 bindings, an end by 4. Mode `Once` (1) disarms it once its packet is queued, and binding the same key to the same object arms it again; `Persistent` (2) doesn't |
| 24 | `MemoryBudgetCreate` | budget, limit | an owning handle to a child budget of limit bytes, charged to the budget |
| 25 | `MemoryBudgetInfo` | budget | its limit, and how much of it is charged, in bytes |
| 26 | `MemoryCreate` | budget, size | an owning handle to a new memory object of size bytes, a whole number of pages up to `MAX_MEMORY_SIZE` (1 GiB), charged for all of it |
| 27 | `MemoryMap` | memory, address space, address, offset, size, protection | nothing: size bytes of the memory from offset, mapped at address, page-aligned, with protection (`PROTECTION_READ`, `_WRITE`, `_EXECUTE`; never writable and executable). Needs the memory rights the protection asks for, and `RIGHT_SPACE_MAP` |
| 28 | `MemoryUnmap` | address space, address | nothing: the mapping that starts at address, unmapped; needs `RIGHT_SPACE_MAP` |
| 29 | `ControllerRegister` | platform, kind, registers | the interrupt controller's number, and how many lines it has: kind is a `ControllerKind`, registers its physical address, from the firmware tables. The same controller registered again gives the same number |
| 30 | `IrqCreate` | platform, budget, controller, line, flags | an owning handle to the line's IRQ, routed to a CPU the kernel picks and unmasked; flags `IRQ_LEVEL` and `IRQ_ACTIVE_LOW`, from the firmware tables. A line has at most one IRQ |
| 31 | `IrqAck` | irq | nothing: a level-triggered line, unmasked again; needs `RIGHT_IRQ_ACK` |
| 32 | `MemoryCreatePhysical` | platform, budget, address, size, cache | an owning handle to device memory: size bytes at the physical address, which mustn't be RAM the kernel owns, mapped with the `CacheMode` |
| 33 | `MemoryCreateWindow` | memory, budget, offset, size | an owning handle to a window onto size bytes of the memory from offset, which can be mapped only as the memory's handle could |
| 34 | `ProcessThreads` | process, IDs, capacity | how many threads the process's subtree has; up to capacity (and 64) of their IDs written at IDs. Needs `RIGHT_PROCESS_INSPECT` |
| 35 | `ProcessReadMemory` | process, address space, address, buffer, size | nothing: size bytes of the space, which must be in the process's subtree, copied to buffer. Needs `RIGHT_PROCESS_READ_MEMORY` |
| 36 | `ProcessWriteMemory` | process, address space, address, buffer, size | nothing: size bytes from buffer copied into the space. Needs `RIGHT_PROCESS_WRITE_STATE` |
| 37 | `ThreadSuspend` | process, thread ID | nothing: the thread stops where it is until `ThreadResume`; a wait it's in goes on. Needs `RIGHT_PROCESS_WRITE_STATE` |
| 38 | `ThreadResume` | process, thread ID | nothing: a suspended thread goes on. Needs `RIGHT_PROCESS_WRITE_STATE` |
| 39 | `ThreadReadRegisters` | process, thread ID, registers | nothing: a stopped or suspended thread's `THREAD_REGISTERS` registers, as u64s, written at registers. Needs `RIGHT_PROCESS_INSPECT` |
| 40 | `ThreadWriteRegisters` | process, thread ID, registers | nothing: a stopped or suspended thread's registers, set from registers. Needs `RIGHT_PROCESS_WRITE_STATE` |
| 41 | `InterceptAttach` | process, port, key, calls, points | an owning handle to an intercept of the process's subtree, paid for by the caller's process's budget: its threads stop at the entry or exit (`STOP_SYSCALL_ENTRY`, `STOP_SYSCALL_EXIT`) of the calls whose bit is set in calls, and at faults (`STOP_FAULT`). Needs `RIGHT_PROCESS_INTERCEPT` and `RIGHT_PORT_BIND` |
| 42 | `InterceptNext` | intercept, stop | nothing: the next stop not yet reported, a `StopInfo`, written at stop |
| 43 | `InterceptResume` | intercept, thread ID, action | nothing: a thread the intercept stopped goes on: `Continue`, `Skip` (at an entry only) or `Kill` |
| 44 | `ProcessKill` | process | nothing: the process is destroyed, with its subtree. Needs `RIGHT_PROCESS_KILL` |

Everything a call creates is owned by the calling thread's process. A budget argument is a memory budget
handle with `RIGHT_BUDGET_CHARGE`, which pays for what's created. A platform argument is a handle to the
platform capability.

## Memory Budgets

Every object is charged to a memory budget (`0011`, `0054`): its slot, and what it holds, a thread's vector
state, a channel's core and rings, a memory object's whole size and its page array, an address space's
root table. What an object takes on later is charged as it does, to the same budget, and can fail with
`BudgetExceeded`: a process's handle-table pages to the process, page tables and mappings to their address
space, port bindings to their port, handle batches in flight to the end that sent them. A budget never
charges more than its limit. An object's whole charge comes back once it's freed, after its grace period.

- **Splitting**: `MemoryBudgetCreate` charges a child's limit to its parent, with its slot. Closing a child
  moves what's charged to it to its parent, which gets back the part of the limit the child hadn't used;
  nothing it paid for is destroyed.
- **Processes**: a process's budget is the one `ProcessCreate` was given. Taking an owning handle out of a
  batch (`ChannelTakeHandles`) moves the object's charge to the taker's process's budget, for all the
  batch's objects or none: if the budget can't take them, the take fails with `BudgetExceeded` and the
  batch stays. While a batch is in flight, its objects stay charged where they were.
- **The root budget** is of the memory free once the kernel is up, and the kernel's own; the budgets
  processes get are split from it.

## Memory Objects

A memory object is anonymous memory, zeroed. It's charged for its whole size when it's made, and filled
only as it's touched: a page fault in a mapping of it maps the page, with the frame it has or a new zeroed
one. Mappings of the same memory share its frames. `MemoryMap` maps nothing at once, and refuses a range
that overlaps another mapping or a channel's rings; `ChannelMap` refuses a range a mapping holds.

A fault in user mode outside any mapping, or an access a mapping doesn't allow (a write to a read-only
one, running code from one that isn't executable), destroys the faulting thread. Closing a memory object
unmaps it from every address space; destroying an address space takes down what's mapped in it.

- **Device memory** (`MemoryCreatePhysical`) is a range of physical addresses that isn't RAM the kernel
  owns: device registers, a framebuffer, firmware tables. Its pages are those addresses, mapped with its
  cache mode (`Device`, uncached and strongly ordered, for registers), and only its slot is charged.
- **A window** (`MemoryCreateWindow`, `0010`) shares a range of another memory object's frames, and is
  charged only its slot. Closing the memory destroys its windows, unmapping them everywhere; closing a
  window leaves the memory and its other windows. A window made through a handle without
  `RIGHT_MEMORY_WRITE` can't be mapped writable, whatever its own handle's rights; so for execute.

## IRQs

An IRQ is one interrupt controller line, made with the platform capability once its controller is
registered (`0039`, `0055`). The kernel routes it to a CPU and unmasks it. Each interrupt adds one to the
count in its binding's `Irq` packet, queuing the packet if it isn't; a driver binds it to a port with
`PortBind`, one binding per IRQ. A level-triggered line is masked when its interrupt arrives, until the
driver calls `IrqAck`. Closing the IRQ masks the line.

## Process Control

Rights on a process cover its whole subtree, including processes made later (`0017`): through one handle a
debugger lists its threads by ID, reads and writes its address spaces' memory, suspends and resumes its
threads, reads and writes the registers of threads stopped or suspended, intercepts it, and kills it. A
thread is held, by a suspend or a stop, only where its whole state is its saved registers: on its next
entry to the kernel if it's running, at once if it's waiting to run, and once its wait is over if it's
blocked, so a wait isn't cancelled and its results are written first (`../../knowledge/design/kernel.md`
§4, `0056`).

**Intercepts.** One per process; the nearest intercepted process above a thread is the one it stops for.
A thread stops at a call's entry, before the call does anything, at its exit, once its results are
written (after any wait), or at a fault its memory doesn't resolve: the intercept is its subtree's
exception port. Each stop adds one to the count in the intercept's `Stop` packet, queuing it if it isn't;
`InterceptNext` reports the stops one by one:

| `StopInfo` field | |
|---|---|
| `thread: u64` | The thread's ID |
| `point: StopPoint` (u32) | `SyscallEntry` (1), `SyscallExit` (2), `Fault` (3) |
| `number: u32` | The call's number; for a fault, the access: 0 read, 1 write, 2 execute |
| `address: u64` | For a fault, the address it touched |

`InterceptResume` lets a stopped thread go on. `Continue` at an entry makes the call, with any registers the
debugger changed (it doesn't stop at that entry again); at an exit, returns to user mode; at a fault,
retries the access, after the debugger has mapped memory or changed registers. `Skip`, at an entry only,
returns to user mode with the registers as the debugger wrote them, the call never made: how a replayer
answers calls. `Kill` destroys the thread. Closing the intercept lets every thread it stopped go on, as
with `Continue`. Without an intercept asking for faults, a faulting thread is destroyed.

**Registers** (`THREAD_REGISTERS`, 18 on x86-64): rax, rbx, rcx, rdx, rsi, rdi, rbp, rsp, r8 to r15, rip,
rflags. Writing them refuses an instruction or stack pointer outside user addresses, and changes only
rflags' status flags and DF.

**Ends**: a process or a thread raises `SIGNAL_TERMINATED` when it's destroyed, which stays raised.

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
| `kind: PacketKind` (u32) | `Signal` (1), `Timer` (2), `User` (3), `Irq` (4), `Stop` (5) |
| `reserved: u32` | |
| `data: u64[2]` | `Signal`: the signals raised since it was last taken; `Timer`: the deadline it was set for; `User`: the bits raised since it was last taken; `Irq`: the interrupts since it was last taken; `Stop`: the stops since it was last taken |

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
| 25 | `BudgetExceeded` | The budget can't pay for it, or (`ChannelTakeHandles`) the taker's can't take what the batch owns |

Calls on a port fail with `slop_os.PortError`, whose tags mean the same where they're shared:

| Tag | Error | Why |
|---|---|---|
| 1 to 6, 25 | as above | |
| 8 | `KeyInUse` | The key is bound already, or bound to another kind of binding |
| 9 | `NoSuchKey` | No binding has that key, or not one of that kind |
| 10 | `BadBuffer` | Packets would go where the thread can't write; nothing was taken |
| 11 | `TooManyBindings` | The object has as many bindings as it takes |

Calls on a channel fail with `slop_os.ChannelError`, the same where tags are shared:

| Tag | Error | Why |
|---|---|---|
| 1 to 6, 10, 25 | as above | |
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

Calls on a memory budget or a memory object fail with `slop_os.MemoryError`:

| Tag | Error | Why |
|---|---|---|
| 1 to 6, 25 | as above | |
| 18 | `BadAddress` | Not a page-aligned user address range, or it overlaps a mapping or a channel's rings |
| 24 | `InvalidSize` | Not a whole number of pages, none, more than `MAX_MEMORY_SIZE`, or past the memory's end |
| 26 | `NotMapped` | No mapping starts at that address |
| 27 | `BadProtection` | Writable and executable at once, or no access at all |

Registering a controller, making an IRQ or device memory fail with `slop_os.DeviceError`:

| Tag | Error | Why |
|---|---|---|
| 1 to 6, 25 | as above | |
| 18 | `BadAddress` | Not page-aligned, or RAM the kernel owns |
| 24 | `InvalidSize` | Not a whole number of pages, or an unknown cache mode |
| 28 | `NoController` | No controller of that kind at those registers, or none of that kind on this architecture |
| 29 | `TooManyControllers` | As many controllers are registered as the kernel takes (8) |
| 30 | `NoSuchController` | No registered controller has that number |
| 31 | `NoSuchLine` | The controller has no such line |
| 32 | `LineInUse` | The line has an IRQ already |
| 33 | `NoFreeInterrupt` | The CPU picked has every device interrupt taken |

Process control fails with `slop_os.ControlError`:

| Tag | Error | Why |
|---|---|---|
| 1 to 6, 10, 25 | as above | |
| 14 | `Empty` | `InterceptNext`: no stop left to report |
| 18 | `BadAddress` | The address space isn't in the process's subtree, or the range isn't mapped there |
| 34 | `NoSuchThread` | No thread with that ID in the subtree, or none the intercept stopped |
| 35 | `NotStopped` | The thread isn't stopped or suspended; or `Skip` at a stop that isn't an entry |
| 36 | `AlreadyIntercepted` | The process has an intercept already |
| 37 | `BadRegisters` | A register value user mode can't have |

## Not Yet

I/O-port ranges, IOMMU domains and message-signaled interrupts come with the platform service and drivers
(M7); pagers for memory objects with memory-mapped files. Process memory is read and written through the
page tables, so a memory object's pages no thread has touched yet can't be.
