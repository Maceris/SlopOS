package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import concurrency from "std"
import maps from "std"
import slop_os from "std/os"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * Intercepts (roadmap M5, knowledge/design/kernel.md §4, decisions/0009, 0017, 0056): a debugger's hold on
 * a process's subtree. Its threads stop at the entry and exit of the system calls it asks for, and at
 * faults their memory doesn't resolve, which would otherwise destroy them: the intercept is the subtree's
 * exception port too. The nearest intercepted process above a thread is the one it stops for.
 *
 * Stopping is a state change and a report: the thread is held (control.hsc) and parked, and goes on the
 * intercept's list of stopped threads; the intercept's port binding counts the stops in its Stop packet,
 * and InterceptNext reports each one. A thread stops only where its whole state is its saved registers:
 * at a call's entry, before it does anything; at its exit, once its results are written, after any wait
 * it blocked in. Nothing allocates.
 *
 * Resuming at an entry with Continue makes the call again from user mode (arch.restart_syscall), with any
 * registers the debugger changed, without stopping at its entry a second time; Skip returns with the
 * registers as written, the call never made. At a fault, Continue retries the access. Destroying the
 * intercept lets every thread it stopped go on, as with Continue.
 *
 * Lock order: an intercept's lock, then a thread's control lock, then a port's.
 */

/** An intercept, a kernel object: a debugger's hold on a process's subtree, and the threads it has stopped. */
Intercept :: struct #align(16) {
    /** The object's header; first, as for every kernel object. */
    header : ObjectHeader,
    /** Held (rank Intercept, before a thread's control lock and a port's) for its stopped threads and its binding. */
    lock : concurrency.SpinLock,
    /** The Process whose subtree it intercepts, as its address. */
    process : u64,
    /** The process's generation when it was made, so a destroyed process isn't taken for it. */
    process_generation : u32,
    /** The system calls it stops at, a bit per call number below 64; written atomically by set_intercept. */
    calls : u64,
    /**
     * Where it stops threads: slop_os.STOP_* bits, for a call's entry and exit, and faults; written atomically by
     * set_intercept.
     */
    points : u32,
    /** The binding's generation when it was made, which changes once the port drops it. */
    binding_generation : u32,
    /** Its port binding, as its address, which counts the stops in its Stop packet; 0 once it's destroyed. */
    binding : u64,
    /** The first thread it stopped, the oldest, through their stop_next; 0 for none. */
    first_stopped : u64,
    /** The last thread it stopped, the newest, through their stop_previous; 0 for none. */
    last_stopped : u64,
    /** 1 while it samples its subtree (tracing.hsc, intercept_sample); read and written atomically. */
    sampling : u32,
    /** Its samples, a SampleRing on the kernel heap, as an address; 0 until it first samples. */
    samples : u64,
}

/**
 * Make an intercept of a process's subtree, reporting its stops to a port.
 *
 * Its binding is made first, so a stop always has somewhere to go; then the process is claimed, as a process has
 * one intercept. Takes the port's lock.
 *
 * @param kernel The kernel: the object comes from its Intercept pool, the binding from its binding pool, and its
 *     count of intercepts goes up once the process is claimed.
 * @param owner The Process to own it, as its address, or 0 for the kernel.
 * @param budget The MemoryBudget the object is charged to, as its address, or 0 for the kernel's own; the binding
 *     is charged to the port's.
 * @param process The process whose subtree it intercepts.
 * @param port The port its Stop packet goes to.
 * @param key The key its packet carries, which no binding on the port may have yet.
 * @param calls The system calls to stop at, a bit per call number below 64.
 * @param points Where to stop threads, slop_os.STOP_* bits.
 * @return The intercept, owned by owner, the process's; the caller makes a handle to it.
 * @error OutOfMemory No memory could be had for the object or its binding.
 * @error BudgetExceeded budget hadn't room for the object, or the port's for the binding.
 * @error ObjectGone The port is being destroyed, or owner is; in owner's case, the intercept is destroyed again.
 * @error WrongKind A binding on the port has the key already.
 * @error AlreadyIntercepted The process has an intercept already; the binding is dropped again.
 */
