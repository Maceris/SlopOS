package kernel

import intrinsics from "base"
import runtime from "base"
import fiber from "std"
import concurrency from "std"
import testing from "std"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * test_pool: two fiber pools sharing five CPUs between them (Hemera's std/fiber), with the boot CPU
 * running neither, as a thread without a fiber runtime: CPUs 1 and 2 run the first pool, CPUs 3 to
 * 5 the second. The boot CPU spawns fibers into both and waits for the CPUs to leave the pools.
 *
 * Each fiber takes POOL_TURNS turns, yielding after each, and records which CPUs it ran on. A
 * fiber has to stay on its own pool's CPUs, every CPU has to run some of its pool's fibers, and
 * fibers have to move between CPUs. One fiber of the first pool spawns another from inside it, and
 * one of the second spawns CHILD_FIBERS, more than its CPU's own queue holds, so half of that queue
 * moves to the pool's shared queue and the other CPUs take from it.
 *
 * Every turn also adds one to a counter behind a std/concurrency Mutex that both pools share,
 * yielding while holding it, so fibers park waiting for it and are woken by fibers of either pool.
 *
 * The CPUs start their pools together, and a fiber that's taken its turns goes on yielding, without
 * counting them, until its pool has run on every one of its CPUs and moved a fiber, or COVER_SECONDS
 * pass: a CPU whose host stalls it would otherwise find its pool's work done before it joined.
 */
/** The CPUs the test needs online: the boot CPU, and five to run the pools. */
POOL_CPUS : u32 : 6
/** The turns each fiber counts, yielding after each. */
POOL_TURNS :: 16
/** The fibers the boot CPU spawns into the first pool, the one that spawns a child among them. */
FIRST_POOL_FIBERS :: 24
/** The fibers the boot CPU spawns into the second pool, the one that spawns CHILD_FIBERS among them. */
SECOND_POOL_FIBERS :: 36
/** The fibers one fiber of the second pool spawns, more than its CPU's own queue holds. */
CHILD_FIBERS :: 300
// The CPUs each pool runs on, a bit per CPU index: 1 and 2, and 3 to 5
/** The CPUs the first pool runs on, a bit per CPU index: 1 and 2. */
FIRST_POOL_CPUS : u64 : 0b000110
/** The CPUs the second pool runs on, a bit per CPU index: 3 to 5. */
SECOND_POOL_CPUS : u64 : 0b111000
/** How long, in seconds, the boot CPU waits for the pools to finish, and the other CPUs wait for the pools. */
POOL_TEST_TIMEOUT_SECONDS :: 10
/** How long, in seconds, fibers go on yielding for every CPU of their pool to have run some, and one to have moved. */
COVER_SECONDS :: 4

/** What one pool's fibers record, each field changed atomically, as fibers on several CPUs add to it. */
PoolCounts :: struct {
    /** Turns counted, POOL_TURNS for each fiber when all went well; the turns after, waiting for cover, aren't. */
    turns : u64,
    /** The CPUs the pool's fibers ran on, a bit per CPU index. */
    cpus : u64,
    /** Turns on a different CPU than the fiber's previous turn. */
    moves : u64,
    /** Turns on a CPU outside the pool, 0 when all went well. */
    strays : u64,
}

/** The test's state, shared by the boot CPU, the pools' CPUs and every fiber, which reach it through context. */
PoolTest :: struct {
    /** The first pool, run by FIRST_POOL_CPUS. */
    first : ptr[mut fiber.FiberPool],
    /** The second pool, run by SECOND_POOL_CPUS. */
    second : ptr[mut fiber.FiberPool],
    /** What the first pool's fibers recorded. */
    first_counts : PoolCounts,
    /** What the second pool's fibers recorded. */
    second_counts : PoolCounts,
    /** Fibers spawned by fibers that ran: CHILD_FIBERS + 1 when all went well. */
    children : u64,
    /** CPUs that have come to their pool, counted atomically; they start running it once all POOL_CPUS - 1 have. */
    carriers_ready : u64,
    /** CPUs that have left their pool, counted atomically; the boot CPU checks the counts once all have. */
    carriers_done : u64,
    /** Held by each turn while it reads counter, yields, and writes it, so fibers park waiting for it. */
    counter_lock : concurrency.Mutex,
    /** Turns that added one with counter_lock held: every fiber's POOL_TURNS when all went well. */
    counter : u64,
}

/**
 * Run test_pool from the boot CPU, reporting it to the kernel's log.
 *
 * @param kernel Not used: the test finds the kernel through per_cpu.
 */
test_pool :: fn(kernel: ptr[mut Kernel]) {
    _ = run_tests("test_pool", testing.Test.[.{name = "two_pools_share_five_cpus", run = two_pools_share_five_cpus}])
}

/**
 * Check two fiber pools sharing five CPUs, from the boot CPU: make the pools, spawn their fibers, hand them to the
 * other CPUs, and check what the fibers recorded.
 *
 * Its state comes from the frame allocator and isn't freed; the pools are destroyed only when every check passes. The
 * kernel needs POOL_CPUS online; the test's state is published in its pool_test for the other CPUs' join_pool_test,
 * and its heap is the fibers' allocator.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if there are too few CPUs, no memory for the test's state, or the other CPUs didn't
 *     all leave their pools in time.
 */
two_pools_share_five_cpus #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    kernel :: per_cpu().kernel
    testing.require_within(t, cast[i64](kernel.online_cpus), cast[i64](POOL_CPUS), cast[i64](0xffffffff),
        "the test is booted with the boot CPU and five more to run the pools")?
    made :: allocate_object[PoolTest](&kernel.frames)
    test :: testing.require_ok(t, made, "a boot's free frames hold the test's state")?
    spawned := false
    push_context pooled (allocator = heap_allocator(kernel), user_data = cast[rawptr](test)) {
        test.first = fiber.create_fiber_pool()
        test.second = fiber.create_fiber_pool()
        spawned = spawn_into(test.first, parent_worker, 1)
        spawned = spawned && spawn_into(test.first, first_worker, FIRST_POOL_FIBERS - 1)
        spawned = spawned && spawn_into(test.second, spawner_worker, 1)
        spawned = spawned && spawn_into(test.second, second_worker, SECOND_POOL_FIBERS - 1)
        fiber.close_pool(test.first)
        fiber.close_pool(test.second)
    }
    testing.expect(t, spawned, "the kernel heap has room for every fiber the boot CPU spawns")
    // A thread without a fiber runtime: yielding does nothing
    runtime.fiber_yield()
    // The other CPUs are waiting for this
    intrinsics.atomic_store_u64_release(&kernel.pool_test, cast[u64](test))
    deadline :: arch.counter() + kernel.counter_frequency * POOL_TEST_TIMEOUT_SECONDS
    loop {
        arch.spin_hint()
    }
    while intrinsics.atomic_load_u64_acquire(&test.carriers_done) < cast[u64](POOL_CPUS - 1) && arch.counter() < deadline
    done :: intrinsics.atomic_load_u64_acquire(&test.carriers_done)
    testing.require_eq(t, done, cast[u64](POOL_CPUS - 1),
        "every pool CPU runs its pool until its fibers are done, well within POOL_TEST_TIMEOUT_SECONDS, and leaves it")?
    expect_pool_counts(t, &test.first_counts, FIRST_POOL_FIBERS, FIRST_POOL_CPUS)
    expect_pool_counts(t, &test.second_counts, SECOND_POOL_FIBERS, SECOND_POOL_CPUS)
    testing.expect_eq(t, test.counter, cast[u64]((FIRST_POOL_FIBERS + SECOND_POOL_FIBERS) * POOL_TURNS),
        "every turn adds one with the mutex held across a yield, so none is lost however fibers park and wake")
    testing.expect_eq(t, test.children, cast[u64](CHILD_FIBERS + 1),
        "every fiber spawned from a fiber runs, the ones past its CPU's queue taken from the shared queue")
    if testing.passed(t) {
        fiber.destroy_fiber_pool(test.first)
        fiber.destroy_fiber_pool(test.second)
    }
    runtime.log_info("test_pool: fibers moved between CPUs % times in the first pool and % in the second",
        test.first_counts.moves, test.second_counts.moves)
    return .Ok
}

