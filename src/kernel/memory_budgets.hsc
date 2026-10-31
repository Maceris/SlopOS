package kernel

import intrinsics from "base"
import runtime from "base"
import concurrency from "std"
import slop_os from "std/os"
import frames from "frames"

/*
 * Memory budgets (roadmap M5, decisions/0011, 0054): quotas of memory, kernel objects themselves. Every
 * object is charged to the budget that paid for it, its slot and what it holds: a thread's vector state,
 * a channel's rings, a memory object's whole size, a process's handle-table pages, an address space's
 * page tables, a port's bindings, the handle batches an end has in flight. What an object grows later is
 * charged then, and can fail with BudgetExceeded. Its whole charge comes back once it's released.
 *
 * A budget is split into child budgets: a child's limit is charged to its parent, with its slot. Closing
 * a child moves its charges to its parent, which gives back the part of its limit it didn't use; nothing
 * charged to it is destroyed. An object charged to no budget (0) is the kernel's own.
 *
 * Each budget has a lock for its counts and its list of what's charged to it. Anything that changes two
 * budgets at once, a child closing or a charge moving with an owning handle, takes kernel.budgets_lock
 * first, so it never waits on another.
 *
 * Pressure (roadmap 9c4, decisions/0111): a budget's holder can set a threshold, and SIGNAL_PRESSURE is raised for
 * the bindings watching it once what it has charged reaches it, so its holder can give something back, a cache's
 * pages, before an allocation fails. It's raised again only once its charges have fallen below the threshold and
 * reached it again. It's raised after the budget's lock is let go, by raise_pressure.
 */

MemoryBudget :: struct #align(16) {
    header : ObjectHeader,
    lock : concurrency.SpinLock,
    // What it may have charged, and what it has: its objects' charges and its child budgets' limits.
    limit : u64,
    used : u64,
    // The objects charged to it, linked through their headers' charged_next and charged_previous.
    first_charged : u64,
    // Once it's destroyed: what it had went to its parent, and nothing more is charged to it.
    closed : bool,
    // Its pressure threshold, 0 for none, and whether SIGNAL_PRESSURE was raised since it last fell below it
    threshold : u64,
    pressured : bool,
    // Bindings watching for pressure (SIGNAL_PRESSURE), under watch_lock.
    watch_lock : concurrency.SpinLock,
    watchers : EndBinding[2],
}

MIB : u64 : 1024 * 1024
// The least the kernel keeps out of the root budget for its own allocations (kernel_reserve)
MIN_KERNEL_RESERVE : u64 : 8 * MIB

/*
 * The root budget, of the frames free once the kernel is up, but the kernel's own share (kernel_reserve), which the
 * kernel keeps: the budgets processes are given are split from it.
 */
make_root_budget :: fn(kernel: ptr[mut Kernel]) -> u64 {
    object :: new_object(kernel, .MemoryBudget, 0, 0) or_else 0
    if object == 0 {
        return 0
    }
    budget :: cast[ptr[mut MemoryBudget]](object)
    free :: kernel.frames.free_frames * frames.FRAME_SIZE
    held :: kernel_reserve(free, kernel.options.kernel_reserve_mib)
    budget.limit = free - held
    // Said when it was asked for: a line here, early, shifts test_pool's timing enough to fail it
    if kernel.options.kernel_reserve_mib != 0 {
        runtime.log_info("memory: % MiB kept out of the root budget for the kernel's own", held / MIB)
    }
    return object
}

/*
 * What the kernel keeps out of the root budget, of free bytes (decisions/0098): its heap, the objects it makes for
 * itself and objects' page arrays come from the same frames as everything charged to budgets, so a fully charged root
 * budget would leave it none. mib asks for that many MiB; otherwise a sixteenth, and at least MIN_KERNEL_RESERVE. Never
 * more than half.
 */
