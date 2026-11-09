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

/** A memory budget: a quota of memory, in bytes, that objects are charged to, and that child budgets are split from. */
MemoryBudget :: struct #align(16) {
    /** The kernel object's header; its budget is the parent's address, 0 for the root budget. */
    header : ObjectHeader,
    /** Guards limit, used, the charged list, closed, threshold and pressured, at LockRank MemoryBudget. */
    lock : concurrency.SpinLock,
    /** What it may have charged, in bytes; 0 once it's closed. */
    limit : u64,
    /** What it has charged, in bytes: its objects' charges and its child budgets' limits. */
    used : u64,
    /** The objects charged to it, linked through their headers' charged_next and charged_previous; 0 for none. */
    first_charged : u64,
    /** Once it's destroyed: what it had went to its parent, and nothing more is charged to it. */
    closed : bool,
    /** Its pressure threshold, in bytes charged, 0 for none. */
    threshold : u64,
    /** Whether SIGNAL_PRESSURE was raised since used last fell below threshold, so it isn't raised again until then. */
    pressured : bool,
    /** Guards watchers, at LockRank Watchers. */
    watch_lock : concurrency.SpinLock,
    /** Bindings watching for pressure (SIGNAL_PRESSURE), under watch_lock; an empty slot's binding is 0. */
    watchers : EndBinding[2],
}

/** A mebibyte, in bytes. */
MIB : u64 : 1024 * 1024
/** The least the kernel keeps out of the root budget for its own allocations (kernel_reserve), in bytes. */
MIN_KERNEL_RESERVE : u64 : 8 * MIB

/**
 * Make the root budget, of the memory free once the kernel is up, but the kernel's own share (kernel_reserve).
 *
 * The kernel keeps its share: the budgets processes are given are split from the root. The root is charged to no
 * budget and owned by no process. Logs the share when the kernel_reserve_mib option asked for one.
 *
 * @param kernel The kernel, whose frame allocator's free frames, now, are what's shared out.
 * @return The root budget's object address, or 0 if there was no memory for its slot.
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

/**
 * Work out what the kernel keeps out of the root budget, of the free memory (decisions/0098).
 *
 * Its heap, the objects it makes for itself and objects' page arrays come from the same frames as everything charged to
 * budgets, so a fully charged root budget would leave it none.
 *
 * @param free The memory free, in bytes.
 * @param mib What was asked for, in MiB, or 0 for the default: a sixteenth of free, and at least MIN_KERNEL_RESERVE.
 * @return The bytes kept, never more than half of free.
 */
kernel_reserve :: fn(free: u64, mib: u64) -> u64 {
    asked :: if mib != 0 { mib * MIB } else { max_u64(free / 16, MIN_KERNEL_RESERVE) }
    return min_u64(asked, free / 2)
}

/**
 * Lock the budget an object is charged to, following it if the charge moves meanwhile.
 *
 * Takes the budget's lock, at LockRank MemoryBudget, which the caller lets go with unlock_at.
 *
 * @param object The object's address, which must stay valid meanwhile.
 * @return The budget, locked, or null for an object charged to no budget (the kernel's own), with nothing locked.
 */
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

/**
 * Charge a new object, not yet anyone's, to a budget, linking it onto the budget's list.
 *
 * Takes the budget's lock, at LockRank MemoryBudget, and raises SIGNAL_PRESSURE after letting it go if the charge
 * reached the budget's threshold.
 *
 * @param budget_address The budget's address, or 0 for the kernel's own, which charges nothing; it must stay valid
 *     meanwhile.
 * @param object The new object's address. Its header's charge and budget are overwritten, 0 when this fails.
 * @param bytes The charge, in bytes: the object's slot and what it holds.
 * @return True if it's charged, or the budget is 0; false if the budget is closed or has less than bytes left, or
 *     fault injection failed the Budget point.
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
    if budget.closed || bytes > room_of(budget) {
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

/**
 * Charge more to the budget an object is charged to, for what it grows.
 *
 * Takes the budget's lock, at LockRank MemoryBudget, and raises SIGNAL_PRESSURE after letting it go if the charge
 * reached the budget's threshold.
 *
 * @param object A live kernel object, by its ObjectHeader's address, which the caller keeps from being freed meanwhile;
 *     its charge grows by bytes when they're charged.
 * @param bytes The bytes more, added to the object's charge.
 * @return True if they're charged, or the object is charged to no budget; false if its budget is closed or has less
 *     than bytes left, or fault injection failed the Budget point, with nothing charged.
 */
