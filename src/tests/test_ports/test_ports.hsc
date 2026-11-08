/**
 * test_ports (decisions/0069, from the kernel's test of 0052): a port, used by the program's first thread, A,
 * and a helper, B:
 * - A binds a wake key, twice (KeyInUse the second time), wakes a key with no binding (NoSuchKey), wakes
 *   its key twice and takes one packet with both bits;
 * - a timer 20 ms off blocks A until it fires; a wait with nothing to take and a 15 ms deadline gives
 *   nothing, no sooner; packets for memory A can't write are refused (BadBuffer);
 * - a wait with no room for a packet is refused at once (BufferTooSmall, decisions/0184), leaving a queued
 *   packet for the next wait;
 * - B, started by A, wakes it through the port, likely from another CPU, and waits for A to have the
 *   packet, since any waiter on the port may take it; A unbinds the key, after which waking it fails;
 * - B waits on the port, and A closes it: B wakes with ObjectGone;
 * - what the port, its bindings and B charged their budget comes back.
 */
package test_ports

import compiler from "base"
import intrinsics from "base"
import runtime from "base"
import os from "std"
import testing from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import test_kit from "../../test_kit"

/** The test's name, which starts each line it logs. */
NAME :: "test_ports"
/** The slot, a u64 by index, of what A and B share, holding the port's handle. */
SHARED_PORT :: 0
/** The slot B sets once it's about to wait on the port. */
SHARED_B_WAITING :: 1
/** The slot A sets once it has B's packet. */
SHARED_A_WOKEN :: 2
/** The slot B puts its wait's result in, as test_kit.tag_of gives it. */
SHARED_B_GOT :: 3
/** The slot B sets once its wait has returned. */
SHARED_B_DONE :: 4
/** The wake binding's key. */
PORT_KEY : u64 : 7
/** The timer's key. */
TIMER_KEY : u64 : 9
/** How far off the timer is set, in nanoseconds: 20 ms. */
TIMER_NANOSECONDS : u64 : 20_000_000
/** How far off a wait's deadline is set, in nanoseconds: 15 ms. */
DEADLINE_NANOSECONDS : u64 : 15_000_000
/** The deadline of a wait with no room for a packet, which is refused well before it: 50 ms. */
EMPTY_DEADLINE_NANOSECONDS : u64 : 50_000_000

/** What main was given that the tests use. */
Given :: struct {
    /** The debug log. */
    log : slop_os.DebugLog,
}

/**
 * Wake A through the port, wait for A to have the packet, then wait on the port until it's closed: B.
 *
 * @param shared What A and B share, by the SHARED_* slots.
 */
helper #calling_convention(.c) #no_context :: fn(shared: ptr[mut u64[8]]) #never_returns {
    port :: test_kit.handle_at[slop_os.Port](intrinsics.volatile_load_u64(&shared^[SHARED_PORT]))
    _ = slop_os.port_wake(port, PORT_KEY, 0x100)
    loop {
        intrinsics.spin_hint()
    }
    while intrinsics.volatile_load_u64(&shared^[SHARED_A_WOKEN]) == 0
    intrinsics.volatile_store_u64(&shared^[SHARED_B_WAITING], 1)
    packets : slop_os.Packet[4]
    gone :: slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
    intrinsics.volatile_store_u64(&shared^[SHARED_B_GOT], test_kit.tag_of(gone))
    intrinsics.volatile_store_u64(&shared^[SHARED_B_DONE], 1)
    slop_os.thread_exit()
}

/**
 * Check that a key's wake binding is made once, that only a bound key can be woken, and that two wakes of a key
 * before a wait come out as one User packet with both bits; then that closing the port gives back what it charged.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the budget or the port couldn't be made.
 */
