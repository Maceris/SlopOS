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
 * CPU budgets as kernel objects (roadmap 9a, decisions/0037, 0093): a CpuTime (budgets.hsc) with a parent, behind
 * handles, split and adjusted from user space by the scheduler service. A budget's share is its time over its period,
 * in millionths of a CPU; its children's shares together can't pass its own, and their priorities can't pass its. The
 * root budget, which the root task is given, is every CPU's whole time at the highest priority.
 *
 * Every process runs on a budget, its creator's unless process_set_cpu_budget gives it another, and so do its threads.
 * Destroyed, a budget's threads, processes and children go to its parent: nothing that ran on it stops running. The
 * shape of the tree, and who runs on what, changes only under kernel.cpu_budgets_lock; what a budget has left changes
 * under its CpuTime's lock, which the scheduler takes at every tick.
 *
 * A budget's threads run only on its CPUs (cpu_budget_set_cpus, decisions/0099): a child starts with its parent's, and
 * a budget's are within its parent's and over its children's.
 */

/** The root budget's period, in nanoseconds: 10 ms. */
ROOT_PERIOD_NS : u64 : 10_000_000
/** The highest priority a budget can have, the root's; priorities run from 0 up to it. */
TOP_PRIORITY : u32 : 255
/** A whole CPU, in the units shares are counted in: a share is in millionths of a CPU. */
WHOLE_CPU : u64 : 1_000_000

/**
 * A CPU budget, a kernel object: some time every period at a priority, on some CPUs, which threads and processes run
 * on, and which is split into children. Its tree links change under kernel.cpu_budgets_lock.
 */
CpuBudget :: struct #align(16) {
    /** The object's header: its kind, generation, owner and charge. */
    header : ObjectHeader,
    /** What the scheduler charges and checks: its priority, period, time and what's left in counter ticks, and CPUs. */
    time : CpuTime,
    /** Its parent CpuBudget, as an address; 0 for the root, and once it's destroyed. */
    parent : u64,
    /**
     * Its share of the CPUs, in millionths of a CPU: time_ns over period_ns. With its siblings', it's within its
     * parent's.
     */
    share : u64,
    /** Its children's shares together, in millionths of a CPU; at most its own share. */
    children_share : u64,
    /** Its period as given, in nanoseconds, above 0. */
    period_ns : u64,
    /** Its time each period as given, in nanoseconds, above 0; more than period_ns for more than one CPU's worth. */
    time_ns : u64,
    /** The first Thread running on it, as an address, 0 for none; the list runs through each thread's budget_next. */
    first_thread : u64,
    /** The first Process on it, as an address, 0 for none; the list runs through each one's cpu_budget_next. */
    first_process : u64,
    /** Its first child CpuBudget, as an address, 0 for none; the list runs through the children's sibling_next. */
    first_child : u64,
    /** The next child of its parent, as an address, 0 for the last. */
    sibling_next : u64,
    /** The previous child of its parent, as an address, 0 for the first. */
    sibling_previous : u64,
}

/**
 * Work out the share of the CPUs some time every period is.
 *
 * Whole CPUs and the rest are worked out apart, so the multiplication doesn't overflow for whole CPUs.
 *
 * @param period_ns The period, in nanoseconds.
 * @param time_ns The time each period, in nanoseconds; more than period_ns is more than one CPU.
 * @return The share, in millionths of a CPU, rounded down; null if period_ns is 0, or time_ns is 2^32 or more
 *     periods.
 */
share_of :: fn(period_ns: u64, time_ns: u64) -> u64? {
    if period_ns == 0 {
        return null
    }
    whole :: time_ns / period_ns
    part :: time_ns % period_ns
    if whole > 0xffff_ffff {
        return null
    }
    return whole * WHOLE_CPU + part * WHOLE_CPU / period_ns
}

/**
 * Make the root CPU budget: every online CPU's whole time, at TOP_PRIORITY, owned by the kernel and never charged.
 *
 * Called once at boot, after the other CPUs have started and before the root task does, which is given it.
 *
 * @param kernel The kernel, whose online_cpus sets its share and time.
 * @return The budget, as an address, owned by the kernel and charged to no memory budget; 0 if there was no memory
 *     for it.
 */
