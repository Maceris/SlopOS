/**
 * test_perf (roadmap Perf, 9c5, decisions/0097, 0112): the kernel's benchmarks, each a number on a line of its own,
 * "perf: <name> <nanoseconds>", which tools/perf_tests.py reads. Under QEMU's -icount, a nanosecond is an
 * instruction, so the numbers are counts it can hold to a baseline; booted as usual, they're wall time, recorded but
 * not held to one.
 * - ipc_round_trip: a message to a thread of its own and its answer, through a channel's kernel path, each way waking
 *   the other through a port: per round trip;
 * - page_fault: a touch of a page of anonymous memory nothing has touched: per page;
 * - thread_create: a thread made, started, ended, and seen to end: per thread;
 * - process_create: a copy of the program launched through the process manager, ending at once as one given nothing
 *   it needs does, and seen to end: per process;
 * - math_<function>_<tier>: float math's sin, exp and log in each tier (decisions/0190; float_math.hsc): per thousand
 *   values.
 */
package test_perf

import compiler from "base"
import intrinsics from "base"
import runtime from "base"
import os from "std"
import testing from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import test_kit from "../../test_kit"

/** The test's name, which starts each line it logs. */
NAME :: "test_perf"
/** A page, in bytes. */
PAGE : u64 : 4096
/** How many round trips ipc_round_trip measures, after WARM_UP that it doesn't. */
ROUNDS : u64 : 200
/** How many round trips are made before measuring, so caches and the scheduler settle. */
WARM_UP : u64 : 20
/** How many pages page_fault touches. */
PAGES : u64 : 256
/** How many threads thread_create makes. */
THREADS : u64 : 16
/** How many copies process_create launches. */
PROCESSES : u64 : 4
/** Each copy's memory budget, in bytes: 4 MiB. */
COPY_BUDGET : u64 : 4 * 1024 * 1024
/** The key the echoing thread's end wakes its port under. */
ECHO_KEY : u64 : 1
/**
 * The first key the watches for an end queue under: thread_create's and process_create's each add their index, as
 * a fired Once binding keeps its key.
 */
ENDED_KEY : u64 : 2
/** The key the measuring thread's end wakes its port under when the answer comes. */
ANSWER_KEY : u64 : 3

/** The echoing thread's end of the channel, and the port its end wakes. */
Echo :: struct {
    /** The echoing thread's end, which it reads and writes back on. */
    end : slop_os.Channel,
    /** The port end is bound to for Readable, under ECHO_KEY. */
    port : slop_os.Port,
}

/** What a copy launched with nothing is given, against its entry's type, which takes nothing. */
NoGrants :: struct {}

/**
 * Stand for an entry that takes nothing, which the copy's isn't, so the launch gives it no grants and it ends at once.
 *
 * @return 0, though it never runs: the copy runs main.
 */
takes_nothing :: fn() -> int {
    return 0
}

/**
 * Write back each message that arrives, until the other end closes, then end the thread.
 *
 * @param echo The end and its port, which have to outlive the thread.
 */
echo #calling_convention(.c) #no_context :: fn(echo: ptr[Echo]) #never_returns {
    data : u8[8]
    loop {
        match slop_os.channel_read(echo.end, data, cast[ptr[mut u32]](0)) {
            case Ok(info) => _ = slop_os.channel_write(echo.end, data, slop_os.NO_BATCH)
            case Error(error) => {
                if error != .Empty {
                    slop_os.thread_exit()
                }
                packets : slop_os.Packet[1]
                _ = slop_os.port_wait(echo.port, packets, slop_os.NO_DEADLINE)
            }
        }
    }
}

/**
 * End the thread at once.
 *
 * @param argument Ignored.
 */
ends #calling_convention(.c) #no_context :: fn(argument: u64) #never_returns {
    slop_os.thread_exit()
}

/** What main was given that the tests use. */
Given :: struct {
    /** The debug log, where the numbers go. */
    log : slop_os.DebugLog,
    /** The process manager, which launches the copies process_create measures; none if main wasn't given it. */
    manager : os.Channel[process_manager.ProcessManager]?,
    /** The test's own module, which the copies run; none if main wasn't given it. */
    program : slop_os.Memory?,
}

/**
 * Measure round trips to a thread of the program's own that echoes, and log it as "perf: ipc_round_trip <nanoseconds>".
 *
 * @param t The test's state.
 * @return Ok once it's measured and logged; Error if setting up failed or a round trip did, or an answer wasn't what
 *     was sent.
 */
