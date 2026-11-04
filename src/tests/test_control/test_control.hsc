/**
 * test_control (decisions/0069, from the kernel's test of 0056): a debugger, D, the program, controls a target,
 * T, and a process that ends itself, E, both copies of it D launches, so both are in D's subtree and D has their
 * handles with every right. Each tells D, through its peer channel, its address space and where its things are;
 * T's first thread, T1, makes system calls and faults, and T2 counts:
 * - T's subtree has two threads; D intercepts ClockMonotonic's entry and exit, and faults, and can't
 *   intercept T twice; it watches for T's end;
 * - D starts T1 by writing to T's memory; T1's first ClockMonotonic stops at its entry, where D sets the
 *   result registers and skips the call, so T1 gets D's value;
 * - the second runs (Continue at its entry), and stops at its exit, where D changes its result;
 * - T1 writes where nothing is mapped: D maps memory there in T's space and lets it retry, which works;
 * - D reads what T1 got from T's memory; suspends T2, whose count then stands still and whose registers
 *   it can read, and resumes it, when it counts again and they can't be read;
 * - D starts a thread in T (thread_create_in), but not in a space outside T's subtree; gives T the memory
 *   T1 faulted on (process_give_handles), after which it's no longer D's, but can't give a process its own
 *   owning handle, nor a handle without RIGHT_TRANSFER; and memory_size says how big memory is;
 * - D kills T, and its port tells it T ended, killed; E ends itself with process_exit once D writes to its
 *   memory, and a port of D's gets its code;
 * - what D made, T and E charged their budgets comes back.
 */
package test_control

import intrinsics from "base"
import runtime from "base"
import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import test_kit from "../../test_kit"

/** The test's name, which starts each line it logs. */
NAME :: "test_control"
/** The size of the memory D maps where T1 faulted, in bytes. */
PAGE : u64 : 4096
/** The key D's intercept of T queues its stops' packet under. */
CONTROL_KEY : u64 : 21
/** The key D's watch for T's end queues under. */
WATCH_KEY : u64 : 22
/** The key D's watch for E's end queues under. */
EXIT_WATCH_KEY : u64 : 23
/** The code E ends itself with. */
EXIT_VALUE : u64 : 42
/** What D makes T1's first, skipped, ClockMonotonic give. */
SKIPPED_VALUE : u64 : 12345
/** What D changes T1's second ClockMonotonic's result to, at its exit. */
CHANGED_VALUE : u64 : 777
/** What T1 writes where it faults, and reads back once D has mapped memory there. */
FAULT_VALUE : u64 : 4242
/** How long D waits, twice, to see a suspended T2's count stand still, in nanoseconds: 10 ms. */
COUNTING_NANOSECONDS : u64 : 10_000_000
/** How long D waits at most for a resumed T2 to count again, in nanoseconds: 200 ms. */
RESUME_NANOSECONDS : u64 : 200_000_000
/** What D tells T, in the first message on its peer channel: be the target. */
ROLE_TARGET : u64 : 1
/** What D tells E, in the first message on its peer channel: end yourself when told. */
ROLE_EXITING : u64 : 2
/** The slot of a copy's page, a u64 by index, D writes to start it. */
SLOT_GO :: 0
/** The slot T2, and the thread D starts in T, count in. */
SLOT_COUNTER :: 1
/** The slot T1 sets to 1 once it's done. */
SLOT_DONE :: 2
/** The first of T1's three results' slots: its two clock calls' results, then what it read where it faulted. */
SLOT_RESULTS :: 8
/*
 * In a thread's registers as a debugger sees them (slop_os.THREAD_REGISTERS): the system call number's, and
 * the result's tag's and first value's
 */