make_root_cpu_budget :: fn(kernel: ptr[mut Kernel]) -> u64 {
    object :: new_object(kernel, .CpuBudget, 0, 0) or_else 0
    if object == 0 {
        return 0
    }
    budget :: cast[ptr[mut CpuBudget]](object)
    cpus :: cast[u64](intrinsics.atomic_load_u32_acquire(&kernel.online_cpus))
    budget.period_ns = ROOT_PERIOD_NS
    budget.time_ns = ROOT_PERIOD_NS * cpus
    budget.share = cpus * WHOLE_CPU
    budget.time = make_budget(kernel, cast[u8](TOP_PRIORITY), budget.period_ns, budget.time_ns)
    // Its threads can't use more than every CPU has, so it's never charged: refills merged past MAX_REFILLS would
    // otherwise hold back time it has
    budget.time.unlimited = true
    return object
}

/** Why a CPU budget couldn't be made or changed. */
CpuBudgetError :: enum {
    /** The object's pool couldn't get frames for it. */
    OutOfMemory,
    /** The process that was to own it is being destroyed. */
    OwnerGone,
    /** The memory budget it's charged to couldn't take it. */
    BudgetExceeded,
    /**
     * More than allowed: out of the parent's share, above its priority or CPUs, below a child's, or a change to the
     * root, which nothing changes; or the parent is being destroyed.
     */
    TooMuch,
    /** A priority above TOP_PRIORITY, a time or period of 0, a share too big to count, or no online CPU given. */
    InvalidArgument,
}

/**
 * Make a child CPU budget, out of its parent's share, full to start with and on its parent's CPUs.
 *
 * Takes kernel.cpu_budgets_lock, at LockRank CpuBudgets, then the owner's object list's lock.
 *
 * @param kernel The kernel: its object pools and frames give the budget's object, and its cpu_budgets_lock, taken
 *     at LockRank CpuBudgets, guards the parent's share and children. Runs in a system call, with no lock held.
 * @param owner The Process that owns it, as an address, or 0 for the kernel.
 * @param memory_budget The MemoryBudget its object is charged to, as an address, or 0 for the kernel's own.
 * @param parent The budget it's a child of, which keeps the share it takes until it's destroyed.
 * @param priority Its threads' priority while it has time, from 0 to the parent's.
 * @param period_ns Its period, in nanoseconds, above 0.
 * @param time_ns Its time each period, in nanoseconds, above 0; with period_ns, a share that fits in what's left of
 *     the parent's.
 * @return The budget, on its owner's list, with nothing running on it.
 * @error InvalidArgument A priority above TOP_PRIORITY, a time or period of 0, or a share too big to count.
 * @error OutOfMemory No memory for the object.
 * @error BudgetExceeded The memory budget couldn't take the object.
 * @error TooMuch The parent is being destroyed, its priority is lower, or what's left of its share is too little.
 * @error OwnerGone The owner is being destroyed; the budget was made and destroyed again, its share given back.
 */
create_cpu_budget :: fn(kernel: ptr[mut Kernel], owner: u64, memory_budget: u64, parent: ptr[mut CpuBudget], priority: u32, period_ns: u64,
    time_ns: u64) -> Result[ptr[mut CpuBudget], CpuBudgetError] {
    share :: share_of(period_ns, time_ns) or_return .Error(.InvalidArgument)
    if priority > TOP_PRIORITY || time_ns == 0 {
        return .Error(.InvalidArgument)
    }
    object := cast[u64](0)
    match new_object(kernel, .CpuBudget, memory_budget, 0) {
        case Ok(made) => object = made
        case Error(error) => return .Error(if error == .BudgetExceeded { CpuBudgetError.BudgetExceeded } else { CpuBudgetError.OutOfMemory })
    }
    budget :: cast[ptr[mut CpuBudget]](object)
    lock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    if parent.header.dying != 0 || priority > cast[u32](parent.time.priority) || parent.children_share + share > parent.share {
        unlock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
        release_object(kernel, object)
        return .Error(.TooMuch)
    }
    budget.period_ns = period_ns
    budget.time_ns = time_ns
    budget.share = share
    budget.time = make_budget(kernel, cast[u8](priority), period_ns, time_ns)
    budget.time.cpus = parent.time.cpus
    budget.parent = cast[u64](parent)
    parent.children_share += share
    link_child(parent, budget)
    unlock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    match adopt(owner, object) {
        case Ok => {}
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return .Error(.OwnerGone)
        }
    }
    return .Ok(budget)
}

