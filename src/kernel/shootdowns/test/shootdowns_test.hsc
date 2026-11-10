/**
 * The TLB shootdown handshake's tests (tools/unit_tests.py, decisions/0175, 0187): under the model checker, two CPUs
 * run the kernel's shootdown steps (shootdown.hsc) with a number for a batch, each flushing whatever it's requested to
 * while it waits to start, and after its own, as an idle CPU takes the flush IPI. The build package's tests target
 * builds them model-checked.
 */
package shootdowns_test

import runtime from "base"
import intrinsics from "base"
import testing from "std"
import shootdowns from ".."

/** How many CPUs there are. */
CPUS :: 2

/** The CPUs' shared state, as the kernel's is, and what the test sees of it. */
Machine :: struct {
    handshake : shootdowns.Handshake,
    /** The running shootdown's batch: a number, written by its CPU after it starts, as the kernel copies its batch. */
    batch : u64,
    /** Each CPU's request flag, as PerCpu.flush_requested. */
    requested : u32[CPUS],
    /** The last batch each CPU flushed, written by that CPU as it flushes. */
    flushed : u64[CPUS],
    /** How many CPUs have finished their shootdowns, after which none is requested to flush. */
    finished : u32,
    /** How many shootdowns each CPU runs: 1, or 0 for one that only flushes. */
    shootdowns : u32[CPUS],
    /** The test's state, by its address, where a shootdown going on before every CPU flushed its batch fails it. */
    t : u64,
}

/**
 * Give the test's state from its address.
 *
 * @param address The address, as a number, which isn't a pointer into anyone's stack for the escape checks: the test's
 *     state outlives check_model, and so every thread.
 * @return The test's state.
 */
test_at :: fn(address: u64) -> ptr[mut testing.T] {
    return cast[ptr[mut testing.T]](cast[rawptr](cast[uintptr](address)))
}

/**
 * Give the test's state's address, as a number.
 *
 * @param t The test's state.
 * @return Its address.
 */
address_of_test :: fn(t: ptr[mut testing.T]) -> u64 {
    return cast[u64](cast[uintptr](cast[rawptr](t)))
}

machine_of :: fn(data: any) -> ptr[mut Machine] {
    return cast[ptr[ptr[mut Machine]]](data.data)^
}

/**
 * Flush for the running shootdown, if this CPU is requested to, as the kernel's flush_for_shootdown does.
 *
 * @param machine The machine.
 * @param cpu The calling CPU's index.
 */
flush_if_requested :: fn(machine: ptr[mut Machine], cpu: usize) {
    if cpu >= CPUS || !shootdowns.is_requested(&machine.requested[cpu]) {
        return void
    }
    batch :: intrinsics.atomic_load_u64_no_fence(&machine.batch)
    intrinsics.atomic_store_u64_no_fence(&machine.flushed[cpu], batch)
    shootdowns.flushed(&machine.handshake, &machine.requested[cpu])
}

/**
 * Run a shootdown of a batch from a CPU, as the kernel's shootdown does, then check every other CPU flushed it.
 *
 * @param machine The machine.
 * @param cpu The calling CPU's index.
 * @param batch The batch's number, not 0.
 */
shoot_down :: fn(machine: ptr[mut Machine], cpu: usize, batch: u64) {
    if cpu >= CPUS {
        return void
    }
    loop {
        flush_if_requested(machine, cpu)
        intrinsics.spin_hint()
    }
    while !shootdowns.try_start(&machine.handshake)
    intrinsics.atomic_store_u64_no_fence(&machine.batch, batch)
    shootdowns.expect_flushes(&machine.handshake, CPUS - 1)
    for i in cast[usize](0)..<CPUS {
        if i != cpu {
            shootdowns.request(&machine.requested[i])
        }
    }
    intrinsics.atomic_store_u64_no_fence(&machine.flushed[cpu], batch)
    loop {
        intrinsics.spin_hint()
    }
    while !shootdowns.all_flushed(&machine.handshake)
    for i in cast[usize](0)..<CPUS {
        testing.expect_eq(test_at(machine.t), intrinsics.atomic_load_u64_no_fence(&machine.flushed[i]), batch,
            "a shootdown goes on once every CPU flushed its batch")
    }
    shootdowns.finish(&machine.handshake)
}

/**
 * Be a CPU: run its shootdown, if it has one, then flush as requested until every shootdown has finished.
 *
 * @param machine The machine.
 * @param cpu The CPU's index.
 */
run_cpu :: fn(machine: ptr[mut Machine], cpu: usize) {
    if cpu < CPUS && machine.shootdowns[cpu] != 0 {
        shoot_down(machine, cpu, cast[u64](cpu) + 1)
        intrinsics.interlocked_increment_u32(&machine.finished)
    }
    wanted :: machine.shootdowns[0] + machine.shootdowns[1]
    loop {
        flush_if_requested(machine, cpu)
        intrinsics.spin_hint()
    }
    while intrinsics.atomic_load_u32(&machine.finished) != wanted
}

first_cpu : runtime.ThreadFunction : fn(data #escaping : any) {
    run_cpu(machine_of(data), 0)
}

second_cpu : runtime.ThreadFunction : fn(data #escaping : any) {
    run_cpu(machine_of(data), 1)
}

machine_body : runtime.ThreadFunction : fn(data #escaping : any) {
    machine :: machine_of(data)
    shootdowns_wanted :: machine.shootdowns
    t :: machine.t
    machine^ = Machine.{shootdowns = shootdowns_wanted, t = t}
    first :: testing.spawn(first_cpu, data) or_return void
    second :: testing.spawn(second_cpu, data) or_return void
    testing.join(first)
    testing.join(second)
}

a_shootdown_waits_for_every_flush #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    machine :: runtime.new(Machine)
    defer runtime.free(machine)
    machine.shootdowns[0] = 1
    machine.t = address_of_test(t)
    outcome :: testing.check_model(t, machine_body, machine)
    testing.expect(t, outcome is_ok, "in every schedule, the shootdown goes on once every CPU flushed its batch")
    return .Ok
}

two_shootdowns_at_once_take_turns #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    machine :: runtime.new(Machine)
    defer runtime.free(machine)
    machine.shootdowns[0] = 1
    machine.shootdowns[1] = 1
    machine.t = address_of_test(t)
    outcome :: testing.check_model(t, machine_body, machine)
    testing.expect(t, outcome is_ok, "in every schedule, each shootdown goes on once every CPU flushed its batch, neither waiting on the other forever")
    return .Ok
}
