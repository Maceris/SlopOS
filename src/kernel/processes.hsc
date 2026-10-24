package kernel

import intrinsics from "base"
import concurrency from "std"
import runtime from "base"
import slop_os from "std/os"

/*
 * Processes (roadmap M5, decisions/0008, 0034): nodes of the ownership tree. A process, a job and a
 * session are all one: what it owns (other processes, threads, address spaces, ...) and its handle
 * table. Destroying one destroys everything it owns, so killing a node reclaims the whole subtree.
 */
//TODO(claude): destroying a large subtree in two phases, with preemption points (knowledge/design/kernel.md §2, Long operations)

Process :: struct #align(16) {
    header : ObjectHeader,
    table : HandleTable,
    owned : OwnedList,
    // The intercept of its subtree, if it has one (intercepts.hsc).
    intercept : u64,
    // Bindings watching for it to end (SIGNAL_TERMINATED), under watch_lock.
    watch_lock : concurrency.SpinLock,
    watchers : EndBinding[2],
    // Set by process_exit, with its code; a process destroyed without it was killed.
    exited : bool,
    exit_code : u32,
}

/*
 * A process owned by owner (a Process's address, 0 for the kernel), with an empty handle table, charged
 * to budget, which is its budget: its table's pages are charged there, and what it takes with owning
 * handles moves there (memory_budgets.hsc).
 */
create_process :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64) -> (made #unrestricted : Result[ptr[mut Process], ObjectError]) {
    object :: new_object(kernel, .Process, budget, 0)?
    cast[ptr[mut Process]](object).table.account = object
    match adopt(owner, object) {
        case Ok => {}
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return .Error(error)
        }
    }
    return .Ok(cast[ptr[mut Process]](object))
}

/*
 * Destroying a process: its table takes no more handles, and everything it owns is destroyed, which
 * reaches the whole subtree.
 */
destroy_process :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process]) {
    ended :: if process.exited { cast[u64](process.exit_code) } else { slop_os.EXIT_KILLED }
    raise_watchers(kernel, &process.watchers, &process.watch_lock, cast[u32](slop_os.SIGNAL_TERMINATED), ended)
    /*
     * The root task's end is the machine's: once its subtree is destroyed and a grace period has passed, the
     * boot CPU's timer says what's left and stops (timer.hsc, root_task_ended)
     */
    if intrinsics.atomic_load_u64_acquire(&kernel.root_task) == cast[u64](process) {
        if process.exited {
            runtime.log_info("root task ended with code %", process.exit_code)
        }
        else {
            runtime.log_error("root task was destroyed")
        }
        intrinsics.atomic_store_u32_release(&kernel.root_ended, 1)
    }
    forget_intercept(kernel, process)
    close_table(&process.table)
    loop {
        owned :: take_owned(&process.owned)
        if owned == 0 {
            break
        }
        _ = destroy_object(kernel, owned)
    }
}

// Once no CPU can use it: its table's memory.
release_process :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process]) {
    free_table(kernel, &process.table)
}

// The process that owns thread.
process_of :: fn(thread: ptr[Thread]) -> ptr[mut Process] {
    return cast[ptr[mut Process]](thread.header.owner)
}

// A handle to object, owning: all rights.
install_owning :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process], object: u64) -> Result[slop_os.Handle, slop_os.HandleError] {
    header :: cast[ptr[ObjectHeader]](object)
    return install(kernel, &process.table, object, header.generation, header.kind, slop_os.RIGHTS_ALL, true)
}

/*
 * The caller's handles, moved out of its table into target's, the value each gets there written at given
 * (decisions/0067): what an owning handle owns is target's from then on, charged to its budget, for all of
 * them or none (decisions/0011). Each needs RIGHT_TRANSFER. An owning handle to target or a process above
 * it can't go, since target would own itself, nor a channel end whose rings are mapped. One closed
 * meanwhile, or that doesn't fit in target's table, comes out as NO_HANDLE.
 */
give_handles :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], target: ptr[mut Process], handles: slop_os.UserBuffer,
    given: slop_os.UserBuffer) -> slop_os.ControlError? {
    count :: handles.count
    if count > cast[u64](slop_os.MAX_HANDLES_PER_BATCH) {
        return slop_os.ControlError.TooBig
    }
    if given.count < count || !is_user_writable(thread.space, given.address, count * 4) {
        return slop_os.ControlError.BadBuffer
    }
    moving : slop_os.Handle[64]
    if !copy_from_user(kernel, thread.space, handles.address, cast[u64](&moving[0]), count * 4) {
        return slop_os.ControlError.BadBuffer
    }
    process :: process_of(thread)
    owned : u64[64]
    owned_count := cast[u32](0)
    for i in 0..<cast[usize](count) {
        match lookup(&process.table, moving[i]) {
            case Ok(found) => {
                if cast[u32](found.rights) & cast[u32](slop_os.RIGHT_TRANSFER) == 0 {
                    return slop_os.ControlError.MissingRight
                }
                if found.owning && (found.object == cast[u64](target) || in_subtree(cast[u64](target), found.object)) {
                    return slop_os.ControlError.NotTransferable
                }
                if found.owning {
                    owned[cast[usize](owned_count) % 64] = found.object
                    owned_count += 1
                }
            }
            case Error(error) => return converted[slop_os.ControlError](error)
        }
    }
    // Ends are held unmapped while they move, as sending them is (channels.hsc)
    held : u64[64]
    held_generations : u32[64]
    held_count : usize = 0
    for i in 0..<cast[usize](count) {
        match lookup(&process.table, moving[i]) {
            case Ok(found) => {
                if found.kind == .Channel {
                    if !hold_for_sending(cast[ptr[mut Channel]](found.object)) {
                        let_go_of_held(&held, &held_generations, held_count)
                        return slop_os.ControlError.NotTransferable
                    }
                    held[held_count % 64] = found.object
                    held_generations[held_count % 64] = found.generation
                    held_count += 1
                }
            }
            case Error(error) => {}
        }
    }
    if !move_charges(kernel, &owned, owned_count, target.header.budget) {
        let_go_of_held(&held, &held_generations, held_count)
        return slop_os.ControlError.BudgetExceeded
    }
    installed : slop_os.Handle[64]
    for i in 0..<cast[usize](count) {
        installed[i] = slop_os.NO_HANDLE
        match remove(&process.table, moving[i]) {
            case Ok(removed) => {
                if is_live(removed.object, removed.generation) {
                    installed[i] = take_one(kernel, target, removed)
                }
            }
            case Error(error) => {}
        }
    }
    let_go_of_held(&held, &held_generations, held_count)
    if !copy_to_user(kernel, thread.space, given.address, cast[u64](&installed[0]), count * 4) {
        return slop_os.ControlError.BadBuffer
    }
    return null
}

// The first count of the ends give_handles held, let go of.
let_go_of_held :: fn(held: ptr[u64[64]], generations: ptr[u32[64]], count: usize) {
    for i in 0..<count {
        let_go_of_end(cast[ptr[mut Channel]](held[i % 64]), generations[i % 64])
    }
}
