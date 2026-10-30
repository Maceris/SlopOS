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
 * The dispatcher (roadmap M4, knowledge/design/scheduling.md §2, decisions/0037, 0050): each CPU runs
 * the highest-priority ready thread whose budget has time left, round robin within a priority, and
 * threads whose budget is spent, or that have none, round robin in the background band below every
 * priority.
 *
 * Each CPU has its own run queue: a list per level, the background band at level 0 and priority p at
 * p + 1, and a bit per level that has threads. A CPU with nothing to run takes a thread from another's
 * queue. Every timer tick charges the running thread's budget and lets the next thread of the same or a
 * higher level run; a thread made ready at a higher level than what its CPU runs gets a reschedule IPI
 * there at once.
 *
 * A thread's level is worked out when it's queued. One whose budget comes back while it waits in the background
 * band is moved up at the next tick (relevel): without that, a thread queued there while its budget was spent would
 * wait behind every thread running at its budget's priority, which could be for good, as a budget shared by threads
 * that keep its CPUs busy never runs out again.
 *
 * A thread runs only on its budget's CPUs (decisions/0099): it's made ready on one of them, a CPU steals only threads
 * that may run on it, and one found on a CPU it may no longer run on, as its budget's CPUs changed, is moved.
 *
 * Returning to user mode and going idle are quiescent points (objects.hsc): the CPU first switches its
 * page tables to what it runs next, then reads the epoch, then checks that the thread it resumes isn't
 * being destroyed, and only then says it's quiescent. So a thread destroyed in an earlier epoch is never
 * resumed, and nothing is freed while a CPU still uses it.
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
    budget :: cast[ptr[mut CpuTime]](thread.budget)
    return if has_time(budget, now) { cast[u32](budget.priority) + 1 } else { BACKGROUND_LEVEL }
}

/*
 * Put thread on cpu_index's run queue, and if it should run there before what runs there now, tell that
 * CPU at once.
 */
make_ready :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], asked: u32) {
    per_cpus :: kernel.per_cpus
    cpu_index :: cpu_for(kernel, thread, asked)
    runtime.assert(cast[usize](cpu_index) < per_cpus.count, "make_ready takes an online CPU")
    target :: cast[ptr[mut PerCpu]](per_cpus[cpu_index])
    level :: level_of(thread, arch.counter())
    thread.state = .Ready
    concurrency.lock(&target.run_queue.lock)
    intrinsics.atomic_store_u32_release(&thread.cpu, cpu_index)
    enqueue(&target.run_queue, thread, level)
    concurrency.unlock(&target.run_queue.lock)
    running :: intrinsics.atomic_load_u32_acquire(&target.current_level)
    if target != per_cpu() && (running == IDLE_LEVEL || level > running) {
        cpus :: kernel.cpus
        runtime.assert(cast[usize](cpu_index) < cpus.count, "every online CPU is in kernel.cpus")
        arch.send_ipi(cpus[cpu_index].hardware_id, .Reschedule)
    }
}

// Whether thread may run on the CPU with index cpu_index: any, without a budget, or one of its budget's.
may_run_on :: fn(thread: ptr[Thread], cpu_index: u32) -> bool {
    if thread.budget == 0 || cpu_index >= 64 {
        return true
    }
    cpus :: intrinsics.atomic_load_u64_acquire(&cast[ptr[mut CpuTime]](thread.budget).cpus)
    return (cpus >> cast[u64](cpu_index)) & 1 != 0
}

// cpu_index if thread may run there, otherwise the next online CPU after it that it may, or cpu_index if none.
cpu_for :: fn(kernel: ptr[Kernel], thread: ptr[Thread], cpu_index: u32) -> u32 {
    if may_run_on(thread, cpu_index) {
        return cpu_index
    }
    online :: intrinsics.atomic_load_u32_acquire(&kernel.online_cpus)
    for offset in 1..<online {
        index :: (cpu_index + offset) % online
        if may_run_on(thread, index) {
            return index
        }
    }
    return cpu_index
}

/*
 * Run what should run next on the calling CPU, after an entry: at a tick, the next thread of the same
 * level or higher, round robin; at any other entry, a thread of a higher level than the current one,
 * which otherwise goes on. With no thread, a ready one here or on another CPU, or idle. A thread being
 * destroyed is dropped wherever it's found.
 */
