/**
 * test_exits (decisions/0068, 0098): how a program ends when it can't start, seen by whoever started it. Two copies
 * of the program, each watched until it ends:
 * - one launched through the process manager as if its entry took nothing, given no grants, ends with
 *   EXIT_MISSING_GRANT (126), as its real entry requires its debug log;
 * - one built with the process builder directly, its startup block saying an ABI version that isn't the kernel's,
 *   ends with EXIT_WRONG_ABI (125) before its entry runs.
 * What both had comes back to its budget. And a launch refused, its watch's key still the first copy's, gives back
 * what it made for the copy, so its starter's budget is charged no more than before.
 */
package test_exits

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import test_kit from "../../test_kit"
import process_builder from "../../process_builder"
import random_stream from "../../random_stream"

/** The test's name, which starts each line it logs. */
NAME :: "test_exits"
/** Each copy's memory budget, in bytes: 4 MiB. */
COPY_BUDGET : u64 : 4 << 20
/** The key the first copy's watch queues its end under, which the refused launch asks for again. */
WATCH_KEY : u64 : 1
/** The key the second copy's watch queues its end under: its own, as a binding keeps its key after it fires. */
BUILT_KEY : u64 : 2

/**
 * Stand for an entry that takes nothing, which the copy's isn't, so the launch gives it no grants.
 *
 * @return 0, though it never runs: the copy runs main.
 */
takes_nothing :: fn() -> int {
    return 0
}

/** The grants of an entry that takes nothing: none. */
NoGrants :: struct {}

/**
 * Check how a copy of the program ends when it can't start, and that a refused launch gives back what it made.
 *
 * @param log The debug log, writable, where the test says what it found and which check failed.
 * @param platform Not used.
 * @param test_device Not used.
 * @param firmware Not used.
 * @param manager The process manager, which launches the first copy; without it the test ends with 101.
 * @param program The test's own module, which both copies run; without it the test ends with 100.
 * @param peer Not used: the copies never get as far as their entry.
 * @param cpu_budget Not used.
 * @return 0 if every check passed. Otherwise the first that failed: 1 if the copy without grants didn't end with
 *     EXIT_MISSING_GRANT, or 2 its budget didn't come back to nothing; 3 if the copy told another ABI version didn't
 *     end with EXIT_WRONG_ABI, or 4 its budget didn't come back; 5 if the launch asking for a key in use wasn't
 *     refused, or 6 it left a copy's budget charged. 102 to 111 if setting up failed: 102 and 103 the ports, 104 the
 *     first launch, 105 to 110 building the second copy, 111 reading the budget.
 */
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    block :: slop_os.startup_block()
    executable :: program or_return 100
    loader :: manager or_return 101
    manager_port :: os.port_for(block.budget, loader.end) or_return 102
    port :: slop_os.port_create(block.budget) or_return 103
    results : u64[6]

    // Launched with nothing, though its entry requires its log
    launched :: os.launch(loader, manager_port, "test_exits without grants", executable, COPY_BUDGET, takes_nothing, NoGrants.{},
        os.LaunchOptions.{watch = os.LaunchWatch.{port = port, key = WATCH_KEY}}) or_return 104
    results[0] = ended_with(port)
    _ = slop_os.handle_close(cast[slop_os.Handle](launched.process))
    results[1] = if test_kit.wait_for_budget(launched.budget, 0, 1_000_000_000) { cast[u64](1) } else { cast[u64](0) }
    _ = slop_os.handle_close(cast[slop_os.Handle](launched.budget))

    // Refused: the first copy's binding keeps WATCH_KEY after it fired
    before :: (slop_os.memory_budget_info(block.budget) or_return 111).used
    refused :: os.launch(loader, manager_port, "test_exits refused", executable, COPY_BUDGET, takes_nothing, NoGrants.{},
        os.LaunchOptions.{watch = os.LaunchWatch.{port = port, key = WATCH_KEY}}) is_error
    after :: (slop_os.memory_budget_info(block.budget) or_return 111).used
    results[4] = if refused { cast[u64](1) } else { cast[u64](0) }
    results[5] = if after < before + COPY_BUDGET { cast[u64](1) } else { cast[u64](0) }

    // Built here, its startup block saying another ABI version
    budget :: slop_os.memory_budget_create(block.budget, COPY_BUDGET) or_return 105
    process :: slop_os.process_create(budget) or_return 106
    space :: slop_os.address_space_create(budget) or_return 107
    slop_os.port_bind(port, cast[slop_os.Handle](process), slop_os.SIGNAL_TERMINATED, BUILT_KEY, .Once) or_return 108
    size :: slop_os.memory_size(executable) or_return 109
    address :: runtime.reserve_addresses(cast[usize](size)) or_return 109
    slop_os.memory_map(executable, block.space, address, 0, size, slop_os.PROTECTION_READ) or_return 109
    file :: view_of(cast[ptr[u8]](address), cast[usize](size))
    stream := random_stream.make(block.seed)
    seed : u8[32]
    random_stream.fill(&stream, seed)
    target :: process_builder.Target.{process = process, space = space, budget = budget}
    no_grants : process_builder.Grant[1]
    thread :: process_builder.build(target, file, view_of(&no_grants[0], 0), seed, &stream, null, slop_os.ABI_VERSION + 1)
        or_return 110
    results[2] = ended_with(port)
    _ = slop_os.memory_unmap(block.space, address)
    // thread is the copy's thread's ID in its own process, not a handle of this one's, so there's nothing to close
    _ = slop_os.handle_close(cast[slop_os.Handle](process))
    results[3] = if test_kit.wait_for_budget(budget, 0, 1_000_000_000) { cast[u64](1) } else { cast[u64](0) }
    _ = slop_os.handle_close(cast[slop_os.Handle](budget))

    expected :: u64.[cast[u64](slop_os.EXIT_MISSING_GRANT), 1, cast[u64](slop_os.EXIT_WRONG_ABI), 1, 1, 1]
    failed :: test_kit.check(log, NAME, results, expected)
    if failed == 0 {
        log_line.write(log, "%: a copy missing a grant it requires ended with 126, one told another ABI version with 125, and a refused launch gave its budget back", NAME)
    }
    return failed
}

/**
 * Wait for a watched process to end, and tell how.
 *
 * @param port The port its watch, for SIGNAL_TERMINATED, queues on; nothing else may be bound to it.
 * @return The process's exit code, or 0xffff if the wait failed.
 */
ended_with :: fn(port: slop_os.Port) -> u64 {
    packets : slop_os.Packet[1]
    taken :: slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_else 0
    return if taken == 1 { packets[0].data[1] } else { cast[u64](0xffff) }
}
