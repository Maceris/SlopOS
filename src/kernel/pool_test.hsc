package kernel

import intrinsics from "base"
import runtime from "base"
import fiber from "std"
import concurrency from "std"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
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
 */
POOL_CPUS : u32 : 6
POOL_TURNS :: 16
FIRST_POOL_FIBERS :: 24
SECOND_POOL_FIBERS :: 36
CHILD_FIBERS :: 300
// The CPUs each pool runs on, a bit per CPU index: 1 and 2, and 3 to 5
FIRST_POOL_CPUS : u64 : 0b000110
SECOND_POOL_CPUS : u64 : 0b111000
// How long the boot CPU waits for the pools to finish, and the other CPUs wait for the pools
POOL_TEST_TIMEOUT_SECONDS :: 10

// What one pool's fibers record.
PoolCounts :: struct {
    turns : u64,
    // A bit per CPU index
    cpus : u64,
    // Turns on a different CPU than the fiber's previous turn
    moves : u64,
    // Turns on a CPU outside the pool
    strays : u64,
}

PoolTest :: struct {
    first : ptr[mut fiber.FiberPool],
    second : ptr[mut fiber.FiberPool],
    first_counts : PoolCounts,
    second_counts : PoolCounts,
    // Fibers spawned by fibers that ran
    children : u64,
    // CPUs that have left their pool
    carriers_done : u64,
    // Every turn adds one to counter with counter_lock held, yielding in between, so fibers park on it
    counter_lock : concurrency.Mutex,
    counter : u64,
}

test_pool :: fn(kernel #escaping : ptr[mut Kernel]) {
    if kernel.online_cpus < POOL_CPUS {
        runtime.log_error("test_pool: needs % CPUs online, not %", POOL_CPUS, kernel.online_cpus)
        return void
    }
    test : ptr[mut PoolTest]
    match allocate_object[PoolTest](&kernel.frames) {
        case Ok(made) => test = made
        case Error(error) => {
            runtime.log_error("test_pool: no memory for the test's state")
            return void
        }
    }
    push_context pooled (allocator = heap_allocator(kernel), user_data = cast[rawptr](test)) {
        test.first = fiber.create_fiber_pool()
        test.second = fiber.create_fiber_pool()
        spawned := spawn_into(test.first, parent_worker, 1)
        spawned = spawned && spawn_into(test.first, first_worker, FIRST_POOL_FIBERS - 1)
        spawned = spawned && spawn_into(test.second, spawner_worker, 1)
        spawned = spawned && spawn_into(test.second, second_worker, SECOND_POOL_FIBERS - 1)
        fiber.close_pool(test.first)
        fiber.close_pool(test.second)
        if !spawned {
            runtime.log_error("test_pool: no memory for the fibers")
        }
    }
    // A thread without a fiber runtime: yielding does nothing
    runtime.fiber_yield()
    // The other CPUs are waiting for this
    intrinsics.atomic_store_u64_release(&kernel.pool_test, cast[u64](test))
    deadline :: arch.counter() + kernel.counter_frequency * POOL_TEST_TIMEOUT_SECONDS
    loop {
        arch.spin_hint()
    }
    while intrinsics.atomic_load_u64_acquire(&test.carriers_done) < cast[u64](POOL_CPUS - 1) && arch.counter() < deadline
    if intrinsics.atomic_load_u64_acquire(&test.carriers_done) < cast[u64](POOL_CPUS - 1) {
        runtime.log_error("test_pool: only % of % CPUs left their pools", test.carriers_done, POOL_CPUS - 1)
        return void
    }
    first_ok :: pool_counts_ok("first", &test.first_counts, FIRST_POOL_FIBERS, FIRST_POOL_CPUS)
    second_ok :: pool_counts_ok("second", &test.second_counts, SECOND_POOL_FIBERS, SECOND_POOL_CPUS)
    if !first_ok || !second_ok {
        return void
    }
    if test.counter != (FIRST_POOL_FIBERS + SECOND_POOL_FIBERS) * POOL_TURNS {
        runtime.log_error("test_pool: the counter behind the mutex is %, not %", test.counter,
            (FIRST_POOL_FIBERS + SECOND_POOL_FIBERS) * POOL_TURNS)
        return void
    }
    if test.children != CHILD_FIBERS + 1 {
        runtime.log_error("test_pool: % fibers spawned from fibers ran, not %", test.children, CHILD_FIBERS + 1)
        return void
    }
    fiber.destroy_fiber_pool(test.first)
    fiber.destroy_fiber_pool(test.second)
    runtime.log_info("test_pool: fibers moved between CPUs % times in the first pool and % in the second",
        test.first_counts.moves, test.second_counts.moves)
    runtime.log_info("test_pool: two pools shared five CPUs, each fiber staying on its own pool's")
}