charge_more :: fn(object: u64, bytes: u64) -> bool {
    header :: cast[ptr[mut ObjectHeader]](object)
    budget :: lock_budget_of(object) or_return true
    if fails(.Budget) || budget.closed || bytes > room_of(budget) {
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

/**
 * Give back part of an object's charge, for what it shrank, if it's still the object of a generation.
 *
 * Once it's destroyed, its release gives back its whole charge, what it held included, so nothing is given here then.
 * Takes the budget's lock, at LockRank MemoryBudget.
 *
 * @param object The object's slot address.
 * @param generation The generation it had when it grew; another means the slot was destroyed or reused.
 * @param bytes The bytes to give back; more than the object's charge gives back nothing.
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

/**
 * Give a released object's whole charge back to its budget, and unlink it from the budget's list.
 *
 * Takes the budget's lock, at LockRank MemoryBudget. The object is charged to no budget afterwards.
 *
 * @param object The object's address; one charged to no budget is left alone.
 */
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

/**
 * Make a child budget, its limit and its slot charged to its parent.
 *
 * @param kernel The kernel, whose object pool the budget's slot comes from, taking the pool's lock and the frame
 *     allocator's, and which destroys the budget again if adopting it fails.
 * @param owner The Process that owns it, as an address, or 0 for the kernel.
 * @param parent The parent budget's address, which pays for it, or 0 for none.
 * @param limit What the child may charge, in bytes, charged to the parent with the child's slot.
 * @return The budget, empty, owned by owner and destroyed with it.
 * @error OutOfMemory No memory for its slot.
 * @error BudgetExceeded The parent is closed, or can't take the limit and the slot.
 * @error OwnerGone The owner is being destroyed, so the new budget is destroyed.
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

/**
 * Close a budget: its charges move to its parent, which takes back its limit, so the parent gains what the child didn't
 * use.
 *
 * Its own slot stays charged to the parent until it's released. Nothing charged to it is destroyed. Takes
 * kernel.budgets_lock, at LockRank Budgets, then both budgets' locks, the lower address first. A budget with no parent
 * (the root) is only marked closed, its charges left on it.
 *
 * @param kernel The kernel, whose budgets_lock is taken, at LockRank Budgets, for the whole move, so the caller mustn't
 *     hold it or any budget's lock.
 * @param budget The budget, being destroyed; it's closed afterwards, its limit and used 0.
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

/**
 * Release a budget's slot once it's destroyed and unreferenced: nothing to do, as destroying it moved its charges.
 *
 * @param kernel Unused, as there's nothing to free.
 * @param budget The budget, closed.
 */
release_memory_budget :: fn(kernel: ptr[mut Kernel], budget: ptr[mut MemoryBudget]) {
}

/**
 * Move the charges of objects, whose owning handles a process takes, to a budget: all of them, or, if the budget can't
 * take them all, none (decisions/0011).
 *
 * With kernel.budgets_lock held, at LockRank Budgets, the budgets they're charged to can't close meanwhile; each move
 * takes the two budgets' locks, the lower address first. What's moved back on failure goes back even if a budget it
 * goes back to can no longer take it. SIGNAL_PRESSURE is raised on the receiving budget when a move reaches its
 * threshold.
 *
 * @param kernel The kernel, whose budgets_lock is taken, at LockRank Budgets, for the whole move, so the caller mustn't
 *     hold it or any budget's lock.
 * @param objects The objects' addresses; only the first count are looked at.
 * @param count How many objects, 0 to 64.
 * @param to_address The receiving budget's address, or 0 for the kernel, which takes any charge.
 * @return True if every charge moved; false if the budget is closed or couldn't take one, with those moved before it
 *     moved back.
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

/**
 * Give how many more bytes a budget can be charged.
 *
 * A charge moved back to a budget unchecked (move_charges undoing a move) can leave it over its limit, when it was
 * charged meanwhile; it then has no room, rather than limit - used wrapping round to nearly all of a u64.
 *
 * @param budget The budget, its lock held by the caller.
 * @return Its limit less what's charged to it, in bytes; 0 when it's at or over its limit.
 */
room_of :: fn(budget: ptr[MemoryBudget]) -> u64 {
    return if budget.used >= budget.limit { cast[u64](0) } else { budget.limit - budget.used }
}

/**
 * Move an object's charge between two budgets whose locks are held, relinking it.
 *
 * @param object The object's address, charged to from_address.
 * @param from_address The budget it's charged to now, or 0 for the kernel.
 * @param to_address The budget it moves to, or 0 for the kernel.
 * @param checked Whether the receiver's limit and closedness are checked; false only to move a charge back.
 * @return True if it moved; false, with nothing changed, if checked and the receiver is closed or can't take it.
 */
move_locked :: fn(object: u64, from_address: u64, to_address: u64, checked: bool) -> bool {
    header :: cast[ptr[mut ObjectHeader]](object)
    charge :: header.charge
    to :: cast[ptr[mut MemoryBudget]](to_address)
    if to_address != 0 && checked && (to.closed || charge > room_of(to)) {
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

/**
 * Lock two budgets, the lower address's first (locks.hsc, lock_after); only one if they're the same, or either is 0.
 *
 * @param first One budget's address, or 0 for none.
 * @param second The other's, or 0 for none; with both 0, nothing is locked.
 */
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

/**
 * Lock a budget, at LockRank MemoryBudget, if there is one.
 *
 * @param address The budget's address, or 0 for none, when nothing is locked.
 */
lock_budget :: fn(address: u64) {
    if address != 0 {
        lock_at(&cast[ptr[mut MemoryBudget]](address).lock, .MemoryBudget)
    }
}

/**
 * Unlock a budget lock_budget or lock_budgets locked, if there is one.
 *
 * @param address The budget's address, or 0 for none.
 */
unlock_budget :: fn(address: u64) {
    if address != 0 {
        unlock_at(&cast[ptr[mut MemoryBudget]](address).lock, .MemoryBudget)
    }
}

/**
 * Tell whether a budget has just reached its threshold, so SIGNAL_PRESSURE is to be raised once its lock is let go.
 *
 * It's marked raised, so it isn't again until it falls below. The caller holds the budget's lock.
 *
 * @param budget The budget, its lock held.
 * @return True if it has a threshold, used has reached it, and it wasn't raised since it last fell below; the caller
 *     then calls raise_pressure after letting the lock go.
 */
pressing :: fn(budget: ptr[mut MemoryBudget]) -> bool {
    if budget.threshold == 0 || budget.pressured || budget.used < budget.threshold {
        return false
    }
    budget.pressured = true
    return true
}

/**
 * Note that a budget has fallen below its threshold, if it has, so pressure is raised again when it next reaches it.
 *
 * @param budget The budget, its lock held by the caller.
 */
ease :: fn(budget: ptr[mut MemoryBudget]) {
    if budget.used < budget.threshold {
        budget.pressured = false
    }
}

/**
 * Raise SIGNAL_PRESSURE for the bindings watching a budget, with what it has charged as their detail.
 *
 * Called with no budget's lock held; takes its watch_lock, at LockRank Watchers, and each bound port's lock.
 *
 * @param budget The budget whose watchers are signalled; its lock mustn't be held. Its used is read atomically, without
 *     the lock, so it may be a moment stale.
 */
raise_pressure :: fn(budget: ptr[mut MemoryBudget]) {
    raise_watchers(per_cpu().kernel, &budget.watchers, &budget.watch_lock, .Watchers, cast[u32](slop_os.SIGNAL_PRESSURE),
        intrinsics.atomic_load_u64(&budget.used))
}

/**
 * Set a budget's pressure threshold, raising SIGNAL_PRESSURE at once if it's reached already.
 *
 * Takes the budget's lock, at LockRank MemoryBudget, and raises after letting it go.
 *
 * @param budget The budget, whose lock is taken, at LockRank MemoryBudget, so the caller mustn't hold it; its pressured
 *     mark is cleared, so the new threshold can be raised at once.
 * @param threshold The threshold, in bytes charged, or 0 for none.
 */
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

/**
 * Read what a budget may charge, and what it has charged, together, under its lock.
 *
 * @param budget The budget, whose lock is taken, at LockRank MemoryBudget, so the two are read together; the caller
 *     mustn't hold it.
 * @return limit What it may charge, in bytes; 0 once it's closed.
 * @return used What it has charged, in bytes, its child budgets' limits included.
 */
budget_info :: fn(budget: ptr[mut MemoryBudget]) -> (limit: u64, used: u64) {
    lock_at(&budget.lock, .MemoryBudget)
    defer unlock_at(&budget.lock, .MemoryBudget)
    return budget.limit, budget.used
}

/**
 * Add up what's charged to a budget by objects of processes not on it (decisions/0185, 12h): a server's, made for a
 * client and charged to the client's budget. A process's own slot, made by its creator, isn't counted.
 *
 * @param budget The budget; its lock is taken, at LockRank MemoryBudget, while its list is walked.
 * @return The bytes.
 */
charged_by_others :: fn(budget: ptr[mut MemoryBudget]) -> u64 {
    lock_at(&budget.lock, .MemoryBudget)
    defer unlock_at(&budget.lock, .MemoryBudget)
    total : u64 = 0
    at := budget.first_charged
    loop {
        if at == 0 {
            break
        }
        header :: cast[ptr[ObjectHeader]](at)
        owner :: header.owner
        if header.kind != .Process && owner != 0 && cast[ptr[Process]](owner).header.budget != cast[u64](budget) {
            total += header.charge
        }
        at = header.charged_next
    }
    return total
}

/**
 * Link an object first onto a budget's list of what's charged to it.
 *
 * @param budget The budget, its lock held by the caller.
 * @param object The object's address, on no budget's list.
 */
link_charged :: fn(budget: ptr[mut MemoryBudget], object: u64) {
    header :: cast[ptr[mut ObjectHeader]](object)
    header.charged_previous = 0
    header.charged_next = budget.first_charged
    if budget.first_charged != 0 {
        cast[ptr[mut ObjectHeader]](budget.first_charged).charged_previous = object
    }
    budget.first_charged = object
}

/**
 * Take an object off a budget's list of what's charged to it.
 *
 * @param budget The budget, its lock held by the caller.
 * @param object The object's address, on that budget's list.
 */
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
