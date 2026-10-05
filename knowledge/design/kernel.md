# The Kernel: Scope, Per-CPU State, and Syscall Interception

Status: **proposed**. Answers the *Kernel* open questions on scope, per-CPU state and
syscall interception. IPC and ports are in `ipc.md`, scheduling in `scheduling.md`, and the
system ABI in `system-abi.md`. Thread decisions are in `../decisions/0023`.

## 1. Baseline: What Existing Microkernels Put in the Kernel

| System | In the kernel | What went wrong, or what it taught |
|---|---|---|
| **seL4** | Threads, address spaces, synchronous endpoints, notifications, capability nodes (CNodes), untyped memory, IRQs, fixed-priority scheduler; MCS adds scheduling contexts | User-managed CSpaces are error-prone (`0008`). No kernel timeouts on IPC, so every timeout needs a user-level timer server. Endpoints and notifications are two separate wait mechanisms, and a thread waiting on both is awkward. Budgets (MCS) came years after the first design and changed the IPC API. |
| **Zircon** (Fuchsia) | ~25 object types (VMO, VMAR, channel, socket, FIFO, stream, event, eventpair, port, timer, job, pager, clock, …) and roughly 170 syscalls; fair and deadline scheduling in the kernel | Large surface, with several overlapping transports. Channel messages are copied into kernel buffers (up to 64 KiB and 64 handles each), and that kernel memory isn't charged to sender or receiver. Reference counting lets objects outlive their creators (`0008`). |
| **QNX Neutrino** | Synchronous send/receive/reply with priority inheritance, pulses (small async messages), timers, scheduling (FIFO, round robin, sporadic), signals; the process manager shares the kernel's address space | Synchronous messaging with priority inheritance works well for real-time systems. Small asynchronous "pulses" had to exist next to it. POSIX signals came along for compatibility. |
| **MINIX 3** | Fixed-size synchronous messages, notifications, then asynchronous send; memory grants for bulk copies | Synchronous sends between servers deadlocked, which forced asynchronous sends in later. Fixed small messages forced grants for almost every payload. |
| **L4 / Fiasco.OC** | Synchronous IPC as the only primitive; IRQs delivered as IPC | Fast RPC. Synchronous-only messaging made asynchronous events and multi-source waiting awkward, which is why later L4s added notifications. |
| **Linux `sched_ext`** | Scheduling policy as verified BPF loaded into the kernel, with a built-in fallback | A misbehaving policy (a runnable task starved past a timeout) is detected and unloaded, and the kernel falls back to its default. Policy can be replaced without trusting it to keep the system alive. |

Lessons SlopOS takes:
1. **One wait mechanism.** Every asynchronous event (channel readiness, timers, IRQs, process
   exit, faults, interception stops) arrives through the same port object (`ipc.md`).
2. **Timeouts and deadlines in the kernel.** The ambient floor already includes timeouts
   (`0009`), and a user-level timer server adds latency to everything.
3. **No unbounded kernel queues.** Message data lives in rings the creator paid for, and port
   packet storage is reserved when something is bound to a port (`ipc.md`), so no syscall
   ever allocates kernel memory on behalf of another process.
4. **Policy outside, mechanism inside, with the kernel never waiting on the policy holder.**
   For scheduling: the kernel enforces parameters, and a user-space service only sets them
   (`scheduling.md`). If that service dies, the system keeps running on the last
   parameters.
5. **Design budgets in from the start** (`0011`), not retrofitted as with seL4 MCS.

## 2. What the Kernel Does

The kernel equivalent of `services.md`. Everything not in this table is in user space.

