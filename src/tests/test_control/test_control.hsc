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

import compiler from "base"
import intrinsics from "base"
import runtime from "base"
import os from "std"
import testing from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import test_kit from "../../test_kit"
import crash_reports from "../../crash_reports"

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
/** What D tells F, in the first message on its peer channel: fault at once, writing where nothing's mapped. */
ROLE_FAULTING : u64 : 3
/** Where F writes, which nothing maps: the first page, kept unmapped. */
FAULTING_ADDRESS : u64 : 16
/** The key F's faults are reported under. */
FAULTS_KEY : u64 : 24
/** The key D's watch for F's end queues under. */
FAULTING_WATCH_KEY : u64 : 25
/** How long D waits at most for F to end once its fault stop isn't let go, in nanoseconds: 5 s. */
FAULTING_END_NANOSECONDS : u64 : 5_000_000_000
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

/** What main was given that the tests use. */
Given :: struct {
    /** The debug log, duplicated for the copies. */
    log : slop_os.DebugLog,
    /** The process manager, which launches T and E; none if main wasn't given it. */
    manager : os.Channel[process_manager.ProcessManager]?,
    /** The test's own module, which T and E are launched from; none if main wasn't given it. */
    program : slop_os.Memory?,
}

/**
 * Run the tests as D, reporting to the debug log; or, run as T or E, be one of the processes D controls.
 *
 * @param log The debug log, writable, where each test is reported.
 * @param platform Not used.
 * @param test_device Not used.
 * @param firmware Not used.
 * @param manager The process manager, which launches T and E; without it the tests fail.
 * @param program The test's own module, which T and E are launched from; without it the tests fail.
 * @param peer Given only to T and E, by D: the channel their role comes on. With it, this runs as a copy.
 * @param cpu_budget Not used.
 * @return How many tests failed, 0 when every one passed; as T or E, what run_copy gives.
 */
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    match peer {
        case Some(end) => return run_copy(end)
        case None => {}
    }
    given :: Given.{log = log, manager = manager, program = program}
    return test_kit.run(log, NAME, #insert testing.tests_of(compiler.load_package(".")), given)
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
    if role == ROLE_FAULTING {
        intrinsics.volatile_store_u64(cast[ptr[mut u64]](FAULTING_ADDRESS), 1)
        slop_os.process_exit(0)
    }
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
 * @param role ROLE_TARGET, ROLE_EXITING or ROLE_FAULTING, sent on the peer channel.
 * @param options What the launch does beyond its grants; none by default.
 * @return The copy, or null if any step failed, leaving behind whatever it had made.
 */
launch_copy :: fn(log: slop_os.DebugLog, manager: os.Channel[process_manager.ProcessManager], manager_port: slop_os.Port,
    program: slop_os.Memory, name: string, role: u64, options: os.LaunchOptions = os.LaunchOptions.{}) -> Copy? {
    block :: slop_os.startup_block()
    pair :: slop_os.channel_create(block.budget, 0, 0) or_return null
    log_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    log_copy :: cast[slop_os.DebugLog](slop_os.handle_duplicate(cast[slop_os.Handle](log), log_rights) or_return null)
    copy := Copy.{end = pair.a}
    copy.launched = os.launch(manager, manager_port, name, program, 4 << 20, main, CopyGrants.{log = log_copy, peer = pair.b}, options)
        or_return null
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
 * Check what a debugger, D, can do to a target in its subtree, T: intercept its calls and faults, once; skip a call,
 * answering it, and change a call's result at its exit; map memory where it faulted and let it retry; read and write
 * its memory; suspend, read and resume a thread; start a thread in it, but not in a space outside its subtree; give it
 * a handle, but not a process its own owning handle, nor a handle without RIGHT_TRANSFER; kill it, and see it end,
 * killed. Then that what D made and T charged their budgets comes back.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if main wasn't given the process manager or its module, or the memory budget, the
 *     manager's port, T, its report, the port, the intercept, the memory, the other address space, the child process
 *     or the sized memory couldn't be made.
 */
a_debugger_controls_a_process_in_its_subtree #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    block :: slop_os.startup_block()
    manager :: testing.require_some(t, given.manager, "the root task grants the process manager")?
    program :: testing.require_some(t, given.program, "the root task grants the program's own module")?
    budget :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 1 << 20), "a budget for what D makes")?
    manager_port :: testing.require_some(t, os.port_for(block.budget, manager.end), "a port for the process manager's replies")?
    copy :: testing.require_some(t, launch_copy(given.log, manager, manager_port, program, "test_control T", ROLE_TARGET), "T is launched and told its role")?
    target :: copy.launched.process
    // Where T's things are, and its space
    found := TargetReport.{}
    space_handles : slop_os.Handle[1]
    testing.require_ok(t, os.receive(copy.end, copy.port, os.mut_bytes_of(&found), space_handles), "T reports where its things are, with its address space")?
    target_space :: cast[slop_os.AddressSpace](space_handles[0])
    one : u64 = 1
    stop := slop_os.StopInfo.{}
    registers : u64[slop_os.THREAD_REGISTERS]
    port :: testing.require_ok(t, slop_os.port_create(budget), "a port for T's stops and end")?
    // T's threads, an intercept, a second refused, and a watch for its end
    ids : u64[4]
    testing.expect_eq(t, slop_os.process_threads(target, ids) or_else 0, 2, "T's subtree has its two threads, T1 and T2")
    points :: slop_os.STOP_SYSCALL_ENTRY | slop_os.STOP_SYSCALL_EXIT | slop_os.STOP_FAULT
    calls :: slop_os.syscall_bit(slop_os.SYSCALL_CLOCK_MONOTONIC)
    intercept :: testing.require_ok(t, slop_os.intercept_attach(target, port, CONTROL_KEY, calls, points), "D intercepts T's ClockMonotonic calls and faults")?
    twice :: slop_os.intercept_attach(target, port, CONTROL_KEY + 100, calls, points)
    testing.expect_error(t, twice, slop_os.ControlError.AlreadyIntercepted, "a process is intercepted by one debugger at a time")
    watched :: slop_os.port_bind(port, cast[slop_os.Handle](target), slop_os.SIGNAL_TERMINATED, WATCH_KEY, .Persistent)
    testing.expect_ok(t, watched, "D watches for T's end")
    // T1 goes, by a write to T's memory
    went :: slop_os.process_write_memory(target, target_space, found.page + SLOT_GO * 8, os.bytes_of(&one))
    testing.expect_ok(t, went, "D writes T's memory, starting T1")
    // The first call, at its entry: answered, and skipped
    next_stop(port, intercept, &stop)
    t1 :: stop.thread
    t2 :: if ids[0] == t1 { ids[1] } else { ids[0] }
    clock :: cast[u64](slop_os.SYSCALL_CLOCK_MONOTONIC)
    testing.expect_eq(t, stop.point, slop_os.StopPoint.SyscallEntry, "an intercepted call stops at its entry")
    testing.expect_eq(t, cast[u64](stop.number), clock, "the stop says which call it is: ClockMonotonic")
    read :: slop_os.thread_read_registers(target, t1, registers)
    testing.expect_ok(t, read, "a stopped thread's registers can be read")
    testing.expect_eq(t, registers[REGISTER_NUMBER], clock, "a thread stopped at a call's entry has the call's number in its registers")
    registers[REGISTER_TAG] = 0
    registers[REGISTER_FIRST] = SKIPPED_VALUE
    written :: slop_os.thread_write_registers(target, t1, registers)
    testing.expect_ok(t, written, "a stopped thread's registers can be written, here with the call's result")
    skipped :: slop_os.intercept_resume(intercept, t1, .Skip)
    testing.expect_ok(t, skipped, "a call stopped at its entry can be skipped")
    // The second runs, and its result is changed at its exit
    next_stop(port, intercept, &stop)
    testing.expect_eq(t, stop.point, slop_os.StopPoint.SyscallEntry, "the second intercepted call stops at its entry")
    _ = slop_os.intercept_resume(intercept, t1, .Continue)
    next_stop(port, intercept, &stop)
    testing.expect_eq(t, stop.point, slop_os.StopPoint.SyscallExit, "a call continued from its entry stops at its exit")
    _ = slop_os.thread_read_registers(target, t1, registers)
    registers[REGISTER_FIRST] = CHANGED_VALUE
    _ = slop_os.thread_write_registers(target, t1, registers)
    skipped_at_exit :: slop_os.intercept_resume(intercept, t1, .Skip)
    testing.expect_error(t, skipped_at_exit, slop_os.ControlError.NotStopped, "a call stopped at its exit has run, so it can't be skipped")
    _ = slop_os.intercept_resume(intercept, t1, .Continue)
    // The fault: memory mapped where it wrote, and it tries again
    next_stop(port, intercept, &stop)
    testing.expect_eq(t, stop.point, slop_os.StopPoint.Fault, "an intercepted fault stops the thread")
    testing.expect_eq(t, stop.address, found.fault_at, "a fault's stop says the address faulted on")
    memory :: testing.require_ok(t, slop_os.memory_create(budget, PAGE), "memory to map where T1 faulted")?
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    mapped :: slop_os.memory_map(memory, target_space, found.fault_at, 0, PAGE, read_write)
    testing.expect_ok(t, mapped, "D maps memory in T's space where it faulted")
    _ = slop_os.intercept_resume(intercept, t1, .Continue)
    started :: test_kit.clock_now()
    loop {
        intrinsics.spin_hint()
    }
    while read_target(target, target_space, found.page, SLOT_DONE) == 0 && test_kit.clock_now() - started < 2_000_000_000
    testing.expect_eq(t, read_target(target, target_space, found.page, SLOT_RESULTS), SKIPPED_VALUE, "a skipped call gives what D wrote in its registers")
    testing.expect_eq(t, read_target(target, target_space, found.page, SLOT_RESULTS + 1), CHANGED_VALUE, "a call's result changed at its exit is what the thread gets")
    testing.expect_eq(t, read_target(target, target_space, found.page, SLOT_RESULTS + 2), FAULT_VALUE, "a faulted write retried once memory is mapped there works")
    // T2, suspended: its count stands still, and its registers can be read; resumed, it counts, and they can't
    suspended :: slop_os.thread_suspend(target, t2)
    testing.expect_ok(t, suspended, "D suspends T2")
    test_kit.wait_nanoseconds(COUNTING_NANOSECONDS)
    before :: read_target(target, target_space, found.page, SLOT_COUNTER)
    test_kit.wait_nanoseconds(COUNTING_NANOSECONDS)
    testing.expect_eq(t, read_target(target, target_space, found.page, SLOT_COUNTER), before, "a suspended thread doesn't run, so its count stands still")
    suspended_read :: slop_os.thread_read_registers(target, t2, registers)
    testing.expect_ok(t, suspended_read, "a suspended thread's registers can be read")
    resumed_ok :: slop_os.thread_resume(target, t2)
    testing.expect_ok(t, resumed_ok, "D resumes T2")
    // Threads busy on every CPU, preempted at ticks: it runs again within a few
    resumed :: test_kit.clock_now()
    loop {
        intrinsics.spin_hint()
    }
    while read_target(target, target_space, found.page, SLOT_COUNTER) == before && test_kit.clock_now() - resumed < RESUME_NANOSECONDS
    testing.expect(t, read_target(target, target_space, found.page, SLOT_COUNTER) > before, "a resumed thread runs again, so it counts on")
    running_read :: slop_os.thread_read_registers(target, t2, registers)
    testing.expect_error(t, running_read, slop_os.ControlError.NotStopped, "a running thread's registers can't be read")
    // Building into T: a thread in its own space starts, one in a space outside its subtree doesn't
    other_space :: testing.require_ok(t, slop_os.address_space_create(budget), "an address space outside T's subtree")?
    outside :: slop_os.thread_create_in(target, budget, other_space, found.counter_entry, found.stack_top, found.page)
    testing.expect_error(t, outside, slop_os.ControlError.BadAddress, "a thread can't be started in a space outside its process's subtree")
    created :: slop_os.thread_create_in(target, budget, target_space, found.counter_entry, found.stack_top, found.page)
    testing.expect_ok(t, created, "D starts a thread in T's own space")
    testing.expect_ne(t, created or_else 0, 0, "the thread started in T has an ID")
    // The memory T1 faulted on goes to T, and isn't D's any more
    handed : slop_os.Handle[4]
    gave :: slop_os.process_give_handles(target, slop_os.Handle.[cast[slop_os.Handle](memory)], handed)
    testing.expect_ok(t, gave, "D gives T the memory T1 faulted on")
    gone :: slop_os.memory_size(memory)
    testing.expect_error(t, gone, slop_os.HandleError.InvalidHandle, "a handle given away is no longer the giver's")
    // A process can't be given its own owning handle, nor a handle without RIGHT_TRANSFER
    child :: testing.require_ok(t, slop_os.process_create(budget), "a process to give its own handle")?
    own :: slop_os.process_give_handles(child, slop_os.Handle.[cast[slop_os.Handle](child)], handed)
    testing.expect_error(t, own, slop_os.ControlError.NotTransferable, "a process can't be given its own owning handle")
    sized :: testing.require_ok(t, slop_os.memory_create(budget, 2 * PAGE), "memory of two pages")?
    testing.expect_eq(t, slop_os.memory_size(sized) or_else 0, 2 * PAGE, "memory_size says how big memory is")
    readable :: slop_os.handle_duplicate(cast[slop_os.Handle](sized), slop_os.RIGHT_MEMORY_READ) or_else slop_os.NO_HANDLE
    untransferable :: slop_os.process_give_handles(target, slop_os.Handle.[readable], handed)
    testing.expect_error(t, untransferable, slop_os.ControlError.MissingRight, "a handle without RIGHT_TRANSFER can't be given")
    // T killed, and its end seen, once the stops' packet is out of the way
    packets : slop_os.Packet[1]
    loop {
        if (slop_os.port_wait(port, packets, 0) or_else 0) == 0 {
            break
        }
    }
    killed :: slop_os.process_kill(target)
    testing.expect_ok(t, killed, "D kills T")
    ended :: slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_else 0
    testing.expect(t, ended == 1 && packets[0].key == WATCH_KEY && packets[0].data[0] & cast[u64](cast[u32](slop_os.SIGNAL_TERMINATED)) != 0,
        "D's watch sees T end")
    testing.expect_eq(t, packets[0].data[1], slop_os.EXIT_KILLED, "a killed process's end says it was killed")
    // What D made goes, and T's budget comes back to nothing
    _ = slop_os.handle_close(cast[slop_os.Handle](intercept))
    _ = slop_os.handle_close(cast[slop_os.Handle](port))
    _ = slop_os.handle_close(cast[slop_os.Handle](other_space))
    _ = slop_os.handle_close(cast[slop_os.Handle](child))
    _ = slop_os.handle_close(cast[slop_os.Handle](sized))
    _ = test_kit.wait_for_budget(budget, 0, 2_000_000_000)
    testing.expect_eq(t, test_kit.used(budget), 0, "D's budget is back to nothing once what it made is closed")
    _ = test_kit.wait_for_budget(copy.launched.budget, 0, 2_000_000_000)
    testing.expect_eq(t, test_kit.used(copy.launched.budget), 0, "T's budget is back to nothing once it's killed")
    return .Ok
}