wakes_of_a_bound_key_merge_into_one_packet #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    block :: slop_os.startup_block()
    budget :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 1 << 20), "a budget for the port")?
    port :: testing.require_ok(t, slop_os.port_create(budget), "a port is made under the budget")?
    bound :: slop_os.port_bind_wake(port, PORT_KEY)
    testing.expect_ok(t, bound, "a key with no binding yet can be bound for wakes")
    bound_again :: slop_os.port_bind_wake(port, PORT_KEY)
    testing.expect_error(t, bound_again, slop_os.PortError.KeyInUse, "a key has one binding at a time")
    unbound :: slop_os.port_wake(port, 99, 1)
    testing.expect_error(t, unbound, slop_os.PortError.NoSuchKey, "only a key bound for wakes can be woken")
    _ = slop_os.port_wake(port, PORT_KEY, 1)
    _ = slop_os.port_wake(port, PORT_KEY, 2)
    packets : slop_os.Packet[4]
    woken :: slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
    testing.expect_ok(t, woken, "a wait with a packet ready takes it")
    testing.expect_eq(t, woken or_else 0, 1, "two wakes of one key before a wait are merged into one packet")
    testing.expect_eq(t, packets[0].key, PORT_KEY, "the packet carries the key it was raised for")
    testing.expect_eq(t, packets[0].kind, slop_os.PacketKind.User, "a wake raises a User packet")
    testing.expect_eq(t, packets[0].data[0], 3, "the merged packet's bits are both wakes' bits, or'd")
    closed :: slop_os.handle_close(cast[slop_os.Handle](port))
    testing.expect_ok(t, closed, "the port closes")
    testing.expect(t, test_kit.wait_for_budget(budget, 0, 1_000_000_000), "the budget is back to nothing once the port and its binding are gone")
    return .Ok
}

/**
 * Check that a timer blocks a wait until it fires, not sooner, and gives a Timer packet; that a wait with nothing to
 * take ends at its deadline with nothing, not sooner; and that a wait for packets into memory the process can't write
 * is refused.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the budget or the port couldn't be made.
 */
timers_and_deadlines_end_waits_no_sooner #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    block :: slop_os.startup_block()
    budget :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 1 << 20), "a budget for the port")?
    port :: testing.require_ok(t, slop_os.port_create(budget), "a port is made under the budget")?
    packets : slop_os.Packet[4]
    // A timer
    set :: test_kit.clock_now()
    _ = slop_os.port_set_timer(port, TIMER_KEY, set + TIMER_NANOSECONDS)
    timed :: slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
    after_timer :: test_kit.clock_now()
    testing.expect_eq(t, timed or_else 0, 1, "the timer's firing gives the wait one packet")
    testing.expect_eq(t, packets[0].kind, slop_os.PacketKind.Timer, "a timer's firing raises a Timer packet")
    testing.expect_ge(t, after_timer - set, TIMER_NANOSECONDS, "a timer fires no sooner than its deadline")
    // A deadline, with nothing to take
    started :: test_kit.clock_now()
    nothing :: slop_os.port_wait(port, packets, started + DEADLINE_NANOSECONDS)
    after_deadline :: test_kit.clock_now()
    testing.expect_eq(t, nothing or_else 1, 0, "a wait with nothing to take ends at its deadline with no packets")
    testing.expect_ge(t, after_deadline - started, DEADLINE_NANOSECONDS, "a wait ends at its deadline, no sooner")
    // Memory it can't write
    unwritable :: slop_os.port_wait(port, test_kit.packets_at(0x10, 4), slop_os.NO_DEADLINE)
    testing.expect_error(t, unwritable, slop_os.PortError.BadBuffer, "packets can't be put in memory the process can't write")
    closed :: slop_os.handle_close(cast[slop_os.Handle](port))
    testing.expect_ok(t, closed, "the port closes")
    testing.expect(t, test_kit.wait_for_budget(budget, 0, 1_000_000_000), "the budget is back to nothing once the port and its timer are gone")
    return .Ok
}

/**
 * Check that a wait with no room for a packet is refused at once (decisions/0184), with nothing queued and with a
 * packet queued, which it leaves for the next wait.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the budget or the port couldn't be made.
 */
an_empty_wait_is_refused_at_once #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    block :: slop_os.startup_block()
    budget :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 1 << 20), "a budget for the port")?
    port :: testing.require_ok(t, slop_os.port_create(budget), "a port is made under the budget")?
    packets : slop_os.Packet[1]
    // Nothing queued: refused, not a pause until the deadline
    started :: test_kit.clock_now()
    nothing :: slop_os.port_wait(port, packets[0..<0], started + EMPTY_DEADLINE_NANOSECONDS)
    after :: test_kit.clock_now()
    testing.expect_error(t, nothing, slop_os.PortError.BufferTooSmall, "a wait with no room for a packet is refused")
    testing.expect_lt(t, after - started, EMPTY_DEADLINE_NANOSECONDS, "it's refused at once, not at its deadline")
    // A packet queued: refused, and the packet stays for the next wait
    _ = slop_os.port_bind_wake(port, PORT_KEY)
    _ = slop_os.port_wake(port, PORT_KEY, 1)
    queued :: slop_os.port_wait(port, packets[0..<0], slop_os.NO_DEADLINE)
    testing.expect_error(t, queued, slop_os.PortError.BufferTooSmall, "a wait with no room is refused with a packet queued too")
    taken :: slop_os.port_wait(port, packets, 0)
    testing.expect_eq(t, taken or_else 0, 1, "the packet stays queued for a wait with room for it")
    testing.expect_eq(t, packets[0].key, PORT_KEY, "it's the woken key's packet")
    closed :: slop_os.handle_close(cast[slop_os.Handle](port))
    testing.expect_ok(t, closed, "the port closes")
    testing.expect(t, test_kit.wait_for_budget(budget, 0, 1_000_000_000), "the budget is back to nothing once the port and its binding are gone")
    return .Ok
}