/**
 * Change a budget's priority, period and time, within its parent's share and priority, and above its children's.
 *
 * The scheduler sees the change at its next look at the budget. Time it has left above the new time per period is
 * cut to it; less isn't topped up. Takes kernel.cpu_budgets_lock, then the budget's CpuTime lock.
 *
 * @param kernel The kernel, for its cpu_budgets_lock, taken at LockRank CpuBudgets, and its counter_frequency, which
 *     converts the new times to ticks. Runs with no lock held.
 * @param budget The budget to change, not the root.
 * @param priority Its new priority, from its children's highest to its parent's.
 * @param period_ns Its new period, in nanoseconds, above 0.
 * @param time_ns Its new time each period, in nanoseconds, above 0; with period_ns, a share its children's together
 *     fit in, and that fits in its parent's with its siblings'.
 * @error InvalidArgument A priority above TOP_PRIORITY, a time or period of 0, or a share too big to count.
 * @error TooMuch The budget is the root, or the change goes past its parent's share or priority, or below its
 *     children's share or a child's priority; nothing changed.
 */
set_cpu_budget :: fn(kernel: ptr[mut Kernel], budget: ptr[mut CpuBudget], priority: u32, period_ns: u64, time_ns: u64) -> Result[void, CpuBudgetError] {
    share :: share_of(period_ns, time_ns) or_return .Error(.InvalidArgument)
    if priority > TOP_PRIORITY || time_ns == 0 {
        return .Error(.InvalidArgument)
    }
    lock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    defer unlock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    if budget.parent == 0 {
        // The root's is every CPU's, which nothing changes
        return .Error(.TooMuch)
    }
    parent :: cast[ptr[mut CpuBudget]](budget.parent)
    if priority > cast[u32](parent.time.priority) || parent.children_share - budget.share + share > parent.share
        || budget.children_share > share || !children_below(budget, priority) {
        return .Error(.TooMuch)
    }
    parent.children_share = parent.children_share - budget.share + share
    budget.share = share
    budget.period_ns = period_ns
    budget.time_ns = time_ns
    lock_at(&budget.time.lock, .CpuTime)
    budget.time.priority = cast[u8](priority)
    budget.time.period = ticks_of(kernel, period_ns)
    budget.time.budget = ticks_of(kernel, time_ns)
    budget.time.available = min_u64(budget.time.available, budget.time.budget)
    unlock_at(&budget.time.lock, .CpuTime)
    return .Ok
}

/**
 * Change the CPUs a budget's threads may run on.
 *
 * Its threads move at their next tick, or the next time they're made ready. Takes kernel.cpu_budgets_lock.
 *
 * @param kernel The kernel, whose online_cpus are read atomically to check cpus, and whose cpu_budgets_lock is
 *     taken at LockRank CpuBudgets. Runs with no lock held.
 * @param budget The budget to change, not the root.
 * @param cpus A bit per CPU's index, bit 0 for CPU 0: at least one of them online, all within the parent's, and
 *     including every CPU of each of its children's.
 * @error InvalidArgument None of cpus is online.
 * @error TooMuch The budget is the root, cpus has a CPU its parent's don't, or leaves out one of a child's; nothing
 *     changed.
 */