kernel_reserve :: fn(free: u64, mib: u64) -> u64 {
    asked :: if mib != 0 { mib * MIB } else { max_u64(free / 16, MIN_KERNEL_RESERVE) }
    return min_u64(asked, free / 2)
}

// Lock the budget object is charged to, following it if it moves meanwhile: null for the kernel's own.
lock_budget_of :: fn(object: u64) -> ptr[mut MemoryBudget]? {
    header :: cast[ptr[mut ObjectHeader]](object)
    loop {
        address :: intrinsics.atomic_load_u64_acquire(&header.budget)
        if address == 0 {
            return null
        }
        budget :: cast[ptr[mut MemoryBudget]](address)
        lock_at(&budget.lock, .MemoryBudget)
        if intrinsics.atomic_load_u64(&header.budget) == address {
            return budget
        }
        unlock_at(&budget.lock, .MemoryBudget)
    }
}

/*
 * Charge a new object, not yet anyone's, to budget (0 for the kernel's own): bytes, linked onto its list.
 * False if the budget is closed or can't take them.
 */
charge_new :: fn(budget_address: u64, object: u64, bytes: u64) -> bool {
    header :: cast[ptr[mut ObjectHeader]](object)
    header.charge = 0
    header.budget = 0
    if budget_address == 0 {
        return true
    }
    if fails(.Budget) {
        return false
    }
    budget :: cast[ptr[mut MemoryBudget]](budget_address)
    lock_at(&budget.lock, .MemoryBudget)
    if budget.closed || bytes > budget.limit - budget.used {
        unlock_at(&budget.lock, .MemoryBudget)
        return false
    }
    budget.used += bytes
    header.charge = bytes
    link_charged(budget, object)
    intrinsics.atomic_store_u64_release(&header.budget, budget_address)
    raise :: pressing(budget)
    unlock_at(&budget.lock, .MemoryBudget)
    if raise {
        raise_pressure(budget)
    }
    return true
}

// Charge bytes more to what object is charged to, for what it grows: false if that can't take them.
charge_more :: fn(object: u64, bytes: u64) -> bool {
    header :: cast[ptr[mut ObjectHeader]](object)
    budget :: lock_budget_of(object) or_return true
    if fails(.Budget) || budget.closed || bytes > budget.limit - budget.used {
        unlock_at(&budget.lock, .MemoryBudget)
        return false
    }
    budget.used += bytes
    header.charge += bytes
    raise :: pressing(budget)
    unlock_at(&budget.lock, .MemoryBudget)
    if raise {
        raise_pressure(budget)
    }
    return true
}

/*
 * Give back bytes object was charged, if it's still the object with generation: once it's destroyed,
 * its release gives back its whole charge, what it held included.
 */
uncharge :: fn(object: u64, generation: u32, bytes: u64) {
    header :: cast[ptr[mut ObjectHeader]](object)
    budget :: lock_budget_of(object) or_return void
    defer unlock_at(&budget.lock, .MemoryBudget)
    if intrinsics.atomic_load_u32_acquire(&header.generation) != generation || bytes > header.charge {
        return void
    }
    header.charge -= bytes
    budget.used -= bytes
    ease(budget)
}

// A released object's whole charge, back to its budget.
return_charge :: fn(object: u64) {
    header :: cast[ptr[mut ObjectHeader]](object)
    budget :: lock_budget_of(object) or_return void
    defer unlock_at(&budget.lock, .MemoryBudget)
    budget.used -= header.charge
    ease(budget)
    unlink_charged(budget, object)
    header.charge = 0
    intrinsics.atomic_store_u64_release(&header.budget, 0)
}

/*
 * A child budget of limit bytes, charged to parent with its slot, owned by owner (a Process's address,
 * 0 for the kernel).
 */
create_budget :: fn(kernel: ptr[mut Kernel], owner: u64, parent: u64, limit: u64) -> Result[ptr[mut MemoryBudget], ObjectError] {
    object :: new_object(kernel, .MemoryBudget, parent, limit)?
    budget :: cast[ptr[mut MemoryBudget]](object)
    budget.limit = limit
    match adopt(owner, object) {
        case Ok => {}
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return .Error(error)
        }
    }
    return .Ok(budget)
}