/**
 * Check that another thread, B, wakes A through the port, likely from another CPU; that once A unbinds the key, waking
 * it is refused; that closing the port under B's wait wakes B with ObjectGone; and that what the port, its bindings
 * and B charged their budget comes back.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the shared slots, the budget, the port or B couldn't be made.
 */
another_thread_wakes_it_and_closing_wakes_waiters #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    block :: slop_os.startup_block()
    pages, error :: runtime.new_array(u64[8], 1)
    if error != null || pages.count == 0 {
        testing.fail(t, "the slots A and B share are allocated")
        return .Error(.Failed)
    }
    shared :: &pages[0]
    budget :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 1 << 20), "a budget for the port and B")?
    port :: testing.require_ok(t, slop_os.port_create(budget), "a port is made under the budget")?
    intrinsics.volatile_store_u64(&shared^[SHARED_PORT], cast[u64](cast[u32](port)))
    bound :: slop_os.port_bind_wake(port, PORT_KEY)
    testing.expect_ok(t, bound, "the key B wakes is bound")
    packets : slop_os.Packet[4]
    // B wakes it
    thread :: testing.require_ok(t, test_kit.start_thread(budget, cast[u64](helper), cast[u64](shared)), "B starts")?
    from_b :: slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
    from_b_bits :: if (from_b or_else 0) == 1 { packets[0].data[0] } else { cast[u64](0) }
    testing.expect_eq(t, from_b_bits, 0x100, "B's wake reaches A's wait, with B's bits")
    intrinsics.volatile_store_u64(&shared^[SHARED_A_WOKEN], 1)
    unbound :: slop_os.port_unbind(port, PORT_KEY)
    testing.expect_ok(t, unbound, "a bound key unbinds")
    woken_unbound :: slop_os.port_wake(port, PORT_KEY, 1)
    testing.expect_error(t, woken_unbound, slop_os.PortError.NoSuchKey, "an unbound key can't be woken")
    // Once B waits, and a while more, closing the port wakes it
    _ = test_kit.wait_for(&shared^[SHARED_B_WAITING], 1_000_000_000)
    while_b :: test_kit.clock_now()
    _ = slop_os.port_wait(port, packets, while_b + DEADLINE_NANOSECONDS)
    closed :: slop_os.handle_close(cast[slop_os.Handle](port))
    testing.expect_ok(t, closed, "the port closes while B waits on it")
    _ = test_kit.wait_for(&shared^[SHARED_B_DONE], 1_000_000_000)
    testing.expect_eq(t, intrinsics.volatile_load_u64(&shared^[SHARED_B_GOT]), test_kit.tag(slop_os.PortError.ObjectGone), "closing a port wakes its waiters with ObjectGone")
    testing.expect_eq(t, intrinsics.volatile_load_u64(&shared^[SHARED_B_DONE]), 1, "B's wait returned once the port was closed")
    // B, which has ended, and the port, closed: their charges come back
    _ = slop_os.handle_close(cast[slop_os.Handle](thread))
    _ = test_kit.wait_for_budget(budget, 0, 1_000_000_000)
    testing.expect_eq(t, test_kit.used(budget), 0, "the budget is back to nothing once B has ended and the port is closed")
    return .Ok
}

/**
 * Run the tests, reporting to the debug log.
 *
 * @param log The debug log, writable, where each test is reported.
 * @param platform Not used.
 * @param test_device Not used.
 * @param firmware Not used.
 * @param manager Not used.
 * @param program Not used.
 * @param peer Not used.
 * @param cpu_budget Not used.
 * @return How many tests failed: 0 when every one passed.
 */
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    given :: Given.{log = log}
    return test_kit.run(log, NAME, #insert testing.tests_of(compiler.load_package(".")), given)
}

