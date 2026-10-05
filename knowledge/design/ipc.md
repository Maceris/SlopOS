# IPC: Shared-Ring Channels and Ports

Status: **proposed**. Built on the direction from the open questions: asynchronous IPC as the
primitive, blocking as a layer on top, and memory-mapped ring buffers as the normal
transport. Related: one channel per connection (`0010`), receives charged to budgets
(`0011`), replay through syscalls (`0009`), the completion-queue direction
(`../problems-and-directions.md` §9).

## 1. Summary

- A **channel** is a kernel object with two ends. Its messages travel through **two
  single-producer/single-consumer rings** (one per direction) in a memory object mapped into
  both processes. Sending and receiving bytes needs no syscall.
- The kernel takes part only for things that can't go through shared memory:
  - **doorbells**, waking a peer that's waiting;
  - **handle transfer**, since handles must stay unforgeable;
  - **signals** (readable, writable, peer closed).
- A **port** is the single wait mechanism: a queue of packets fed by bindings (channel
  signals, timers, IRQs, process events, interception stops). Packet storage is reserved
  when something is bound, so the kernel never allocates on a notify.
- **Blocking, RPC and `call()` are `std` code**: send, then wait on a port. A combined
  "notify and wait" syscall recovers synchronous-RPC latency where it matters (§5).
- **Direct by default, replayable on request:** the same rings can be accessed through
  syscalls instead, for recorded processes (§6, `../decisions/0024`).
- **The ring, header and packet layouts are stable ABI surfaces** (`system-abi.md` §1).

## 2. Channels

### Creation and memory
```
channel_create :: fn(
    budget: MemoryBudget,   // pays for the object and the ring memory (0011)
    ring_bytes: u32,        // per direction, power of two, ≥ 2 KiB; default 2 KiB (one page total)
) -> Result[ChannelPair, ChannelError]

ChannelPair :: struct { a: Channel, b: Channel }   // 'Channel[P]' once protocol tags are decided
```
- The ring memory is a memory object owned by the channel. Each end's holder maps it with
  `channel_map(end, space) -> Result[RingView, ...]`. Both sides must write indices in both
  rings (the producer's `tail`, the consumer's `head`), so the mapping is read/write in both
  processes. The default 2 KiB + 2 KiB fits one page, and `std` treats everything the peer
  can write as untrusted (see "Untrusted peer memory" below).
- **Bounded by construction.** A full ring makes `send` fail with `Full`. The sender waits for
  the `Writable` signal. Nothing queues in the kernel, unlike Zircon's kernel-copied
  messages.

### Ring layout
```
RingIndices :: struct #align(64) {          // producer and consumer on separate cache lines
    tail: u32,                // written by producer: bytes committed
    _pad0: u8[60],
    head: u32,                // written by consumer: bytes consumed
    consumer_waiting: u32,    // consumer sets this before sleeping (event suppression)
    _pad1: u8[56],
}
#run assert(size_of(RingIndices) == 128)

MessageHeader :: struct {
    size: u32,                // bytes of payload after this header
    flags: u16,               // HasHandles, ...
    handle_batch: u16,        // which kernel-side handle batch belongs to this message
}
#run assert(size_of(MessageHeader) == 8)
```
- Messages are variable-length records, 8-byte aligned. They are committed by advancing
  `tail` with a release store, so a reader never sees a partial message. If a sender dies
  mid-write, its last message simply never appears.
- The **wake protocol** is the standard event-suppression scheme (virtio's, io_uring's):
  - The consumer sets `consumer_waiting`, issues a sequentially consistent fence, checks
    the ring once more, then waits on its port.
  - The producer commits, fences, and calls `channel_notify(end)` only if it sees
    `consumer_waiting`.
  - Many messages can share one doorbell.

### Untrusted peer memory
The peer can write its ring at any time, including while a message is being read.
- **`std` copies each message out of the ring into private memory before decoding it**, and
  bounds-checks `head`/`tail`/`size` against the ring size. Since Hemera allows stack
  buffers to be passed as views, small messages can be copied into a stack buffer. Large ones
  shouldn't be on a fiber, whose stack segments are 1 KiB (`../open-questions.md`, *IPC and
  data*). This is one copy, the same
  number a kernel-copying design makes, but done by the receiver.
- Double-fetch bugs (reading a length twice, from memory the attacker controls) are the
  classic failure of shared-memory IPC, in Xen and virtio backends among others. All ring
  parsing lives in one `std` package and is fuzzed.
- This is a candidate house-rule check (`0007`): only that package may read a `RingView`.

