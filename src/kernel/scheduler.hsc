package kernel

import intrinsics from "base"
import runtime from "base"
import concurrency from "std"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}

/*
 * The dispatcher (roadmap M4, knowledge/design/scheduling.md §2, decisions/0037): each CPU runs the
 * highest-priority ready thread whose budget has time left, round robin within a priority, and threads
 * whose budget is spent, or that have none, round robin in the background band below every priority.
 *
 * Each CPU has its own run queue: a list per level, the background band at level 0 and priority p at
 * p + 1, and a bit per level that has threads. A CPU with nothing to run takes a thread from another's
 * queue. Every timer tick charges the running thread's budget and lets the next thread of the same or a
 * higher level run; a thread made ready at a higher level than what its CPU runs gets a reschedule IPI
 * there at once.
 *
 * A thread's level is worked out when it's queued, so one whose budget comes back while it waits in the
 * background band moves up only once it's run again: within a tick, since the band is round robin.
 */
//SPEC: knowledge/design/scheduling.md §2 (dispatch, Demote, replenishment)

LEVELS :: 257
BACKGROUND_LEVEL : u32 : 0
// PerCpu.current_level while it has no thread.
IDLE_LEVEL : u32 : 0xffffffff

RunQueue :: struct {
    lock : concurrency.SpinLock,
    first : u64[LEVELS],
    last : u64[LEVELS],
    // A bit per level with threads.
    nonempty : u64[5],
    count : u32,
}

// The level thread runs at now: its budget's priority while it has time, the background band otherwise.
level_of :: fn(thread: ptr[Thread], now: u64) -> u32 {
    if thread.budget == 0 {
        return BACKGROUND_LEVEL
    }
    budget :: cast[ptr[mut CpuBudget]](thread.budget)
    return if has_time(budget, now) { cast[u32](budget.priority) + 1 } else { BACKGROUND_LEVEL }
}

/*
 * Put thread on cpu_index's run queue, and if it should run there before what runs there now, tell that
 * CPU at once.
 */
make_ready :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], cpu_index: u32) {
    per_cpus :: kernel.per_cpus
    runtime.assert(cast[usize](cpu_index) < per_cpus.count, "make_ready takes an online CPU")
    target :: cast[ptr[mut PerCpu]](per_cpus[cpu_index])
    level :: level_of(thread, arch.counter())
    thread.state = .Ready
    thread.cpu = cpu_index
    concurrency.lock(&target.run_queue.lock)
    enqueue(&target.run_queue, thread, level)
    concurrency.unlock(&target.run_queue.lock)
    running :: intrinsics.atomic_load_u32_acquire(&target.current_level)
    if target != per_cpu() && (running == IDLE_LEVEL || level > running) {
        cpus :: kernel.cpus
        runtime.assert(cast[usize](cpu_index) < cpus.count, "every online CPU is in kernel.cpus")
        arch.send_ipi(cpus[cpu_index].hardware_id, .Reschedule)
    }
}

/*
 * Run what should run next on the calling CPU, after an entry: at a tick, the next thread of the same
 * level or higher, round robin; at any other entry, a thread of a higher level than the current one,
 * which otherwise goes on. With no thread, a ready one here or on another CPU, or idle.
 */
schedule :: fn(tick: bool) #never_returns {
    cpu :: per_cpu()
    kernel :: cpu.kernel
    now :: arch.counter()
    current :: cpu.current
    current_level := IDLE_LEVEL
    if current != 0 {
        account(cpu, cast[ptr[mut Thread]](current), now)
        current_level = level_of(cast[ptr[Thread]](current), now)
    }
    next := cast[u64](0)
    concurrency.lock(&cpu.run_queue.lock)
    best :: highest_level(&cpu.run_queue)
    if best != IDLE_LEVEL && (current == 0 || best > current_level || (tick && best == current_level)) {
        next = dequeue(&cpu.run_queue, best)
    }
    concurrency.unlock(&cpu.run_queue.lock)
    if next == 0 && current == 0 {
        next = steal(kernel, cpu)
    }
    if next == 0 {
        if current != 0 {
            go_on(cpu, cast[ptr[mut Thread]](current), current_level)
        }
        go_idle(cpu)
    }
    if current != 0 {
        // Saved before it's queued, where another CPU may take it
        thread :: cast[ptr[mut Thread]](current)
        arch.save_vector_state(cast[ptr[mut arch.VectorState]](thread.vector))
        thread.state = .Ready
        concurrency.lock(&cpu.run_queue.lock)
        enqueue(&cpu.run_queue, thread, current_level)
        concurrency.unlock(&cpu.run_queue.lock)
    }
    run(cpu, cast[ptr[mut Thread]](next), now)
}

