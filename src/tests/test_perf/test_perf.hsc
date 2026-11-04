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
 *   it needs does, and seen to end: per process.
 */
package test_perf

import intrinsics from "base"
import runtime from "base"
import os from "std"
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

/**
 * Measure the kernel's benchmarks, and log each as "perf: <name> <nanoseconds>".
 *
 * @param log The debug log, writable, where the numbers go.
 * @param platform Not used.
 * @param test_device Not used.
 * @param firmware Not used.
 * @param manager The process manager, which launches the copies process_create measures; without it the test ends
 *     with 104, after the other benchmarks.
 * @param program The test's own module, which the copies run; without it the test ends with 104.
 * @param peer Not used.
 * @param cpu_budget Not used.
 * @return 0 once every benchmark is measured and logged; it holds them to nothing itself. 100 if the memory budget
 *     couldn't be made; 101 if ipc_round_trip, 102 page_fault, 103 thread_create, or 105 process_create couldn't
 *     be measured.
 */
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    block :: slop_os.startup_block()
    budget :: slop_os.memory_budget_create(block.budget, 8 << 20) or_return 100
    report(log, "ipc_round_trip", ipc_round_trip(budget) or_return 101)
    report(log, "page_fault", page_fault(budget) or_return 102)
    report(log, "thread_create", thread_create(budget) or_return 103)
    report(log, "process_create", process_create(manager or_return 104, program or_return 104) or_return 105)
    _ = slop_os.handle_close(cast[slop_os.Handle](budget))
    log_line.write(log, "%: measured ipc_round_trip, page_fault, thread_create and process_create", NAME)
    return 0
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

/**
 * Measure round trips to a thread that echoes.
 *
 * @param budget The memory budget the channel, ports and thread are charged to.
 * @return The time of one round trip, in nanoseconds, averaged over ROUNDS; or null if setting up failed or a round
 *     trip did, or an answer wasn't what was sent.
 */
ipc_round_trip :: fn(budget: slop_os.MemoryBudget) -> u64? {
    block :: slop_os.startup_block()
    pair :: slop_os.channel_create(budget, 0, 0) or_return null
    echoing :: runtime.new(Echo)
    echoing.end = pair.b
    echoing.port = slop_os.port_create(budget) or_return null
    slop_os.port_bind(echoing.port, cast[slop_os.Handle](pair.b), slop_os.SIGNAL_READABLE, ECHO_KEY, .Persistent) or_return null
    port :: slop_os.port_create(budget) or_return null
    slop_os.port_bind(port, cast[slop_os.Handle](pair.a), slop_os.SIGNAL_READABLE, ANSWER_KEY, .Persistent) or_return null
    thread :: test_kit.start_thread(budget, cast[u64](echo), cast[u64](echoing)) or_return null
    for i in cast[u64](0)..<WARM_UP {
        echoed :: round_trip(pair.a, port, i) or_return null
        if !echoed {
            return null
        }
    }
    start :: test_kit.clock_now()
    for i in cast[u64](0)..<ROUNDS {
        echoed :: round_trip(pair.a, port, i) or_return null
        if !echoed {
            return null
        }
    }
    took :: test_kit.clock_now() - start
    _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
    _ = slop_os.handle_close(cast[slop_os.Handle](thread))
    _ = slop_os.handle_close(cast[slop_os.Handle](port))
    return took / ROUNDS
}

/**
 * Send a value to the echoing thread, and wait for its answer.
 *
 * @param end The measuring thread's end.
 * @param port The port end is bound to for Readable.
 * @param value Any value, sent as one 8-byte message; the round's index, so an echo of an earlier round doesn't
 *     match.
 * @return Whether the answer was value; or null if writing failed, or reading failed other than finding nothing.
 */
round_trip :: fn(end: slop_os.Channel, port: slop_os.Port, value: u64) -> bool? {
    sent : u64[1]
    sent[0] = value
    slop_os.channel_write(end, view_of(cast[ptr[u8]](&sent[0]), 8), slop_os.NO_BATCH) or_return null
    answer : u64[1]
    loop {
        match slop_os.channel_read(end, view_of(cast[ptr[mut u8]](&answer[0]), 8), cast[ptr[mut u32]](0)) {
            case Ok(info) => return answer[0] == value
            case Error(error) => {
                if error != .Empty {
                    return null
                }
                packets : slop_os.Packet[1]
                _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
            }
        }
    }
}