schedule :: fn(tick: bool) #never_returns {
    cpu :: per_cpu()
    kernel :: cpu.kernel
    loop {
        now :: arch.counter()
        current := cpu.current
        if current != 0 && is_dying(current) {
            cpu.current = 0
            current = 0
        }
        // Held while it ran (control.hsc): parked, its registers and vector state saved
        if current != 0 && park_if_held(cast[ptr[mut Thread]](current), true) {
            cpu.current = 0
            current = 0
        }
        current_level := IDLE_LEVEL
        if current != 0 {
            account(cpu, cast[ptr[mut Thread]](current), now)
            current_level = level_of(cast[ptr[Thread]](current), now)
        }
        // Its budget's CPUs changed while it ran, and this isn't one: made ready on one that is
        if current != 0 && cpu_for(kernel, cast[ptr[Thread]](current), cpu.index) != cpu.index {
            thread :: cast[ptr[mut Thread]](current)
            arch.save_vector_state(cast[ptr[mut arch.VectorState]](thread.vector))
            cpu.current = 0
            current = 0
            current_level = IDLE_LEVEL
            make_ready(kernel, thread, cpu.index)
        }
        next := cast[u64](0)
        concurrency.lock(&cpu.run_queue.lock)
        if tick {
            relevel(&cpu.run_queue, now)
        }
        next = pick(&cpu.run_queue, now, current, current_level, tick)
        concurrency.unlock(&cpu.run_queue.lock)
        // Queued here before its budget's CPUs changed
        if next != 0 && cpu_for(kernel, cast[ptr[Thread]](next), cpu.index) != cpu.index {
            make_ready(kernel, cast[ptr[mut Thread]](next), cpu.index)
            continue
        }
        if next == 0 && current == 0 {
            next = steal(kernel, cpu)
        }
        if next == 0 && current == 0 {
            go_idle(kernel, cpu)
        }
        if next == 0 {
            go_on(kernel, cpu, cast[ptr[mut Thread]](current), current_level)
            continue
        }
        if current != 0 {
            // Saved before it's queued, where another CPU may take it
            thread :: cast[ptr[mut Thread]](current)
            arch.save_vector_state(cast[ptr[mut arch.VectorState]](thread.vector))
            thread.state = .Ready
            concurrency.lock(&cpu.run_queue.lock)
            enqueue(&cpu.run_queue, thread, current_level)
            concurrency.unlock(&cpu.run_queue.lock)
            cpu.current = 0
        }
        run(kernel, cpu, cast[ptr[mut Thread]](next), now)
    }
}

// Charge the time since the current thread started running, or since the last charge.
account :: fn(cpu: ptr[mut PerCpu], thread: ptr[mut Thread], now: u64) {
    used :: now - cpu.run_start
    thread.run_time += used
    if thread.budget != 0 {
        charge(cast[ptr[mut CpuTime]](thread.budget), cpu.run_start, used, now)
    }
    cpu.run_start = now
}

/*
 * Switch to thread: its address space, its vector state, its registers. Returns only if it turns out to
 * be dying.
 */
run :: fn(kernel: ptr[mut Kernel], cpu: ptr[mut PerCpu], thread: ptr[mut Thread], now: u64) {
    if cpu.space != cast[u64](thread.space) {
        arch.activate(&thread.space.table)
        cpu.space = cast[u64](thread.space)
    }
    epoch :: intrinsics.atomic_load_u64(&kernel.epoch)
    if is_dying(cast[u64](thread)) {
        return void
    }
    // A woken thread finishes its wait first, or blocks again; then stops at its call's exit, if it's intercepted
    if thread.wait_port != 0 {
        if !complete_wait(kernel, thread) {
            return void
        }
        if stop_thread(kernel, thread, .SyscallExit, thread.syscall_number, 0, false) {
            return void
        }
    }
    // Held while it waited or was queued (control.hsc)
    if park_if_held(thread, false) {
        return void
    }
    pass_quiescent(kernel, cpu, epoch)
    thread.state = .Running
    intrinsics.atomic_store_u32_release(&thread.cpu, cpu.index)
    cpu.current = cast[u64](thread)
    intrinsics.atomic_store_u32_release(&cpu.current_level, thread.level)
    cpu.run_start = now
    arch.restore_vector_state(cast[ptr[arch.VectorState]](thread.vector))
    arch.return_to_user(&thread.registers)
}

/*
 * Back to the current thread, whose registers, vector state and address space are all still its own.
 * Returns only if it turns out to be dying.
 */
go_on :: fn(kernel: ptr[mut Kernel], cpu: ptr[mut PerCpu], thread: ptr[mut Thread], level: u32) {
    epoch :: intrinsics.atomic_load_u64(&kernel.epoch)
    if is_dying(cast[u64](thread)) {
        return void
    }
    pass_quiescent(kernel, cpu, epoch)
    thread.level = level
    intrinsics.atomic_store_u32_release(&cpu.current_level, level)
    arch.return_to_user(&thread.registers)
}