#if TARGET_ARCH == .x86_64 {
    /** The index of the register holding a system call's number: rax. */
    REGISTER_NUMBER :: 0
    /** The index of the register holding a call's result's tag: rax. */
    REGISTER_TAG :: 0
    /** The index of the register holding a call's result's first value: rdx. */
    REGISTER_FIRST :: 3
}
#else_if TARGET_ARCH == .arm64 {
    /** The index of the register holding a system call's number: x8. */
    REGISTER_NUMBER :: 8
    /** The index of the register holding a call's result's tag: x0. */
    REGISTER_TAG :: 0
    /** The index of the register holding a call's result's first value: x1. */
    REGISTER_FIRST :: 1
}

/** What T tells D, with its address space's handle in the message's batch: where its things are. */
TargetReport :: struct {
    /** The address in T of its page, u64[16], whose slots D reads and writes. */
    page : u64,
    /** The address in T, reserved and left unmapped, T1 writes to and faults on; 0 from E. */
    fault_at : u64,
    /** The address in T of counter, which the thread D starts there runs; 0 from E. */
    counter_entry : u64,
    /** The top of a stack T mapped for the thread D starts, 8 below a multiple of 16; 0 from E. */
    stack_top : u64,
}

/** What a copy is given (main): its log, and its peer channel to D. */
CopyGrants :: struct {
    /** A copy of D's debug log, writable. */
    log : slop_os.DebugLog,
    /** Not given. */
    platform : slop_os.Platform?,
    /** Not given. */
    test_device : slop_os.Memory?,
    /** Not given. */
    firmware : slop_os.Memory?,
    /** Not given. */
    manager : os.Channel[process_manager.ProcessManager]?,
    /** Not given. */
    program : slop_os.Memory?,
    /** The copy's end of its peer channel to D, which makes main run as a copy. */
    peer : slop_os.Channel?,
    /** Not given. */
    cpu_budget : slop_os.CpuBudget?,
}

/**
 * Count in a page, for good: T2, and the thread D starts in T.
 *
 * @param page The page, whose SLOT_COUNTER is counted in; it wraps after 2^64 counts.
 */
counter #calling_convention(.c) #no_context :: fn(page: ptr[mut u64[16]]) #never_returns {
    loop {
        intrinsics.volatile_store_u64(&page^[SLOT_COUNTER], intrinsics.volatile_load_u64(&page^[SLOT_COUNTER]) + 1)
    }
}

/**
 * Check what a debugger can do to processes in its subtree; or, run as T or E, be one of them.
 *
 * @param log The debug log, writable, where the test says what it found and which check failed.
 * @param platform Not used.
 * @param test_device Not used.
 * @param firmware Not used.
 * @param manager The process manager, which launches T and E; without it the test ends with 100.
 * @param program The test's own module, which T and E are launched from; without it the test ends with 100.
 * @param peer Given only to T and E, by D: the channel their role comes on. With it, this runs as a copy.
 * @param cpu_budget Not used.
 * @return What run_debugger gives for D, or run_copy for T or E.
 */
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    match peer {
        case Some(end) => return run_copy(end)
        case None => {}
    }
    connection :: manager or_return 100
    executable :: program or_return 100
    return run_debugger(log, connection, executable)
}

/**
 * Run as T or E, as D says in its first message: report where its things are, with its address space, then do what
 * D controls.
 *
 * @param peer The copy's end of its peer channel to D.
 * @return For E, it ends itself with EXIT_VALUE once D writes to its page, so never returns. T never returns, as D
 *     kills it. Either gives 1 if no port could be made for peer, 2 if the role couldn't be received, 3 if its page
 *     couldn't be allocated, 7 if its address space's handle couldn't be duplicated; T 4 if T2 couldn't be started, 5
 *     if the stack couldn't be made, 6 if no addresses were left to fault on.
 */