create_intercept :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64, process: ptr[mut Process], port: ptr[mut Port], key: u64,
    calls: u64, points: u32) -> Result[ptr[mut Intercept], slop_os.ControlError] {
    object := cast[u64](0)
    match new_object(kernel, .Intercept, budget, 0) {
        case Ok(made) => object = made
        case Error(error) => return .Error(if error == .BudgetExceeded { slop_os.ControlError.BudgetExceeded } else { slop_os.ControlError.OutOfMemory })
    }
    intercept :: cast[ptr[mut Intercept]](object)
    intercept.process = cast[u64](process)
    intercept.process_generation = process.header.generation
    intercept.calls = calls
    intercept.points = points
    // Its binding first, so a stop always has somewhere to go
    lock_at(&port.lock, .Port)
    failure := cast[u32](0)
    if is_dying(cast[u64](port)) {
        failure = cast[u32](slop_os.ControlError.ObjectGone)
    }
    else if maps.map_has(&port.bindings, key) {
        failure = cast[u32](slop_os.ControlError.WrongKind)
    }
    else {
        match new_binding(kernel, port, key, .Stop) {
            case Some(binding) => {
                binding.object = object
                binding.object_generation = intercept.header.generation
                binding.armed = true
                intercept.binding = cast[u64](binding)
                intercept.binding_generation = binding.generation
            }
            case None => failure = cast[u32](if port.short_of_budget { slop_os.ControlError.BudgetExceeded } else { slop_os.ControlError.OutOfMemory })
        }
    }
    unlock_at(&port.lock, .Port)
    if failure != 0 {
        release_object(kernel, object)
        return .Error(cast[slop_os.ControlError](failure))
    }
    _, claimed :: intrinsics.interlocked_compare_exchange_u64(&process.intercept, object, 0)
    if !claimed {
        drop_binding(kernel, intercept.binding, intercept.binding_generation)
        release_object(kernel, object)
        return .Error(.AlreadyIntercepted)
    }
    _ = intrinsics.interlocked_increment_u32(&kernel.intercepts)
    match adopt(owner, object) {
        case Ok => {}
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return .Error(.ObjectGone)
        }
    }
    return .Ok(intercept)
}

/**
 * Destroy an intercept, as destroy_object does each kind: its process isn't intercepted any more, every thread it
 * stopped goes on (as with Continue), and its binding goes.
 *
 * Takes its lock, then a thread's control lock, then the port's, one after the other.
 *
 * @param kernel The kernel, whose count of intercepts goes down if the process still had this one; called from
 *     destroy_object, on any CPU, with interrupts off.
 * @param intercept The intercept being destroyed, already dying.
 */
destroy_intercept :: fn(kernel: ptr[mut Kernel], intercept: ptr[mut Intercept]) {
    free_samples(intercept)
    // Unless the process was destroyed first, when it let go of its intercept itself
    if intercept.process != 0 && is_live(intercept.process, intercept.process_generation) {
        process :: cast[ptr[mut Process]](intercept.process)
        _, cleared :: intrinsics.interlocked_compare_exchange_u64(&process.intercept, 0, cast[u64](intercept))
        if cleared {
            _ = intrinsics.interlocked_decrement_u32(&kernel.intercepts)
        }
    }
    loop {
        lock_at(&intercept.lock, .Intercept)
        first :: intercept.first_stopped
        if first != 0 {
            unlink_stopped(intercept, cast[ptr[mut Thread]](first))
        }
        unlock_at(&intercept.lock, .Intercept)
        if first == 0 {
            break
        }
        let_go(kernel, cast[ptr[mut Thread]](first), .Continue)
    }
    lock_at(&intercept.lock, .Intercept)
    binding :: intercept.binding
    generation :: intercept.binding_generation
    intercept.binding = 0
    unlock_at(&intercept.lock, .Intercept)
    if binding != 0 {
        drop_binding(kernel, binding, generation)
    }
}

