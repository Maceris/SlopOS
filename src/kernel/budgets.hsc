package kernel

import runtime from "base"
import concurrency from "std"

/*
 * CPU time (roadmap M4, knowledge/design/scheduling.md §2, decisions/0011, 0037): a priority, and
 * how much CPU time per period its threads get at that priority, which a CPU budget (cpu_budgets.hsc) holds. Once it's spent they run in the
 * background band (Demote, the only kind so far) until it's replenished.
 *
 * Replenishment follows the sporadic-server rule: time used from some moment comes back one period
 * after that moment, so a budget can't save time up across periods and burst past its share. Times are
 * in counter ticks.
 */
//SPEC: Sprunt, Sha and Lehoczky, "Aperiodic Task Scheduling for Hard-Real-Time Systems" (1989), the sporadic server;
//      as seL4 MCS keeps it (Lyons et al., "Scheduling-context capabilities", EuroSys 2018)
//TODO(claude): Throttle

// Refills a budget keeps track of; past that, a new one is merged into the last.
MAX_REFILLS :: 8

Refill :: struct {
    // When it comes back, and how much.
    at : u64,
    amount : u64,
}

CpuTime :: struct {
    lock : concurrency.SpinLock,
    priority : u8,
    period : u64,
    budget : u64,
    // Time left now.
    available : u64,
    // Oldest first, in a ring.
    refills : Refill[MAX_REFILLS],
    first : usize,
    count : usize,
    // Every CPU's whole time, like the root CPU budget's (cpu_budgets.hsc): what can't be overspent isn't counted
    unlimited : bool,
}

/*
 * A budget of budget_ns every period_ns at priority, full to start with. The counter's frequency is
 * known by then.
 */
make_budget :: fn(kernel: ptr[Kernel], priority: u8, period_ns: u64, budget_ns: u64) -> CpuTime {
    result : CpuTime
    result.priority = priority
    result.period = ticks_of(kernel, period_ns)
    result.budget = ticks_of(kernel, budget_ns)
    result.available = result.budget
    return result
}

ticks_of :: fn(kernel: ptr[Kernel], nanoseconds: u64) -> u64 {
    frequency :: kernel.counter_frequency
    return nanoseconds / runtime.NANOSECONDS_PER_SECOND * frequency + nanoseconds % runtime.NANOSECONDS_PER_SECOND * frequency / runtime.NANOSECONDS_PER_SECOND
}

// Whether there's time left at now.
has_time :: fn(budget: ptr[mut CpuTime], now: u64) -> bool {
    if budget.unlimited {
        return true
    }
    concurrency.lock(&budget.lock)
    defer concurrency.unlock(&budget.lock)
    replenish(budget, now)
    return budget.available > 0
}

/*
 * Charge used ticks, from start on, to the budget: they come back one period after start. Running past
 * what's left, by at most a tick, is accepted (knowledge/design/scheduling.md §2).
 */
charge :: fn(budget: ptr[mut CpuTime], start: u64, used: u64, now: u64) {
    if budget.unlimited {
        return void
    }
    concurrency.lock(&budget.lock)
    defer concurrency.unlock(&budget.lock)
    replenish(budget, now)
    budget.available = if budget.available > used { budget.available - used } else { cast[u64](0) }
    count :: budget.count
    runtime.assert(count <= MAX_REFILLS, "a budget keeps up to MAX_REFILLS refills")
    if count == MAX_REFILLS {
        // The latest one comes back with this too, later
        last :: (budget.first + count - 1) % MAX_REFILLS
        budget.refills[last].amount += used
        budget.refills[last].at = start + budget.period
        return void
    }
    budget.refills[(budget.first + count) % MAX_REFILLS] = Refill.{at = start + budget.period, amount = used}
    budget.count = count + 1
}

// Takes the lock as held.
replenish :: fn(budget: ptr[mut CpuTime], now: u64) {
    loop {
        refill :: budget.refills[budget.first % MAX_REFILLS]
        if refill.at > now {
            break
        }
        budget.available = min_u64(budget.available + refill.amount, budget.budget)
        budget.first = (budget.first + 1) % MAX_REFILLS
        budget.count -= 1
    }
    while budget.count > 0
}

min_u64 :: fn(a, b: u64) -> u64 {
    return if a < b { a } else { b }
}