/**
 * Spawn fibers into a pool, stopping at the first that can't be.
 *
 * @param pool The pool, which keeps the fibers.
 * @param function What each fiber runs.
 * @param count How many fibers to spawn.
 * @return True if all were spawned, false if one ran out of memory, with those before it spawned.
 */
spawn_into :: fn(pool #escaping : ptr[mut fiber.FiberPool], function: runtime.ThreadFunction, count: usize) -> bool {
    for i in 0..<count {
        _, error :: fiber.spawn(pool, function)
        if error != null {
            return false
        }
    }
    return true
}

/**
 * Check what a pool's fibers recorded: every turn taken, all on its own CPUs, every one of those, with a move.
 *
 * @param t The test's state, which each failure is recorded in.
 * @param counts What its fibers recorded.
 * @param fibers How many fibers the boot CPU spawned into it.
 * @param cpus The CPUs it should have run on, every one of them, a bit per CPU index.
 * @param location Where the test asked, which a failure is recorded at, telling the pools apart: the caller's own.
 */
expect_pool_counts :: fn(t: ptr[mut testing.T], counts: ptr[PoolCounts], fibers: u64, cpus: u64, location := #caller_location) {
    testing.expect_eq(t, counts.turns, fibers * POOL_TURNS, "each of the pool's fibers takes its POOL_TURNS turns", location)
    testing.expect_eq(t, counts.strays, 0, "a pool's fibers run only on its own CPUs, never another pool's", location)
    testing.expect_eq(t, counts.cpus, cpus, "every CPU of the pool runs some of its fibers, as they wait for each to have", location)
    testing.expect_ne(t, counts.moves, 0, "a pool's CPUs take fibers from each other, so some fiber moves", location)
}