| Responsibility | The kernel provides (mechanism) | User space decides (policy) | Why it's in the kernel |
|---|---|---|---|
| **Boot and CPUs** | Consumes `BootInfo`, starts the other CPUs, detects CPU features (`0019`), starts the root task (`0012`) | What runs at boot (root task, boot configuration) | Needs ring 0 |
| **Physical memory** | Owns every frame. Memory budgets (`0011`). Memory objects, including device memory and child memory objects (`0010`) | Who gets how much (root task, session manager) | Isolation depends on it |
| **Address spaces** | Map, unmap and protect memory objects. Page faults are resolved for committed memory, otherwise delivered as a fault packet to a port | Layout, ASLR, program loading, lazy loading through a user-space pager (later) | The MMU is privileged |
| **Threads** | TCBs, register and vector state, context switch (`0023`) | Stacks, fibers, thread pools | Needs ring 0 |
| **Scheduling** | Per-CPU dispatch by priority, budget enforcement, budget lending (`scheduling.md`) | Priorities, budget sizes and shares, CPU placement (scheduler service) | Dispatch happens on every interrupt; it can't wait on a process |
| **Time** | Monotonic clock, deadlines as port timer bindings, timeouts on waits | Wall clock, time zones, NTP (`clock` service, `0009`) | Timer hardware is privileged; timeouts must be cheap |
| **IPC** | Channels (shared rings, doorbells, handle transfer) and ports (`ipc.md`) | Protocols, encoding, RPC and blocking styles | Handles must stay unforgeable, and waiting needs the scheduler |
| **Capabilities** | Handle tables, rights, generations, ownership tree, destruction (`0008`, `0010`) | Names, directories, the powerbox, persistent grants | It's the security boundary |
| **Interrupts** | IRQ → port packet, mask and acknowledge | Drivers | Interrupt vectors are privileged |
| **Device access** | Device memory objects, I/O-port ranges (x86), IOMMU domains | Which driver gets which device (platform service) | Isolates drivers (`0013`) |
| **Process control** | Process nodes, `inspect`/`read_memory`/`write_state`/`intercept`/`kill` (`0017`), syscall interception (§4) | Debuggers, recorders, supervisors | Acts on other address spaces and on the syscall path |
| **Kernel entropy** | RDSEED for the kernel's own use (KASLR, hash seeds) and the boot seed for the root task | The `entropy` service (`0009`) | Needed before any user space exists |
| **Kernel log** | Early serial output and a fixed-size in-kernel log ring readable through a capability given to the root task | Where logs go (events service) | Must work before user space and after a crash |

**Deliberately not in the kernel:**
- scheduling *policy*, wall-clock time, drivers, filesystems, naming, program loading
  (ELF parsing), users and sessions;
- signals and `fork`;
- futexes. `std` blocks threads through ports: a lock's waiter list lives in user memory,
  and an unlocker wakes a waiter's port, like WebKit's ParkingLot. Add a futex-style
  address-keyed wait only if measurements show it's needed.

### Kernel object types (proposed)
Answers the open question on object types, pending confirmation:

| Object | Notes |
|---|---|
| `MemoryBudget`, `CpuBudget` | `0011`, `scheduling.md` |
| `Memory` | Memory object: anonymous, device memory, or a child window onto another (`0010`) |
| `AddressSpace` | Owns its mappings and page tables |
| `Thread` | `0023` |
| `Process` | An ownership-tree node: process, job and session are all this type, distinguished only by what they hold (to confirm) |
| `Channel` | Two ends, each owned independently (`0008`, `ipc.md`) |
| `Port` | The single wait mechanism (`ipc.md`) |
| `Irq`, `IoPortRange`, `IommuDomain` | Device access |

Not objects:
- **Timers** are deadlines bound to a port.
- **Notifications** are channel signals or `port_wake`, so no separate notification object
  is needed.
- **Interception** is a binding of a process to a port (§4).

### Long operations
With one kernel stack per CPU (`0023`), every kernel operation must be short or splittable.
The long ones are destroying large subtrees and large unmaps.
- **Destroying a subtree** is done in two phases:
  1. Mark the root node dying (one store) and stop its threads from being scheduled. From
     then on, lookups through the subtree fail.
  2. Tear the subtree down incrementally, with a preemption point after each object.
  The teardown is charged to the destroyer's CPU budget. Children are already unusable
  after phase 1, so it doesn't matter to anyone how long phase 2 takes.
- **Large unmaps and protects** work a bounded number of page-table entries at a time,
  record progress in the calling thread's continuation, and resume after a preemption point.
- A preemption point checks for pending interrupts and a higher-priority runnable thread. It
  never changes CPU.

## 3. Per-CPU State Without Mutable Globals

Answers *"Per-CPU kernel state with no mutable globals: where does it live?"*
(`../hemera-feedback.md` §2).

**Yes, `context.user_data` is enough in the kernel**, because of one invariant that
`0023` already guarantees: **a kernel entry never leaves the CPU it started on.** The kernel
doesn't block or migrate in the middle of an operation, so "this call tree" and "this CPU"
are the same thing for the whole entry.

```
Kernel :: struct {            // one, allocated at boot; shared and internally synchronized
    pools: ObjectPools,
    frames: FrameAllocator,
    cpus: PerCpu[],           //HEMERA(guess): slice type spelling
    ...
}

PerCpu :: struct #align(64) { // one per CPU, in a per-CPU area (randomized, 0021)
    context: Context,         // prebuilt: this CPU's allocator, logger, clock, random
    kernel: ptr[Kernel],
    run_queue: RunQueue,
    limbo: LimboList,         // 0008 quiescent-state reclamation
    current: ptr[Tcb],
    ...
}
```