set_cpu_budget_cpus :: fn(kernel: ptr[mut Kernel], budget: ptr[mut CpuBudget], cpus: u64) -> Result[void, CpuBudgetError] {
    online :: intrinsics.atomic_load_u32_acquire(&kernel.online_cpus)
    online_mask :: if online >= 64 { ~cast[u64](0) } else { (cast[u64](1) << cast[u64](online)) - 1 }
    if cpus & online_mask == 0 {
        return .Error(.InvalidArgument)
    }
    lock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    defer unlock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    if budget.parent == 0 {
        // The root's are every CPU
        return .Error(.TooMuch)
    }
    parent :: cast[ptr[CpuBudget]](budget.parent)
    if cpus & ~parent.time.cpus != 0 {
        return .Error(.TooMuch)
    }
    at := budget.first_child
    loop {
        if at == 0 {
            break
        }
        child :: cast[ptr[CpuBudget]](at)
        if child.time.cpus & ~cpus != 0 {
            return .Error(.TooMuch)
        }
        at = child.sibling_next
    }
    intrinsics.atomic_store_u64_release(&budget.time.cpus, cpus)
    return .Ok
}

/**
 * Find the CPUs a process's threads may run on, as its CPU budget has them.
 *
 * Takes kernel.cpu_budgets_lock.
 *
 * @param kernel The kernel, whose cpu_budgets_lock is taken at LockRank CpuBudgets; called with no lock of that
 *     rank or above held.
 * @param process The process, live or being destroyed; its cpu_budget is read under the lock.
 * @return A bit per CPU's index; all ones if the process is on no budget. Its bits may include CPUs not online.
 */
cpus_of :: fn(kernel: ptr[mut Kernel], process: ptr[Process]) -> u64 {
    lock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    defer unlock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    if process.cpu_budget == 0 {
        return ~cast[u64](0)
    }
    return cast[ptr[CpuBudget]](process.cpu_budget).time.cpus
}

/**
 * Pick the next online CPU in turn that's among some CPUs, for something to be routed or started on.
 *
 * @param kernel The kernel, whose online_cpus are the CPUs picked from.
 * @param counter The counter turned from, incremented atomically each call, so calls spread over the CPUs.
 * @param cpus A bit per CPU's index, the CPUs allowed; CPUs at index 64 and above are always allowed.
 * @return The index of an online CPU: the first allowed from the counter's turn on, or the one at its turn if none of
 *     the online CPUs is allowed.
 */
next_cpu_of :: fn(kernel: ptr[mut Kernel], counter: ptr[mut u32], cpus: u64) -> u32 {
    online :: intrinsics.atomic_load_u32_acquire(&kernel.online_cpus)
    start :: intrinsics.interlocked_increment_u32(counter) % online
    for offset in 0..<online {
        index :: (start + offset) % online
        if index >= 64 || (cpus >> cast[u64](index)) & 1 != 0 {
            return index
        }
    }
    return start
}

/**
 * Tell whether every child of a budget has a priority at most some priority.
 *
 * @param budget The budget, whose children are read with kernel.cpu_budgets_lock held by the caller.
 * @param priority The priority to compare with.
 * @return True if no child's priority is above it, or there are no children.
 */
children_below :: fn(budget: ptr[CpuBudget], priority: u32) -> bool {
    at := budget.first_child
    loop {
        if at == 0 {
            return true
        }
        child :: cast[ptr[CpuBudget]](at)
        if cast[u32](child.time.priority) > priority {
            return false
        }
        at = child.sibling_next
    }
}

/**
 * Put a budget first on its parent's list of children; its parent field isn't set here.
 *
 * @param parent The parent, whose list changes under kernel.cpu_budgets_lock, held by the caller.
 * @param child The child, on no parent's list.
 */
link_child :: fn(parent: ptr[mut CpuBudget], child: ptr[mut CpuBudget]) {
    child.sibling_previous = 0
    child.sibling_next = parent.first_child
    if parent.first_child != 0 {
        cast[ptr[mut CpuBudget]](parent.first_child).sibling_previous = cast[u64](child)
    }
    parent.first_child = cast[u64](child)
}