/**
 * Release a destroyed intercept, as release_object does each kind: destroy_intercept let go of everything it held,
 * so this does nothing.
 *
 * @param kernel Unused: the intercept holds nothing of the kernel's by now.
 * @param intercept The destroyed intercept, whose memory release_object frees after this.
 */
release_intercept :: fn(kernel: ptr[mut Kernel], intercept: ptr[mut Intercept]) {
}

/**
 * Let go of a process's intercept, as the process is destroyed, if it has one; the intercept itself lives on until
 * its handles go, holding nothing of the process's.
 *
 * @param kernel The kernel, whose count of intercepts goes down.
 * @param process The process being destroyed.
 */
forget_intercept :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process]) {
    held :: intrinsics.atomic_load_u64_acquire(&process.intercept)
    if held == 0 {
        return void
    }
    _, cleared :: intrinsics.interlocked_compare_exchange_u64(&process.intercept, 0, held)
    if cleared {
        _ = intrinsics.interlocked_decrement_u32(&kernel.intercepts)
    }
}

/**
 * Find the intercept a thread stops for: its nearest intercepted owner's, up at most MAX_OWNER_DEPTH processes.
 *
 * Takes no lock; with no intercept anywhere, it costs one load.
 *
 * @param kernel The kernel, whose count of intercepts is loaded with acquire, so a kernel with none stops at once.
 * @param thread The thread, whose owner chain is walked; it may be running on this CPU, at a system call or fault.
 * @return The Intercept, as its address, or 0 for none.
 */
intercept_of :: fn(kernel: ptr[Kernel], thread: ptr[Thread]) -> u64 {
    if intrinsics.atomic_load_u32_acquire(&kernel.intercepts) == 0 {
        return 0
    }
    process := thread.header.owner
    for depth in 0..<MAX_OWNER_DEPTH {
        if process == 0 {
            return 0
        }
        intercept :: intrinsics.atomic_load_u64_acquire(&cast[ptr[Process]](process).intercept)
        if intercept != 0 {
            return intercept
        }
        process = cast[ptr[ObjectHeader]](process).owner
    }
    return 0
}

/**
 * Stop a thread at a point, if its intercept asks to: held and parked, put on the intercept's list, and reported.
 *
 * A call made again after its entry stop (Continue) doesn't stop at its entry a second time. Takes the intercept's
 * lock, then the thread's control lock, then the port's.
 *
 * @param kernel The kernel, whose count of intercepts says whether to look; the port's queue changes if it stops.
 * @param thread The thread, at a point where its whole state is its saved registers; a dying one isn't stopped.
 * @param point Where it is: a system call's entry or exit, or a fault its memory didn't resolve.
 * @param number The system call's number, or for a fault, its access; a call stops only if its bit is in the
 *     intercept's calls.
 * @param address The faulting address, for a fault; reported, not checked.
 * @param current Whether it's this CPU's current thread, whose vector state is still in the CPU and is saved.
 * @return True if it stopped, when the caller takes it off the CPU; false if it goes on.
 */