/*
 * Closing a budget: its charges move to its parent, which takes back its limit, so the parent gains
 * what the child didn't use. Its own slot stays charged to the parent until it's released.
 */
destroy_memory_budget :: fn(kernel: ptr[mut Kernel], budget: ptr[mut MemoryBudget]) {
    lock_at(&kernel.budgets_lock, .Budgets)
    defer unlock_at(&kernel.budgets_lock, .Budgets)
    // Its parent doesn't change with budgets_lock held; the two locks by address (lock_budgets)
    parent_address :: budget.header.budget
    lock_budgets(cast[u64](budget), parent_address)
    defer unlock_budget(cast[u64](budget))
    defer unlock_budget(parent_address)
    budget.closed = true
    if parent_address == 0 {
        return void
    }
    parent :: cast[ptr[mut MemoryBudget]](parent_address)
    loop {
        object :: budget.first_charged
        if object == 0 {
            break
        }
        unlink_charged(budget, object)
        link_charged(parent, object)
        intrinsics.atomic_store_u64_release(&cast[ptr[mut ObjectHeader]](object).budget, parent_address)
    }
    // Its limit was charged to the parent; what it used is now
    parent.used = parent.used - budget.limit + budget.used
    ease(parent)
    budget.header.charge -= budget.limit
    budget.used = 0
    budget.limit = 0
}

release_memory_budget :: fn(kernel: ptr[mut Kernel], budget: ptr[mut MemoryBudget]) {
}

/*
 * Move the charges of objects, whose owning handles a process takes, to budget (0 for the kernel): all
 * of them, or, if budget can't take them all, none (decisions/0011). With budgets_lock held, the
 * budgets they're charged to can't close meanwhile; what's moved back on failure goes back even if one
 * of them grew in the meantime.
 */
move_charges :: fn(kernel: ptr[mut Kernel], objects: ptr[u64[64]], count: u32, to_address: u64) -> bool {
    lock_at(&kernel.budgets_lock, .Budgets)
    defer unlock_at(&kernel.budgets_lock, .Budgets)
    from : u64[64]
    for object, i in objects^ {
        if i >= cast[usize](count) {
            break
        }
        from_address :: cast[ptr[ObjectHeader]](object).budget
        from[i] = from_address
        if from_address != to_address {
            // With budgets_lock held, no one else holds two budgets' locks; they're taken by address, the order checked
            lock_budgets(to_address, from_address)
            done :: move_locked(object, from_address, to_address, true)
            raise :: done && to_address != 0 && pressing(cast[ptr[mut MemoryBudget]](to_address))
            unlock_budget(from_address)
            unlock_budget(to_address)
            if raise {
                raise_pressure(cast[ptr[mut MemoryBudget]](to_address))
            }
            if !done {
                for earlier, j in objects^ {
                    if j >= i {
                        break
                    }
                    back :: from[j]
                    if back != to_address {
                        lock_budgets(to_address, back)
                        _ = move_locked(earlier, to_address, back, false)
                        unlock_budget(back)
                        unlock_budget(to_address)
                    }
                }
                return false
            }
        }
    }
    return true
}

// Move object's charge between two budgets whose locks are held, checking the receiver's limit if checked.
move_locked :: fn(object: u64, from_address: u64, to_address: u64, checked: bool) -> bool {
    header :: cast[ptr[mut ObjectHeader]](object)
    charge :: header.charge
    to :: cast[ptr[mut MemoryBudget]](to_address)
    if to_address != 0 && checked && (to.closed || charge > to.limit - to.used) {
        return false
    }
    if from_address != 0 {
        from :: cast[ptr[mut MemoryBudget]](from_address)
        from.used -= charge
        ease(from)
        unlink_charged(from, object)
    }
    if to_address != 0 {
        to.used += charge
        link_charged(to, object)
    }
    intrinsics.atomic_store_u64_release(&header.budget, to_address)
    return true
}