run_copy :: fn(peer: slop_os.Channel) -> int {
    block :: slop_os.startup_block()
    port :: os.port_for(block.budget, peer) or_return 1
    role : u64 = 0
    none : slop_os.Handle[1]
    _ = os.receive(peer, port, os.mut_bytes_of(&role), none) or_return 2
    pages, error :: runtime.new_array(u64[16], 1)
    if error != null || pages.count == 0 {
        return 3
    }
    page :: &pages[0]
    if role == ROLE_EXITING {
        // Ends itself, once D writes to its page
        report := TargetReport.{page = cast[u64](page)}
        exiting_space :: slop_os.handle_duplicate(cast[slop_os.Handle](block.space), slop_os.RIGHTS_ALL) or_return 7
        _ = os.send(peer, port, os.bytes_of(&report), slop_os.Handle.[exiting_space])
        loop {
            intrinsics.spin_hint()
        }
        while intrinsics.volatile_load_u64(&page^[SLOT_GO]) == 0
        slop_os.process_exit(cast[u32](EXIT_VALUE))
    }
    // T: T2 counts, and a stack for the thread D starts; where it faults is left unmapped
    _ = test_kit.start_thread(block.budget, cast[u64](counter), cast[u64](page)) or_return 4
    stack :: slop_os.memory_create(block.budget, test_kit.THREAD_STACK) or_return 5
    stack_at :: runtime.reserve_addresses(cast[usize](test_kit.THREAD_STACK)) or_return 5
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(stack, block.space, stack_at, 0, test_kit.THREAD_STACK, read_write) or_return 5
    fault_at :: runtime.reserve_addresses(cast[usize](PAGE)) or_return 6
    report := TargetReport.{page = cast[u64](page), fault_at = fault_at, counter_entry = cast[u64](counter),
        stack_top = stack_at + test_kit.THREAD_STACK - 8}
    space :: slop_os.handle_duplicate(cast[slop_os.Handle](block.space), slop_os.RIGHTS_ALL) or_return 7
    _ = os.send(peer, port, os.bytes_of(&report), slop_os.Handle.[space])
    // T1: once D says so, two clock calls and a fault, with no other calls of its own
    loop {
        intrinsics.spin_hint()
    }
    while intrinsics.volatile_load_u64(&page^[SLOT_GO]) == 0
    page^[SLOT_RESULTS] = slop_os.clock_monotonic() or_else 0
    page^[SLOT_RESULTS + 1] = slop_os.clock_monotonic() or_else 0
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](fault_at), FAULT_VALUE)
    page^[SLOT_RESULTS + 2] = intrinsics.volatile_load_u64(cast[ptr[u64]](fault_at))
    intrinsics.volatile_store_u64(&page^[SLOT_DONE], 1)
    loop {
        intrinsics.spin_hint()
    }
}

/** A copy launched with a peer channel, told its role: its process, the end D keeps, and the end's port. */
Copy :: struct {
    /** The copy's process and memory budget, as the launch gave them, which D owns. */
    launched : os.Launched,
    /** D's end of the peer channel. */
    end : slop_os.Channel,
    /** D's port for end. */
    port : slop_os.Port,
}

/**
 * Launch a copy of the test, with a peer channel, and tell it its role.
 *
 * @param log The test's debug log, duplicated for the copy.
 * @param manager The process manager connection the copy is launched through.
 * @param manager_port D's port for the manager connection.
 * @param program The test's own module, which the copy runs.
 * @param name The copy's process name.
 * @param role ROLE_TARGET or ROLE_EXITING, sent on the peer channel.
 * @return The copy, or null if any step failed, leaving behind whatever it had made.
 */
launch_copy :: fn(log: slop_os.DebugLog, manager: os.Channel[process_manager.ProcessManager], manager_port: slop_os.Port,
    program: slop_os.Memory, name: string, role: u64) -> Copy? {
    block :: slop_os.startup_block()
    pair :: slop_os.channel_create(block.budget, 0, 0) or_return null
    log_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    log_copy :: cast[slop_os.DebugLog](slop_os.handle_duplicate(cast[slop_os.Handle](log), log_rights) or_return null)
    copy := Copy.{end = pair.a}
    copy.launched = os.launch(manager, manager_port, name, program, 4 << 20, main, CopyGrants.{log = log_copy, peer = pair.b}) or_return null
    copy.port = os.port_for(block.budget, pair.a) or_return null
    told := role
    none : slop_os.Handle[1]
    match os.send(pair.a, copy.port, os.bytes_of(&told), view_of(&none[0], 0)) {
        case Some(error) => return null
        case None => return copy
    }
}

