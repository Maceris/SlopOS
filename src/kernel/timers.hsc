package kernel

import runtime from "base"
import concurrency from "std"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
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

NOT_QUEUED : u32 : 0xffffffff

TimerKind :: enum #backed_by(u8) {
    // A port's timer binding: its packet is queued.
    PortTimer,
    // A thread waiting on a port with a deadline: it's woken.
    WaitTimeout,
}

TimerEntry :: struct {
    // In counter ticks.
    deadline : u64,
    // Where it is in its CPU's heap, NOT_QUEUED if it isn't, and that CPU.
    index : u32,
    cpu : u32,
    kind : TimerKind,
    // What it's for, and that's generation when it was armed: a Binding, or a Thread.
    owner : u64,
    owner_generation : u64,
    // The port it's for.
    port : u64,
}

// One CPU's armed timers, earliest first.
TimerHeap :: struct {
    lock : concurrency.SpinLock,
    // Entries' addresses, from the heap allocator.
    entries : mut u64[],
    count : usize,
}

// An entry that isn't armed.
make_timer :: fn() -> TimerEntry {
    result : TimerEntry
    result.index = NOT_QUEUED
    return result
}

/*
 * Arm entry on the calling CPU, at deadline, reprogramming its timer if this comes first. False without
 * memory for the heap to grow.
 */
arm_timer :: fn(entry: ptr[mut TimerEntry], deadline: u64) -> bool {
    cpu :: per_cpu()
    heap :: &cpu.timers
    concurrency.lock(&heap.lock)
    if !grow_heap(heap) {
        concurrency.unlock(&heap.lock)
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
    concurrency.unlock(&heap.lock)
    program_deadline(cpu)
    return true
}

// Disarm entry, wherever it's armed: whether it was.
cancel_timer :: fn(kernel: ptr[Kernel], entry: ptr[mut TimerEntry]) -> bool {
    per_cpus :: kernel.per_cpus
    cpu_index :: cast[usize](entry.cpu)
    if entry.index == NOT_QUEUED || cpu_index >= per_cpus.count {
        return false
    }
    heap :: &cast[ptr[mut PerCpu]](per_cpus[cpu_index]).timers
    concurrency.lock(&heap.lock)
    defer concurrency.unlock(&heap.lock)
    index :: entry.index
    if index == NOT_QUEUED || cast[usize](index) >= heap.count {
        return false
    }
    remove_at(heap, cast[usize](index))
    return true
}

/*
 * Take every entry due by now off the calling CPU's heap and fire it: what each was for, copied while it
 * was still armed.
 */
fire_timers :: fn(kernel: ptr[mut Kernel], now: u64) {
    cpu :: per_cpu()
    heap :: &cpu.timers
    loop {
        concurrency.lock(&heap.lock)
        entries :: heap.entries
        if heap.count == 0 || entries.count == 0 {
            concurrency.unlock(&heap.lock)
            break
        }
        first :: cast[ptr[mut TimerEntry]](entries[0])
        if first.deadline > now {
            concurrency.unlock(&heap.lock)
            break
        }
        fired :: first^
        remove_at(heap, 0)
        concurrency.unlock(&heap.lock)
        match fired.kind {
            case .PortTimer => fire_port_timer(kernel, &fired)
            case .WaitTimeout => fire_wait_timeout(kernel, &fired)
        }
    }
}

// The calling CPU's timer, for its next tick or its earliest deadline.
program_deadline :: fn(cpu: ptr[mut PerCpu]) {
    deadline := cpu.next_tick
    heap :: &cpu.timers
    concurrency.lock(&heap.lock)
    entries :: heap.entries
    if heap.count > 0 && entries.count > 0 {
        earliest :: cast[ptr[TimerEntry]](entries[0]).deadline
        deadline = if earliest < deadline { earliest } else { deadline }
    }
    concurrency.unlock(&heap.lock)
    arch.set_deadline(deadline)
}

// Room for one more entry. Takes the lock as held.
grow_heap :: fn(heap: ptr[mut TimerHeap]) -> bool {
    if heap.count < heap.entries.count {
        return true
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

// Take the entry at index out, keeping the heap's order. Takes the lock as held.
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

deadline_at :: fn(entries: u64[], index: usize) -> u64 {
    runtime.assert(index < entries.count, "deadline_at takes an entry")
    return cast[ptr[TimerEntry]](entries[index]).deadline
}

swap :: fn(entries: mut u64[], a: usize, b: usize) {
    runtime.assert(a < entries.count && b < entries.count, "swap takes two entries")
    held :: entries[a]
    entries[a] = entries[b]
    entries[b] = held
    cast[ptr[mut TimerEntry]](entries[a]).index = cast[u32](a)
    cast[ptr[mut TimerEntry]](entries[b]).index = cast[u32](b)
}
