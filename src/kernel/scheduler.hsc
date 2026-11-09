package kernel

import intrinsics from "base"
import slop_os from "std/os"
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

/** How many run-queue levels there are: the background band, then one for each of 256 priorities. */
LEVELS :: 257
/** The background band's level, below every priority: threads whose budget is spent, or that have none. */
BACKGROUND_LEVEL : u32 : 0
/** PerCpu.current_level while it has no thread. */
IDLE_LEVEL : u32 : 0xffffffff

/** One CPU's ready threads: a list per level, round robin within each. */
RunQueue :: struct {
    /** Held, at rank RunQueue, while the queue or a queued thread's links change. */
    lock : concurrency.SpinLock,
    /** Each level's first thread, as an address, 0 when it has none. */
    first : u64[LEVELS],
    /** Each level's last thread, as an address, 0 when it has none. */
    last : u64[LEVELS],
    /** A bit per level with threads, level l at bit l % 64 of word l / 64. */
    nonempty : u64[5],
    /** How many threads are queued; written with a release store under the lock, read without it as a hint. */
    count : u32,
}

/**
 * Work out the level a thread runs at now: its budget's priority while it has time, the background band otherwise.
 *
 * Takes the CpuTime's lock, at rank CpuTime, as replenishing it may change it.
 *
 * @param thread The thread, whose budget, a CpuTime, may be replenished: read while the caller holds at most locks
 *     below rank CpuTime, as a run queue's.
 * @param now The counter's value now, in ticks.
 * @return Its budget's priority plus 1, from 1 to 256, if its budget has time at now; BACKGROUND_LEVEL if it doesn't,
 *     or the thread has no budget.
 */
level_of :: fn(thread: ptr[Thread], now: u64) -> u32 {
    if thread.budget == 0 {
        return BACKGROUND_LEVEL
    }
    budget :: cast[ptr[mut CpuTime]](thread.budget)
    return if has_time(budget, now) { cast[u32](budget.priority) + 1 } else { BACKGROUND_LEVEL }
}

/**
 * Make a thread ready: put it on a CPU's run queue, at the level it runs at now, and if it should run there before
 * what runs there now, tell that CPU at once with a reschedule IPI.
 *
 * If it's queued behind what runs there, a CPU idle without ticking, if there is one, gets the IPI instead, so it
 * can steal it. Takes the target's run-queue lock, at rank RunQueue, so it's called with no lock held of that rank
 * or above.
 *
 * @param kernel The kernel: kernel.per_cpus and kernel.cpus find the target and its interrupt ID, and the target's
 *     run-queue lock is taken, at rank RunQueue.
 * @param thread The thread, on no run queue, not running, and not being destroyed by the caller.
 * @param asked The index of the CPU it's wanted on, an online one; if its budget's CPUs don't include it, the next
 *     online CPU after it that they do is used (cpu_for).
 */
make_ready :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], asked: u32) {
    per_cpus :: kernel.per_cpus
    cpu_index :: cpu_for(kernel, thread, asked)
    runtime.assert(cast[usize](cpu_index) < per_cpus.count, "make_ready takes an online CPU")
    target :: cast[ptr[mut PerCpu]](per_cpus[cpu_index])
    level :: level_of(thread, arch.counter())
    thread.state = .Ready
    trace_event(kernel, .Wake, thread.id, cast[u64](cpu_index))
    lock_at(&target.run_queue.lock, .RunQueue)
    intrinsics.atomic_store_u32_release(&thread.cpu, cpu_index)
    enqueue(&target.run_queue, thread, level)
    unlock_at(&target.run_queue.lock, .RunQueue)
    running :: intrinsics.atomic_load_u32_acquire(&target.current_level)
    if target != per_cpu() && (running == IDLE_LEVEL || level > running) {
        cpus :: kernel.cpus
        runtime.assert(cast[usize](cpu_index) < cpus.count, "every online CPU is in kernel.cpus")
        arch.send_ipi(cpus[cpu_index].hardware_id, .Reschedule)
    }
    else if running != IDLE_LEVEL {
        // Queued behind what runs there: an idle CPU that isn't ticking wouldn't look to steal it, so it's woken to
        idle :: tickless_cpu(kernel, cpu_index)
        cpus :: kernel.cpus
        if idle != NO_CPU && cast[usize](idle) < cpus.count && idle != per_cpu().index {
            arch.send_ipi(cpus[idle].hardware_id, .Reschedule)
        }
    }
}