/**
 * Wait for an intercepted thread's next stop.
 *
 * @param port The port the intercept queues its packet on, waited on while there's no stop.
 * @param intercept The intercept on the thread's process, attached with port; intercept_next is asked again each
 *     time a packet comes, until it gives a stop. Packets of other kinds on port are taken and dropped.
 * @param stop Where the stop's StopInfo goes.
 */
next_stop :: fn(port: slop_os.Port, intercept: slop_os.Intercept, stop: ptr[mut slop_os.StopInfo]) {
    loop {
        if test_kit.tag_of(slop_os.intercept_next(intercept, stop)) == 0 {
            break
        }
        packets : slop_os.Packet[1]
        _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Read a slot of T's page through D's handle to T.
 *
 * @param target D's handle to T.
 * @param space T's address space.
 * @param page The page's address in T.
 * @param slot Which slot, a u64 by index.
 * @return What the slot holds, or 0 if it couldn't be read.
 */
read_target :: fn(target: slop_os.Process, space: slop_os.AddressSpace, page: u64, slot: u64) -> u64 {
    value : u64 = 0
    _ = slop_os.process_read_memory(target, space, page + slot * 8, os.mut_bytes_of(&value))
    return value
}

/**
 * Run as D: launch T and E, control them, and check what each call did.
 *
 * @param log The debug log, duplicated for the copies.
 * @param manager The process manager connection the copies are launched through.
 * @param program The test's own module, which the copies run.
 * @return 0 if every check passed. Otherwise the first that failed, by its result's index plus one: 1 T not having
 *     two threads; 2 intercepting T, 3 intercepting it twice not refused with AlreadyIntercepted, or 4 watching for
 *     its end; 5 starting T1; 6 and 7 T1's first stop not ClockMonotonic's entry; 8 reading T1's registers, or 9
 *     their call number not ClockMonotonic's; 10 writing them, or 11 skipping the call; 12 the second call not
 *     stopping at its entry, or 13 at its exit; 14 skipping a call at its exit not refused with NotStopped; 15 the
 *     fault not stopping, 16 not at fault_at, or 17 mapping memory there; 18 to 20 what T1 got not SKIPPED_VALUE,
 *     CHANGED_VALUE and FAULT_VALUE; 21 suspending T2, 22 its count not standing still, 23 reading its registers, 24
 *     resuming it, 25 its count not going on, or 26 reading its registers while it runs not refused with NotStopped;
 *     27 killing T, or 28 its end not seen as killed; 29 watching E, 30 telling it to end, or 31 its code not
 *     EXIT_VALUE; 32 a thread in a space outside T's subtree not refused with BadAddress, or 33 one in T's not
 *     started; 34 giving T the memory, or 35 the memory's handle still D's; 36 giving a process its own owning
 *     handle not refused with NotTransferable; 37 memory_size wrong; 38 giving a handle without RIGHT_TRANSFER not
 *     refused with MissingRight. 90 if D's, T's or E's budget didn't come back to nothing. 101 to 110 if setting up
 *     failed: 101 the memory budget, 102 the manager's port, 103 launching T or E, 104 their reports, 105 the ports,
 *     107 the memory, 108 the other address space, 109 the child process, 110 the sized memory.
 */
run_debugger :: fn(log: slop_os.DebugLog, manager: os.Channel[process_manager.ProcessManager], program: slop_os.Memory) -> int {
    block :: slop_os.startup_block()
    budget :: slop_os.memory_budget_create(block.budget, 1 << 20) or_return 101
    manager_port :: os.port_for(block.budget, manager.end) or_return 102
    t :: launch_copy(log, manager, manager_port, program, "test_control T", ROLE_TARGET) or_return 103
    e :: launch_copy(log, manager, manager_port, program, "test_control E", ROLE_EXITING) or_return 103
    target :: t.launched.process
    exiting :: e.launched.process
    // Where T's things are, and its space; and E's page
    found := TargetReport.{}
    space_handles : slop_os.Handle[1]
    _ = os.receive(t.end, t.port, os.mut_bytes_of(&found), space_handles) or_return 104
    target_space :: cast[slop_os.AddressSpace](space_handles[0])
    exiting_found := TargetReport.{}
    exiting_space_handles : slop_os.Handle[1]
    _ = os.receive(e.end, e.port, os.mut_bytes_of(&exiting_found), exiting_space_handles) or_return 104
    exiting_space :: cast[slop_os.AddressSpace](exiting_space_handles[0])
    one : u64 = 1
    results : u64[38]
    stop := slop_os.StopInfo.{}
    registers : u64[slop_os.THREAD_REGISTERS]
    port :: slop_os.port_create(budget) or_return 105
    // T's threads, an intercept, a second refused, and a watch for its end
    ids : u64[4]
    results[0] = cast[u64](slop_os.process_threads(target, ids) or_else 0)
    points :: slop_os.STOP_SYSCALL_ENTRY | slop_os.STOP_SYSCALL_EXIT | slop_os.STOP_FAULT
    calls :: slop_os.syscall_bit(slop_os.SYSCALL_CLOCK_MONOTONIC)
    attached :: slop_os.intercept_attach(target, port, CONTROL_KEY, calls, points)
    results[1] = test_kit.tag_of(attached)
    intercept :: attached or_else test_kit.handle_at[slop_os.Intercept](0)
    results[2] = test_kit.tag_of(slop_os.intercept_attach(target, port, CONTROL_KEY + 100, calls, points))
    results[3] = test_kit.tag_of(slop_os.port_bind(port, cast[slop_os.Handle](target), slop_os.SIGNAL_TERMINATED, WATCH_KEY, .Persistent))
    // E ends itself once told to, watched on a port of its own, which is looked at last
    exit_port :: slop_os.port_create(budget) or_return 105
    results[28] = test_kit.tag_of(slop_os.port_bind(exit_port, cast[slop_os.Handle](exiting), slop_os.SIGNAL_TERMINATED, EXIT_WATCH_KEY, .Once))
    results[29] = test_kit.tag_of(slop_os.process_write_memory(exiting, exiting_space, exiting_found.page + SLOT_GO * 8, os.bytes_of(&one)))
    // T1 goes, by a write to T's memory
    results[4] = test_kit.tag_of(slop_os.process_write_memory(target, target_space, found.page + SLOT_GO * 8, os.bytes_of(&one)))
    // The first call, at its entry: answered, and skipped
    next_stop(port, intercept, &stop)
    t1 :: stop.thread
    t2 :: if ids[0] == t1 { ids[1] } else { ids[0] }
    clock :: cast[u64](slop_os.SYSCALL_CLOCK_MONOTONIC)
    results[5] = cast[u64](cast[u32](stop.point))
    results[6] = cast[u64](stop.number)
    results[7] = test_kit.tag_of(slop_os.thread_read_registers(target, t1, registers))
    results[8] = registers[REGISTER_NUMBER]
    registers[REGISTER_TAG] = 0
    registers[REGISTER_FIRST] = SKIPPED_VALUE
    results[9] = test_kit.tag_of(slop_os.thread_write_registers(target, t1, registers))
    results[10] = test_kit.tag_of(slop_os.intercept_resume(intercept, t1, .Skip))
    // The second runs, and its result is changed at its exit
    next_stop(port, intercept, &stop)
    results[11] = cast[u64](cast[u32](stop.point))
    _ = slop_os.intercept_resume(intercept, t1, .Continue)
    next_stop(port, intercept, &stop)
    results[12] = cast[u64](cast[u32](stop.point))
    _ = slop_os.thread_read_registers(target, t1, registers)
    registers[REGISTER_FIRST] = CHANGED_VALUE
    _ = slop_os.thread_write_registers(target, t1, registers)
    results[13] = test_kit.tag_of(slop_os.intercept_resume(intercept, t1, .Skip))
    _ = slop_os.intercept_resume(intercept, t1, .Continue)
    // The fault: memory mapped where it wrote, and it tries again
    next_stop(port, intercept, &stop)
    results[14] = cast[u64](cast[u32](stop.point))
    results[15] = if stop.address == found.fault_at { cast[u64](1) } else { cast[u64](0) }
    memory :: slop_os.memory_create(budget, PAGE) or_return 107
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    results[16] = test_kit.tag_of(slop_os.memory_map(memory, target_space, found.fault_at, 0, PAGE, read_write))
    _ = slop_os.intercept_resume(intercept, t1, .Continue)
    started :: test_kit.clock_now()
    loop {
        intrinsics.spin_hint()
    }
    while read_target(target, target_space, found.page, SLOT_DONE) == 0 && test_kit.clock_now() - started < 2_000_000_000
    results[17] = read_target(target, target_space, found.page, SLOT_RESULTS)
    results[18] = read_target(target, target_space, found.page, SLOT_RESULTS + 1)
    results[19] = read_target(target, target_space, found.page, SLOT_RESULTS + 2)
    // T2, suspended: its count stands still, and its registers can be read; resumed, it counts, and they can't
    results[20] = test_kit.tag_of(slop_os.thread_suspend(target, t2))
    test_kit.wait_nanoseconds(COUNTING_NANOSECONDS)
    before :: read_target(target, target_space, found.page, SLOT_COUNTER)
    test_kit.wait_nanoseconds(COUNTING_NANOSECONDS)
    results[21] = if read_target(target, target_space, found.page, SLOT_COUNTER) == before { cast[u64](1) } else { cast[u64](0) }
    results[22] = test_kit.tag_of(slop_os.thread_read_registers(target, t2, registers))
    results[23] = test_kit.tag_of(slop_os.thread_resume(target, t2))
    // Threads busy on every CPU, preempted at ticks: it runs again within a few
    resumed :: test_kit.clock_now()
    loop {
        intrinsics.spin_hint()
    }
    while read_target(target, target_space, found.page, SLOT_COUNTER) == before && test_kit.clock_now() - resumed < RESUME_NANOSECONDS
    results[24] = if read_target(target, target_space, found.page, SLOT_COUNTER) > before { cast[u64](1) } else { cast[u64](0) }
    results[25] = test_kit.tag_of(slop_os.thread_read_registers(target, t2, registers))
    // Building into T: a thread in its own space starts, one in a space outside its subtree doesn't
    other_space :: slop_os.address_space_create(budget) or_return 108
    results[31] = test_kit.tag_of(slop_os.thread_create_in(target, budget, other_space, found.counter_entry, found.stack_top, found.page))
    created :: slop_os.thread_create_in(target, budget, target_space, found.counter_entry, found.stack_top, found.page)
    results[32] = if test_kit.tag_of(created) == 0 && (created or_else 0) != 0 { cast[u64](1) } else { cast[u64](0) }
    // The memory T1 faulted on goes to T, and isn't D's any more
    given : slop_os.Handle[4]
    results[33] = test_kit.tag_of(slop_os.process_give_handles(target, slop_os.Handle.[cast[slop_os.Handle](memory)], given))
    results[34] = test_kit.tag_of(slop_os.memory_size(memory))
    // A process can't be given its own owning handle, nor a handle without RIGHT_TRANSFER
    child :: slop_os.process_create(budget) or_return 109
    results[35] = test_kit.tag_of(slop_os.process_give_handles(child, slop_os.Handle.[cast[slop_os.Handle](child)], given))
    sized :: slop_os.memory_create(budget, 2 * PAGE) or_return 110
    results[36] = if (slop_os.memory_size(sized) or_else 0) == 2 * PAGE { cast[u64](1) } else { cast[u64](0) }
    readable :: slop_os.handle_duplicate(cast[slop_os.Handle](sized), slop_os.RIGHT_MEMORY_READ) or_else slop_os.NO_HANDLE
    results[37] = test_kit.tag_of(slop_os.process_give_handles(target, slop_os.Handle.[readable], given))
    // T killed, and its end seen, once the stops' packet is out of the way
    packets : slop_os.Packet[1]
    loop {
        if (slop_os.port_wait(port, packets, 0) or_else 0) == 0 {
            break
        }
    }
    results[26] = test_kit.tag_of(slop_os.process_kill(target))
    ended :: slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_else 0
    results[27] = if ended == 1 && packets[0].key == WATCH_KEY && packets[0].data[0] & cast[u64](cast[u32](slop_os.SIGNAL_TERMINATED)) != 0
        && packets[0].data[1] == slop_os.EXIT_KILLED { cast[u64](1) } else { cast[u64](0) }
    // E's end, which says with what
    exited :: slop_os.port_wait(exit_port, packets, slop_os.NO_DEADLINE) or_else 0
    results[30] = if exited == 1 && packets[0].key == EXIT_WATCH_KEY && packets[0].data[1] == EXIT_VALUE { cast[u64](1) } else { cast[u64](0) }
    expected :: u64.[
        2, 0, test_kit.tag(slop_os.ControlError.AlreadyIntercepted), 0, 0,
        test_kit.tag(slop_os.StopPoint.SyscallEntry), clock, 0, clock, 0, 0,
        test_kit.tag(slop_os.StopPoint.SyscallEntry), test_kit.tag(slop_os.StopPoint.SyscallExit), test_kit.tag(slop_os.ControlError.NotStopped),
        test_kit.tag(slop_os.StopPoint.Fault), 1, 0,
        SKIPPED_VALUE, CHANGED_VALUE, FAULT_VALUE,
        0, 1, 0, 0, 1, test_kit.tag(slop_os.ControlError.NotStopped),
        0, 1,
        0, 0, 1,
        test_kit.tag(slop_os.ControlError.BadAddress), 1, 0, test_kit.tag(slop_os.HandleError.InvalidHandle),
        test_kit.tag(slop_os.ControlError.NotTransferable), 1, test_kit.tag(slop_os.ControlError.MissingRight),
    ]
    failed := test_kit.check(log, NAME, results, expected)
    if failed != 0 {
        return failed
    }
    // What D made goes, and T's and E's budgets come back to nothing
    _ = slop_os.handle_close(cast[slop_os.Handle](intercept))
    _ = slop_os.handle_close(cast[slop_os.Handle](port))
    _ = slop_os.handle_close(cast[slop_os.Handle](exit_port))
    _ = slop_os.handle_close(cast[slop_os.Handle](other_space))
    _ = slop_os.handle_close(cast[slop_os.Handle](child))
    _ = slop_os.handle_close(cast[slop_os.Handle](sized))
    if !test_kit.wait_for_budget(budget, 0, 2_000_000_000) || !test_kit.wait_for_budget(t.launched.budget, 0, 2_000_000_000)
        || !test_kit.wait_for_budget(e.launched.budget, 0, 2_000_000_000) {
        log_line.write(log, "%: budgets still charged: D's %, T's %, E's %", NAME, test_kit.used(budget), test_kit.used(t.launched.budget),
            test_kit.used(e.launched.budget))
        return 90
    }
    log_line.write(log, "%: a debugger skipped and changed calls, fixed a fault, read and wrote memory, suspended, resumed and started threads, gave a handle and killed its target; an exit's code came with its end", NAME)
    return 0
}