/**
 * Join the pool test from a CPU after the boot CPU, once it's online: wait for the boot CPU's pools, and run this
 * CPU's until it's done.
 *
 * Gives up, logging an error, if the pools don't come within POOL_TEST_TIMEOUT_SECONDS. Masks interrupts and leaves
 * them masked, for the CPU's idle, next, to unmask.
 *
 * @param kernel The kernel, whose pool_test it waits for.
 * @param index This CPU's index; a CPU in neither pool returns at once.
 */
join_pool_test :: fn(kernel: ptr[Kernel], index: u32) {
    deadline :: arch.counter() + kernel.counter_frequency * POOL_TEST_TIMEOUT_SECONDS
    loop {
        arch.spin_hint()
    }
    while intrinsics.atomic_load_u64_acquire(&kernel.pool_test) == 0 && arch.counter() < deadline
    address :: intrinsics.atomic_load_u64_acquire(&kernel.pool_test)
    if address == 0 {
        runtime.log_error("test_pool: CPU % got no pool", index)
        return void
    }
    test :: cast[ptr[mut PoolTest]](address)
    bit :: cast[u64](1) << cast[u64](index)
    if bit & (FIRST_POOL_CPUS | SECOND_POOL_CPUS) == 0 {
        return void
    }
    pool :: if bit & FIRST_POOL_CPUS != 0 { test.first } else { test.second }
    /*
     * While a fiber resumes, its stack holds frames above the stack pointer, which an interrupt would
     * overwrite. They stay masked after: an interrupt never returns into kernel code, so unmasking here would
     * let a timer tick that came meanwhile take the CPU to idle before it counted itself; the CPU's idle,
     * next, unmasks them.
     */
    arch.mask_interrupts()
    // Every pool's CPUs start together
    intrinsics.interlocked_increment_u64(&test.carriers_ready)
    loop {
        arch.spin_hint()
    }
    while intrinsics.atomic_load_u64_acquire(&test.carriers_ready) < cast[u64](POOL_CPUS - 1) && arch.counter() < deadline
    fiber.run_carrier(pool)
    intrinsics.interlocked_increment_u64(&test.carriers_done)
}

/**
 * Take a first-pool fiber's turns.
 *
 * @param data Unused; the test's state is the context's user_data.
 */
first_worker : runtime.ThreadFunction : fn(data #escaping : any) {
    test :: cast[ptr[mut PoolTest]](context.user_data)
    take_turns(&test.first_counts, FIRST_POOL_CPUS)
}