stop_thread :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], point: slop_os.StopPoint, number: u64, address: u64, current: bool) -> bool {
    if is_dying(cast[u64](thread)) {
        return false
    }
    // A call made again after its entry stop doesn't stop there twice
    if point == .SyscallEntry && thread.restarted {
        thread.restarted = false
        return false
    }
    found :: intercept_of(kernel, thread)
    if found == 0 {
        return false
    }
    intercept :: cast[ptr[mut Intercept]](found)
    wanted :: match point {
        case .SyscallEntry => intercept.points & slop_os.STOP_SYSCALL_ENTRY != 0 && wants_call(intercept, number)
        case .SyscallExit => intercept.points & slop_os.STOP_SYSCALL_EXIT != 0 && wants_call(intercept, number)
        case .Fault => intercept.points & slop_os.STOP_FAULT != 0
        case .ThreadStart => intercept.points & slop_os.STOP_THREAD_START != 0
    }
    if !wanted {
        return false
    }
    lock_at(&intercept.lock, .Intercept)
    defer unlock_at(&intercept.lock, .Intercept)
    if is_dying(found) {
        return false
    }
    lock_at(&thread.control, .ThreadControl)
    thread.held |= HELD_STOP
    if current {
        arch.save_vector_state(cast[ptr[mut arch.VectorState]](thread.vector))
    }
    thread.parked = true
    thread.state = .Stopped
    thread.stop_intercept = found
    thread.stop_point = cast[u32](point)
    thread.stop_number = cast[u32](number)
    thread.stop_address = address
    thread.stop_reported = false
    unlock_at(&thread.control, .ThreadControl)
    link_stopped(intercept, thread)
    // Under STOP_FAULT_LIMITED, its process ends if it's still stopped here past FAULT_STOP_LIMIT (fire_fault_stop)
    if point == .Fault && intercept.points & slop_os.STOP_FAULT_LIMITED != 0 {
        thread.fault_stops += 1
        thread.fault_timer.kind = .FaultStop
        thread.fault_timer.owner = cast[u64](thread)
        thread.fault_timer.owner_generation = (cast[u64](thread.header.generation) << 32) | cast[u64](thread.fault_stops)
        thread.fault_timer.port = 0
        _ = arm_timer(&thread.fault_timer, arch.counter() + FAULT_STOP_LIMIT_MILLISECONDS * kernel.counter_frequency / 1000)
    }
    report_stop(kernel, intercept)
    return true
}

/** How long a thread may stay stopped at a fault under STOP_FAULT_LIMITED before its process ends, in milliseconds. */
FAULT_STOP_LIMIT_MILLISECONDS : u64 : 1000

/**
 * End the process of a thread still stopped at a fault its limit after it stopped (STOP_FAULT_LIMITED), as a fault
 * without an intercept ends it (decisions/0181's F6); one let go, destroyed or stopped again since is left alone.
 *
 * Runs from the timer interrupt of the CPU it was armed on (fire_timers), with no lock held; takes the intercept's
 * lock, and destroys the process once this CPU isn't destroying something else (destroy_later).
 *
 * @param kernel The kernel.
 * @param fired A copy of the fault timer's entry: its owner is the thread, its owner_generation the thread's
 *     generation in the high 32 bits and its count of fault stops in the low.
 */
fire_fault_stop :: fn(kernel: ptr[mut Kernel], fired: ptr[TimerEntry]) {
    thread :: cast[ptr[mut Thread]](fired.owner)
    address :: thread.stop_intercept
    if address == 0 {
        return void
    }
    intercept :: cast[ptr[mut Intercept]](address)
    lock_at(&intercept.lock, .Intercept)
    expected :: (cast[u64](thread.header.generation) << 32) | cast[u64](thread.fault_stops)
    still :: expected == fired.owner_generation && thread.stop_linked && thread.stop_intercept == address
        && thread.stop_point == cast[u32](slop_os.StopPoint.Fault)
    owner :: thread.header.owner
    generation :: if owner != 0 { intrinsics.atomic_load_u32_acquire(&cast[ptr[ObjectHeader]](owner).generation) } else { 0 }
    id :: thread.id
    unlock_at(&intercept.lock, .Intercept)
    if !still || owner == 0 {
        return void
    }
    runtime.log_info("thread % stayed stopped at a fault, so its process ends", id)
    destroy_later(kernel, owner, generation)
}

/**
 * Tell whether an intercept stops at a system call.
 *
 * @param intercept The intercept, whose calls and points are read without its lock (set_intercept).
 * @param number The system call's number, from the stopping thread's registers; any value.
 * @return True with STOP_ALL_CALLS among its points; otherwise if number is below 64 and its bit is in its calls.
 */
wants_call :: fn(intercept: ptr[Intercept], number: u64) -> bool {
    if intercept.points & slop_os.STOP_ALL_CALLS != 0 {
        return true
    }
    return number < 64 && intercept.calls & (cast[u64](1) << number) != 0
}