// Charge the time since the current thread started running, or since the last charge.
account :: fn(cpu: ptr[mut PerCpu], thread: ptr[mut Thread], now: u64) {
    used :: now - cpu.run_start
    thread.run_time += used
    if thread.budget != 0 {
        charge(cast[ptr[mut CpuBudget]](thread.budget), cpu.run_start, used, now)
    }
    cpu.run_start = now
}

// Switch to thread: its vector state, its address space, its registers.
run :: fn(cpu: ptr[mut PerCpu], thread: ptr[mut Thread], now: u64) #never_returns {
    thread.state = .Running
    thread.cpu = cpu.index
    cpu.current = cast[u64](thread)
    intrinsics.atomic_store_u32_release(&cpu.current_level, thread.level)
    cpu.run_start = now
    arch.restore_vector_state(cast[ptr[arch.VectorState]](thread.vector))
    if cpu.space != cast[u64](thread.space) {
        arch.activate(&thread.space.table)
        cpu.space = cast[u64](thread.space)
    }
    arch.return_to_user(&thread.registers)
}

// Back to the current thread, whose registers, vector state and address space are all still its own.
go_on :: fn(cpu: ptr[mut PerCpu], thread: ptr[mut Thread], level: u32) #never_returns {
    thread.level = level
    intrinsics.atomic_store_u32_release(&cpu.current_level, level)
    arch.return_to_user(&thread.registers)
}

go_idle :: fn(cpu: ptr[mut PerCpu]) #never_returns {
    cpu.current = 0
    intrinsics.atomic_store_u32_release(&cpu.current_level, IDLE_LEVEL)
    arch.idle()
}

// A ready thread from another online CPU's run queue, its highest level's first, or 0.
steal :: fn(kernel: ptr[Kernel], cpu: ptr[PerCpu]) -> u64 {
    per_cpus :: kernel.per_cpus
    online :: cast[usize](intrinsics.atomic_load_u32_acquire(&kernel.online_cpus))
    for offset in 1..<online {
        index :: (cast[usize](cpu.index) + offset) % online
        if index >= per_cpus.count || per_cpus[index] == 0 {
            continue
        }
        other :: cast[ptr[mut PerCpu]](per_cpus[index])
        if intrinsics.atomic_load_u32_acquire(&other.run_queue.count) == 0 {
            continue
        }
        concurrency.lock(&other.run_queue.lock)
        level :: highest_level(&other.run_queue)
        taken :: if level != IDLE_LEVEL { dequeue(&other.run_queue, level) } else { cast[u64](0) }
        concurrency.unlock(&other.run_queue.lock)
        if taken != 0 {
            return taken
        }
    }
    return 0
}

// The highest level with threads, or IDLE_LEVEL. Takes the lock as held.
highest_level :: fn(queue: ptr[RunQueue]) -> u32 {
    for word in 0..<5 #reverse {
        bits :: queue.nonempty[word]
        if bits != 0 {
            return cast[u32](word * 64) + highest_bit(bits)
        }
    }
    return IDLE_LEVEL
}

// The highest set bit of a value that has one, by halves.
highest_bit :: fn(value: u64) -> u32 {
    bits := value
    result : u32 = 0
    for shift in u32.[32, 16, 8, 4, 2, 1] {
        if bits >> cast[u64](shift) != 0 {
            bits >>= cast[u64](shift)
            result += shift
        }
    }
    return result
}

// Append thread to its level's list. Takes the lock as held.
enqueue :: fn(queue: ptr[mut RunQueue], thread: ptr[mut Thread], level: u32) {
    index :: cast[usize](level) % LEVELS
    thread.level = cast[u32](index)
    thread.next = 0
    thread.previous = queue.last[index]
    if queue.last[index] != 0 {
        cast[ptr[mut Thread]](queue.last[index]).next = cast[u64](thread)
    }
    else {
        queue.first[index] = cast[u64](thread)
    }
    queue.last[index] = cast[u64](thread)
    queue.nonempty[index / 64 % 5] |= cast[u64](1) << cast[u64](index % 64)
    intrinsics.atomic_store_u32_release(&queue.count, queue.count + 1)
}

// The first thread at level, taken off. Takes the lock as held.
dequeue :: fn(queue: ptr[mut RunQueue], level: u32) -> u64 {
    index :: cast[usize](level) % LEVELS
    first :: queue.first[index]
    runtime.assert(first != 0, "dequeue takes a level with threads")
    thread :: cast[ptr[mut Thread]](first)
    queue.first[index] = thread.next
    if thread.next != 0 {
        cast[ptr[mut Thread]](thread.next).previous = 0
    }
    else {
        queue.last[index] = 0
        queue.nonempty[index / 64 % 5] &= ~(cast[u64](1) << cast[u64](index % 64))
    }
    thread.next = 0
    intrinsics.atomic_store_u32_release(&queue.count, queue.count - 1)
    return first
}
