# Proposal: Atomic Loads, Stores and Fences

Status: **adopted** into `base/intrinsics/intrinsics.hsc` (2026-09-30), with the naming
`_acquire_release`, `fence_acquire_release`, `fence_sequentially_consistent`,
`compiler_fence_sequentially_consistent`, and compare-exchange returning
`(old, success)`; increment/decrement return the old value. Examples below use the
adopted names. Remaining gaps are listed in §4.

The current intrinsics cover read-modify-write operations (`interlocked_exchange_add`,
`interlocked_compare_exchange`, ...). Lock-free code also needs **atomic loads**, **atomic
stores**, and **standalone fences**. Below: what to add, then real SlopOS code that needs it.

Naming follows the existing intrinsics: un-suffixed = sequentially consistent,
`_acquire`, `_release`, `_no_fence` (= C++ `relaxed` / LLVM `monotonic`).

## 1. What to Add

### Loads
Only orderings that make sense for a load (a load can't be "release"):

```
atomic_load_u32          : fn(target: ptr[u32]) -> u32 : ---   // seq_cst
atomic_load_u32_acquire  : fn(target: ptr[u32]) -> u32 : ---
atomic_load_u32_no_fence : fn(target: ptr[u32]) -> u32 : ---
```

### Stores
A store can't be "acquire":

```
atomic_store_u32          : fn(target: ptr[mut u32], value: u32) : ---   // seq_cst
atomic_store_u32_release  : fn(target: ptr[mut u32], value: u32) : ---
atomic_store_u32_no_fence : fn(target: ptr[mut u32], value: u32) : ---
```

(Both repeated for each integer type the RMW intrinsics already cover, plus `uintptr`
and pointers — atomic pointer loads/stores are needed for lock-free lists.)

### Fences
```
fence_acquire : fn() : ---   // later loads/stores can't move before earlier loads
fence_release : fn() : ---   // earlier loads/stores can't move after later stores
fence_acq_rel : fn() : ---   // both
fence_seq_cst : fn() : ---   // full barrier, including store→load ordering

compiler_fence_acquire : fn() : ---   // same, but only stops the *compiler* reordering;
compiler_fence_release : fn() : ---   // emits no instruction. For data shared with an
compiler_fence_seq_cst : fn() : ---   // interrupt handler on the same CPU.
```

### Smaller gaps in the existing RMW set
- `interlocked_increment_*` / `interlocked_decrement_*` have no ordering variants.
- No `_acq_rel` variant for RMW operations (common for lock handoff).
- Document whether `increment`/`decrement` return the old or the new value
  (Windows' `InterlockedIncrement` returns new, `InterlockedExchangeAdd` returns old).
- `compare_exchange` could return `(old: T, success: bool)` so callers don't compare
  manually, and eventually take a separate failure ordering and a `_weak` form. Weak
  CAS matters on ARM/RISC-V (LL/SC), which ties into the portability goal.

### How these map to LLVM and hardware

| Hemera | LLVM IR | x86-64 | AArch64 |
|---|---|---|---|
| `atomic_load_*_no_fence` | `load atomic monotonic` | `mov` | `ldr` |
| `atomic_load_*_acquire` | `load atomic acquire` | `mov` | `ldar` |
| `atomic_store_*_release` | `store atomic release` | `mov` | `stlr` |
| `atomic_store_*` | `store atomic seq_cst` | `xchg` | `stlr` |
| `fence_acquire/release` | `fence acquire/release` | nothing (compiler barrier only) | `dmb ishld` / `dmb ish` |
| `fence_seq_cst` | `fence seq_cst` | `mfence` | `dmb ish` |
| `compiler_fence_*` | `fence syncscope("singlethread") ...` | nothing | nothing |

On x86 most of these compile to plain `mov`s, which is exactly why code tested only on
x86 breaks on ARM. Making the ordering explicit in source is what keeps SlopOS portable.

## 2. Where SlopOS Needs Them

### Example A: Single-producer/single-consumer ring (IPC channels)

The core of shared-memory IPC (`../design/layers.md`, L2). Release/acquire pairs make
the message contents visible before the index that publishes them.

```
RING_SIZE :: 256

Ring :: struct {
    head : u32,                  // written only by the consumer
    tail : u32,                  // written only by the producer
    slots : Message[RING_SIZE],
}

ring_push :: fn(ring: ptr[mut Ring], message: Message) -> bool {
    tail :: atomic_load_u32_no_fence(&ring.tail)    // only this side writes tail
    head :: atomic_load_u32_acquire(&ring.head)     // see how far the consumer got
    if tail - head == RING_SIZE {
        return false                                // full
    }
    ring.slots[tail % RING_SIZE] = message
    atomic_store_u32_release(&ring.tail, tail + 1)  // publish: message before index
    return true
}

ring_pop :: fn(ring: ptr[mut Ring]) -> (message: Message, ok: bool) {
    head :: atomic_load_u32_no_fence(&ring.head)
    tail :: atomic_load_u32_acquire(&ring.tail)     // pairs with the release in push
    if head == tail {
        return message, false                       // empty
    }
    message = ring.slots[head % RING_SIZE]
    atomic_store_u32_release(&ring.head, head + 1)  // slot may now be overwritten
    return message, true
}
```

`tail - head` relies on wrapping `u32` arithmetic, which Hemera defines (two's complement,
no panic on overflow) — a nice example of defined behavior paying off.

### Example B: Spinlock (kernel, per-CPU queues)

```
spin_lock :: fn(lock: ptr[mut u32]) {
    with {
        acquired : bool = false
    }
    loop {
        _, acquired = interlocked_compare_exchange_u32_acquire(lock, 1, 0)
        if !acquired {
            // Wait with plain loads so we don't hammer the cache line with writes
            loop {
                cpu_pause()                         // x86 `pause` (arch intrinsic)
            }
            while atomic_load_u32_no_fence(lock) != 0
        }
    }
    while !acquired
}

spin_unlock :: fn(lock: ptr[mut u32]) {
    atomic_store_u32_release(lock, 0)
}
```

Without `atomic_store_u32_release`, unlocking has to use an RMW (`interlocked_exchange`),
which is a full locked instruction for no reason.

### Example C: Reference counting (shared capabilities, `std/memory/SharedPtr`)

The standard pattern needs a **standalone acquire fence**: decrements are `release` so
each owner's writes happen before the count drops, and only the thread that frees the
object pays for an acquire.

```
release_reference :: fn(object: ptr[mut SharedObject]) {
    previous :: interlocked_decrement_i32_release(&object.count)   // returns the old value
    if previous != 1 {
        return void
    }
    fence_acquire()          // see every other owner's writes before destroying
    destroy(object)
}
```

(Separately: `SharedPtr.count` in `std/memory/shared_ptr.hsc` is a plain `u16` updated
with `+=`, so it isn't thread-safe today.)

### Example D: virtio queues (drivers) — the case for `fence_seq_cst`

A virtio driver writes descriptors to shared memory, publishes an index, and then must
check whether the device wants a notification. Publishing (a store) followed by checking
(a load) needs **store→load ordering**, which only a full fence gives:

```
submit :: fn(queue: ptr[mut VirtQueue], descriptor_index: u16) {
    index :: queue.available.index
    queue.available.ring[index % queue.size] = descriptor_index
    fence_release()                                             // ring entry before index
    atomic_store_u16_no_fence(&queue.available.index, index + 1)
    fence_sequentially_consistent()                                             // index store before flags load
    if (atomic_load_u16_no_fence(&queue.used.flags) & VIRTQ_USED_F_NO_NOTIFY) == 0 {
        notify_device(queue)                                    // MMIO write
    }
}
```

Leave out `fence_seq_cst` and on x86 the flag load can be satisfied before the index store
is visible: the device misses the notification and the queue occasionally stalls. This
kind of bug is rare and miserable to find.

### Example E: Sequence lock (kernel-published clock page)

To read the time without a system call, the kernel maps a read-only page into processes
and updates it with a sequence counter. Readers retry if they caught an update halfway.

```
ClockPage :: struct {
    sequence : u32,
    base_nanoseconds : u64,
    base_tsc : u64,
    tsc_multiplier : u64,
}

// Kernel (the only writer)
clock_page_update :: fn(page: ptr[mut ClockPage], nanoseconds, tsc, multiplier: u64) {
    sequence :: atomic_load_u32_no_fence(&page.sequence)
    atomic_store_u32_no_fence(&page.sequence, sequence + 1)   // odd = update in progress
    fence_release()
    atomic_store_u64_no_fence(&page.base_nanoseconds, nanoseconds)
    atomic_store_u64_no_fence(&page.base_tsc, tsc)
    atomic_store_u64_no_fence(&page.tsc_multiplier, multiplier)
    atomic_store_u32_release(&page.sequence, sequence + 2)    // even = stable
}

// Any process
clock_page_read :: fn(page: ptr[ClockPage]) -> (nanoseconds, tsc, multiplier: u64) {
    with {
        before : u32
        after : u32
    }
    loop #at_least_once {     // directive placement assumed by analogy with `#reverse`
        before      = atomic_load_u32_acquire(&page.sequence)
        nanoseconds = atomic_load_u64_no_fence(&page.base_nanoseconds)
        tsc         = atomic_load_u64_no_fence(&page.base_tsc)
        multiplier  = atomic_load_u64_no_fence(&page.tsc_multiplier)
        fence_acquire()                                        // data loads before re-check
        after       = atomic_load_u32_no_fence(&page.sequence)
    }
    while before != after || (before & 1) != 0
    return nanoseconds, tsc, multiplier
}
```

This needs both kinds of standalone fence, and shows why `_no_fence` loads and stores
matter: the payload fields are read concurrently with writes. If they were plain
(non-atomic) accesses, that would be a data race — undefined behavior in C/C++/LLVM.

### Example F: Compiler-only fence (interrupts on the same CPU)

```
// Kernel: per-CPU "don't preempt me" counter, also read by the timer interrupt
// handler on the same CPU. No other CPU touches it, so no hardware barrier is
// needed, but the compiler must not move the critical section outside it.
preempt_disable :: fn(cpu: ptr[mut PerCpu]) {
    cpu.preempt_count += 1
    compiler_fence_sequentially_consistent()
}
```

## 3. Related Language Question: Racy Plain Accesses

Hemera wants as little undefined behavior as possible. In LLVM, a plain load that races
with a store returns `undef`, and in C/C++ the whole program is undefined. Options:
1. Same as C (racy plain access is UB). Simplest, but contradicts Hemera's goals.
2. Define racy plain accesses as `_no_fence` atomics for types that fit in a register
   (LLVM `unordered`): no UB, values may be stale but never torn. Small optimizer cost.
3. Make shared mutable memory a distinct type (e.g. `shared[T]`) that only allows atomic
   access. Most explicit; more typing.

Worth deciding before much lock-free code exists.

## 4. Remaining Gaps (after adoption)

- **Done (2026-10-01):** atomic load/store for `int`, `uint`, `uintptr`; `compiler_fence_acquire_release`;
  `_` to ignore return values (used in the spinlock above).
- **Still open:** atomic operations on pointers (`ptr[T]`). Lock-free linked structures
  (free lists, wait queues) need atomic pointer load/store/compare-exchange. `uintptr` +
  casts works meanwhile but loses the pointer type.
- **Future:** `_weak` compare-exchange and a separate failure ordering, for LL/SC architectures.
- **Minor friction:** the spinlock still needs a `with` block to hold `acquired` across the
  loop condition. Fine, but worth watching as more lock-free code gets written.