/**
 * Count one more stop in an intercept's packet, queued if it isn't, which wakes a waiter. Nothing happens once the
 * port dropped the binding. Takes the port's lock.
 *
 * @param kernel The kernel; only the port's queue changes, under the port's lock.
 * @param intercept The intercept, whose lock the caller holds.
 */
report_stop :: fn(kernel: ptr[mut Kernel], intercept: ptr[mut Intercept]) {
    if intercept.binding == 0 {
        return void
    }
    binding :: cast[ptr[mut Binding]](intercept.binding)
    port :: lock_bound_port(binding, intercept.binding_generation) or_return void
    defer unlock_at(&port.lock, .Port)
    binding.data += 1
    queue_binding(kernel, port, binding)
}

/**
 * Report the oldest stop not yet reported, as a slop_os.StopInfo written to user memory. Takes the intercept's lock.
 *
 * @param kernel The kernel, for the direct map the StopInfo is written through.
 * @param intercept The intercept; its lock is taken, so the caller holds none of rank Intercept or above.
 * @param space The caller's address space.
 * @param buffer The user address the StopInfo is written at, in space.
 * @return Null once written; Empty if every stop has been reported; BadBuffer if the buffer isn't writable user
 *     memory, when the stop counts as reported all the same.
 */
intercept_next :: fn(kernel: ptr[mut Kernel], intercept: ptr[mut Intercept], space: ptr[mut AddressSpace], buffer: u64) -> slop_os.ControlError? {
    info := slop_os.StopInfo.{}
    found := false
    lock_at(&intercept.lock, .Intercept)
    with {
        address := intercept.first_stopped
    }
    loop {
        if address == 0 {
            break
        }
        thread :: cast[ptr[mut Thread]](address)
        if !thread.stop_reported {
            thread.stop_reported = true
            info = slop_os.StopInfo.{thread = thread.id, point = cast[slop_os.StopPoint](thread.stop_point), number = thread.stop_number,
                address = thread.stop_address}
            found = true
            break
        }
        address = thread.stop_next
    }
    unlock_at(&intercept.lock, .Intercept)
    if !found {
        return slop_os.ControlError.Empty
    }
    if !copy_to_user(kernel, space, buffer, cast[u64](&info), cast[u64](size_of(slop_os.StopInfo))) {
        return slop_os.ControlError.BadBuffer
    }
    return null
}

/**
 * Let a thread the intercept stopped go on as an action says. Takes the intercept's lock, then the thread's control
 * lock.
 *
 * @param kernel The kernel: a thread let go joins a run queue, and one killed is destroyed.
 * @param intercept The intercept; its lock is taken, so the caller holds none of rank Intercept or above.
 * @param id A thread ID as user mode gave it, unchecked: it's looked for only among the threads this intercept stopped,
 *     and any other gives NoSuchThread.
 * @param action Continue, Skip (only at a call's entry) or Kill.
 * @return Null once it's let go; NoSuchThread if the intercept stopped no thread with that ID; NotStopped for Skip
 *     at a point other than a call's entry, when the thread stays stopped.
 */
intercept_resume :: fn(kernel: ptr[mut Kernel], intercept: ptr[mut Intercept], id: u64, action: slop_os.InterceptAction) -> slop_os.ControlError? {
    lock_at(&intercept.lock, .Intercept)
    found := cast[ptr[mut Thread]](0)
    with {
        address := intercept.first_stopped
    }
    loop {
        if address == 0 {
            break
        }
        thread :: cast[ptr[mut Thread]](address)
        if thread.id == id {
            found = thread
            break
        }
        address = thread.stop_next
    }
    if cast[u64](found) == 0 {
        unlock_at(&intercept.lock, .Intercept)
        return slop_os.ControlError.NoSuchThread
    }
    if action == .Skip && found.stop_point != cast[u32](slop_os.StopPoint.SyscallEntry) {
        unlock_at(&intercept.lock, .Intercept)
        return slop_os.ControlError.NotStopped
    }
    unlink_stopped(intercept, found)
    unlock_at(&intercept.lock, .Intercept)
    _ = cancel_timer(kernel, &found.fault_timer)
    let_go(kernel, found, action)
    return null
}