ipc_round_trip_is_measured #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    block :: slop_os.startup_block()
    budget :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 8 << 20), "a budget for what's measured")?
    pair :: testing.require_ok(t, slop_os.channel_create(budget, 0, 0), "a channel to the echoing thread")?
    echoing :: runtime.new(Echo)
    echoing.end = pair.b
    echoing.port = testing.require_ok(t, slop_os.port_create(budget), "a port for the echoing thread")?
    testing.require_ok(t, slop_os.port_bind(echoing.port, cast[slop_os.Handle](pair.b), slop_os.SIGNAL_READABLE, ECHO_KEY, .Persistent), "the echoing thread's end wakes its port")?
    port :: testing.require_ok(t, slop_os.port_create(budget), "a port for the answers")?
    testing.require_ok(t, slop_os.port_bind(port, cast[slop_os.Handle](pair.a), slop_os.SIGNAL_READABLE, ANSWER_KEY, .Persistent), "the measuring end wakes its port")?
    thread :: testing.require_ok(t, test_kit.start_thread(budget, cast[u64](echo), cast[u64](echoing)), "the echoing thread starts")?
    for i in cast[u64](0)..<WARM_UP {
        round_trip(t, pair.a, port, i)?
    }
    start :: test_kit.clock_now()
    for i in cast[u64](0)..<ROUNDS {
        round_trip(t, pair.a, port, i)?
    }
    took :: test_kit.clock_now() - start
    _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
    _ = slop_os.handle_close(cast[slop_os.Handle](thread))
    _ = slop_os.handle_close(cast[slop_os.Handle](port))
    _ = slop_os.handle_close(cast[slop_os.Handle](budget))
    report(given.log, "ipc_round_trip", took / ROUNDS)
    return .Ok
}

/**
 * Send a value to the echoing thread, and wait for its answer.
 *
 * @param t The test's state, which a failed round trip is recorded in.
 * @param end The measuring thread's end.
 * @param port The port end is bound to for Readable.
 * @param value Any value, sent as one 8-byte message; the round's index, so an echo of an earlier round doesn't
 *     match.
 * @return Ok once the answer came back as value; Error(Failed), recorded, if writing failed, reading failed other than
 *     finding nothing, or the answer wasn't value.
 */
round_trip :: fn(t: ptr[mut testing.T], end: slop_os.Channel, port: slop_os.Port, value: u64) -> testing.Outcome {
    sent : u64[1]
    sent[0] = value
    testing.require_ok(t, slop_os.channel_write(end, view_of(cast[ptr[u8]](&sent[0]), 8), slop_os.NO_BATCH), "a message is written to the echoing thread")?
    answer : u64[1]
    loop {
        read :: slop_os.channel_read(end, view_of(cast[ptr[mut u8]](&answer[0]), 8), cast[ptr[mut u32]](0))
        if read is_ok {
            return testing.require_eq(t, answer[0], value, "the echoing thread answers each message with itself, in order")
        }
        testing.require_error(t, read, slop_os.ChannelError.Empty, "reading the answer fails only by finding nothing yet")?
        packets : slop_os.Packet[1]
        _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Measure touching pages of anonymous memory for the first time, and log it as "perf: page_fault <nanoseconds>".
 *
 * @param t The test's state.
 * @return Ok once it's measured and logged; Error if the budget or the memory couldn't be made or mapped.
 */
page_fault_is_measured #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    block :: slop_os.startup_block()
    budget :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 8 << 20), "a budget for what's measured")?
    memory :: testing.require_ok(t, slop_os.memory_create(budget, PAGES * PAGE), "anonymous memory to touch")?
    address :: testing.require_some(t, runtime.reserve_addresses(cast[usize](PAGES * PAGE)), "addresses to map it at")?
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    testing.require_ok(t, slop_os.memory_map(memory, block.space, address, 0, PAGES * PAGE, read_write), "the memory is mapped to write")?
    start :: test_kit.clock_now()
    for page in cast[u64](0)..<PAGES {
        intrinsics.volatile_store_u8(cast[ptr[mut u8]](address + page * PAGE), 1)
    }
    took :: test_kit.clock_now() - start
    _ = slop_os.memory_unmap(block.space, address)
    _ = slop_os.handle_close(cast[slop_os.Handle](memory))
    _ = slop_os.handle_close(cast[slop_os.Handle](budget))
    report(given.log, "page_fault", took / PAGES)
    return .Ok
}