/**
 * Take a second-pool fiber's turns.
 *
 * @param data Unused; the test's state is the context's user_data.
 */
second_worker : runtime.ThreadFunction : fn(data #escaping : any) {
    test :: cast[ptr[mut PoolTest]](context.user_data)
    take_turns(&test.second_counts, SECOND_POOL_CPUS)
}

/**
 * Spawn a child into the first pool, onto this CPU's own queue, then take a first-pool fiber's turns.
 *
 * @param data Unused; the test's state is the context's user_data.
 */
parent_worker : runtime.ThreadFunction : fn(data #escaping : any) {
    test :: cast[ptr[mut PoolTest]](context.user_data)
    fiber.spawn(test.first, child_worker)
    take_turns(&test.first_counts, FIRST_POOL_CPUS)
}

/**
 * Spawn CHILD_FIBERS children into the second pool, onto this CPU's own queue, which overflows into the pool's shared
 * queue, then take a second-pool fiber's turns.
 *
 * @param data Unused; the test's state is the context's user_data.
 */
spawner_worker : runtime.ThreadFunction : fn(data #escaping : any) {
    test :: cast[ptr[mut PoolTest]](context.user_data)
    for i in 0..<CHILD_FIBERS {
        fiber.spawn(test.second, child_worker)
    }
    take_turns(&test.second_counts, SECOND_POOL_CPUS)
}

/**
 * Count a spawned child that ran, in the test's children.
 *
 * @param data Unused; the test's state is the context's user_data.
 */
child_worker : runtime.ThreadFunction : fn(data #escaping : any) {
    test :: cast[ptr[mut PoolTest]](context.user_data)
    intrinsics.interlocked_increment_u64(&test.children)
}

/**
 * Add one to the test's counter: read, yield, write, all with the lock held, so others wanting it park.
 *
 * @param test The test's state, whose counter goes up by one under its counter_lock, held across a yield.
 */
add_one :: fn(test: ptr[mut PoolTest]) {
    concurrency.mutex_lock(&test.counter_lock)
    defer concurrency.mutex_unlock(&test.counter_lock)
    before :: test.counter
    runtime.fiber_yield()
    test.counter = before + 1
}

/**
 * Take POOL_TURNS turns, recording each, then go on yielding until every CPU of the pool has run some and one fiber
 * has moved, or COVER_SECONDS pass.
 *
 * @param counts The pool's counts, added to atomically.
 * @param cpus The pool's CPUs, a bit per CPU index; a turn elsewhere counts as a stray.
 */
take_turns :: fn(counts: ptr[mut PoolCounts], cpus: u64) {
    previous := per_cpu().index
    for turn in 0..<POOL_TURNS {
        here :: per_cpu().index
        bit :: cast[u64](1) << cast[u64](here)
        if bit & cpus == 0 {
            intrinsics.interlocked_increment_u64(&counts.strays)
        }
        if here != previous {
            intrinsics.interlocked_increment_u64(&counts.moves)
        }
        intrinsics.interlocked_or_u64(&counts.cpus, bit)
        intrinsics.interlocked_increment_u64(&counts.turns)
        previous = here
        add_one(cast[ptr[mut PoolTest]](context.user_data))
        runtime.fiber_yield()
    }
    // Then until every CPU of the pool has run some of its fibers, and one has moved
    kernel :: per_cpu().kernel
    deadline :: arch.counter() + kernel.counter_frequency * COVER_SECONDS
    loop {
        if (intrinsics.atomic_load_u64_acquire(&counts.cpus) == cpus && intrinsics.atomic_load_u64_acquire(&counts.moves) > 0)
            || arch.counter() >= deadline {
            break
        }
        here :: per_cpu().index
        bit :: cast[u64](1) << cast[u64](here)
        if bit & cpus == 0 {
            intrinsics.interlocked_increment_u64(&counts.strays)
        }
        if here != previous {
            intrinsics.interlocked_increment_u64(&counts.moves)
        }
        intrinsics.interlocked_or_u64(&counts.cpus, bit)
        previous = here
        runtime.fiber_yield()
    }
}