/**
 * Let a stopped thread go on: at an entry, Continue makes the call again from user mode, without its entry stop;
 * Skip returns with its registers as written; Kill destroys it.
 *
 * The thread runs again once nothing else holds it, a suspend for one.
 *
 * @param kernel The kernel: Kill destroys the thread through destroy_object, and otherwise it may join a run
 *     queue. Called with no lock held.
 * @param thread The thread, already off its intercept's list.
 * @param action What it does.
 */
let_go :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], action: slop_os.InterceptAction) {
    if action == .Kill {
        _ = destroy_object(kernel, cast[u64](thread))
        return void
    }
    if action == .Continue && thread.stop_point == cast[u32](slop_os.StopPoint.SyscallEntry) {
        arch.restart_syscall(&thread.registers)
        thread.restarted = true
    }
    unhold_thread(kernel, thread, HELD_STOP)
}

/**
 * Take a thread being destroyed off the list of the intercept that stopped it, if one did. Takes that intercept's
 * lock.
 *
 * @param thread The thread being destroyed.
 */
forget_stop :: fn(thread: ptr[mut Thread]) {
    address :: thread.stop_intercept
    if address == 0 {
        return void
    }
    intercept :: cast[ptr[mut Intercept]](address)
    lock_at(&intercept.lock, .Intercept)
    unlink_stopped(intercept, thread)
    unlock_at(&intercept.lock, .Intercept)
    _ = cancel_timer(per_cpu().kernel, &thread.fault_timer)
}

/**
 * Put a thread last on an intercept's list of stopped threads.
 *
 * @param intercept The intercept, whose lock the caller holds.
 * @param thread The thread, on no intercept's list.
 */
link_stopped :: fn(intercept: ptr[mut Intercept], thread: ptr[mut Thread]) {
    thread.stop_next = 0
    thread.stop_previous = intercept.last_stopped
    if intercept.last_stopped != 0 {
        cast[ptr[mut Thread]](intercept.last_stopped).stop_next = cast[u64](thread)
    }
    else {
        intercept.first_stopped = cast[u64](thread)
    }
    intercept.last_stopped = cast[u64](thread)
    thread.stop_linked = true
}

/**
 * Take a thread off an intercept's list of stopped threads, if it's on that list.
 *
 * @param intercept The intercept, whose lock the caller holds.
 * @param thread The thread; one not on the list, or on another intercept's, is left alone.
 */
unlink_stopped :: fn(intercept: ptr[mut Intercept], thread: ptr[mut Thread]) {
    if !thread.stop_linked || thread.stop_intercept != cast[u64](intercept) {
        return void
    }
    if thread.stop_previous != 0 {
        cast[ptr[mut Thread]](thread.stop_previous).stop_next = thread.stop_next
    }
    else {
        intercept.first_stopped = thread.stop_next
    }
    if thread.stop_next != 0 {
        cast[ptr[mut Thread]](thread.stop_next).stop_previous = thread.stop_previous
    }
    else {
        intercept.last_stopped = thread.stop_previous
    }
    thread.stop_linked = false
}

/**
 * Change where an intercept stops threads (intercept_set). Each is written atomically, and read without a lock as a
 * thread reaches a point, so a thread there as they change may stop by either.
 *
 * @param intercept The intercept.
 * @param calls The system calls it stops at, a bit per call number below 64.
 * @param points slop_os.STOP_ bits.
 */
set_intercept :: fn(intercept: ptr[mut Intercept], calls: u64, points: u32) {
    intrinsics.atomic_store_u64_release(&intercept.calls, calls)
    intrinsics.atomic_store_u32_release(&intercept.points, points)
}
