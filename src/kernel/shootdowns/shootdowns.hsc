/*
 * The TLB shootdown's handshake (roadmap M3, decisions/0187): how the CPU running a shootdown and the CPUs it asks to
 * flush agree on who has, without a lock. The kernel's shootdown (shootdown.hsc) is made of these steps, with its batch,
 * IPIs and flushes; a package of its own, so a hosted test checks them under the model checker.
 *
 * One shootdown runs at a time: its CPU starts it, writes its batch, expects a flush of each other CPU, and requests
 * them; it flushes its own TLB, and waits until every other has flushed, then finishes. A CPU asked to flush reads the
 * batch, flushes it, and says it has. Whatever the running CPU wrote before it requested a flush, its batch, is seen
 * by the CPU that takes the request; whatever a CPU did before it said it flushed is seen by the running CPU once all
 * have; and whatever a shootdown did is seen by the next to start.
 */
package shootdowns

import intrinsics from "base"

/** One shootdown at a time, and how many CPUs haven't flushed its batch. */
Handshake :: struct {
    /** 1 while a shootdown runs, 0 otherwise; taken with an atomic compare-exchange, so one runs at a time. */
    running : u32,
    /** How many other CPUs haven't flushed the running shootdown's batch yet; each decrements it as it does. */
    pending : u32,
}

/**
 * Try to start a shootdown.
 *
 * @param handshake The handshake.
 * @return True if none was running, and this CPU's now is: it sees everything the last to finish did. False if
 *     another is running.
 */
try_start :: fn(handshake: ptr[mut Handshake]) -> bool {
    _, started :: intrinsics.interlocked_compare_exchange_u32_acquire(&handshake.running, 1, 0)
    return started
}

/**
 * Say how many flushes the running shootdown waits for, by its CPU, before it requests any.
 *
 * @param handshake The handshake, which this CPU's shootdown runs.
 * @param others How many other CPUs it requests to flush.
 */
expect_flushes :: fn(handshake: ptr[mut Handshake], others: u32) {
    intrinsics.atomic_store_u32_release(&handshake.pending, others)
}

/**
 * Request a CPU's flush, by the running shootdown's CPU, after expect_flushes counted it: what this CPU wrote before,
 * its batch, is seen by the CPU that takes the request.
 *
 * @param requested The other CPU's request flag, 0 when it has none.
 */
request :: fn(requested: ptr[mut u32]) {
    intrinsics.atomic_store_u32_release(requested, 1)
}

/**
 * Say whether a CPU is requested to flush, by that CPU; if it is, it sees what the running shootdown's CPU wrote
 * before it requested, and is to flush, then call flushed.
 *
 * @param requested The calling CPU's request flag.
 * @return True if it's requested to flush.
 */
is_requested :: fn(requested: ptr[u32]) -> bool {
    return intrinsics.atomic_load_u32_acquire(requested) != 0
}

/**
 * Say a requested CPU has flushed, by that CPU: what it did before, its flush, is seen by the shootdown's CPU once
 * all_flushed says every CPU has.
 *
 * @param handshake The handshake whose running shootdown requested it.
 * @param requested The calling CPU's request flag, which is_requested said is set.
 */
flushed :: fn(handshake: ptr[mut Handshake], requested: ptr[mut u32]) {
    intrinsics.atomic_store_u32_no_fence(requested, 0)
    intrinsics.interlocked_decrement_u32_release(&handshake.pending)
}

/**
 * Say whether every CPU requested has flushed, by the running shootdown's CPU.
 *
 * @param handshake The handshake, which this CPU's shootdown runs.
 * @return True if they have, and this CPU sees what each did before it said so.
 */
all_flushed :: fn(handshake: ptr[Handshake]) -> bool {
    return intrinsics.atomic_load_u32_acquire(&handshake.pending) == 0
}

/**
 * Finish the running shootdown, by its CPU, once all_flushed: another may start, and sees what this one did.
 *
 * @param handshake The handshake, which this CPU's shootdown runs.
 */
finish :: fn(handshake: ptr[mut Handshake]) {
    intrinsics.atomic_store_u32_release(&handshake.running, 0)
}