- **Entry costs nothing extra.** Each `PerCpu` holds a prebuilt `Context` with
  `user_data` pointing back at the `PerCpu`. The syscall, interrupt and exception stubs read
  `GS`, then call into Hemera with the context register pointing at `PerCpu.context`. No
  context is built per entry.
- **Global state** (object pools, the frame allocator, other CPUs' run queues for IPIs and
  migration) lives in the single boot-allocated `Kernel`, reached as `per_cpu().kernel`. No
  global variable is involved.
- **Per-CPU context fields come out naturally:** per-CPU slab caches as `allocator`, a
  per-CPU lock-free log buffer as `logger`, and a per-CPU CSPRNG as `random`. That last one
  also avoids the shared-generator problem noted in `../hemera-proposals/context-clock-random.md`.
- **Inside the kernel, the "one `rawptr` shared by every subsystem" friction doesn't arise.**
  The kernel is the only user of `user_data`, and its subsystems are fields of
  `PerCpu`/`Kernel`. The friction is real in *user space*, where `std`, libraries and the
  program all want a slot. See `../hemera-proposals/context-extensions.md`.
- **The "context at `gs:[0]`" feedback item isn't needed.** The context is already passed in
  a register. `GS` is only read at entry.
- **What breaks the invariant:** kernel code that runs on behalf of one CPU on another (IPIs,
  TLB shootdown handlers). Those run as their own entry on the target CPU, with that CPU's
  context, so the rule holds.

## 4. Syscall Interception

Answers the open question on stop points, result injection, blocking calls and the
one-kernel-stack design (`0009`, `0017`).

**Rule: a thread stops only at syscall boundaries.** At entry (before the call does any
work) and at exit (after it has completed and written its results), the thread's whole state
is its saved user registers in the TCB. Nothing is on the kernel stack. Stopping is
therefore a state change plus a packet, and fits the one-kernel-stack design with no
continuation.

**Attaching.** With the `intercept` right on a process (`0017`):
```
intercept_attach :: fn(
    target: Process,
    port: Port,
    key: u64,
    filter: SyscallSet,     // which syscalls (bitset over the syscall table)
    points: StopPoints,     // entry, exit, or both
) -> Result[Intercept, InterceptError]
```
Interception covers the target's whole subtree, including processes created later (`0017`).

**Stopping.**
1. At a matching entry or exit, the kernel sets the thread's state to
   `Stopped(SyscallEntry(number))` or `Stopped(SyscallExit(number))`.
2. It queues the thread's stop packet on the interceptor's port. The packet slot is
   preallocated in the TCB, and a thread can only be stopped once at a time, so this never
   allocates.
3. The CPU returns to the scheduler.

The fast-path cost when nothing is attached is one flag test at entry and one at exit.

**Inspecting and resuming.** The interceptor reads and writes the syscall's argument and
result registers through the `Intercept` handle. Memory the call points to (buffers, output
arrays) needs `read_memory` / `write_state`. A recorder therefore needs `intercept`,
`read_memory` and `write_state`. Then:
```
InterceptAction :: union {
    Continue,                  // run the call (entry) or return to user space (exit),
                               // with any registers the interceptor changed
    Skip,                      // entry only: don't run the call; return to user space with
                               // the result registers and memory the interceptor wrote
}
```
`Skip` is how a replayer injects results.

**Blocking calls.** A blocked thread is in state `Blocked(continuation)`. When the wait
completes, the kernel writes the results, and the thread goes through the **single
`syscall_return` path**, which is also the exit stop point. A call that blocked for two
seconds while recording is answered at its entry stop with `Skip` during replay and never
blocks.

**Stopping a blocked thread doesn't cancel its wait.** There is no `EINTR`:
- `thread_suspend` on a blocked thread marks it suspended. Its user registers are readable
  at once.
- If the wait completes while the thread is suspended, the results are written and the
  thread stays stopped at the exit point.
- Resuming a thread that's still waiting leaves it waiting.

**Detaching.** Destroying the `Intercept` (or its owner, the debugger) resumes every thread it
stopped with `Continue`, which is principle 4 applied.

**Interaction with shared-memory IPC.** Messages read from a mapped ring don't arrive as
syscall results. Under `../decisions/0024`, a recorder launches the recorded process with
channel ends that lack the `map` right, so it reads through syscalls that interception
sees. Processes using direct access aren't strictly replayable.

## 5. Open Questions
- Is `Process` one type for process, job and session, or several?
- Fault delivery: does a page fault on uncommitted memory go to a per-memory-object pager
  port (Zircon-style user pagers, for memory-mapped files later), or only to the process's
  exception port for now?
- Does the kernel parse the ACPI MADT itself to start CPUs, or is Limine's SMP information
  enough? (Already open under *Layering*.)