/**
 * Check that a process in D's subtree, E, ending itself with process_exit once D writes to its memory, gives a port
 * of D's its code; and that its budget comes back to nothing.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if main wasn't given the process manager or its module, or the manager's port, E,
 *     its report or the port couldn't be made.
 */
a_process_ending_itself_gives_its_code #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    block :: slop_os.startup_block()
    manager :: testing.require_some(t, given.manager, "the root task grants the process manager")?
    program :: testing.require_some(t, given.program, "the root task grants the program's own module")?
    manager_port :: testing.require_some(t, os.port_for(block.budget, manager.end), "a port for the process manager's replies")?
    copy :: testing.require_some(t, launch_copy(given.log, manager, manager_port, program, "test_control E", ROLE_EXITING), "E is launched and told its role")?
    exiting :: copy.launched.process
    exiting_found := TargetReport.{}
    exiting_space_handles : slop_os.Handle[1]
    testing.require_ok(t, os.receive(copy.end, copy.port, os.mut_bytes_of(&exiting_found), exiting_space_handles), "E reports where its page is, with its address space")?
    exiting_space :: cast[slop_os.AddressSpace](exiting_space_handles[0])
    one : u64 = 1
    // E ends itself once told to, watched on a port of its own
    exit_port :: testing.require_ok(t, slop_os.port_create(block.budget), "a port for E's end")?
    watched :: slop_os.port_bind(exit_port, cast[slop_os.Handle](exiting), slop_os.SIGNAL_TERMINATED, EXIT_WATCH_KEY, .Once)
    testing.expect_ok(t, watched, "D watches for E's end")
    told :: slop_os.process_write_memory(exiting, exiting_space, exiting_found.page + SLOT_GO * 8, os.bytes_of(&one))
    testing.expect_ok(t, told, "D writes E's memory, telling it to end")
    packets : slop_os.Packet[1]
    exited :: slop_os.port_wait(exit_port, packets, slop_os.NO_DEADLINE) or_else 0
    testing.expect(t, exited == 1 && packets[0].key == EXIT_WATCH_KEY, "D's watch sees E end")
    testing.expect_eq(t, packets[0].data[1], EXIT_VALUE, "a process's end gives the code it ended itself with")
    _ = slop_os.handle_close(cast[slop_os.Handle](exit_port))
    _ = test_kit.wait_for_budget(copy.launched.budget, 0, 2_000_000_000)
    testing.expect_eq(t, test_kit.used(copy.launched.budget), 0, "E's budget is back to nothing once it has ended")
    return .Ok
}

