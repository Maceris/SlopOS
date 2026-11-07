package kernel

import intrinsics from "base"
import testing from "std"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * test_ownership_race: an object moved from one process's owned list to another's, as take_one moves an owning handle
 * taken out of a batch (disown, then adopt), while another CPU destroys it, round after round. Once both are done,
 * neither process owns anything: the object is on no list, and the lists aren't torn. disown read the owner without a
 * lock, and adopt set it before taking the new list's lock and took a dying object, so a destroy racing the move
 * could unlink it from the old list by the new one's links, or leave it, freed, on the new list (decisions/0051). The
 * other CPU moves the object when a reschedule IPI takes it from idle (move_for_ownership_race_test), taking only the
 * lists' locks; the boot CPU destroys it, waiting a little longer each round first, so the two meet at every point of
 * the move.
 */
/** How many objects are moved and destroyed. */
OWNERSHIP_RACE_ROUNDS :: 4000
/** How long the boot CPU waits for the moving CPU to start, and to finish a round, in milliseconds. */
OWNERSHIP_RACE_TIMEOUT_MS :: 1000
/** The most spins the boot CPU waits before it destroys a round's object: each round waits a different number below it. */
OWNERSHIP_RACE_SPREAD :: 64

/** test_ownership_race's state, which the moving CPU reaches through kernel.ownership_race_test while it runs. */
OwnershipRaceTest :: struct {
    /** The round's object, by address, set before its round is. */
    object : u64,
    /** The process it's moved to, by address. */
    to : u64,
    /** The round being run, from 1; the moving CPU moves the object once it sees a new one. */
    round : u32,
    /** The last round the moving CPU has moved the object of. */
    moved : u32,
    /** Moves refused, as the object was dying by then, counted by the moving CPU. */
    refused : u32,
    /** 1 while there are rounds to run; the moving CPU stops when it's 0. */
    running : u32,
    /** 1 once a CPU has claimed the moving: the first to answer the IPI; the rest go back to idle. */
    started : u32,
    /** 1 once the moving CPU has stopped. */
    stopped : u32,
}

/**
 * Run test_ownership_race on the boot CPU at boot, reporting it to the kernel's log.
 *
 * @param kernel Not used: the test finds the kernel through per_cpu.
 */
test_ownership_race :: fn(kernel: ptr[mut Kernel]) {
    _ = run_tests("test_ownership_race", testing.Test.[.{name = "an_object_moved_while_it_is_destroyed_is_on_no_list",
        run = an_object_moved_while_it_is_destroyed_is_on_no_list}])
}

/**
 * Check that an object moved between owners while it's destroyed ends on neither owner's list, and leaves both lists
 * whole: OWNERSHIP_RACE_ROUNDS ports, each made the first process's, then moved to the second's by another CPU as
 * this one destroys it.
 *
 * Runs on the boot CPU, with 2 CPUs or more online. Its state is never freed; the two processes are destroyed at the
 * end.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if there's only one CPU, no memory for the state, the processes or a port, or the
 *     moving CPU doesn't start or keep up in time.
 */