/**
 * Tell whether a thread may run on a CPU: any, without a budget, or one of its budget's.
 *
 * @param thread The thread, whose budget's CPUs are read atomically, without a lock.
 * @param cpu_index The CPU's index; one past 63 is always allowed, as a budget's set has 64 bits (decisions/0099).
 * @return True if it may run there.
 */
may_run_on :: fn(thread: ptr[Thread], cpu_index: u32) -> bool {
    if thread.budget == 0 || cpu_index >= 64 {
        return true
    }
    cpus :: intrinsics.atomic_load_u64_acquire(&cast[ptr[mut CpuTime]](thread.budget).cpus)
    return (cpus >> cast[u64](cpu_index)) & 1 != 0
}

/**
 * Choose the CPU a thread goes on, near the one asked for.
 *
 * @param kernel The kernel, for the online CPUs.
 * @param thread The thread, whose budget's CPUs are read atomically, without a lock.
 * @param cpu_index The CPU asked for, by index.
 * @return cpu_index if the thread may run there; otherwise the next online CPU after it, wrapping round, that it may;
 *     or cpu_index if it may run on none.
 */
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

/**
 * Run what should run next on the calling CPU, after an entry: at a tick, the next thread of the same
 * level or higher, round robin; at any other entry, a thread of a higher level than the current one,
 * which otherwise goes on. With no thread, a ready one here or on another CPU, or idle. A thread being
 * destroyed is dropped wherever it's found.
 *
 * The current thread is charged for its time first. One that's held is parked, and one that may no longer run on
 * this CPU is made ready on one it may. Called on the CPU's kernel stack, with interrupts off and no lock held; it
 * leaves through return_to_user or idle.
 *
 * @param tick Whether this entry is a timer tick: threads of the current one's level get their turn, and threads in
 *     the background band whose budget has time again move up (relevel).
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
            // Its per-thread page's binding, if it changed: the loan its fiber scheduler put it on (thread_pages.hsc)
            bind_from_page(kernel, cast[ptr[mut Thread]](current))
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
        lock_at(&cpu.run_queue.lock, .RunQueue)
        if tick {
            relevel(&cpu.run_queue, now)
        }
        next = pick(&cpu.run_queue, now, current, current_level, tick)
        unlock_at(&cpu.run_queue.lock, .RunQueue)
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
            lock_at(&cpu.run_queue.lock, .RunQueue)
            enqueue(&cpu.run_queue, thread, current_level)
            unlock_at(&cpu.run_queue.lock, .RunQueue)
            cpu.current = 0
        }
        run(kernel, cpu, cast[ptr[mut Thread]](next), now)
    }
}

/**
 * Charge the time since the current thread started running, or since the last charge, to it and its budget.
 *
 * @param cpu The calling CPU's PerCpu, whose run_start becomes now.
 * @param thread The CPU's current thread.
 * @param now The counter's value now, in ticks, no earlier than run_start.
 */
