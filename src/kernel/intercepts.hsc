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

Intercept :: struct #align(16) {
    header : ObjectHeader,
    // Held for its list of stopped threads and its binding.
    lock : concurrency.SpinLock,
    process : u64,
    process_generation : u32,
    // Which calls, a bit per number below 64, and where (slop_os.STOP_*).
    calls : u64,
    points : u32,
    // Its port binding, and that binding's generation, which changes once the port drops it.
    binding_generation : u32,
    binding : u64,
    // The threads it stopped, oldest first, through their stop_next and stop_previous.
    first_stopped : u64,
    last_stopped : u64,
}

/*
 * An intercept of process's subtree, owned by owner, charged to budget, reporting to port under key. One
 * per process.
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
    concurrency.lock(&port.lock)
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
    concurrency.unlock(&port.lock)
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

/*
 * Destroying an intercept: its process isn't intercepted any more, every thread it stopped goes on (as
 * with Continue), and its binding goes.
 */
destroy_intercept :: fn(kernel: ptr[mut Kernel], intercept: ptr[mut Intercept]) {
    // Unless the process was destroyed first, when it let go of its intercept itself
    if intercept.process != 0 && is_live(intercept.process, intercept.process_generation) {
        process :: cast[ptr[mut Process]](intercept.process)
        _, cleared :: intrinsics.interlocked_compare_exchange_u64(&process.intercept, 0, cast[u64](intercept))
        if cleared {
            _ = intrinsics.interlocked_decrement_u32(&kernel.intercepts)
        }
    }
    loop {
        concurrency.lock(&intercept.lock)
        first :: intercept.first_stopped
        if first != 0 {
            unlink_stopped(intercept, cast[ptr[mut Thread]](first))
        }
        concurrency.unlock(&intercept.lock)
        if first == 0 {
            break
        }
        let_go(kernel, cast[ptr[mut Thread]](first), .Continue)
    }
    concurrency.lock(&intercept.lock)
    binding :: intercept.binding
    generation :: intercept.binding_generation
    intercept.binding = 0
    concurrency.unlock(&intercept.lock)
    if binding != 0 {
        drop_binding(kernel, binding, generation)
    }
}

release_intercept :: fn(kernel: ptr[mut Kernel], intercept: ptr[mut Intercept]) {
}

// A process being destroyed lets go of its intercept, if it has one.
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

// The intercept a thread stops for: its nearest intercepted process's, or 0.
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

/*
 * Stop thread at point if its intercept asks: number is the call's (or a fault's access), address a
 * fault's. current: it's the CPU's current thread, whose vector state is still in the CPU. True if it
 * stopped, when the caller takes it off the CPU.
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
    }
    if !wanted {
        return false
    }
    concurrency.lock(&intercept.lock)
    defer concurrency.unlock(&intercept.lock)
    if is_dying(found) {
        return false
    }
    concurrency.lock(&thread.control)
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
    concurrency.unlock(&thread.control)
    link_stopped(intercept, thread)
    report_stop(kernel, intercept)
    return true
}

wants_call :: fn(intercept: ptr[Intercept], number: u64) -> bool {
    return number < 64 && intercept.calls & (cast[u64](1) << number) != 0
}

// One more stop counted in the intercept's packet, queued if it isn't. Takes the intercept's lock as held.
report_stop :: fn(kernel: ptr[mut Kernel], intercept: ptr[mut Intercept]) {
    if intercept.binding == 0 {
        return void
    }
    binding :: cast[ptr[mut Binding]](intercept.binding)
    port :: cast[ptr[mut Port]](intrinsics.atomic_load_u64(&binding.port))
    concurrency.lock(&port.lock)
    defer concurrency.unlock(&port.lock)
    if binding.generation != intercept.binding_generation || binding.port != cast[u64](port) || is_dying(cast[u64](port)) {
        return void
    }
    binding.data += 1
    queue_binding(kernel, port, binding)
}

// The next stop not yet reported, written at buffer in space.
intercept_next :: fn(kernel: ptr[mut Kernel], intercept: ptr[mut Intercept], space: ptr[mut AddressSpace], buffer: u64) -> slop_os.ControlError? {
    info := slop_os.StopInfo.{}
    found := false
    concurrency.lock(&intercept.lock)
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
    concurrency.unlock(&intercept.lock)
    if !found {
        return slop_os.ControlError.Empty
    }
    if !copy_to_user(kernel, space, buffer, cast[u64](&info), cast[u64](size_of(slop_os.StopInfo))) {
        return slop_os.ControlError.BadBuffer
    }
    return null
}

// Let a thread the intercept stopped go on as action says.
intercept_resume :: fn(kernel: ptr[mut Kernel], intercept: ptr[mut Intercept], id: u64, action: slop_os.InterceptAction) -> slop_os.ControlError? {
    concurrency.lock(&intercept.lock)
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
        concurrency.unlock(&intercept.lock)
        return slop_os.ControlError.NoSuchThread
    }
    if action == .Skip && found.stop_point != cast[u32](slop_os.StopPoint.SyscallEntry) {
        concurrency.unlock(&intercept.lock)
        return slop_os.ControlError.NotStopped
    }
    unlink_stopped(intercept, found)
    concurrency.unlock(&intercept.lock)
    let_go(kernel, found, action)
    return null
}

/*
 * A stopped thread, off its intercept's list, going on: at an entry, Continue makes the call again from
 * user mode, without its entry stop; Kill destroys it.
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

// A thread being destroyed, off the list of the intercept that stopped it, if one did.
forget_stop :: fn(thread: ptr[mut Thread]) {
    address :: thread.stop_intercept
    if address == 0 {
        return void
    }
    intercept :: cast[ptr[mut Intercept]](address)
    concurrency.lock(&intercept.lock)
    unlink_stopped(intercept, thread)
    concurrency.unlock(&intercept.lock)
}

// Takes the intercept's lock as held.
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
