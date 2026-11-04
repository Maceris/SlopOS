package kernel

import intrinsics from "base"
import runtime from "base"
import concurrency from "std"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * Timers (roadmap M5, knowledge/design/kernel.md §2, ipc.md §3): deadlines on each CPU, in a binary
 * min-heap of entries the things that time out keep themselves (a port's timer binding, a waiting
 * thread), so arming one allocates only when a heap grows. The CPU's timer is programmed for its next
 * tick or its earliest deadline, whichever comes first, so a deadline fires on time rather than at a
 * tick.
 *
 * An entry is armed on the CPU that arms it, and can be cancelled from any CPU. Firing takes it off the
 * heap under the heap's lock, then acts on what it was for without the lock; whatever it was for may
 * have changed meanwhile, which each kind checks (ports.hsc).
 */

/** A TimerEntry's index while it isn't on any heap: never armed, cancelled, or taken off to fire. */
NOT_QUEUED : u32 : 0xffffffff

/** What a timer entry is for, which says what firing it does. */
TimerKind :: enum #backed_by(u8) {
    /** A port's timer binding: its packet is queued on the port (ports.hsc, fire_port_timer). */
    PortTimer,
    /** A thread waiting on a port with a deadline: it's woken (ports.hsc, fire_wait_timeout). */
    WaitTimeout,
}

/**
 * A deadline, kept by what times out (a port's timer binding, a waiting thread) inside itself, and put on a CPU's
 * TimerHeap while it's armed. make_timer makes one that isn't armed.
 */
TimerEntry :: struct {
    /** When it fires, as a value of arch.counter(), in counter ticks. */
    deadline : u64,
    /** Where it is in its CPU's heap, NOT_QUEUED if it isn't on one; changed under that heap's lock. */
    index : u32,
    /** The index of the CPU whose heap it was last armed on; meaningful only while index isn't NOT_QUEUED. */
    cpu : u32,
    /** What it's for, which says what owner is. */
    kind : TimerKind,
    /** What it's for, as an address: a Binding for PortTimer, a Thread for WaitTimeout. Set by whoever arms it. */
    owner : u64,
    /**
     * What owner was when it was armed, so firing can tell it changed since: a binding's generation, or a thread's
     * generation in the high 32 bits and its wait's sequence number in the low.
     */
    owner_generation : u64,
    /** The Port it's for, as an address. */
    port : u64,
}

/** One CPU's armed timers, a binary min-heap by deadline, earliest first. */
TimerHeap :: struct {
    /** Held, at LockRank Timers, while the heap or an entry's index changes; any CPU may take it to cancel. */
    lock : concurrency.SpinLock,
    /**
     * The armed entries' addresses, in heap order, from the kernel heap; empty until the first entry is armed. Its
     * count is the room it has, which only grows, doubling from 16.
     */
    entries : mut u64[],
    /** How many of entries are armed: the first count of them. */
    count : usize,
}

/**
 * Make a timer entry that isn't armed.
 *
 * @return The entry, zeroed but for its index, NOT_QUEUED; its owner, owner_generation, kind and port are the
 *     caller's to set before it's armed.
 */
make_timer :: fn() -> TimerEntry {
    result : TimerEntry
    result.index = NOT_QUEUED
    return result
}

/**
 * Arm a timer entry on the calling CPU's heap, reprogramming the CPU's timer if it comes first.
 *
 * Takes the heap's lock, at LockRank Timers, and may allocate from the kernel heap under it to grow the heap. The
 * entry fires from this CPU's timer interrupt (fire_timers) once the counter reaches its deadline.
 *
 * @param entry The entry, not armed, with its kind, owner, owner_generation and port set. It stays on the heap until
 *     it fires or is cancelled, so it has to stay where it is, and not be freed, until then.
 * @param deadline When it fires, in counter ticks; one already past fires at the CPU's next timer interrupt.
 * @return True if it's armed; false, with it not armed, if the heap had no room and couldn't grow: no memory, or fault
 *     injection failed it.
 */