/**
 * Measure making threads, starting them, and seeing them end, and log it as "perf: thread_create <nanoseconds>".
 *
 * @param t The test's state.
 * @return Ok once it's measured and logged; Error if the budget, the port or a thread couldn't be made, or a thread
 *     couldn't be watched.
 */
thread_create_is_measured #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    block :: slop_os.startup_block()
    budget :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 8 << 20), "a budget for what's measured")?
    port :: testing.require_ok(t, slop_os.port_create(budget), "a port to watch the threads end on")?
    start :: test_kit.clock_now()
    for i in cast[u64](0)..<THREADS {
        thread :: testing.require_ok(t, test_kit.start_thread(budget, cast[u64](ends), 0), "each thread starts")?
        // A key of its own, a fired Once binding keeping its key; gone already, it ended before it could be watched
        watched :: slop_os.port_bind(port, cast[slop_os.Handle](thread), slop_os.SIGNAL_TERMINATED, ENDED_KEY + i, .Once)
        if watched is_ok {
            packets : slop_os.Packet[1]
            _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
        }
        else {
            testing.require_error(t, watched, slop_os.PortError.ObjectGone, "a thread's end is watched, unless it has ended already")?
        }
        _ = slop_os.handle_close(cast[slop_os.Handle](thread))
    }
    took :: test_kit.clock_now() - start
    _ = slop_os.handle_close(cast[slop_os.Handle](port))
    _ = slop_os.handle_close(cast[slop_os.Handle](budget))
    report(given.log, "thread_create", took / THREADS)
    return .Ok
}

/**
 * Measure launching copies of the program through the manager, each ending at once, given nothing, and seen to, and
 * log it as "perf: process_create <nanoseconds>".
 *
 * Each copy's budget is waited for, up to a second, to come back to nothing before the next, and that's in the time.
 *
 * @param t The test's state.
 * @return Ok once it's measured and logged; Error if main wasn't given the process manager or its module, or a port
 *     or a launch failed.
 */
process_create_is_measured #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    block :: slop_os.startup_block()
    loader :: testing.require_some(t, given.manager, "the root task grants the process manager")?
    executable :: testing.require_some(t, given.program, "the root task grants the program's own module")?
    manager_port :: testing.require_some(t, os.port_for(block.budget, loader.end), "a port for the process manager's replies")?
    port :: testing.require_ok(t, slop_os.port_create(block.budget), "a port to watch the copies end on")?
    start :: test_kit.clock_now()
    for i in cast[u64](0)..<PROCESSES {
        launch :: os.launch(loader, manager_port, "test_perf copy", executable, COPY_BUDGET, takes_nothing, NoGrants.{},
            os.LaunchOptions.{watch = os.LaunchWatch.{port = port, key = ENDED_KEY + i}})
        launched :: testing.require_ok(t, launch, "the process manager launches each copy")?
        packets : slop_os.Packet[1]
        _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
        _ = slop_os.handle_close(cast[slop_os.Handle](launched.process))
        _ = test_kit.wait_for_budget(launched.budget, 0, 1_000_000_000)
        _ = slop_os.handle_close(cast[slop_os.Handle](launched.budget))
    }
    took :: test_kit.clock_now() - start
    _ = slop_os.handle_close(cast[slop_os.Handle](port))
    report(given.log, "process_create", took / PROCESSES)
    return .Ok
}

/**
 * Run the benchmarks, each a test, reporting to the debug log, where each logs its number.
 *
 * @param log The debug log, writable, where the numbers and the tests' report go.
 * @param platform Not used.
 * @param test_device Not used.
 * @param firmware Not used.
 * @param manager The process manager, which launches the copies process_create measures; without it that test fails.
 * @param program The test's own module, which the copies run; without it process_create's test fails.
 * @param peer Not used.
 * @param cpu_budget Not used.
 * @return How many tests failed: 0 when every benchmark was measured and logged; it holds them to nothing itself.
 */
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    given :: Given.{log = log, manager = manager, program = program}
    return test_kit.run(log, NAME, #insert testing.tests_of(compiler.load_package(".")), given)
}

/**
 * Log a benchmark's number, as tools/perf_tests.py reads it.
 *
 * @param log The debug log the line goes to, which needs RIGHT_DEBUG_LOG_WRITE; a write that fails is ignored.
 * @param name The benchmark's name, one word.
 * @param nanoseconds What one of it took, in nanoseconds, or instructions under -icount.
 */
report :: fn(log: slop_os.DebugLog, name: string, nanoseconds: u64) {
    log_line.write(log, "%: perf: % %", NAME, name, nanoseconds)
}