### Handle transfer
Handles can't be written into shared memory.
```
channel_send_handles :: fn(end: Channel, handles: Handle[], batch: u16) -> Result[void, ChannelError]
channel_take_handles :: fn(end: Channel, batch: u16, out: mut Handle[]) -> Result[u32, ChannelError]
```
- The sender moves handles into a kernel-side slot (one per in-flight batch, preallocated per
  channel, default 16 slots), then writes a message whose header names the batch.
- The receiver takes them explicitly. That's where `0011` applies: the receiver's budget
  absorbs the objects' charges, or the take fails with `BudgetExceeded` and the batch stays
  put.
- If the sender dies before the batch is taken, objects it still owned are destroyed
  (`0011`).
- **Limits:** at most 64 handles per batch.

### Message size limit
- Maximum message size is **half the ring** (so 1 KiB with the default ring), capped at
  **64 KiB** whatever the ring size.
- Anything bigger goes in a shared memory object referenced by the message (a
  `SharedBuffer`, as in `../design/layers.md`). The limit comes from the ring, not a kernel
  constant, so a protocol that wants bigger messages creates bigger rings and pays for them.

### Closing
Closing an end raises `PeerClosed` on the other. The ring stays mapped in the surviving
process until it closes its end too. Then the channel is freed (`0008`).

## 3. Ports

Answers *"readiness or completion packets? Same object as the completion queue?"*

**Recommendation: one port object. It delivers readiness packets for channels and
completion packets for kernel events, and it *is* the completion queue.**

### Why readiness for channels
With shared rings, the data is already in the receiver's memory. A completion packet
carrying the message would copy it a second time. All the waiter needs is "channel K has
something", after which it drains the ring. So channel bindings deliver **signals**
(readable, writable, peer closed).

### Why completion for kernel events
Timers, IRQs, process exit, faults and interception stops have no ring to drain. The packet
carries the event (`deadline reached`, `IRQ 11`, `exit status`).

### No io_uring-style submission queue in the kernel
io_uring exists because Linux's I/O lives in the kernel. In SlopOS, I/O is a request to a
user-space server over a channel. **The channel's outgoing ring already is the submission
queue, and its incoming ring the completion queue.** The port is only the "wait for any of
these" mechanism, so `../problems-and-directions.md` §9's "completion-based, async-first
interface" falls out without a second queue design. If batching *kernel* calls ever
matters, a `syscall_batch` can be added later.

### Interface sketch
```
port_create :: fn(budget: MemoryBudget) -> Result[Port, PortError]

// Readiness: queue one packet when any of 'signals' is set on 'object'.
port_bind :: fn(port: Port, object: Handle, signals: Signals, key: u64, mode: BindMode)
    -> Result[void, PortError]
BindMode :: enum { Once, Persistent }   // Once: disarm after delivery (like EPOLLONESHOT)

port_set_timer :: fn(port: Port, key: u64, deadline: MonotonicTime, slack: Duration)
    -> Result[void, PortError]
port_wake :: fn(port: Port, key: u64, bits: u64) -> Result[void, PortError]   // user wakeups
port_unbind :: fn(port: Port, key: u64) -> Result[void, PortError]

port_wait :: fn(port: Port, out: mut Packet[], deadline: MonotonicTime?) -> Result[u32, PortError]

Packet :: struct {
    key: u64,
    data: PacketData,
}
PacketData :: union {
    Signal(observed: Signals),
    Timer(deadline: MonotonicTime),
    User(bits: u64),
    Irq(count: u32),
    ProcessExit(status: ExitStatus),
    Fault(thread_key: u64, fault: Fault),
    InterceptStop(thread_key: u64, point: StopPoint, syscall: u32),
}
```

### Rules that keep it cheap and bounded
- **Each binding owns its packet slot, preallocated when it's created** and charged to the
  binder's budget. A binding whose packet is already queued just updates the queued packet
  (signals OR together, IRQ counts add). Memory per port is therefore bounded by its
  number of bindings, and notifying never allocates.
- **Keys are user-chosen `u64`s**, unique per port. `std`'s fiber scheduler stores
  `(fiber index, generation)` in them and maps packets back to fibers without a lookup
  table.
- **`port_wait` returns batches.** One syscall drains up to `out.count` packets.
- **Several threads may wait on one port.** Each packet wakes one thread, the most recent
  waiter first (LIFO, like IOCP), to avoid thundering herds and keep caches warm. `std`'s
  fiber scheduler uses one port per scheduler, shared by its worker threads.
- **Timers are not objects.** They are bindings, so they cost a packet slot and nothing
  else, and a timer is cancelled by unbinding. This answers *"Are timers just deadlines
  delivered through ports?"*: yes.
