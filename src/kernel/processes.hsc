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
    raise_watchers(kernel, &process.watchers, &process.watch_lock, cast[u32](slop_os.SIGNAL_TERMINATED))
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