/**
 * Take a budget off its parent's list of children; its parent field and shares aren't changed here.
 *
 * @param parent The parent, whose list changes under kernel.cpu_budgets_lock, held by the caller.
 * @param child The child, on parent's list; its sibling links are cleared.
 */
unlink_child :: fn(parent: ptr[mut CpuBudget], child: ptr[mut CpuBudget]) {
    if child.sibling_previous != 0 {
        cast[ptr[mut CpuBudget]](child.sibling_previous).sibling_next = child.sibling_next
    }
    else {
        parent.first_child = child.sibling_next
    }
    if child.sibling_next != 0 {
        cast[ptr[mut CpuBudget]](child.sibling_next).sibling_previous = child.sibling_previous
    }
    child.sibling_next = 0
    child.sibling_previous = 0
}

/**
 * Put a process on a budget, off the one it was on; its threads stay where they are (set_process_budget moves them).
 *
 * @param process The process, on a budget or none.
 * @param budget The budget it goes first on the list of; kernel.cpu_budgets_lock is held by the caller.
 */
move_process :: fn(process: ptr[mut Process], budget: ptr[mut CpuBudget]) {
    if process.cpu_budget != 0 {
        unlink_process(cast[ptr[mut CpuBudget]](process.cpu_budget), process)
    }
    process.cpu_budget = cast[u64](budget)
    process.cpu_budget_previous = 0
    process.cpu_budget_next = budget.first_process
    if budget.first_process != 0 {
        cast[ptr[mut Process]](budget.first_process).cpu_budget_previous = cast[u64](process)
    }
    budget.first_process = cast[u64](process)
}

/**
 * Take a process off a budget's list, leaving it on no budget.
 *
 * @param budget The budget it's on, whose list changes under kernel.cpu_budgets_lock, held by the caller.
 * @param process The process, whose cpu_budget and links are cleared.
 */
unlink_process :: fn(budget: ptr[mut CpuBudget], process: ptr[mut Process]) {
    if process.cpu_budget_previous != 0 {
        cast[ptr[mut Process]](process.cpu_budget_previous).cpu_budget_next = process.cpu_budget_next
    }
    else {
        budget.first_process = process.cpu_budget_next
    }
    if process.cpu_budget_next != 0 {
        cast[ptr[mut Process]](process.cpu_budget_next).cpu_budget_previous = process.cpu_budget_previous
    }
    process.cpu_budget = 0
    process.cpu_budget_next = 0
    process.cpu_budget_previous = 0
}

/**
 * Put a thread on a budget, off the one it was on: it runs on the budget's time from its next tick.
 *
 * @param thread The thread, on a budget or none; its budget, the CpuTime the scheduler charges, is set atomically.
 * @param budget The budget it goes first on the list of; kernel.cpu_budgets_lock is held by the caller.
 */
move_thread :: fn(thread: ptr[mut Thread], budget: ptr[mut CpuBudget]) {
    if thread.budget_object != 0 {
        unlink_thread_budget(cast[ptr[mut CpuBudget]](thread.budget_object), thread)
    }
    thread.budget_object = cast[u64](budget)
    thread.budget_previous = 0
    thread.budget_next = budget.first_thread
    if budget.first_thread != 0 {
        cast[ptr[mut Thread]](budget.first_thread).budget_previous = cast[u64](thread)
    }
    budget.first_thread = cast[u64](thread)
    intrinsics.atomic_store_u64_release(&thread.budget, cast[u64](&budget.time))
}

/**
 * Take a thread off a budget's list. Its budget, the CpuTime the scheduler charges, is left as it was.
 *
 * @param budget The budget it's on, whose list changes under kernel.cpu_budgets_lock, held by the caller.
 * @param thread The thread, whose budget_object and links are cleared.
 */
unlink_thread_budget :: fn(budget: ptr[mut CpuBudget], thread: ptr[mut Thread]) {
    if thread.budget_previous != 0 {
        cast[ptr[mut Thread]](thread.budget_previous).budget_next = thread.budget_next
    }
    else {
        budget.first_thread = thread.budget_next
    }
    if thread.budget_next != 0 {
        cast[ptr[mut Thread]](thread.budget_next).budget_previous = thread.budget_previous
    }
    thread.budget_object = 0
    thread.budget_next = 0
    thread.budget_previous = 0
}

