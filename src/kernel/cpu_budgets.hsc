package kernel

import intrinsics from "base"
import runtime from "base"
import concurrency from "std"

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
 */

// The root budget's period, and the most a budget's priority can be.
ROOT_PERIOD_NS : u64 : 10_000_000
TOP_PRIORITY : u32 : 255
// A share of a whole CPU, in its units.
WHOLE_CPU : u64 : 1_000_000

CpuBudget :: struct #align(16) {
    header : ObjectHeader,
    time : CpuTime,
    // Its parent, 0 for the root; its share, and its children's together, in millionths of a CPU
    parent : u64,
    share : u64,
    children_share : u64,
    // Its period and time as given, in nanoseconds
    period_ns : u64,
    time_ns : u64,
    // What runs on it, linked through their own fields, and its children, linked through theirs
    first_thread : u64,
    first_process : u64,
    first_child : u64,
    sibling_next : u64,
    sibling_previous : u64,
}

// time_ns every period_ns, in millionths of a CPU, or null if it's more than u64 holds.
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

// The root budget: every CPU's whole time, at the top priority, owned by the kernel.
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

CpuBudgetError :: enum {
    OutOfMemory,
    OwnerGone,
    BudgetExceeded,
    // Out of the parent's share or above its priority
    TooMuch,
    InvalidArgument,
}

/*
 * A child of parent, owned by owner and charged to memory_budget: priority, and time_ns every period_ns, out of its
 * parent's share.
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
    concurrency.lock(&kernel.cpu_budgets_lock)
    if parent.header.dying != 0 || priority > cast[u32](parent.time.priority) || parent.children_share + share > parent.share {
        concurrency.unlock(&kernel.cpu_budgets_lock)
        release_object(kernel, object)
        return .Error(.TooMuch)
    }
    budget.period_ns = period_ns
    budget.time_ns = time_ns
    budget.share = share
    budget.time = make_budget(kernel, cast[u8](priority), period_ns, time_ns)
    budget.parent = cast[u64](parent)
    parent.children_share += share
    link_child(parent, budget)
    concurrency.unlock(&kernel.cpu_budgets_lock)
    match adopt(owner, object) {
        case Ok => {}
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return .Error(.OwnerGone)
        }
    }
    return .Ok(budget)
}

// A budget's priority, period and time changed, within its parent's share and priority, and above its children's.
set_cpu_budget :: fn(kernel: ptr[mut Kernel], budget: ptr[mut CpuBudget], priority: u32, period_ns: u64, time_ns: u64) -> Result[void, CpuBudgetError] {
    share :: share_of(period_ns, time_ns) or_return .Error(.InvalidArgument)
    if priority > TOP_PRIORITY || time_ns == 0 {
        return .Error(.InvalidArgument)
    }
    concurrency.lock(&kernel.cpu_budgets_lock)
    defer concurrency.unlock(&kernel.cpu_budgets_lock)
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
    concurrency.lock(&budget.time.lock)
    budget.time.priority = cast[u8](priority)
    budget.time.period = ticks_of(kernel, period_ns)
    budget.time.budget = ticks_of(kernel, time_ns)
    budget.time.available = min_u64(budget.time.available, budget.time.budget)
    concurrency.unlock(&budget.time.lock)
    return .Ok
}

// Whether every child's priority is at most priority, with the tree's lock held.
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

link_child :: fn(parent: ptr[mut CpuBudget], child: ptr[mut CpuBudget]) {
    child.sibling_previous = 0
    child.sibling_next = parent.first_child
    if parent.first_child != 0 {
        cast[ptr[mut CpuBudget]](parent.first_child).sibling_previous = cast[u64](child)
    }
    parent.first_child = cast[u64](child)
}

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

// A process put on budget, with the tree's lock held: off the one it was on, and every thread of its with it.
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

// A thread put on budget, with the tree's lock held. The scheduler sees its new time from its next tick.
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

/*
 * A new process on its creator's budget (owner, a Process, or 0 for the kernel's, which puts it on the root budget).
 */
join_creators_budget :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process], creator: u64) {
    concurrency.lock(&kernel.cpu_budgets_lock)
    defer concurrency.unlock(&kernel.cpu_budgets_lock)
    from :: if creator != 0 { cast[ptr[Process]](creator).cpu_budget } else { kernel.root_cpu_budget }
    if from != 0 {
        move_process(process, cast[ptr[mut CpuBudget]](from))
    }
}

// A process, and every thread of its, put on budget.
set_process_budget :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process], budget: ptr[mut CpuBudget]) -> bool {
    concurrency.lock(&kernel.cpu_budgets_lock)
    defer concurrency.unlock(&kernel.cpu_budgets_lock)
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

// A new thread on its process's budget.
join_process_budget :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], process: ptr[Process]) {
    concurrency.lock(&kernel.cpu_budgets_lock)
    defer concurrency.unlock(&kernel.cpu_budgets_lock)
    if process.cpu_budget != 0 {
        move_thread(thread, cast[ptr[mut CpuBudget]](process.cpu_budget))
    }
}

// A thread or process that's going, off its budget.
leave_thread_budget :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread]) {
    concurrency.lock(&kernel.cpu_budgets_lock)
    defer concurrency.unlock(&kernel.cpu_budgets_lock)
    if thread.budget_object != 0 {
        unlink_thread_budget(cast[ptr[mut CpuBudget]](thread.budget_object), thread)
    }
}

leave_process_budget :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process]) {
    concurrency.lock(&kernel.cpu_budgets_lock)
    defer concurrency.unlock(&kernel.cpu_budgets_lock)
    if process.cpu_budget != 0 {
        unlink_process(cast[ptr[mut CpuBudget]](process.cpu_budget), process)
    }
}

/*
 * A budget destroyed: what ran on it runs on its parent, its children become its parent's, and its share goes back.
 * A tick may still be charging it; its memory stays until every CPU has passed a quiescent point (objects.hsc).
 */
destroy_cpu_budget :: fn(kernel: ptr[mut Kernel], budget: ptr[mut CpuBudget]) {
    concurrency.lock(&kernel.cpu_budgets_lock)
    defer concurrency.unlock(&kernel.cpu_budgets_lock)
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

release_cpu_budget :: fn(kernel: ptr[mut Kernel], budget: ptr[mut CpuBudget]) {
}

// What cpu_budget_info gives, in its words.
cpu_budget_words :: fn(kernel: ptr[mut Kernel], budget: ptr[CpuBudget], words: mut u64[]) {
    concurrency.lock(&kernel.cpu_budgets_lock)
    defer concurrency.unlock(&kernel.cpu_budgets_lock)
    values :: u64.[cast[u64](budget.time.priority), budget.period_ns, budget.time_ns, budget.share, budget.children_share]
    for value, i in values {
        if i < words.count {
            words[i] = value
        }
    }
}