account :: fn(cpu: ptr[mut PerCpu], thread: ptr[mut Thread], now: u64) {
    used :: now - cpu.run_start
    thread.run_time += used
    if thread.budget != 0 {
        charge(cast[ptr[mut CpuTime]](thread.budget), cpu.run_start, used, now)
    }
    // Its process's time, and its budget's run by others, a loan's, for attribution (decisions/0185)
    owner :: thread.header.owner
    if owner != 0 {
        process :: cast[ptr[mut Process]](owner)
        _ = intrinsics.interlocked_exchange_add_u64(&process.run_time, used)
        if thread.budget_object != 0 && process.cpu_budget != thread.budget_object {
            _ = intrinsics.interlocked_exchange_add_u64(&cast[ptr[mut CpuBudget]](thread.budget_object).run_by_others, used)
        }
    }
    cpu.run_start = now
}

/**
 * Switch to a thread: its address space, its vector state, its registers, and return to user mode in it.
 *
 * A woken thread finishes its port wait first, and may stop at its call's exit; a held one is parked. This is a
 * quiescent point (pass_quiescent), passed only once the thread is known not to be dying.
 *
 * It returns only when the thread doesn't run after all: it's dying, its wait blocked it again, it stopped, or it
 * was parked. The caller then looks for another.
 *
 * @param kernel The kernel, whose epoch is read for the quiescent point, and whose objects past their grace period
 *     this CPU frees there.
 * @param cpu The calling CPU's PerCpu, which has no current thread.
 * @param thread The thread, off every run queue.
 * @param now The counter's value now, in ticks, from which its running is charged.
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
    trace_event(kernel, .Switch, thread.id, running_fiber_of(kernel, thread))
    intrinsics.atomic_store_u32_release(&thread.cpu, cpu.index)
    cpu.current = cast[u64](thread)
    intrinsics.atomic_store_u32_release(&cpu.current_level, thread.level)
    cpu.run_start = now
    arch.restore_vector_state(cast[ptr[arch.VectorState]](thread.vector))
    prepare_return(thread)
    arch.return_to_user(&thread.registers)
}

/**
 * Go back to the current thread, whose registers, vector state and address space are all still its own: a
 * quiescent point (pass_quiescent).
 *
 * It returns only if the thread turns out to be dying; the caller then looks for another.
 *
 * @param kernel The kernel, whose epoch is read for the quiescent point.
 * @param cpu The calling CPU's PerCpu.
 * @param thread The CPU's current thread.
 * @param level The level it runs at now, which current_level becomes.
 */
go_on :: fn(kernel: ptr[mut Kernel], cpu: ptr[mut PerCpu], thread: ptr[mut Thread], level: u32) {
    epoch :: intrinsics.atomic_load_u64(&kernel.epoch)
    if is_dying(cast[u64](thread)) {
        return void
    }
    pass_quiescent(kernel, cpu, epoch)
    thread.level = level
    intrinsics.atomic_store_u32_release(&cpu.current_level, level)
    prepare_return(thread)
    arch.return_to_user(&thread.registers)
}

/**
 * Go idle, with nothing to run: switch to the kernel's own page tables, so no address space stays active here, pass
 * a quiescent point, and wait for an interrupt.
 *
 * A CPU other than the boot CPU with nothing queued and nothing in limbo stops ticking until an interrupt wakes it.
 *
 * @param kernel The kernel: its page tables are activated, and its epoch read for the quiescent point.
 * @param cpu The calling CPU's PerCpu, whose current thread is cleared.
 */
go_idle :: fn(kernel: ptr[mut Kernel], cpu: ptr[mut PerCpu]) #never_returns {
    cpu.current = 0
    intrinsics.atomic_store_u32_release(&cpu.current_level, IDLE_LEVEL)
    if cpu.space != 0 {
        arch.activate(&kernel.page_table)
        cpu.space = 0
    }
    pass_quiescent(kernel, cpu, intrinsics.atomic_load_u64(&kernel.epoch))
    /*
     * Tickless (decisions/0127, 0128): with nothing queued and nothing waiting for a grace period, its timer is armed
     * only for its own timers, and it counts as quiescent until an interrupt wakes it. Not the boot CPU, whose ticks
     * keep the kernel's own time for stopping and its tests. A thread made ready here wakes it (make_ready).
     */
    if cpu.index != 0 && !kernel.options.test_lockup && intrinsics.atomic_load_u32_acquire(&cpu.run_queue.count) == 0 &&
        cpu.limbo == 0 {
        intrinsics.atomic_store_u32_release(&cpu.tickless, 1)
        intrinsics.atomic_store_u64(&cpu.quiescent_epoch, IDLE_EPOCH)
        program_deadline(cpu)
    }
    arch.idle()
}