/**
 * Put a new process on its creator's CPU budget. Takes kernel.cpu_budgets_lock.
 *
 * @param kernel The kernel, whose cpu_budgets_lock is taken, and whose root_cpu_budget is used for a kernel-made
 *     process. Called as the process is made, with no lock held.
 * @param process The new process, on no budget.
 * @param creator The Process that made it, as an address, or 0 for the kernel, which puts it on the root budget. If
 *     the creator is on none, or there's no root budget yet, it's left on none.
 */
join_creators_budget :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process], creator: u64) {
    lock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    defer unlock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    from :: if creator != 0 { cast[ptr[Process]](creator).cpu_budget } else { kernel.root_cpu_budget }
    if from != 0 {
        move_process(process, cast[ptr[mut CpuBudget]](from))
    }
}

/**
 * Put a process, and every thread of its on the budget it was on, on another budget.
 *
 * Takes kernel.cpu_budgets_lock. Its threads on other budgets, lent them, stay there.
 *
 * @param kernel The kernel, whose cpu_budgets_lock is taken at LockRank CpuBudgets. Runs in a system call, with no
 *     lock held.
 * @param process The process to move, a live object; if it's being destroyed, nothing changes.
 * @param budget The budget it goes on.
 * @return True if it moved; false, with nothing changed, if the budget or the process is being destroyed.
 */
set_process_budget :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process], budget: ptr[mut CpuBudget]) -> bool {
    lock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    defer unlock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    if budget.header.dying != 0 || process.header.dying != 0 {
        return false
    }
    old :: process.cpu_budget
    move_process(process, budget)
    if old != 0 {
        moving := cast[ptr[mut CpuBudget]](old).first_thread
        loop {
            if moving == 0 {
                break
            }
            thread :: cast[ptr[mut Thread]](moving)
            moving = thread.budget_next
            if thread.header.owner == cast[u64](process) {
                move_thread(thread, budget)
            }
        }
    }
    return true
}

/**
 * Move the calling thread onto a budget, its process's or one lent it (decisions/0130), charging what it has run so far
 * to the one it was on.
 *
 * Takes kernel.cpu_budgets_lock, then the old budget's CpuTime lock to charge it.
 *
 * @param kernel The kernel, whose cpu_budgets_lock is taken at LockRank CpuBudgets. Runs on the thread's CPU, in a
 *     system call, with no lock held.
 * @param thread The thread running on this CPU.
 * @param budget The CpuBudget, as an address; 0, or the one it's on, changes nothing.
 * @return True if it's on the budget, or nothing was asked; false, with nothing changed, if the budget is being
 *     destroyed.
 */
set_thread_budget :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], budget: u64) -> bool {
    lock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    defer unlock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    if budget == 0 || thread.budget_object == budget {
        return true
    }
    target :: cast[ptr[mut CpuBudget]](budget)
    if target.header.dying != 0 {
        return false
    }
    account(per_cpu(), thread, arch.counter())
    move_thread(thread, target)
    return true
}

/**
 * Put a new thread on its process's CPU budget, if the process is on one. Takes kernel.cpu_budgets_lock.
 *
 * @param kernel The kernel, whose cpu_budgets_lock is taken at LockRank CpuBudgets. Called as the thread is made,
 *     before it can run, with no lock held.
 * @param thread The new thread, on no budget.
 * @param process The process that owns it.
 */
join_process_budget :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], process: ptr[Process]) {
    lock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    defer unlock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    if process.cpu_budget != 0 {
        move_thread(thread, cast[ptr[mut CpuBudget]](process.cpu_budget))
    }
}

/**
 * Take a thread that's being destroyed off its budget's list. Takes kernel.cpu_budgets_lock.
 *
 * The CpuTime the scheduler charges stays as it was, so a tick still charging it reaches memory that stays until every
 * CPU has passed a quiescent point (objects.hsc).
 *
 * @param kernel The kernel, whose cpu_budgets_lock is taken at LockRank CpuBudgets. Called from destroy_thread,
 *     with no lock held.
 * @param thread The thread, on a budget or none.
 */