// Two budgets' locks, the lower address's first (locks.hsc, lock_after); one, if they're the same budget or either is 0.
lock_budgets :: fn(first: u64, second: u64) {
    low :: if first < second { first } else { second }
    high :: if first < second { second } else { first }
    if low == high || low == 0 {
        lock_budget(high)
        return void
    }
    lock_budget(low)
    lock_after(&cast[ptr[mut MemoryBudget]](high).lock, .MemoryBudget)
}

lock_budget :: fn(address: u64) {
    if address != 0 {
        lock_at(&cast[ptr[mut MemoryBudget]](address).lock, .MemoryBudget)
    }
}

unlock_budget :: fn(address: u64) {
    if address != 0 {
        unlock_at(&cast[ptr[mut MemoryBudget]](address).lock, .MemoryBudget)
    }
}

/*
 * Whether budget has just reached its threshold, so SIGNAL_PRESSURE is to be raised once its lock is let go: it's
 * marked raised, so it isn't again until it falls below. Takes the budget's lock as held.
 */
pressing :: fn(budget: ptr[mut MemoryBudget]) -> bool {
    if budget.threshold == 0 || budget.pressured || budget.used < budget.threshold {
        return false
    }
    budget.pressured = true
    return true
}

// A budget that has fallen below its threshold, raised again when it next reaches it. Takes the budget's lock as held.
ease :: fn(budget: ptr[mut MemoryBudget]) {
    if budget.used < budget.threshold {
        budget.pressured = false
    }
}

// SIGNAL_PRESSURE raised for the bindings watching budget, with what it has charged. Called with no budget's lock held.
raise_pressure :: fn(budget: ptr[mut MemoryBudget]) {
    raise_watchers(per_cpu().kernel, &budget.watchers, &budget.watch_lock, .Watchers, cast[u32](slop_os.SIGNAL_PRESSURE),
        intrinsics.atomic_load_u64(&budget.used))
}

// The budget's threshold set, 0 for none, and SIGNAL_PRESSURE raised at once if it's reached already.
set_threshold :: fn(budget: ptr[mut MemoryBudget], threshold: u64) {
    lock_at(&budget.lock, .MemoryBudget)
    budget.threshold = threshold
    budget.pressured = false
    raise :: pressing(budget)
    unlock_at(&budget.lock, .MemoryBudget)
    if raise {
        raise_pressure(budget)
    }
}

// What it may charge, and what it has charged.
budget_info :: fn(budget: ptr[mut MemoryBudget]) -> (limit: u64, used: u64) {
    lock_at(&budget.lock, .MemoryBudget)
    defer unlock_at(&budget.lock, .MemoryBudget)
    return budget.limit, budget.used
}

// Link object onto what budget is charged with. Takes the budget's lock as held.
link_charged :: fn(budget: ptr[mut MemoryBudget], object: u64) {
    header :: cast[ptr[mut ObjectHeader]](object)
    header.charged_previous = 0
    header.charged_next = budget.first_charged
    if budget.first_charged != 0 {
        cast[ptr[mut ObjectHeader]](budget.first_charged).charged_previous = object
    }
    budget.first_charged = object
}

unlink_charged :: fn(budget: ptr[mut MemoryBudget], object: u64) {
    header :: cast[ptr[mut ObjectHeader]](object)
    if header.charged_previous != 0 {
        cast[ptr[mut ObjectHeader]](header.charged_previous).charged_next = header.charged_next
    }
    else {
        budget.first_charged = header.charged_next
    }
    if header.charged_next != 0 {
        cast[ptr[mut ObjectHeader]](header.charged_next).charged_previous = header.charged_previous
    }
    header.charged_next = 0
    header.charged_previous = 0
}