an_object_moved_while_it_is_destroyed_is_on_no_list #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    kernel :: per_cpu().kernel
    testing.require_ge(t, kernel.online_cpus - 1, 1, "the test is booted with another CPU to move the objects")?
    made :: allocate_object[OwnershipRaceTest](&kernel.frames)
    test :: testing.require_ok(t, made, "a boot's free frames hold the test's state")?
    first_made :: create_process(kernel, 0, 0)
    first :: testing.require_ok(t, first_made, "the process pool has a slot at boot")?
    second_made :: create_process(kernel, 0, 0)
    second :: testing.require_ok(t, second_made, "the process pool has a second slot at boot")?
    test.to = cast[u64](second)
    intrinsics.atomic_store_u32(&test.running, 1)
    intrinsics.atomic_store_u64_release(&kernel.ownership_race_test, cast[u64](test))
    cpus :: kernel.cpus
    for cpu, index in cpus {
        if index > 0 && index < cast[usize](kernel.online_cpus) {
            arch.send_ipi(cpu.hardware_id, .Reschedule)
        }
    }
    started :: wait_for_count(kernel, &test.started, 1)
    torn := 0
    kept := 0
    made_all := true
    kept_up := true
    if started {
        for round in cast[u32](1)..<OWNERSHIP_RACE_ROUNDS + 1 {
            object :: match create_port(kernel, cast[u64](first), 0) {
                case Ok(made_port) => cast[u64](made_port)
                case Error(_) => cast[u64](0)
            }
            if object == 0 {
                made_all = false
                break
            }
            intrinsics.atomic_store_u64_release(&test.object, object)
            intrinsics.atomic_store_u32_release(&test.round, round)
            // Later each round, so the move and the destroy meet at every point of each other
            for spin in 0..<(round % OWNERSHIP_RACE_SPREAD) {
                arch.spin_hint()
            }
            _ = destroy_object(kernel, object)
            if !wait_for_count(kernel, &test.moved, round) {
                kept_up = false
                break
            }
            // Destroyed, so on neither list, and the lists whole
            if !list_empty(&first.owned) || !list_empty(&second.owned) {
                torn += 1
                // Emptied again, for the next round: what's left is the destroyed port, which neither should hold
                clear_list(&first.owned)
                clear_list(&second.owned)
            }
            kept += 1
        }
    }
    intrinsics.atomic_store_u32_release(&test.running, 0)
    stopped :: wait_for_count(kernel, &test.stopped, 1)
    intrinsics.atomic_store_u64_release(&kernel.ownership_race_test, 0)
    testing.require(t, started, "another CPU starts moving when asked")?
    testing.require(t, stopped, "the moving CPU stops once the boot CPU is done")?
    testing.require(t, made_all, "the port pool has a slot for each round")?
    testing.require(t, kept_up, "the moving CPU moves each round's object in time")?
    _ = destroy_object(kernel, cast[u64](first))
    _ = destroy_object(kernel, cast[u64](second))
    whole :: testing.expect_eq(t, torn, 0, "an object moved while it's destroyed is on neither owner's list, and both lists are whole")
    ran :: testing.expect_eq(t, kept, cast[int](OWNERSHIP_RACE_ROUNDS), "every round ran")
    return testing.outcome_of(whole && ran)
}

/**
 * Tell whether an owned list is empty, under its lock.
 *
 * @param list The list.
 * @return True if nothing's on it.
 */
list_empty :: fn(list: ptr[mut OwnedList]) -> bool {
    lock_at(&list.lock, .ObjectList)
    defer unlock_at(&list.lock, .ObjectList)
    return list.first == 0
}

/**
 * Empty an owned list without destroying what's on it, after a round left it torn, so the next round starts from
 * empty.
 *
 * @param list The list.
 */
clear_list :: fn(list: ptr[mut OwnedList]) {
    lock_at(&list.lock, .ObjectList)
    defer unlock_at(&list.lock, .ObjectList)
    list.first = 0
}

/**
 * Wait for a count to reach a number, up to OWNERSHIP_RACE_TIMEOUT_MS.
 *
 * @param kernel The kernel, whose counter frequency times the wait.
 * @param count The count, read atomically.
 * @param wanted The number it has to reach.
 * @return True if it reached wanted in time.
 */
wait_for_count :: fn(kernel: ptr[Kernel], count: ptr[u32], wanted: u32) -> bool {
    deadline :: arch.counter() + kernel.counter_frequency / 1000 * OWNERSHIP_RACE_TIMEOUT_MS
    loop {
        arch.spin_hint()
    }
    while intrinsics.atomic_load_u32_acquire(count) < wanted && arch.counter() < deadline
    return intrinsics.atomic_load_u32_acquire(count) >= wanted
}

/**
 * Move each round's object of test_ownership_race to its new owner as soon as its round is set, as take_one moves an
 * owning handle (disown, then adopt), until the boot CPU is done; called at a Reschedule IPI.
 *
 * Does nothing if kernel.ownership_race_test is 0, or another CPU is already moving. Spins with interrupts disabled,
 * answering TLB shootdowns as it goes, since a shootdown waits for every CPU.
 */
move_for_ownership_race_test :: fn() {
    cpu :: per_cpu()
    address :: intrinsics.atomic_load_u64_acquire(&cpu.kernel.ownership_race_test)
    if address == 0 {
        return void
    }
    test :: cast[ptr[mut OwnershipRaceTest]](address)
    _, first :: intrinsics.interlocked_compare_exchange_u32(&test.started, 1, 0)
    if !first {
        return void
    }
    done := cast[u32](0)
    loop {
        round :: intrinsics.atomic_load_u32_acquire(&test.round)
        if round != done {
            object :: intrinsics.atomic_load_u64_acquire(&test.object)
            disown(object)
            match adopt(test.to, object) {
                case Ok => {}
                case Error(_) => _ = intrinsics.interlocked_increment_u32_release(&test.refused)
            }
            done = round
            intrinsics.atomic_store_u32_release(&test.moved, round)
        }
        flush_for_shootdown(cpu)
    }
    while intrinsics.atomic_load_u32_acquire(&test.running) != 0
    intrinsics.atomic_store_u32_release(&test.stopped, 1)
}