arm_timer :: fn(entry: ptr[mut TimerEntry], deadline: u64) -> bool {
    cpu :: per_cpu()
    heap :: &cpu.timers
    lock_at(&heap.lock, .Timers)
    if !grow_heap(heap) {
        unlock_at(&heap.lock, .Timers)
        return false
    }
    entry.deadline = deadline
    entry.cpu = cpu.index
    entries :: heap.entries
    count :: heap.count
    runtime.assert(count < entries.count, "grow_heap leaves room")
    entries[count] = cast[u64](entry)
    entry.index = cast[u32](count)
    heap.count = count + 1
    sift_up(heap, count)
    unlock_at(&heap.lock, .Timers)
    program_deadline(cpu)
    return true
}

/**
 * Disarm a timer entry, from any CPU, wherever it's armed.
 *
 * Takes the heap's lock of the CPU it was armed on, at LockRank Timers. An entry that already fired, or is firing, is
 * left alone, and what it was for may still be acted on (fire_timers works from a copy), which is why firing checks
 * owner_generation. The entry's CPU is read before the lock is taken, so it mustn't be armed again at the same time.
 *
 * @param kernel The kernel, whose per_cpus finds the entry's CPU.
 * @param entry The entry: armed, never armed, or already fired or cancelled.
 * @return True if it was armed and is now off its heap; false if it wasn't armed.
 */
cancel_timer :: fn(kernel: ptr[Kernel], entry: ptr[mut TimerEntry]) -> bool {
    per_cpus :: kernel.per_cpus
    cpu_index :: cast[usize](entry.cpu)
    if entry.index == NOT_QUEUED || cpu_index >= per_cpus.count {
        return false
    }
    heap :: &cast[ptr[mut PerCpu]](per_cpus[cpu_index]).timers
    lock_at(&heap.lock, .Timers)
    defer unlock_at(&heap.lock, .Timers)
    index :: entry.index
    if index == NOT_QUEUED || cast[usize](index) >= heap.count {
        return false
    }
    remove_at(heap, cast[usize](index))
    return true
}

/**
 * Fire every entry due by now on the calling CPU's heap, earliest first.
 *
 * Each is taken off the heap under its lock, which is then given back, and fired from a copy made while it was still
 * armed, so what it was for may have changed or gone meanwhile; each kind checks that (ports.hsc). Runs from the
 * CPU's timer interrupt, with no other lock held.
 *
 * @param kernel The kernel, whose fired entries' ports and owners are acted on (ports.hsc), each kind taking the
 *     port's lock. Runs in this CPU's timer interrupt, with interrupts off and no lock held.
 * @param now The counter's value now, in ticks: entries whose deadline is at most this fire.
 */
fire_timers :: fn(kernel: ptr[mut Kernel], now: u64) {
    cpu :: per_cpu()
    heap :: &cpu.timers
    loop {
        lock_at(&heap.lock, .Timers)
        entries :: heap.entries
        if heap.count == 0 || entries.count == 0 {
            unlock_at(&heap.lock, .Timers)
            break
        }
        first :: cast[ptr[mut TimerEntry]](entries[0])
        if first.deadline > now {
            unlock_at(&heap.lock, .Timers)
            break
        }
        fired :: first^
        remove_at(heap, 0)
        unlock_at(&heap.lock, .Timers)
        match fired.kind {
            case .PortTimer => fire_port_timer(kernel, &fired)
            case .WaitTimeout => fire_wait_timeout(kernel, &fired)
        }
    }
}

/**
 * Program a CPU's timer for its next tick or its earliest deadline, whichever comes first.
 *
 * While the CPU idles without ticking, its next tick doesn't count: only its earliest deadline, or none. Takes the
 * heap's lock, at LockRank Timers.
 *
 * @param cpu The calling CPU's PerCpu: the timer programmed is the one of the CPU this runs on.
 */
program_deadline :: fn(cpu: ptr[mut PerCpu]) {
    deadline := if intrinsics.atomic_load_u32_acquire(&cpu.tickless) == 1 { ~cast[u64](0) } else { cpu.next_tick }
    heap :: &cpu.timers
    lock_at(&heap.lock, .Timers)
    entries :: heap.entries
    if heap.count > 0 && entries.count > 0 {
        earliest :: cast[ptr[TimerEntry]](entries[0]).deadline
        deadline = if earliest < deadline { earliest } else { deadline }
    }
    unlock_at(&heap.lock, .Timers)
    arch.set_deadline(deadline)
}

