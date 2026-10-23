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
  kind: `RIGHT_SPACE_THREADS` for an address space; `RIGHT_PORT_WAIT` and `RIGHT_PORT_BIND` for a port. An
  owning handle has every right. Duplicating keeps or drops rights, never adds them.

Object kinds (`slop_os.ObjectKind`, `0034`): `MemoryBudget`, `CpuBudget`, `Memory`, `AddressSpace`,
`Thread`, `Process`, `Channel`, `Port`, `Irq`, `IoPortRange`, `IommuDomain`. So far processes, threads,
address spaces and ports exist.

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

Threads, processes, address spaces and ports a call creates are owned by the calling thread's process.

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
| `data: u64[2]` | `Timer`: the deadline it was set for; `User`: the bits raised since it was last taken |

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

## Not Yet

Channels and IPC, memory objects and budgets as objects, IRQ objects, process control and interception
come with the rest of M5 (`../architecture/kernel.md`, Not Built Yet).