/**
 * Leave idle, as an interrupt wakes the calling CPU: one that wasn't ticking records the epoch now, before anything
 * it runs could reach an object, renews its heartbeat for lockup detection (lockups.hsc), and ticks again from now,
 * its next tick a tick's time away.
 *
 * Called at an interrupt's entry, on the CPU's kernel stack; a CPU that was ticking is left as it was.
 */
leave_idle :: fn() {
    cpu :: per_cpu()
    if intrinsics.atomic_load_u32_acquire(&cpu.tickless) == 0 {
        return void
    }
    intrinsics.atomic_store_u64(&cpu.quiescent_epoch, intrinsics.atomic_load_u64(&cpu.kernel.epoch))
    now :: arch.counter()
    // Its heartbeat is from before it idled: renewed before it counts as ticking again, so no other CPU sees it stale
    intrinsics.atomic_store_u64_release(&cpu.heartbeat, now)
    intrinsics.fence_sequentially_consistent()
    intrinsics.atomic_store_u32_release(&cpu.tickless, 0)
    cpu.next_tick = now + cpu.kernel.counter_frequency / TICKS_PER_SECOND
    program_deadline(cpu)
}

/**
 * Find an idle CPU that isn't ticking, which a busy CPU's queue wakes to steal from it.
 *
 * @param kernel The kernel, whose online CPUs' tickless flags are read atomically.
 * @param skip The index of a CPU not to choose, the busy one.
 * @return The lowest such CPU's index, or NO_CPU if there's none.
 */
tickless_cpu :: fn(kernel: ptr[Kernel], skip: u32) -> u32 {
    per_cpus :: kernel.per_cpus
    online :: cast[usize](intrinsics.atomic_load_u32_acquire(&kernel.online_cpus))
    for index in 0..<online {
        if index < per_cpus.count && per_cpus[index] != 0 && cast[u32](index) != skip {
            other :: cast[ptr[PerCpu]](per_cpus[index])
            if intrinsics.atomic_load_u32_acquire(&other.tickless) == 1 {
                return cast[u32](index)
            }
        }
    }
    return NO_CPU
}

/** No CPU: what tickless_cpu finds when no CPU is idle without ticking. */
NO_CPU : u32 : 0xffffffff

/**
 * Steal a ready thread from another online CPU's run queue, for a CPU with nothing to run.
 *
 * The other CPUs are tried in turn from the one after cpu, each one's queue lock taken in a short spell, at rank
 * RunQueue; one whose queue looks empty is skipped without it.
 *
 * @param kernel The kernel, whose online CPUs' run queues are searched.
 * @param cpu The calling CPU's PerCpu, holding no run-queue lock.
 * @return The thread, as an address, taken off its queue: the first at the highest level of the first queue that has
 *     one that may run on cpu. 0 if there's none.
 */
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
        lock_at(&other.run_queue.lock, .RunQueue)
        taken :: take_for(&other.run_queue, cpu.index)
        unlock_at(&other.run_queue.lock, .RunQueue)
        if taken != 0 {
            return taken
        }
    }
    return 0
}

/**
 * Find a queue's highest level with threads. Takes the lock as held.
 *
 * @param queue The run queue, whose lock the caller holds.
 * @return The level, 0 to LEVELS - 1, or IDLE_LEVEL if the queue is empty.
 */
