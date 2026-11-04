package kernel

import runtime from "base"
import concurrency from "std"

/*
 * CPU time (roadmap M4, knowledge/design/scheduling.md §2, decisions/0011, 0037): a priority, and
 * how much CPU time per period its threads get at that priority, which a CPU budget (cpu_budgets.hsc)
 * holds. Once it's spent they run in the background band (Demote, the only kind so far) until it's
 * replenished.
 *
 * Replenishment follows the sporadic-server rule: time used from some moment comes back one period
 * after that moment, so a budget can't save time up across periods and burst past its share. Times are
 * in counter ticks.
 */
/*
 * SPEC: Sprunt, Sha and Lehoczky, "Aperiodic Task Scheduling for Hard-Real-Time Systems" (1989), the sporadic server;
 *     as seL4 MCS keeps it (Lyons et al., "Scheduling-context capabilities", EuroSys 2018)
 * TODO(claude): Throttle
 */

/** Refills a budget keeps track of; past that, a new one is merged into the last. */
MAX_REFILLS :: 8

/** Time used that comes back to a budget: how much, and when. */
Refill :: struct {
    /** When it comes back, in counter ticks: one period after the moment it was used from. */
    at : u64,
    /** How much comes back, in counter ticks, less any debt it pays first. */
    amount : u64,
}

/** A priority, and how much CPU time per period its threads get at it, with what's been used and comes back. */
CpuTime :: struct {
    /** Guards available, debt and the refills, taken at LockRank CpuTime. */
    lock : concurrency.SpinLock,
    /** The priority its threads run at while it has time. */
    priority : u8,
    /** The replenishment period, in counter ticks. */
    period : u64,
    /** The time its threads get each period, in counter ticks; available never goes above it. */
    budget : u64,
    /** Time left now, in counter ticks; 0 when spent, and its threads are demoted. */
    available : u64,
    /** Ticks used past what was left, which refills pay before they give time again. */
    debt : u64,
    /** The refills to come, a ring of count from first, oldest first. */
    refills : Refill[MAX_REFILLS],
    /** The index in refills of the oldest refill. */
    first : usize,
    /** How many refills there are, 0 to MAX_REFILLS. */
    count : usize,
    /** Every CPU's whole time, like the root CPU budget's (cpu_budgets.hsc): what can't be overspent isn't counted. */
    unlimited : bool,
    /** The CPUs its threads may run on, a bit per CPU's index; a CPU past 63 is always one (decisions/0099). */
    cpus : u64,
}

/**
 * Make a budget of some time every period at a priority, full to start with.
 *
 * The counter's frequency is known by then. The budget may run on every CPU, and isn't unlimited.
 *
 * @param kernel The kernel, for its counter_frequency, which must be set.
 * @param priority The priority its threads run at while it has time.
 * @param period_ns The replenishment period, in nanoseconds.
 * @param budget_ns The time its threads get each period, in nanoseconds; more than period_ns isn't checked.
 * @return The budget, with all of budget_ns available, in counter ticks. Its lock is used in place, so it's put where
 *     it lives before it's used.
 */
make_budget :: fn(kernel: ptr[Kernel], priority: u8, period_ns: u64, budget_ns: u64) -> CpuTime {
    result : CpuTime
    result.priority = priority
    result.period = ticks_of(kernel, period_ns)
    result.budget = ticks_of(kernel, budget_ns)
    result.available = result.budget
    result.cpus = ~cast[u64](0)
    return result
}

/**
 * Convert nanoseconds to counter ticks, whole seconds apart from the rest, so the multiplication doesn't overflow.
 *
 * @param kernel The kernel, for its counter_frequency, in ticks per second.
 * @param nanoseconds The time, in nanoseconds.
 * @return The time in counter ticks, rounded down.
 */
ticks_of :: fn(kernel: ptr[Kernel], nanoseconds: u64) -> u64 {
    frequency :: kernel.counter_frequency
    return nanoseconds / runtime.NANOSECONDS_PER_SECOND * frequency + nanoseconds % runtime.NANOSECONDS_PER_SECOND * frequency / runtime.NANOSECONDS_PER_SECOND
}

/**
 * Tell whether a budget has time left, replenishing it first with what's come back by now.
 *
 * Takes the budget's lock, at LockRank CpuTime, unless it's unlimited.
 *
 * @param budget The CPU budget; unless it's unlimited, its lock is taken, at LockRank CpuTime, so the caller mustn't
 *     hold it, and the refills due by now are applied to it.
 * @param now The counter's value now, in ticks.
 * @return True if it's unlimited or has time available; false while it's spent, or paying a debt.
 */
has_time :: fn(budget: ptr[mut CpuTime], now: u64) -> bool {
    if budget.unlimited {
        return true
    }
    lock_at(&budget.lock, .CpuTime)
    defer unlock_at(&budget.lock, .CpuTime)
    replenish(budget, now)
    return budget.available > 0
}

/**
 * Charge time used to a budget, which comes back one period after it started.
 *
 * Running past what's left, by at most a tick, is accepted (knowledge/design/scheduling.md §2): what ran past is owed
 * as debt, paid from the refills before they give time again, so time left, refills and debt always add up to the
 * budget. With MAX_REFILLS waiting already, the time joins the latest refill, which then comes back with it, later.
 * Takes the budget's lock, at LockRank CpuTime; an unlimited budget isn't charged.
 *
 * @param budget The CPU budget the time is charged to; unless it's unlimited, its lock is taken, at LockRank CpuTime,
 *     so the caller mustn't hold it.
 * @param start The counter's value, in ticks, when the time used began.
 * @param used The time used, in counter ticks.
 * @param now The counter's value now, in ticks, for replenishing first.
 */
charge :: fn(budget: ptr[mut CpuTime], start: u64, used: u64, now: u64) {
    if budget.unlimited {
        return void
    }
    lock_at(&budget.lock, .CpuTime)
    defer unlock_at(&budget.lock, .CpuTime)
    replenish(budget, now)
    // What ran past what was left is owed, and paid from the refills before they give time again: every tick used
    // comes back, so a budget's time left, its refills and its debt always add up to its budget
    if used > budget.available {
        budget.debt += used - budget.available
        budget.available = 0
    }
    else {
        budget.available -= used
    }
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

/**
 * Give a budget back every refill that's come by now, paying its debt from them first.
 *
 * The caller holds the budget's lock. available never goes above the budget.
 *
 * @param budget The budget, its lock held.
 * @param now The counter's value now, in ticks; refills at or before it come back.
 */
replenish :: fn(budget: ptr[mut CpuTime], now: u64) {
    loop {
        refill :: budget.refills[budget.first % MAX_REFILLS]
        if refill.at > now {
            break
        }
        paid :: min_u64(budget.debt, refill.amount)
        budget.debt -= paid
        budget.available = min_u64(budget.available + refill.amount - paid, budget.budget)
        budget.first = (budget.first + 1) % MAX_REFILLS
        budget.count -= 1
    }
    while budget.count > 0
}

/**
 * Find the smaller of two values.
 *
 * @param a One value, any u64.
 * @param b The other value, any u64.
 * @return The smaller, or either when they're equal.
 */
min_u64 :: fn(a, b: u64) -> u64 {
    return if a < b { a } else { b }
}