/**
 * Check a launch's intercept of a program's faults (os.LaunchOptions.faults, decisions/0183): F, a copy, faults at
 * once, which stops it there, reported as a write fault at the address it wrote; a crash report of it has its
 * registers and its faulting instruction in its image. Its stop isn't let go, so it ends within a few seconds
 * (STOP_FAULT_LIMITED), and what it had comes back.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if main wasn't given the process manager or its module, or the port, F or its faults'
 *     intercept couldn't be had.
 */
a_launch_reports_faults_and_ends_a_program_left_stopped #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    block :: slop_os.startup_block()
    manager :: testing.require_some(t, given.manager, "the root task grants the process manager")?
    program :: testing.require_some(t, given.program, "the root task grants the program's own module")?
    manager_port :: testing.require_some(t, os.port_for(block.budget, manager.end), "a port for the process manager's replies")?
    port :: testing.require_ok(t, slop_os.port_create(block.budget), "a port for F's stops and end")?
    options := os.LaunchOptions.{watch = os.LaunchWatch.{port = port, key = FAULTING_WATCH_KEY},
        faults = os.LaunchFaults.{port = port, key = FAULTS_KEY}}
    copy :: testing.require_some(t, launch_copy(given.log, manager, manager_port, program, "test_control F", ROLE_FAULTING, options),
        "F is launched with its faults intercepted, and told its role")?
    faults :: testing.require_some(t, copy.launched.faults, "the launch gives F's faults' intercept and its address space")?
    testing.expect(t, copy.launched.image != 0, "the launch says where F's image is")
    stop := slop_os.StopInfo.{}
    next_stop(port, faults.intercept, &stop)
    testing.expect_eq(t, stop.point, slop_os.StopPoint.Fault, "F stops at a fault")
    testing.expect_eq(t, stop.number, slop_os.FAULT_WRITE, "it's a write fault")
    testing.expect_eq(t, stop.address, FAULTING_ADDRESS, "at the address F wrote")
    report :: crash_reports.make(copy.launched.process, faults.space, copy.launched.image, "test_control F", stop)
    testing.expect(t, report.frame_count >= 2, "a report of the fault has its faulting frame and its caller's")
    testing.expect(t, report.frames[0] >= copy.launched.image, "the faulting instruction is in F's image")
    // Not let go: F ends within the limit, as if nothing intercepted it
    deadline :: (slop_os.clock_monotonic() or_else 0) + FAULTING_END_NANOSECONDS
    ended := false
    loop {
        packets : slop_os.Packet[4]
        taken :: slop_os.port_wait(port, packets, deadline) or_else 0
        if taken == 0 {
            break
        }
        for packet, i in packets {
            if cast[u64](i) < taken && packet.kind == .Signal && packet.key == FAULTING_WATCH_KEY {
                ended = true
            }
        }
        if ended {
            break
        }
    }
    testing.expect(t, ended, "F, its fault stop not let go, ends within a few seconds")
    for handle in slop_os.Handle.[cast[slop_os.Handle](faults.intercept), cast[slop_os.Handle](faults.space),
        cast[slop_os.Handle](copy.launched.process), cast[slop_os.Handle](copy.end), cast[slop_os.Handle](copy.port),
        cast[slop_os.Handle](port)] {
        _ = slop_os.handle_close(handle)
    }
    testing.expect(t, test_kit.wait_for_budget(copy.launched.budget, 0, 1_000_000_000), "F's budget is back to nothing once it has ended")
    _ = slop_os.handle_close(cast[slop_os.Handle](copy.launched.budget))
    return .Ok
}