/**
 * Measure touching pages of anonymous memory for the first time.
 *
 * @param budget The memory budget the memory is charged to.
 * @return The time of one touch, in nanoseconds, averaged over PAGES; or null if the memory couldn't be made or
 *     mapped.
 */
page_fault :: fn(budget: slop_os.MemoryBudget) -> u64? {
    block :: slop_os.startup_block()
    memory :: slop_os.memory_create(budget, PAGES * PAGE) or_return null
    address :: runtime.reserve_addresses(cast[usize](PAGES * PAGE)) or_return null
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(memory, block.space, address, 0, PAGES * PAGE, read_write) or_return null
    start :: test_kit.clock_now()
    for page in cast[u64](0)..<PAGES {
        intrinsics.volatile_store_u8(cast[ptr[mut u8]](address + page * PAGE), 1)
    }
    took :: test_kit.clock_now() - start
    _ = slop_os.memory_unmap(block.space, address)
    _ = slop_os.handle_close(cast[slop_os.Handle](memory))
    return took / PAGES
}

/**
 * Measure making threads, starting them, and seeing them end.
 *
 * @param budget The memory budget the threads and the port are charged to.
 * @return The time of one thread, in nanoseconds, averaged over THREADS; or null if the port or a thread couldn't be
 *     made, or a thread couldn't be watched.
 */
thread_create :: fn(budget: slop_os.MemoryBudget) -> u64? {
    port :: slop_os.port_create(budget) or_return null
    start :: test_kit.clock_now()
    for i in cast[u64](0)..<THREADS {
        thread :: test_kit.start_thread(budget, cast[u64](ends), 0) or_return null
        // A key of its own, a fired Once binding keeping its key; gone already, it ended before it could be watched
        match slop_os.port_bind(port, cast[slop_os.Handle](thread), slop_os.SIGNAL_TERMINATED, ENDED_KEY + i, .Once) {
            case Ok => {
                packets : slop_os.Packet[1]
                _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
            }
            case Error(error) => if error != .ObjectGone {
                return null
            }
        }
        _ = slop_os.handle_close(cast[slop_os.Handle](thread))
    }
    took :: test_kit.clock_now() - start
    _ = slop_os.handle_close(cast[slop_os.Handle](port))
    return took / THREADS
}

/**
 * Measure launching copies of the program through the manager, each ending at once, given nothing, and seen to.
 *
 * Each copy's budget is waited for, up to a second, to come back to nothing before the next, and that's in the time.
 *
 * @param loader The process manager connection.
 * @param executable The test's own module, which the copies run.
 * @return The time of one process, in nanoseconds, averaged over PROCESSES; or null if a port or a launch failed.
 */
process_create :: fn(loader: os.Channel[process_manager.ProcessManager], executable: slop_os.Memory) -> u64? {
    block :: slop_os.startup_block()
    manager_port :: os.port_for(block.budget, loader.end) or_return null
    port :: slop_os.port_create(block.budget) or_return null
    start :: test_kit.clock_now()
    for i in cast[u64](0)..<PROCESSES {
        launched :: os.launch(loader, manager_port, "test_perf copy", executable, COPY_BUDGET, takes_nothing, NoGrants.{},
            os.LaunchOptions.{watch = os.LaunchWatch.{port = port, key = ENDED_KEY + i}}) or_return null
        packets : slop_os.Packet[1]
        _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
        _ = slop_os.handle_close(cast[slop_os.Handle](launched.process))
        _ = test_kit.wait_for_budget(launched.budget, 0, 1_000_000_000)
        _ = slop_os.handle_close(cast[slop_os.Handle](launched.budget))
    }
    took :: test_kit.clock_now() - start
    _ = slop_os.handle_close(cast[slop_os.Handle](port))
    return took / PROCESSES
}
