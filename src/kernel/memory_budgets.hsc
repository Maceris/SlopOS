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
}

/*
 * The root budget, of every frame free once the kernel is up, which the kernel keeps: the budgets
 * processes are given are split from it.
 */
make_root_budget :: fn(kernel: ptr[mut Kernel]) -> u64 {
    object :: new_object(kernel, .MemoryBudget, 0, 0) or_else 0
    if object == 0 {
        return 0
    }
    budget :: cast[ptr[mut MemoryBudget]](object)
    budget.limit = kernel.frames.free_frames * frames.FRAME_SIZE
    return object
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
        concurrency.lock(&budget.lock)
        if intrinsics.atomic_load_u64(&header.budget) == address {
            return budget
        }
        concurrency.unlock(&budget.lock)
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
    budget :: cast[ptr[mut MemoryBudget]](budget_address)
    concurrency.lock(&budget.lock)
    defer concurrency.unlock(&budget.lock)
    if budget.closed || bytes > budget.limit - budget.used {
        return false
    }
    budget.used += bytes
    header.charge = bytes
    link_charged(budget, object)
    intrinsics.atomic_store_u64_release(&header.budget, budget_address)
    return true
}

// Charge bytes more to what object is charged to, for what it grows: false if that can't take them.
charge_more :: fn(object: u64, bytes: u64) -> bool {
    header :: cast[ptr[mut ObjectHeader]](object)
    budget :: lock_budget_of(object) or_return true
    defer concurrency.unlock(&budget.lock)
    if budget.closed || bytes > budget.limit - budget.used {
        return false
    }
    budget.used += bytes
    header.charge += bytes
    return true
}

/*
 * Give back bytes object was charged, if it's still the object with generation: once it's destroyed,
 * its release gives back its whole charge, what it held included.
 */
uncharge :: fn(object: u64, generation: u32, bytes: u64) {
    header :: cast[ptr[mut ObjectHeader]](object)
    budget :: lock_budget_of(object) or_return void
    defer concurrency.unlock(&budget.lock)
    if intrinsics.atomic_load_u32_acquire(&header.generation) != generation || bytes > header.charge {
        return void
    }
    header.charge -= bytes
    budget.used -= bytes
}

// A released object's whole charge, back to its budget.
return_charge :: fn(object: u64) {
    header :: cast[ptr[mut ObjectHeader]](object)
    budget :: lock_budget_of(object) or_return void
    defer concurrency.unlock(&budget.lock)
    budget.used -= header.charge
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
    concurrency.lock(&kernel.budgets_lock)
    defer concurrency.unlock(&kernel.budgets_lock)
    concurrency.lock(&budget.lock)
    defer concurrency.unlock(&budget.lock)
    budget.closed = true
    parent_address :: budget.header.budget
    if parent_address == 0 {
        return void
    }
    parent :: cast[ptr[mut MemoryBudget]](parent_address)
    concurrency.lock(&parent.lock)
    defer concurrency.unlock(&parent.lock)
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
    concurrency.lock(&kernel.budgets_lock)
    defer concurrency.unlock(&kernel.budgets_lock)
    from : u64[64]
    for object, i in objects^ {
        if i >= cast[usize](count) {
            break
        }
        from_address :: cast[ptr[ObjectHeader]](object).budget
        from[i] = from_address
        if from_address != to_address {
            // With budgets_lock held, no one else holds two budgets' locks, so these can be taken in any order
            lock_budget(to_address)
            lock_budget(from_address)
            done :: move_locked(object, from_address, to_address, true)
            unlock_budget(from_address)
            unlock_budget(to_address)
            if !done {
                for earlier, j in objects^ {
                    if j >= i {
                        break
                    }
                    back :: from[j]
                    if back != to_address {
                        lock_budget(to_address)
                        lock_budget(back)
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
        unlink_charged(from, object)
    }
    if to_address != 0 {
        to.used += charge
        link_charged(to, object)
    }
    intrinsics.atomic_store_u64_release(&header.budget, to_address)
    return true
}

lock_budget :: fn(address: u64) {
    if address != 0 {
        concurrency.lock(&cast[ptr[mut MemoryBudget]](address).lock)
    }
}

unlock_budget :: fn(address: u64) {
    if address != 0 {
        concurrency.unlock(&cast[ptr[mut MemoryBudget]](address).lock)
    }
}

// What it may charge, and what it has charged.
budget_info :: fn(budget: ptr[mut MemoryBudget]) -> (limit: u64, used: u64) {
    concurrency.lock(&budget.lock)
    defer concurrency.unlock(&budget.lock)
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
