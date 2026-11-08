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

/** A process: a node of the ownership tree, with its handle table and what it owns. */
Process :: struct #align(16) {
    /** Its object header; its budget is the process's memory budget. */
    header : ObjectHeader,
    /** Its handles, whose pages are charged to the process itself. */
    table : HandleTable,
    /** What it owns: processes, threads, address spaces and every other object, destroyed with it. */
    owned : OwnedList,
    /** The intercept of its subtree, as an address, 0 if it has none (intercepts.hsc). */
    intercept : u64,
    /** What its threads trap on, slop_os.TRAP_ bits (process_set_traps); 0 at first. Read and written atomically. */
    traps : u32,
    /** Held, at rank Watchers, while watchers is read or changed. */
    watch_lock : concurrency.SpinLock,
    /** Bindings watching for it to end, raised with SIGNAL_TERMINATED and its exit code; empty slots are 0. */
    watchers : EndBinding[2],
    /** Set by process_exit; a process destroyed without it was killed. */
    exited : bool,
    /** The code process_exit gave, while exited is set. */
    exit_code : u32,
    /**
     * Its threads started and not yet destroyed, counted atomically; when the last goes, so does it (threads.hsc,
     * end_process_if_last).
     */
    live_threads : u32,
    /** The CpuBudget it and its threads run on, as an address, 0 for none (cpu_budgets.hsc). */
    cpu_budget : u64,
    /** The next process on its CPU budget's list, 0 at the end; under kernel.cpu_budgets_lock. */
    cpu_budget_next : u64,
    /** The previous process on its CPU budget's list, 0 at the start; under kernel.cpu_budgets_lock. */
    cpu_budget_previous : u64,
}

/**
 * Make a process, with an empty handle table, on its creator's CPU budget.
 *
 * @param kernel The kernel: its pools give the process's slot, and kernel.cpu_budgets_lock is taken to join the
 *     creator's CPU budget.
 * @param owner The Process that owns it, as an address, or 0 for the kernel, which puts it on the root CPU budget.
 * @param budget Its memory budget, a MemoryBudget's address, or 0 for the kernel's own: its slot and its table's
 *     pages are charged there, and what it takes with owning handles moves there (memory_budgets.hsc).
 * @return made The process, owned by owner, with no threads; destroyed with its owner, or when its last started
 *     thread goes.
 * @error OutOfMemory No slot for it.
 * @error BudgetExceeded The budget can't pay for its slot.
 * @error OwnerGone The owner is being destroyed; the process was destroyed again.
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
    // On its creator's CPU budget, until process_set_cpu_budget gives it another
    join_creators_budget(kernel, cast[ptr[mut Process]](object), owner)
    return .Ok(cast[ptr[mut Process]](object))
}

/**
 * Destroy a process, as destroy_object does for its kind: its table takes no more handles, and everything it owns is
 * destroyed, which reaches the whole subtree.
 *
 * It leaves its CPU budget, its watchers are raised with its exit code (slop_os.EXIT_KILLED if it didn't exit), and
 * it lets go of its intercept. If it's the root task, the kernel stops once a grace period has passed (timer.hsc).
 *
 * @param kernel The kernel: kernel.cpu_budgets_lock is taken to leave the CPU budget, kernel.root_ended is set if
 *     it's the root task, and everything owned is destroyed through destroy_object.
 * @param process The process, already dying, its generation advanced.
 */
destroy_process :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process]) {
    leave_process_budget(kernel, process)
    ended :: if process.exited { cast[u64](process.exit_code) } else { slop_os.EXIT_KILLED }
    raise_watchers(kernel, &process.watchers, &process.watch_lock, .Watchers, cast[u32](slop_os.SIGNAL_TERMINATED), ended)
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

/**
 * Release a destroyed process once no CPU can use it, as release_object does for its kind: its table's pages and
 * directory go back.
 *
 * @param kernel The kernel, whose frames the table's pages go back to, through this CPU's frame cache.
 * @param process The process, its grace period over.
 */
release_process :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process]) {
    free_table(kernel, &process.table)
}

/**
 * Find the process that owns a thread.
 *
 * @param thread The thread, one a process owns, as every thread a system call runs on is.
 * @return Its owner; for a thread the kernel owns, a null pointer.
 */
process_of :: fn(thread: ptr[Thread]) -> ptr[mut Process] {
    return cast[ptr[mut Process]](thread.header.owner)
}

/**
 * Make an owning handle to an object, with every right, in a process's table.
 *
 * @param kernel The kernel, whose frames pay for a new page of the table, if one is needed.
 * @param process The process whose table it goes in, which the caller has made the object's owner.
 * @param object The object, as an address, live; its current generation and kind go in the handle.
 * @return The handle in the process's table, owning, with slop_os.RIGHTS_ALL; never NO_HANDLE.
 * @error ObjectGone The process's table is closed, as it's being destroyed.
 * @error TableFull The process's table is full.
 * @error OutOfMemory No frame for the table's page.
 * @error BudgetExceeded The process's budget can't pay for the table's page.
 * @error InvalidHandle The table's free list is broken, which never happens.
 */
install_owning :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process], object: u64) -> Result[slop_os.Handle, slop_os.HandleError] {
    header :: cast[ptr[ObjectHeader]](object)
    return install(kernel, &process.table, object, header.generation, header.kind, slop_os.RIGHTS_ALL, true)
}

/**
 * Move the caller's handles out of its table into another process's (decisions/0067).
 *
 * What an owning handle owns is target's from then on, its charge moved to target's budget, for all of them or none
 * (decisions/0011). Every handle is checked before any moves; channel ends are held unmapped while they move, as
 * sending them is (channels.hsc). Takes the caller's table's lock, and target's, in short spells.
 *
 * @param kernel The kernel: kernel.budgets_lock is taken to move the charges, and both tables' locks, each alone.
 * @param thread The calling thread, whose process's handles move.
 * @param target The process they move to.
 * @param handles The handles: count slop_os.Handle values at a user virtual address in the thread's space, at most
 *     slop_os.MAX_HANDLES_PER_BATCH of them. Each needs RIGHT_TRANSFER. An owning handle to target or a process
 *     above it can't go, since target would own itself, nor a channel end whose rings are mapped.
 * @param given Where the handle each gets in target's table is written, in the same order: at least as many
 *     slop_os.Handle values as handles has, writable by user mode. One closed meanwhile, or that doesn't fit in
 *     target's table, comes out as NO_HANDLE, and an owning one is destroyed.
 * @return Null once they've moved; or why nothing moved: TooBig for too many handles, BadBuffer for buffers that
 *     can't be read or written, MissingRight, NotTransferable, BudgetExceeded when target's budget can't take what
 *     moves, or InvalidHandle or ObjectGone for a handle that isn't one. BadBuffer also comes back when given can't be
 *     written at the end, after the handles have moved.
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

/**
 * Let go of the channel ends give_handles held for sending.
 *
 * @param held The ends, as addresses.
 * @param generations Each end's generation when it was held; one destroyed since is skipped.
 * @param count How many of held to let go of, from the first, at most 64.
 */
let_go_of_held :: fn(held: ptr[u64[64]], generations: ptr[u32[64]], count: usize) {
    for i in 0..<count {
        let_go_of_end(cast[ptr[mut Channel]](held[i % 64]), generations[i % 64])
    }
}