// Nothing to run: the kernel's own page tables, so no address space stays active here, then idle.
go_idle :: fn(kernel: ptr[mut Kernel], cpu: ptr[mut PerCpu]) #never_returns {
    cpu.current = 0
    intrinsics.atomic_store_u32_release(&cpu.current_level, IDLE_LEVEL)
    if cpu.space != 0 {
        arch.activate(&kernel.page_table)
        cpu.space = 0
    }
    pass_quiescent(kernel, cpu, intrinsics.atomic_load_u64(&kernel.epoch))
    arch.idle()
}

// A ready thread that may run on cpu from another online CPU's run queue, the first at its highest level, or 0.
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
        taken :: take_for(&other.run_queue, cpu.index)
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
    thread.queued = true
    intrinsics.atomic_store_u32_release(&queue.count, queue.count + 1)
}

/*
 * Every thread in the background band whose budget has time again, moved up to its budget's level, behind what's
 * there. Takes the lock as held.
 */
relevel :: fn(queue: ptr[mut RunQueue], now: u64) {
    at := queue.first[BACKGROUND_LEVEL]
    loop {
        if at == 0 {
            break
        }
        thread :: cast[ptr[mut Thread]](at)
        at = thread.next
        level :: level_of(thread, now)
        if level != BACKGROUND_LEVEL {
            unlink(queue, thread)
            enqueue(queue, thread, level)
        }
    }
}

/*
 * The thread to run next instead of current, at current_level, or 0 to go on with it: the first at the highest level,
 * if that's above current's, or the same at a tick. A thread waiting at a level its budget no longer has time for, spent
 * by another of its budget's threads meanwhile, is moved down to where it belongs first, so a budget's threads together
 * never run past it by more than a tick. Takes the lock as held.
 */
pick :: fn(queue: ptr[mut RunQueue], now: u64, current: u64, current_level: u32, tick: bool) -> u64 {
    loop {
        best :: highest_level(queue)
        if best == IDLE_LEVEL || (current != 0 && best < current_level) || (current != 0 && best == current_level && !tick) {
            return 0
        }
        candidate :: dequeue(queue, best)
        level :: level_of(cast[ptr[Thread]](candidate), now)
        if level == best || level == BACKGROUND_LEVEL && best == BACKGROUND_LEVEL {
            return candidate
        }
        enqueue(queue, cast[ptr[mut Thread]](candidate), level)
    }
}

// The first thread at the highest level that may run on cpu_index, taken off, or 0. Takes the lock as held.
take_for :: fn(queue: ptr[mut RunQueue], cpu_index: u32) -> u64 {
    for level in 0..<LEVELS #reverse {
        index :: cast[usize](level)
        if queue.nonempty[index / 64 % 5] & (cast[u64](1) << cast[u64](index % 64)) != 0 {
            at := queue.first[index]
            loop {
                if at == 0 {
                    break
                }
                thread :: cast[ptr[mut Thread]](at)
                if may_run_on(thread, cpu_index) {
                    unlink(queue, thread)
                    return at
                }
                at = thread.next
            }
        }
    }
    return 0
}

// The first thread at level, taken off. Takes the lock as held.
dequeue :: fn(queue: ptr[mut RunQueue], level: u32) -> u64 {
    index :: cast[usize](level) % LEVELS
    first :: queue.first[index]
    runtime.assert(first != 0, "dequeue takes a level with threads")
    unlink(queue, cast[ptr[mut Thread]](first))
    return first
}

// Take thread off its level's list. Takes the lock as held.
unlink :: fn(queue: ptr[mut RunQueue], thread: ptr[mut Thread]) {
    index :: cast[usize](thread.level) % LEVELS
    if thread.previous != 0 {
        cast[ptr[mut Thread]](thread.previous).next = thread.next
    }
    else {
        queue.first[index] = thread.next
    }
    if thread.next != 0 {
        cast[ptr[mut Thread]](thread.next).previous = thread.previous
    }
    else {
        queue.last[index] = thread.previous
    }
    if queue.first[index] == 0 {
        queue.nonempty[index / 64 % 5] &= ~(cast[u64](1) << cast[u64](index % 64))
    }
    thread.next = 0
    thread.previous = 0
    thread.queued = false
    intrinsics.atomic_store_u32_release(&queue.count, queue.count - 1)
}