highest_level :: fn(queue: ptr[RunQueue]) -> u32 {
    for word in 0..<5 #reverse {
        bits :: queue.nonempty[word]
        if bits != 0 {
            return cast[u32](word * 64) + highest_bit(bits)
        }
    }
    return IDLE_LEVEL
}

/**
 * Find the highest set bit of a value, by halves.
 *
 * @param value The value, which has a bit set.
 * @return The bit's index, 0 to 63; 0 for a value of 0 too.
 */
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

/**
 * Append a thread to a level's list. Takes the lock as held.
 *
 * @param queue The run queue, whose lock the caller holds; its count is published with a release store.
 * @param thread The thread, on no run queue; its level becomes level.
 * @param level The level, below LEVELS; a larger one is taken modulo LEVELS.
 */
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

/**
 * Move every thread in the background band whose budget has time again up to its budget's level, behind what's
 * there. Takes the lock as held, and each budget's lock in turn.
 *
 * @param queue The run queue, whose lock the caller holds, at rank RunQueue, so each budget's lock can be taken.
 * @param now The counter's value now, in ticks.
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

/**
 * Choose the thread to run next instead of the current one.
 *
 * A thread waiting at a level its budget no longer has time for, spent by another of its budget's threads meanwhile,
 * is moved down to where it belongs first, so a budget's threads together never run past it by more than a tick.
 * Takes the lock as held.
 *
 * @param queue The calling CPU's run queue.
 * @param now The counter's value now, in ticks.
 * @param current The CPU's current thread, as an address, or 0 for none.
 * @param current_level The current thread's level, IDLE_LEVEL for none.
 * @param tick Whether this is a timer tick, when a thread of current's own level takes its turn.
 * @return The thread, as an address, taken off the queue: the first at the highest level, if that's above current's,
 *     or the same at a tick; any at all with no current thread. 0 to go on with current, or with nothing queued.
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

/**
 * Take a thread that may run on a CPU off a queue, for stealing. Takes the lock as held.
 *
 * @param queue Another CPU's run queue.
 * @param cpu_index The index of the CPU it's for.
 * @return The first thread at the highest level that may run on cpu_index, as an address, or 0 if there's none.
 */
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

/**
 * Take the first thread at a level off a queue. Takes the lock as held.
 *
 * @param queue The run queue, whose lock the caller holds.
 * @param level The level, one with threads; an empty one fails an assertion, which stops the kernel.
 * @return The thread, as an address.
 */
dequeue :: fn(queue: ptr[mut RunQueue], level: u32) -> u64 {
    index :: cast[usize](level) % LEVELS
    first :: queue.first[index]
    runtime.assert(first != 0, "dequeue takes a level with threads")
    unlink(queue, cast[ptr[mut Thread]](first))
    return first
}

/**
 * Take a thread off its level's list. Takes the lock as held.
 *
 * @param queue The run queue it's on.
 * @param thread The thread, queued there at its level.
 */
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

/**
 * Set the calling CPU up for a thread about to return to user mode: its debugging state loaded, and its process's
 * counter reads trapped or not.
 *
 * @param thread The thread.
 */
prepare_return :: fn(thread: ptr[mut Thread]) {
    owner :: thread.header.owner
    // Its process's breakpoints and watchpoints, unless it's stepping, when its own are
    process :: cast[ptr[mut Process]](owner)
    if owner != 0 && !thread.stepping && intrinsics.atomic_load_u32_acquire(&process.debugging) != 0 {
        lock_at(&process.debug_lock, .ProcessDebug)
        loaded := process.debug
        unlock_at(&process.debug_lock, .ProcessDebug)
        arch.debug_on(&loaded, &thread.registers)
    }
    else {
        arch.debug_on(&thread.debug, &thread.registers)
    }
    traps :: if owner != 0 { intrinsics.atomic_load_u32_acquire(&cast[ptr[mut Process]](owner).traps) } else { 0 }
    arch.set_counter_trap(traps & slop_os.TRAP_COUNTER != 0)
}