leave_thread_budget :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) {
    lock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    defer unlock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    if thread.budget_object != 0 {
        unlink_thread_budget(cast[ptr[mut CpuBudget]](thread.budget_object), thread)
    }
}

/**
 * Take a process that's being destroyed off its budget's list. Takes kernel.cpu_budgets_lock.
 *
 * @param kernel The kernel, whose cpu_budgets_lock is taken at LockRank CpuBudgets. Called from destroy_process,
 *     with no lock held.
 * @param process The process, on a budget or none.
 */
leave_process_budget :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process]) {
    lock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    defer unlock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    if process.cpu_budget != 0 {
        unlink_process(cast[ptr[mut CpuBudget]](process.cpu_budget), process)
    }
}

/**
 * Destroy a budget: what ran on it runs on its parent, its children become its parent's, and its share goes back.
 *
 * A budget's destroy, called from destroy_object. A tick may still be charging it; its memory stays until every CPU
 * has passed a quiescent point (objects.hsc). Takes kernel.cpu_budgets_lock. The root, with no parent, is left as it
 * is.
 *
 * @param kernel The kernel, whose cpu_budgets_lock is taken at LockRank CpuBudgets. Called from destroy_object,
 *     with no lock of that rank or above held.
 * @param budget The budget, already dying, its generation advanced.
 */
destroy_cpu_budget :: fn(kernel: ptr[mut Kernel], budget: ptr[mut CpuBudget]) {
    lock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    defer unlock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    if budget.parent == 0 {
        return void
    }
    parent :: cast[ptr[mut CpuBudget]](budget.parent)
    loop {
        if budget.first_thread == 0 {
            break
        }
        move_thread(cast[ptr[mut Thread]](budget.first_thread), parent)
    }
    loop {
        if budget.first_process == 0 {
            break
        }
        move_process(cast[ptr[mut Process]](budget.first_process), parent)
    }
    loop {
        if budget.first_child == 0 {
            break
        }
        child :: cast[ptr[mut CpuBudget]](budget.first_child)
        unlink_child(budget, child)
        child.parent = cast[u64](parent)
        link_child(parent, child)
    }
    // Its children's shares, which were inside its own, are its parent's now, and the rest of its share comes back
    unlink_child(parent, budget)
    parent.children_share = parent.children_share - budget.share + budget.children_share
    budget.parent = 0
}

/**
 * Let go of what a budget holds as its memory is freed (release_object): nothing, since destroying it moved
 * everything off it, and one never handed out holds nothing.
 *
 * @param kernel The kernel, unused: there's nothing to give back to it.
 * @param budget The budget: destroyed and past its grace period, or never handed out, as when making it failed.
 */
release_cpu_budget :: fn(kernel: ptr[mut Kernel], budget: ptr[mut CpuBudget]) {
}

/**
 * Fill in what cpu_budget_info gives, in its order: priority, period_ns, time_ns, share, children's share, and CPUs.
 *
 * Takes kernel.cpu_budgets_lock, so the words are of one moment.
 *
 * @param kernel The kernel, whose cpu_budgets_lock is taken at LockRank CpuBudgets. Runs in a system call, with no
 *     lock held.
 * @param budget The budget, looked up from the caller's handle, so its memory stays good for the call; read under
 *     the lock.
 * @param words Where they go, in the kernel's memory; past its count, they're left out.
 */
cpu_budget_words :: fn(kernel: ptr[mut Kernel], budget: ptr[CpuBudget], words: mut u64[]) {
    lock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    defer unlock_at(&kernel.cpu_budgets_lock, .CpuBudgets)
    values :: u64.[cast[u64](budget.time.priority), budget.period_ns, budget.time_ns, budget.share, budget.children_share, budget.time.cpus]
    for value, i in values {
        if i < words.count {
            words[i] = value
        }
    }
}