spawn_into :: fn(pool #escaping : ptr[mut fiber.FiberPool], function: runtime.ThreadFunction, count: usize) -> bool {
    for i in 0..<count {
        _, error :: fiber.spawn(pool, function)
        if error != null {
            return false
        }
    }
    return true
}

pool_counts_ok :: fn(name: string, counts: ptr[PoolCounts], fibers: u64, cpus: u64) -> bool {
    if counts.turns != fibers * POOL_TURNS || counts.strays != 0 || counts.cpus != cpus || counts.moves == 0 {
        runtime.log_error("test_pool: the % pool's fibers took % turns (not %), % on other pools' CPUs, on CPUs %{x} (not %{x}), with % moves",
            name, counts.turns, fibers * POOL_TURNS, counts.strays, counts.cpus, cpus, counts.moves)
        return false
    }
    return true
}

/*
 * On each CPU after the boot CPU, once online: wait for the boot CPU's pools, run the one for this
 * CPU until it's done, then go idle.
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
    // While a fiber resumes, its stack holds frames above the stack pointer, which an interrupt would overwrite
    arch.mask_interrupts()
    fiber.run_carrier(pool)
    arch.unmask_interrupts()
    intrinsics.interlocked_increment_u64(&test.carriers_done)
}

first_worker : runtime.ThreadFunction : fn(data #escaping : any) {
    test :: cast[ptr[mut PoolTest]](context.user_data)
    take_turns(&test.first_counts, FIRST_POOL_CPUS)
}

second_worker : runtime.ThreadFunction : fn(data #escaping : any) {
    test :: cast[ptr[mut PoolTest]](context.user_data)
    take_turns(&test.second_counts, SECOND_POOL_CPUS)
}

// A fiber of the first pool that spawns another into it first, onto its own CPU's queue.
parent_worker : runtime.ThreadFunction : fn(data #escaping : any) {
    test :: cast[ptr[mut PoolTest]](context.user_data)
    fiber.spawn(test.first, child_worker)
    take_turns(&test.first_counts, FIRST_POOL_CPUS)
}

// A fiber of the second pool that spawns CHILD_FIBERS into it, onto its own CPU's queue, which overflows.
spawner_worker : runtime.ThreadFunction : fn(data #escaping : any) {
    test :: cast[ptr[mut PoolTest]](context.user_data)
    for i in 0..<CHILD_FIBERS {
        fiber.spawn(test.second, child_worker)
    }
    take_turns(&test.second_counts, SECOND_POOL_CPUS)
}

child_worker : runtime.ThreadFunction : fn(data #escaping : any) {
    test :: cast[ptr[mut PoolTest]](context.user_data)
    intrinsics.interlocked_increment_u64(&test.children)
}

// One more on the counter: read, yield, write, all with the lock held, so others wanting it park.
add_one :: fn(test: ptr[mut PoolTest]) {
    concurrency.mutex_lock(&test.counter_lock)
    defer concurrency.mutex_unlock(&test.counter_lock)
    before :: test.counter
    runtime.fiber_yield()
    test.counter = before + 1
}

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
}