/**
 * Make room in a heap for one more entry, doubling its array from the kernel heap if it's full.
 *
 * @param heap The heap, whose lock the caller holds.
 * @return True if there's room; false if it was full and couldn't grow (no memory, or fault injection failed it),
 *     when it's unchanged.
 */
grow_heap :: fn(heap: ptr[mut TimerHeap]) -> bool {
    if heap.count < heap.entries.count {
        return true
    }
    if fails(.Timers) {
        return false
    }
    size :: if heap.entries.count == 0 { cast[usize](16) } else { heap.entries.count * 2 }
    grown, error :: runtime.new_array(u64, size)
    if error != null {
        return false
    }
    old :: heap.entries
    for i in 0..<heap.count {
        if i < old.count && i < grown.count {
            grown[i] = old[i]
        }
    }
    runtime.free_array(old)
    heap.entries = grown
    return true
}

/**
 * Take the entry at an index off a heap, keeping the heap's order: its index becomes NOT_QUEUED, and the last entry
 * takes its place.
 *
 * @param heap The heap, whose lock the caller holds.
 * @param index The entry's index, below the heap's count; asserted.
 */
remove_at :: fn(heap: ptr[mut TimerHeap], index: usize) {
    entries :: heap.entries
    count :: heap.count
    runtime.assert(index < count && count <= entries.count, "remove_at takes an entry in the heap")
    cast[ptr[mut TimerEntry]](entries[index]).index = NOT_QUEUED
    last :: count - 1
    heap.count = last
    if index == last {
        return void
    }
    entries[index] = entries[last]
    cast[ptr[mut TimerEntry]](entries[index]).index = cast[u32](index)
    sift_up(heap, index)
    sift_down(heap, cast[usize](cast[ptr[TimerEntry]](entries[index]).index))
}

/**
 * Move an entry toward the heap's root while its deadline is earlier than its parent's, updating each moved entry's
 * index.
 *
 * @param heap The heap, whose lock the caller holds.
 * @param start The entry's index; 0 does nothing.
 */
sift_up :: fn(heap: ptr[mut TimerHeap], start: usize) {
    entries :: heap.entries
    index := start
    loop {
        parent :: (index - 1) / 2
        if index >= entries.count || parent >= entries.count || deadline_at(entries, parent) <= deadline_at(entries, index) {
            break
        }
        swap(entries, index, parent)
        index = parent
    }
    while index > 0
}

/**
 * Move an entry away from the heap's root while a child's deadline is earlier than its own, updating each moved
 * entry's index.
 *
 * @param heap The heap, whose lock the caller holds.
 * @param start The entry's index, below the heap's count.
 */
sift_down :: fn(heap: ptr[mut TimerHeap], start: usize) {
    entries :: heap.entries
    count :: heap.count
    index := start
    loop {
        left :: index * 2 + 1
        right :: left + 1
        smallest := index
        if left < count && left < entries.count && smallest < entries.count && deadline_at(entries, left) < deadline_at(entries, smallest) {
            smallest = left
        }
        if right < count && right < entries.count && smallest < entries.count && deadline_at(entries, right) < deadline_at(entries, smallest) {
            smallest = right
        }
        if smallest == index {
            break
        }
        swap(entries, index, smallest)
        index = smallest
    }
    while true
}

/**
 * Read the deadline of a heap's entry.
 *
 * @param entries The heap's entries' addresses.
 * @param index The entry's index, below entries' count; asserted.
 * @return Its deadline, in counter ticks.
 */
deadline_at :: fn(entries: u64[], index: usize) -> u64 {
    runtime.assert(index < entries.count, "deadline_at takes an entry")
    return cast[ptr[TimerEntry]](entries[index]).deadline
}

/**
 * Swap two of a heap's entries, and set each one's index to its new place.
 *
 * @param entries The heap's entries' addresses, whose heap's lock the caller holds.
 * @param a One entry's index, below entries' count; asserted.
 * @param b The other's, below entries' count; asserted.
 */
swap :: fn(entries: mut u64[], a: usize, b: usize) {
    runtime.assert(a < entries.count && b < entries.count, "swap takes two entries")
    held :: entries[a]
    entries[a] = entries[b]
    entries[b] = held
    cast[ptr[mut TimerEntry]](entries[a]).index = cast[u32](a)
    cast[ptr[mut TimerEntry]](entries[b]).index = cast[u32](b)
}