- **No separate notification object.** Cross-thread wakeups use `port_wake`; cross-process
  wakeups use a channel. This answers *"Are separate notification objects needed next to
  ports?"*: no.

### Thousands of channels, one thread
1. A server binds each connection's channel to its scheduler's port with `Persistent` and
   key = fiber.
2. An idle connection costs its channel plus one binding (about 64 bytes of kernel memory).
3. A busy server's `port_wait` returns up to N ready connections per syscall, and the
   matching fibers drain their rings without further syscalls.

## 4. Blocking on Top

`std` provides the blocking forms as library code:
- `send` (retry on `Full` after waiting for `Writable`);
- `receive` (wait for `Readable`, then copy out);
- `call(request) -> response`, which matches responses by request ID, as idempotent
  protocols need anyway (`0017`).

On a fiber, waiting goes through the scheduler's `park` (Hemera `docs/multitasking.md`,
*Waiting*), not `fiber_yield`, which is only a hint and may return at once. `park` binds the
fiber's key on the scheduler's port and suspends it. When the fiber can't be suspended (a
plain thread, foreign frames on the stack, a no-yield region), `park` says so and waiting is
`port_wait` on the thread's own port.

## 5. Fast Path for Synchronous RPC

Async rings plus a doorbell mean a client→server→client round trip takes two scheduler
passes, and an IPI if the server runs on another CPU. L4's direct process switch (switch
straight to the receiver, skip the scheduler) is why synchronous IPC is fast. To keep that:
```
channel_notify_and_wait :: fn(notify: Channel, wait: Port, out: mut Packet[], deadline: MonotonicTime?)
    -> Result[u32, PortError]
```
- If the notify wakes a thread that is waiting on the same CPU, the kernel switches to it
  directly.
- It runs on the caller's lent CPU budget if one is attached (`scheduling.md`).
- It's an optimization to measure, not part of the model. `std`'s `call()` uses it when
  available.

## 6. Direct and Kernel Access Modes (Replay)

Decided in `../decisions/0024`: **performance over determinism; direct access by default,
replay opt-in.**

- **Direct** (default): with the `map` right on its end, a process maps the rings and moves
  messages without syscalls.
- **Through the kernel:** without `map`, `std` uses
  `channel_read(end, out)` / `channel_write(end, bytes)`, which copy through the kernel using
  the same ring and format. Every receive is a syscall result, so the process can be
  recorded and replayed (`0009`).
- The peer can't tell which mode the other side uses. `std` checks the right once when an
  end arrives and picks the backend.
- A **recorder** launches the recorded process with ends that lack `map`, and strips `map`
  from every channel that later reaches it. Any other process uses direct access and simply
  isn't strictly replayable, like a program that reads `RDRAND`.
- Small or rarely used channels can also skip the mapping to save a page.

### When the kernel is involved, in direct mode

| Situation | Kernel entries |
|---|---|
| Both sides busy, streaming messages | **None.** The producer commits, the consumer polls |
| Consumer is idle (sleeping on its port) | One `channel_notify` per batch of messages, plus the consumer's `port_wait` |
| Ring full | The producer waits for `Writable` (one `port_wait`), and the consumer notifies when it frees space and sees the producer waiting |
| Sending handles | One `channel_send_handles` and one `channel_take_handles` per batch |
| Synchronous call/response with an idle server | `channel_notify_and_wait` (§5): one entry each way, with a direct switch on the same CPU |

`std` can also **spin briefly before sleeping** (polling the ring for a bounded time before
setting `consumer_waiting`). This trades CPU time for latency, which suits audio and other
latency-sensitive paths. It's a per-channel `std` option, never a kernel policy.

## 7. Cost of Many Connections

The default channel uses one page (4 KiB) for both rings, mapped in both processes. 10 000
connections cost about 40 MiB plus page-table entries. That's acceptable to start with.

If it matters later: in SlopOS, many connections between the *same pair* of processes is the
common case (every TCP connection of a web server comes from the network service). A
**link** object between two fixed processes could hold many small rings in shared pages.
Its channels' ends can't be transferred, since moving one would expose the neighbouring
rings to a third process. Measure first.

## 8. Open Questions
- Default ring size and the 64 KiB cap: right numbers?
- Protocol tags and wire format (already open under *IPC and data*): the tag would sit in
  the channel object, set at `channel_create`.
- Should ports also be mappable (a completion ring drained without `port_wait` while it's
  non-empty)? It would follow `0024`: direct by default, `port_wait` for recorded processes.
