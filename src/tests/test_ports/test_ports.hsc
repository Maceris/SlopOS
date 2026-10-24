/*
 * test_ports (decisions/0069, from the kernel's test of 0052): a port, used by the program's first thread, A,
 * and a helper, B:
 * - A binds a wake key, twice (KeyInUse the second time), wakes a key with no binding (NoSuchKey), wakes
 *   its key twice and takes one packet with both bits;
 * - a timer 20 ms off blocks A until it fires; a wait with nothing to take and a 15 ms deadline gives
 *   nothing, no sooner; packets for memory A can't write are refused (BadBuffer);
 * - B, started by A, wakes it through the port, likely from another CPU, and waits for A to have the
 *   packet, since any waiter on the port may take it; A unbinds the key, after which waking it fails;
 * - B waits on the port, and A closes it: B wakes with ObjectGone;
 * - what the port, its bindings and B charged their budget comes back.
 */
package test_ports

import intrinsics from "base"
import runtime from "base"
import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import test_kit from "../../test_kit"

NAME :: "test_ports"
// What A and B share, by its slots.
SHARED_PORT :: 0
SHARED_B_WAITING :: 1
SHARED_A_WOKEN :: 2
SHARED_B_GOT :: 3
SHARED_B_DONE :: 4
PORT_KEY : u64 : 7
TIMER_KEY : u64 : 9
TIMER_NANOSECONDS : u64 : 20_000_000
DEADLINE_NANOSECONDS : u64 : 15_000_000

// B: wakes A, waits for A to have it, then waits on the port until it's closed.
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

main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?) -> int {
    block :: slop_os.startup_block()
    pages, error :: runtime.new_array(u64[8], 1)
    if error != null || pages.count == 0 {
        return 100
    }
    shared :: &pages[0]
    budget :: slop_os.memory_budget_create(block.budget, 1 << 20) or_return 101
    results : u64[20]
    packets : slop_os.Packet[4]
    port :: slop_os.port_create(budget) or_return 102
    intrinsics.volatile_store_u64(&shared^[SHARED_PORT], cast[u64](cast[u32](port)))
    results[0] = test_kit.tag_of(slop_os.port_bind_wake(port, PORT_KEY))
    results[1] = test_kit.tag_of(slop_os.port_bind_wake(port, PORT_KEY))
    results[2] = test_kit.tag_of(slop_os.port_wake(port, 99, 1))
    _ = slop_os.port_wake(port, PORT_KEY, 1)
    _ = slop_os.port_wake(port, PORT_KEY, 2)
    woken :: slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
    results[3] = test_kit.tag_of(woken)
    results[4] = cast[u64](woken or_else 0)
    results[5] = packets[0].key
    results[6] = cast[u64](cast[u32](packets[0].kind))
    results[7] = packets[0].data[0]
    // A timer
    set :: test_kit.clock_now()
    _ = slop_os.port_set_timer(port, TIMER_KEY, set + TIMER_NANOSECONDS)
    timed :: slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
    after_timer :: test_kit.clock_now()
    results[8] = cast[u64](timed or_else 0)
    results[9] = cast[u64](cast[u32](packets[0].kind))
    results[10] = if after_timer - set >= TIMER_NANOSECONDS { cast[u64](1) } else { cast[u64](0) }
    // A deadline, with nothing to take
    started :: test_kit.clock_now()
    nothing :: slop_os.port_wait(port, packets, started + DEADLINE_NANOSECONDS)
    after_deadline :: test_kit.clock_now()
    results[11] = cast[u64](nothing or_else 0)
    results[12] = if after_deadline - started >= DEADLINE_NANOSECONDS { cast[u64](1) } else { cast[u64](0) }
    // Memory it can't write
    results[13] = test_kit.tag_of(slop_os.port_wait(port, test_kit.packets_at(0x10, 4), slop_os.NO_DEADLINE))
    // B wakes it
    thread :: test_kit.start_thread(budget, cast[u64](helper), cast[u64](shared)) or_return 103
    from_b :: slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
    results[14] = if (from_b or_else 0) == 1 { packets[0].data[0] } else { cast[u64](0) }
    intrinsics.volatile_store_u64(&shared^[SHARED_A_WOKEN], 1)
    results[17] = test_kit.tag_of(slop_os.port_unbind(port, PORT_KEY))
    results[18] = test_kit.tag_of(slop_os.port_wake(port, PORT_KEY, 1))
    // Once B waits, and a while more, closing the port wakes it
    _ = test_kit.wait_for(&shared^[SHARED_B_WAITING], 1_000_000_000)
    while_b :: test_kit.clock_now()
    _ = slop_os.port_wait(port, packets, while_b + DEADLINE_NANOSECONDS)
    results[19] = test_kit.tag_of(slop_os.handle_close(cast[slop_os.Handle](port)))
    _ = test_kit.wait_for(&shared^[SHARED_B_DONE], 1_000_000_000)
    results[15] = intrinsics.volatile_load_u64(&shared^[SHARED_B_GOT])
    results[16] = intrinsics.volatile_load_u64(&shared^[SHARED_B_DONE])
    // B, which has ended, and the port, closed: their charges come back
    _ = slop_os.handle_close(cast[slop_os.Handle](thread))
    emptied :: test_kit.wait_for_budget(budget, 0, 1_000_000_000)
    expected :: u64.[
        0, test_kit.tag(slop_os.PortError.KeyInUse), test_kit.tag(slop_os.PortError.NoSuchKey),
        0, 1, PORT_KEY, test_kit.tag(slop_os.PacketKind.User), 3,
        1, test_kit.tag(slop_os.PacketKind.Timer), 1,
        0, 1,
        test_kit.tag(slop_os.PortError.BadBuffer),
        0x100,
        test_kit.tag(slop_os.PortError.ObjectGone), 1,
        0, test_kit.tag(slop_os.PortError.NoSuchKey), 0,
    ]
    failed := test_kit.check(log, NAME, results, expected)
    if failed == 0 && !emptied {
        log_line.write(log, "%: its budget still has % bytes charged", NAME, test_kit.used(budget))
        failed = 21
    }
    if failed == 0 {
        log_line.write(log, "%: wakes, timers, deadlines and other threads woke waiters; closing the port woke the last", NAME)
    }
    return failed
}
